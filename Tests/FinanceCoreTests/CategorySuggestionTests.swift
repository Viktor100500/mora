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

    func testWholeFoodsBankDescriptorsUseGroceriesAndRespectUserChoices() {
        var ledger = Ledger.empty
        let groceries = ledger.categories.first { $0.name == "Продукты" }!.id
        for merchant in ["Whole Foods Market", "Wholefds", "Wholefds Hkn 12345", "WHOLEFDS MKT #12345", "CARD PURCHASE POS*WHOLEFDS MKT #12345"] {
            XCTAssertEqual(ledger.suggestedCategory(merchant: merchant, kind: .expense), groceries, merchant)
        }
        for merchant in ["Wholefdsology", "Notwholefds", "Wholefds12345"] {
            XCTAssertNil(ledger.suggestedCategory(merchant: merchant, kind: .expense), merchant)
        }
        XCTAssertNil(ledger.suggestedCategory(merchant: "Wholefds MKT #12345", kind: .income))
        XCTAssertNil(ledger.suggestedCategory(merchant: "Wholefds MKT #12345", kind: .transfer))

        let account = Account(name: "Test"); ledger.accounts = [account]
        let dining = ledger.categories.first { $0.name == "Кафе и рестораны" }!.id
        ledger.transactions = [Transaction(date: Date(), merchant: "Wholefds MKT #12345", amount: -10,
            accountID: account.id, categoryID: dining)]
        XCTAssertEqual(ledger.suggestedCategory(merchant: "WHOLEFDS MKT #12345", kind: .expense), dining)
        ledger.rules = [CategoryRule(keyword: "wholefds", categoryID: groceries)]
        XCTAssertEqual(ledger.suggestedCategory(merchant: "WHOLEFDS MKT #12345", kind: .expense), groceries)
        ledger.categories.removeAll { $0.id == groceries }
        ledger.rules = []; ledger.transactions = []
        XCTAssertNil(ledger.suggestedCategory(merchant: "Wholefds MKT #12345", kind: .expense))
    }

    func testHistoryReusesStoreDescriptorsButNotUnrelatedNames() {
        var ledger = Ledger.empty
        let account = Account(name: "Test"); ledger.accounts = [account]
        let groceries = ledger.categories.first { $0.name == "Продукты" }!.id
        ledger.transactions = [Transaction(date: Date(), merchant: "Test Deli Market", amount: -10,
            accountID: account.id, categoryID: groceries)]
        for name in ["Test Deli", "TEST DELI STORE", "SQ *Test Deli"] {
            XCTAssertEqual(ledger.historicalCategory(merchant: name, kind: .expense), groceries, name)
        }
        for name in ["Test", "Test Delicatessen", "Other Test Deli", "Test Deli Restaurant"] {
            XCTAssertNil(ledger.historicalCategory(merchant: name, kind: .expense), name)
        }
        XCTAssertNil(ledger.historicalCategory(merchant: "Test Deli", kind: .income))
        ledger.transactions[0].merchant = "Boston Market"
        XCTAssertNil(ledger.historicalCategory(merchant: "Boston", kind: .expense))
    }

    func testDescriptorConflictsStayUncategorizedAndExactHistoryAndRulesWin() {
        var ledger = Ledger.empty
        let account = Account(name: "Test"); ledger.accounts = [account]
        let groceries = ledger.categories.first { $0.name == "Продукты" }!.id
        let dining = ledger.categories.first { $0.name == "Кафе и рестораны" }!.id
        ledger.transactions = [
            Transaction(date: Date(), merchant: "Test Deli Market", amount: -10, accountID: account.id, categoryID: groceries),
            Transaction(date: Date(), merchant: "Test Deli Shop", amount: -5, accountID: account.id, categoryID: dining)
        ]
        XCTAssertNil(ledger.historicalCategory(merchant: "Test Deli", kind: .expense))
        ledger.transactions.append(Transaction(date: Date(), merchant: "Test Deli", amount: -2, accountID: account.id, categoryID: dining))
        XCTAssertEqual(ledger.historicalCategory(merchant: "Test Deli", kind: .expense), dining)
        ledger.rules = [CategoryRule(keyword: "Test", categoryID: groceries)]
        XCTAssertEqual(ledger.historicalCategory(merchant: "Test Deli", kind: .expense), groceries)
    }
}
