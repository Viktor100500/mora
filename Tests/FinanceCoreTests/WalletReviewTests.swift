import XCTest
@testable import FinanceCore

final class WalletReviewTests: XCTestCase {
    private func capture(account: UUID, amount: String = "$31.54", currency: String = "", merchant: String = "Test cafe",
                         card: (id: UUID, name: String, linked: Bool)? = nil) throws -> CloudCapture {
        var object: [String: Any] = ["id": UUID().uuidString, "merchant": merchant, "amount": amount, "currency": currency,
                      "account_id": account.uuidString, "date": "2026-10-16T20:19:00Z", "label": "Настя · Alta · EUR"]
        if let card { object["card_id"] = card.id.uuidString; object["card"] = card.name; object["card_linked"] = card.linked }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CloudCapture.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testPrefillKeepsLinkedAccountAmountTimestampAndSenderAndTreatsDollarsAsUSD() throws {
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "Other"), Account(name: "Alta", currency: "EUR")]
        let capture = try capture(account: ledger.accounts[1].id)
        let draft = WalletReviewDraft(capture: capture, ledger: ledger, locale: Locale(identifier: "ru_RU"), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(draft.accountID, ledger.accounts[1].id)
        XCTAssertEqual(draft.amount, "31.54")
        XCTAssertEqual(draft.currency, "USD")
        XCTAssertEqual(draft.date, capture.date)
        XCTAssertEqual(draft.merchant, "Test cafe")
        for detail in ["Apple Wallet", "Настя", "20:19"] { XCTAssertTrue(draft.note.contains(detail)) }
        XCTAssertFalse(draft.note.contains("Test cafe"))
        XCTAssertEqual(draft.tags, ["Apple Wallet"])
    }

