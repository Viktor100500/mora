import XCTest
@testable import FinanceCore

final class TransactionTagsTests: XCTestCase {
    private let tags = ["Apple Wallet", "Работа", "личное", "Поездка"]

    func testSuggestionsIncludePersistedTagsAcrossAccountsAndTransactionTypes() throws {
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "One", currency: "USD"), Account(name: "Two", currency: "USD")]
        ledger.transactions = [
            Transaction(date: Date(), merchant: "Purchase", amount: -1, accountID: ledger.accounts[0].id, tags: [" Работа ", "личное"]),
            Transaction(date: Date(), merchant: "Income", amount: 1, accountID: ledger.accounts[1].id, kind: .income, tags: ["работа", "Apple Wallet", ""])
        ]
        let restored = try LedgerFile.decode(LedgerFile.encode(ledger))
        XCTAssertEqual(Set(restored.availableTags), ["Работа", "личное", "Apple Wallet"])
        XCTAssertEqual(TransactionTags.suggestions(for: "", available: restored.availableTags).count, 3)
    }

    func testFiltersCurrentFragmentAndExcludesAlreadySelectedTags() {
        XCTAssertEqual(TransactionTags.suggestions(for: "личное, РАБ", available: tags), ["Работа"])
        XCTAssertEqual(TransactionTags.suggestions(for: "личное, ", available: tags).count, 3)
        XCTAssertEqual(TransactionTags.suggestions(for: "личное", available: tags).count, 3)
        XCTAssertTrue(TransactionTags.suggestions(for: "неизвестный", available: tags).isEmpty)
        XCTAssertTrue(TransactionTags.suggestions(for: "", available: []).isEmpty)
    }

    func testSelectionCompletesFragmentAndKeepsPreviousTags() {
        XCTAssertEqual(TransactionTags.selecting("Работа", in: "личное, раб", available: tags), "личное, Работа, ")
        XCTAssertEqual(TransactionTags.selecting("Работа", in: "личное", available: tags), "личное, Работа, ")
        XCTAssertEqual(TransactionTags.selecting("Работа", in: "новый, ", available: tags), "новый, Работа, ")
        XCTAssertEqual(TransactionTags.selecting("Работа", in: "", available: tags), "Работа, ")
        XCTAssertEqual(TransactionTags.selecting("Работа", in: "работа, ", available: tags), "работа, ")
    }

    func testFreeTextRemainsAvailableWithoutEmptyOrCaseDuplicateTags() {
        XCTAssertEqual(TransactionTags.parse(" новый, , Новый,\nРабота ,работа, "), ["новый", "Работа"])
    }

    func testAccountDefaultUsesOnlyOrMostRecentlyUsedActiveAccount() {
        var ledger = Ledger.empty
        XCTAssertNil(ledger.suggestedTransactionAccountID)
        let first = Account(name: "One"), second = Account(name: "Two"), archived = Account(name: "Archived", archived: true)
        ledger.accounts = [first, archived]
        XCTAssertEqual(ledger.suggestedTransactionAccountID, first.id)
        ledger.accounts.append(second)
        XCTAssertNil(ledger.suggestedTransactionAccountID)
        ledger.transactions = [
            Transaction(date: Date(), merchant: "One", amount: -1, accountID: second.id),
            Transaction(date: Date(), merchant: "Archived", amount: -1, accountID: archived.id)
        ]
        XCTAssertEqual(ledger.suggestedTransactionAccountID, second.id)
        ledger.accounts.removeAll { $0.id == second.id }
        XCTAssertEqual(ledger.suggestedTransactionAccountID, first.id)
    }
}
