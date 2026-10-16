import XCTest
@testable import FinanceCore

final class OnboardingTests: XCTestCase {
    func testNewLedgerHasNoDemoDataAndUsesChosenReportingCurrency() throws {
        let ledger = try Ledger.personal(baseCurrency: "EUR")
        XCTAssertTrue(ledger.accounts.isEmpty)
        XCTAssertTrue(ledger.transactions.isEmpty)
        XCTAssertTrue(ledger.importHistory.isEmpty)
        XCTAssertTrue(ledger.goals.isEmpty)
        XCTAssertTrue(ledger.recurring.isEmpty)
        XCTAssertNil(ledger.changeHistory)
        XCTAssertFalse(ledger.categories.isEmpty)
        XCTAssertEqual(ledger.preferences.baseCurrency, "EUR")
        XCTAssertEqual(ledger.preferences.rates, ["EUR": 1])
        XCTAssertEqual(try LedgerFile.decode(LedgerFile.encode(ledger)), ledger)
    }
    func testUnsupportedReportingCurrencyCannotInitializeLedger() {
        XCTAssertThrowsError(try Ledger.personal(baseCurrency: "INVALID"))
    }
}