    func testAutomaticDollarPurchaseUsesAccountFeeAndStableIdentity() async throws {
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "EUR", currency: "EUR", conversionFeePercent: Decimal(string: "0.23"))]
        let item = try capture(account: ledger.accounts[0].id)
        let candidate = try await WalletReviewDraft.automaticTransaction(for: item, in: ledger) { amount, from, to, date in
            XCTAssertEqual(amount, Decimal(string: "-31.54")); XCTAssertEqual(from, "USD"); XCTAssertEqual(to, "EUR")
            return CardConversion(originalAmount: amount, originalCurrency: from, accountCurrency: to, rate: Decimal(string: "0.9")!, date: date)
        }
        let value = try XCTUnwrap(candidate)
        XCTAssertEqual(value.amount, Decimal(string: "-28.45"))
        XCTAssertEqual(value.conversion?.feePercent, Decimal(string: "0.23"))
        XCTAssertEqual(value.id, item.id); XCTAssertEqual(value.tags, ["Apple Wallet"])
        ledger.transactions.append(value)
        let retry = try await WalletReviewDraft.automaticTransaction(for: item, in: ledger) { _, _, _, _ in
            XCTFail("A committed purchase must retain its saved conversion"); throw LedgerError.invalid("offline")
        }
        XCTAssertEqual(retry, value)
    }
    func testAutomaticSameCurrencyAndIncompletePurchasesNeverFetchRates() async throws {
        var ledger = Ledger.empty; ledger.accounts = [Account(name: "USD", currency: "USD")]
        let account = ledger.accounts[0].id
        for (amount, merchant, expected) in [("$3.00", "Metro", true), ("3.00", "Metro", false), ("$3.00", "", false), ("", "Metro", false), ("31$54", "Metro", false), ("12,34.56", "Metro", false), ("$31.54 USD", "Metro", false)] {
            let value = try await WalletReviewDraft.automaticTransaction(for: try capture(account: account, amount: amount, merchant: merchant), in: ledger) { _, _, _, _ in
                XCTFail("No conversion expected"); throw LedgerError.invalid("offline")
            }
            XCTAssertEqual(value != nil, expected)
            if expected { XCTAssertEqual(value?.amount, -3); XCTAssertNil(value?.conversion) }
        }
        XCTAssertEqual(WalletReviewDraft(capture: try capture(account: account, currency: "CAD"), ledger: ledger).currency, "CAD")
    }

    func testWholeFoodsBankDescriptorIsCategorizedWhenWalletPurchaseIsBooked() async throws {
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "USD", currency: "USD")]
        let item = try capture(account: ledger.accounts[0].id, merchant: "Wholefds Hkn 12345")
        let transaction = try await WalletReviewDraft.automaticTransaction(for: item, in: ledger) { _, _, _, _ in
            XCTFail("A same-currency purchase must not request a rate"); throw CancellationError()
        }
        XCTAssertEqual(try XCTUnwrap(transaction).categoryID, ledger.categories.first { $0.name == "Продукты" }?.id)
    }

    func testExplicitCurrencyAndUnambiguousEuroSymbolArePrefilled() throws {
        var ledger = Ledger.empty; ledger.accounts = [Account(name: "Test", currency: "EUR")]
        let account = ledger.accounts[0].id
        XCTAssertEqual(WalletReviewDraft(capture: try capture(account: account, currency: "usd"), ledger: ledger).currency, "USD")
        XCTAssertEqual(WalletReviewDraft(capture: try capture(account: account, amount: "31,54 €"), ledger: ledger).currency, "EUR")
        XCTAssertEqual(WalletReviewDraft(capture: try capture(account: account, amount: "USD 31.54"), ledger: ledger).currency, "USD")
    }
    func testMissingAmountOrArchivedAccountDoesNotSelectAnUnrelatedAccount() throws {
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "Other"), Account(name: "Archived", archived: true)]
        let draft = WalletReviewDraft(capture: try capture(account: ledger.accounts[1].id, amount: ""), ledger: ledger)
        XCTAssertNil(draft.accountID)
        XCTAssertEqual(draft.amount, "")
    }
    func testReviewedTransactionPreservesEditedFieldsAndConversionWithStableIdentity() throws {
        var ledger = Ledger.empty; ledger.accounts = [Account(name: "EUR", currency: "EUR")]
        let capture = try capture(account: ledger.accounts[0].id)
        let conversion = CardConversion(originalAmount: Decimal(string: "-31.54")!, originalCurrency: "USD", accountCurrency: "EUR", rate: Decimal(string: "0.9")!, date: capture.date)
        var value = Transaction(date: capture.date, merchant: "Edited description", amount: try conversion.convertedAmount(),
                                accountID: ledger.accounts[0].id, categoryID: ledger.categories[0].id,
                                note: "Edited note", tags: ["Apple Wallet", "reviewed"])
        value.conversion = conversion
        let reviewed = try WalletReviewDraft.transaction(value, for: capture, in: ledger)
        XCTAssertEqual(reviewed.id, capture.id)
        XCTAssertEqual(reviewed.externalID, "wallet:" + capture.id.uuidString.lowercased())
        XCTAssertEqual(reviewed.date, capture.date)
        XCTAssertEqual(reviewed.note, value.note)
        XCTAssertEqual(reviewed.tags, value.tags)
        XCTAssertEqual(reviewed.categoryID, value.categoryID)
        XCTAssertEqual(reviewed.conversion, conversion)
        ledger.transactions.append(reviewed)
        XCTAssertNoThrow(try WalletReviewDraft.transaction(value, for: capture, in: ledger))
    }

    func testNewCardPurchaseWaitsForAccountChoiceAndLinkedCardBooksAutomatically() async throws {
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "USD card", currency: "USD")]
        let cardID = UUID()
        let waiting = try capture(account: ledger.accounts[0].id, card: (cardID, "Chase Sapphire", false))
        XCTAssertTrue(waiting.awaitsCardLink)
        XCTAssertEqual(waiting.card, "Chase Sapphire")
        let none = try await WalletReviewDraft.automaticTransaction(for: waiting, in: ledger) { _, _, _, _ in
            XCTFail("A purchase of an unlinked card must not request a rate"); throw CancellationError()
        }
        XCTAssertNil(none)
        let linked = try capture(account: ledger.accounts[0].id, card: (cardID, "Chase Sapphire", true))
        XCTAssertFalse(linked.awaitsCardLink)
        let booked = try await WalletReviewDraft.automaticTransaction(for: linked, in: ledger) { _, _, _, _ in throw CancellationError() }
        XCTAssertEqual(booked?.amount, Decimal(string: "-31.54"))
        XCTAssertFalse(try capture(account: ledger.accounts[0].id).awaitsCardLink)
    }
    func testKnownPurchaseCurrencyNeverUsesAnAmountFromAnotherCurrency() throws {
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "EUR", currency: "EUR"), Account(name: "USD", currency: "USD")]
        let eur = ledger.accounts[0].id, usd = ledger.accounts[1].id
        ledger.transactions = [
            Transaction(date: Date(timeIntervalSince1970: 1000), merchant: "Test shop", amount: -12, accountID: usd),
            Transaction(date: Date(timeIntervalSince1970: 2000), merchant: "Test shop", amount: -20, accountID: eur)
        ]
        let draft = WalletReviewDraft(capture: try capture(account: eur, amount: "", currency: "USD", merchant: "Test shop"), ledger: ledger)
        XCTAssertEqual(draft.prefillAmount, "12")
        XCTAssertEqual(draft.prefillCurrency, "USD")
        ledger.transactions.removeFirst()
        let unmatched = WalletReviewDraft(capture: try capture(account: eur, amount: "", currency: "USD", merchant: "Test shop"), ledger: ledger)
        XCTAssertNil(unmatched.suggestion)
        XCTAssertEqual(unmatched.prefillAmount, "")
        XCTAssertEqual(unmatched.prefillCurrency, "USD")
    }
    func testMissingAmountSuggestsLastPaidAmountAtTheSameMerchantInItsOriginalCurrency() throws {
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "EUR", currency: "EUR"), Account(name: "USD", currency: "USD")]
        let eur = ledger.accounts[0].id, usd = ledger.accounts[1].id
        var converted = Transaction(date: Date(timeIntervalSince1970: 2_000_000), merchant: "OMNY", amount: Decimal(string: "-2.78")!, accountID: eur)
        converted.conversion = CardConversion(originalAmount: -3, originalCurrency: "USD", accountCurrency: "EUR",
                                              rate: Decimal(string: "0.926")!, date: converted.date)
        ledger.transactions = [
            Transaction(date: Date(timeIntervalSince1970: 1_000_000), merchant: "omny", amount: Decimal(string: "-2.90")!, accountID: usd),
            converted,
            Transaction(date: Date(timeIntervalSince1970: 3_000_000), merchant: "PATH", amount: Decimal(string: "-3.25")!, accountID: usd),
            Transaction(date: Date(timeIntervalSince1970: 4_000_000), merchant: "OMNY", amount: 3, accountID: usd, kind: .income),
        ]
        let draft = WalletReviewDraft(capture: try capture(account: eur, amount: "", merchant: " OMNY "), ledger: ledger)
        XCTAssertEqual(draft.amount, "")
        XCTAssertEqual(draft.suggestion?.currency, "USD")
        XCTAssertEqual(Decimal(string: draft.prefillAmount), 3)
        XCTAssertEqual(draft.prefillCurrency, "USD")
        let path = WalletReviewDraft(capture: try capture(account: usd, amount: "$0.00", merchant: "PATH"), ledger: ledger)
        XCTAssertEqual(Decimal(string: path.prefillAmount), Decimal(string: "3.25"))
        XCTAssertEqual(path.prefillCurrency, "USD")
        let priced = WalletReviewDraft(capture: try capture(account: usd, amount: "$4.10", merchant: "OMNY"), ledger: ledger)
        XCTAssertNil(priced.suggestion)
        XCTAssertEqual(priced.prefillAmount, "4.1")
        XCTAssertNil(WalletReviewDraft(capture: try capture(account: usd, amount: "", merchant: "Unknown shop"), ledger: ledger).suggestion)
        XCTAssertNil(WalletReviewDraft(capture: try capture(account: usd, amount: "", merchant: ""), ledger: ledger).suggestion)
    }
}
