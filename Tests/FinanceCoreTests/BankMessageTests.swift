import XCTest
@testable import FinanceCore

final class BankMessageTests: XCTestCase {
    private func parsed(_ text: String, sender: String = "24273", templates: [BankMessageTemplate] = [], file: StaticString = #filePath, line: UInt = #line) throws -> BankMessage.Parsed {
        guard case .parsed(let value) = BankMessage.parse(text, sender: sender, templates: templates) else {
            XCTFail("Not parsed: \(BankMessage.parse(text, templates: templates))", file: file, line: line)
            throw XCTSkip()
        }
        return value
    }

    func testEnglishCardPurchase() throws {
        let value = try parsed("Chase: You made a $12.34 transaction with STARBUCKS 1234 on Chase Sapphire Preferred (...5678) at 8:15AM ET on Nov 4, 2026.")
        XCTAssertEqual(value.amount, Decimal(string: "12.34"))
        XCTAssertEqual(value.currency, "USD")
        XCTAssertEqual(value.merchant, "STARBUCKS 1234")
        XCTAssertEqual(value.cardLast4, "5678")
        XCTAssertEqual(value.direction, .expense)
        XCTAssertFalse(value.automatic)
    }

    func testWalletNotificationIsReadFieldByField() throws {
        let transit = try XCTUnwrap(BankMessage.walletNotification(subtitle: "", body: "Njtransit Paygo Iron, Jersey City, NJ\n$5.45"))
        XCTAssertTrue(transit.wallet)
        XCTAssertFalse(transit.automatic)
        XCTAssertEqual(transit.amount, Decimal(string: "5.45"))
        XCTAssertEqual(transit.currency, "USD")
        XCTAssertEqual(transit.merchant, "Njtransit Paygo Iron")
        let split = try XCTUnwrap(BankMessage.walletNotification(subtitle: "Port Authority of New York & New Jersey, New York, NY", body: "$3.25"))
        XCTAssertEqual(split.merchant, "Port Authority of New York & New Jersey"); XCTAssertEqual(split.amount, Decimal(string: "3.25"))
        let inline = try XCTUnwrap(BankMessage.walletNotification(subtitle: "", body: "Metropolitan Transportation Authority $3.00"))
        XCTAssertEqual(inline.merchant, "Metropolitan Transportation Authority"); XCTAssertEqual(inline.amount, 3)
        XCTAssertNil(BankMessage.walletNotification(subtitle: "", body: "Your card is ready for Apple Pay"))
        XCTAssertEqual(BankMessage.parse("Raiffeisen banka a.d. Beograd\nNjtransit Paygo Iron, Jersey City, NJ\n$5.45"), .ignored(.noTransaction),
                       "bank messages are never read as Wallet notifications")
    }

    private let raiffeisen = """
        Koriscenje kartice 4054**5109
        Datum: 04.11.2026 22:07:20
        Iznos: 8,40 USD
        Raspolozivo: 3.195,32 EUR
        Mesto: NJT BUS MY-TIX NEWARK US
        """

    func testRaiffeisenSerbiaFields() throws {
        let value = try parsed(raiffeisen)
        XCTAssertEqual(value.amount, Decimal(string: "8.4"))
        XCTAssertEqual(value.currency, "USD")
        XCTAssertEqual(value.merchant, "NJT BUS MY-TIX NEWARK")
        XCTAssertEqual(value.cardLast4, "5109")
        XCTAssertEqual(value.direction, .expense)
    }

    func testRaiffeisenMessagesFromOneEvening() throws {
        let cases = [("73,25 USD", "73.25", "NEW YORK STATE DMV ALBANY"), ("3,00 USD", "3", "MTA*NYCT PAYGO NEW YORK"),
                     ("15,48 USD", "15.48", "TARGET STORE T-3385 NEW YORK")]
        for (amount, value, merchant) in cases {
            let message = try parsed("Koriscenje kartice 4054**5109\nDatum: 04.11.2026 20:26:33\nIznos: \(amount)\nRaspolozivo: 3.219,62 EUR\nMesto: \(merchant) US")
            XCTAssertEqual(message.amount, Decimal(string: value))
            XCTAssertEqual(message.merchant, merchant)
            XCTAssertEqual(message.cardLast4, "5109")
        }
    }

    func testRaiffeisenTemplateAcceptsOtherBalancesAndTimes() throws {
        let template = try XCTUnwrap(BankMessageTemplate(learningFrom: raiffeisen, sender: "Raiffeisen", parsed: parsed(raiffeisen, sender: "Raiffeisen")))
        let next = try parsed("""
            Koriscenje kartice 4054**5109
            Datum: 05.11.2026 9:01:07
            Iznos: 1.073,25 USD
            Raspolozivo: 219,62 EUR
            Mesto: NEW YORK STATE DMV ALBANY US
            """, sender: "Raiffeisen", templates: [template])
        XCTAssertTrue(next.automatic)
        XCTAssertEqual(next.amount, Decimal(string: "1073.25"))
        XCTAssertEqual(next.merchant, "NEW YORK STATE DMV ALBANY")
        XCTAssertEqual(next.cardLast4, "5109")
    }

