import XCTest
@testable import FinanceCore

final class CategorySuggestionTests: XCTestCase {
    func testMerchantVocabularyAndUnknownMerchant() {
        let ledger = Ledger.empty
        let dining = ledger.categories.first { $0.name == "Кафе и рестораны" }!.id
        XCTAssertEqual(ledger.suggestedCategory(merchant: "Raising Canes 0981", kind: .expense), dining)
        XCTAssertNil(ledger.suggestedCategory(merchant: "Unknown merchant", kind: .expense))
        XCTAssertNil(ledger.suggestedCategory(merchant: "Raising Canes", kind: .income))
        XCTAssertNil(ledger.suggestedCategory(merchant: "Raising Canes", kind: .transfer))
        XCTAssertNil(ledger.suggestedCategory(merchant: "Supercafeology", kind: .expense))
    }
    func testHistoryAndExplicitRulesTakePriorityOverVocabulary() {
        var ledger = Ledger.empty
        let first = ledger.categories[0].id, second = ledger.categories[1].id
        let account = Account(name: "Test"); ledger.accounts = [account]
        ledger.transactions = [Transaction(date: Date(), merchant: "Raising Canes 0981", amount: -10, accountID: account.id, categoryID: first)]
        XCTAssertEqual(ledger.suggestedCategory(merchant: "RAISING CANES 0981", kind: .expense), first)
        ledger.rules = [CategoryRule(keyword: "Canes", categoryID: second)]
        XCTAssertEqual(ledger.suggestedCategory(merchant: "Raising Canes 0981", kind: .expense), second)
    }
}
