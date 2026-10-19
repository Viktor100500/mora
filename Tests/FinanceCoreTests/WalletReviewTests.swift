import XCTest
@testable import FinanceCore

final class WalletReviewTests: XCTestCase {
    private func capture(account: UUID, amount: String = "$31.54", currency: String = "", merchant: String = "Test cafe") throws -> CloudCapture {
        let object = ["id": UUID().uuidString, "merchant": merchant, "amount": amount, "currency": currency,
                      "account_id": account.uuidString, "date": "2026-10-16T20:19:00Z", "label": "Настя · Alta · EUR"]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CloudCapture.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testPrefillKeepsLinkedAccountAmountTimestampAndSenderWithoutGuessingDollars() throws {
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "Other"), Account(name: "Alta", currency: "EUR")]
        let capture = try capture(account: ledger.accounts[1].id)
        let draft = WalletReviewDraft(capture: capture, ledger: ledger, locale: Locale(identifier: "ru_RU"), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(draft.accountID, ledger.accounts[1].id)
        XCTAssertEqual(draft.amount, "31.54")
        XCTAssertEqual(draft.currency, WalletReviewDraft.unknownCurrency)
        XCTAssertEqual(draft.date, capture.date)
        XCTAssertEqual(draft.merchant, "Test cafe")
        for detail in ["Apple Wallet", "Настя", "20:19"] { XCTAssertTrue(draft.note.contains(detail)) }
        XCTAssertFalse(draft.note.contains("Test cafe"))
        XCTAssertEqual(draft.tags, ["Apple Wallet"])
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