    func testForeignCurrencyAfterAmount() throws {
        let value = try parsed("You spent 1,250.50 EUR at LIDL BEOGRAD with your card ending 4321.")
        XCTAssertEqual(value.amount, Decimal(string: "1250.5"))
        XCTAssertEqual(value.currency, "EUR")
        XCTAssertEqual(value.merchant, "LIDL BEOGRAD")
        XCTAssertEqual(value.cardLast4, "4321")
    }

    func testRussianMessagesWithSeparateMerchantAndPreposition() throws {
        let segments = try parsed("Покупка, карта *1234. 450 RUB. PYATEROCHKA. Доступно 1 200,50 RUB")
        XCTAssertEqual(segments.amount, 450)
        XCTAssertEqual(segments.currency, "RUB")
        XCTAssertEqual(segments.merchant, "PYATEROCHKA")
        XCTAssertEqual(segments.cardLast4, "1234")

        let preposition = try parsed("Оплата 350,90 ₽ в Яндекс Такси, карта •9876")
        XCTAssertEqual(preposition.amount, Decimal(string: "350.9"))
        XCTAssertEqual(preposition.merchant, "Яндекс Такси")
        XCTAssertEqual(preposition.cardLast4, "9876")
    }

    func testRefundIsIncome() throws {
        let value = try parsed("Chase: A $15.00 refund from AMAZON MKTPL was credited to your card ending in 1234.")
        XCTAssertEqual(value.direction, .income)
        XCTAssertEqual(value.merchant, "AMAZON MKTPL")
        XCTAssertEqual(value.amount, 15)
    }

    func testCodesFraudChecksDeclinesAndOffersAreIgnored() {
        let cases: [(String, BankMessage.Ignored)] = [
            ("Your Chase verification code is 123456. Don't share it with anyone.", .oneTimeCode),
            ("Код подтверждения: 4821. Никому не сообщайте его.", .oneTimeCode),
            ("Chase Fraud: Did you use card ending 1234 for $45.00 at WALMART on 11/04? Reply YES or NO", .fraudCheck),
            ("Your card ending in 1234 was declined for $20.00 at UBER.", .declined),
            ("Earn a $200 bonus when you open a new checking account today!", .noTransaction),
            ("Your available balance is $1,234.56 as of 11/04.", .noTransaction),
            ("Meeting at 10:30 tomorrow, see you", .noTransaction),
        ]
        for (text, reason) in cases { XCTAssertEqual(BankMessage.parse(text), .ignored(reason), text) }
    }

    func testBalanceAfterPurchaseIsNotTheAmount() throws {
        let value = try parsed("Баланс 5 000 RUB. Списание 120 RUB, карта *1111, METRO")
        XCTAssertEqual(value.amount, 120)
    }

    func testLearnedTemplateBooksTheSameWordingAutomatically() throws {
        let first = "Chase: You made a $12.34 transaction with STARBUCKS 1234 on Chase Sapphire Preferred (...5678) at 8:15AM ET on Nov 4, 2026."
        let template = try XCTUnwrap(BankMessageTemplate(learningFrom: first, sender: "24273", parsed: parsed(first)))
        XCTAssertTrue(template.pattern.contains("{amount}") && template.pattern.contains("{merchant}") && template.pattern.contains("{card}"))

        let next = try parsed("Chase: You made a $1,005.00 transaction with UBER TRIP on Chase Sapphire Preferred (...5678) at 11:02PM ET on Dec 21, 2026.",
                              templates: [template])
        XCTAssertTrue(next.automatic)
        XCTAssertEqual(next.amount, 1005)
        XCTAssertEqual(next.merchant, "UBER TRIP")
        XCTAssertEqual(next.cardLast4, "5678")

        let other = BankMessage.parse("Chase: A $15.00 refund from AMAZON was credited to your card ending in 1234.", templates: [template])
        guard case .parsed(let refund) = other else { return XCTFail("\(other)") }
        XCTAssertFalse(refund.automatic)
        XCTAssertNil(template.match(next.merchantText, sender: "other"))
        XCTAssertNil(BankMessageTemplate(sender: "CHASE", pattern: template.pattern, direction: .expense)
            .match("Chase: You made a $5.00 transaction with UBER on Chase Sapphire Preferred (...5678) at 1:00PM ET on Dec 1, 2026.", sender: "WISE"))
    }

    func testTemplateNeedsTheConfirmedMerchantInTheText() throws {
        var value = try parsed("You spent 12.50 EUR at LIDL with your card ending 4321.")
        value.merchantText = "Lidl Serbia"
        XCTAssertNil(BankMessageTemplate(learningFrom: "You spent 12.50 EUR at LIDL with your card ending 4321.", sender: "", parsed: value))
    }
}
