import XCTest
@testable import FinanceCore

final class WalletReviewTests: XCTestCase {
    private func capture(account: UUID, amount: String = "$31.54", currency: String = "", merchant: String = "Test cafe") throws -> CloudCapture {
        let object = ["id": UUID().uuidString, "merchant": merchant, "amount": amount, "currency": currency,
                      "account_id": account.uuidString, "date": "2026-10-16T20:19:00Z", "label": "Настя · Alta · EUR"]
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
}
