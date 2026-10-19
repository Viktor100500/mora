import XCTest
@testable import FinanceCore

final class AIImportCSVTests: XCTestCase {
    private let csv = MoraAutomation.csvHeader + "\n\"2026-10-18\",\"Test cafe\",\"-3.20\",\"USD\",\"Test account\",\"Cafe\",\"expense\",\"\",\"\",\"\",\"\",\"\"\n"

    func testFirstLaunchCSVPreviewCommitAndRetryUseNormalImportRules() throws {
        let table = try CSVTable.read(Data(csv.utf8))
        var ledger = try Ledger.personal(baseCurrency: "USD")
        ledger.accounts = [Account(name: "Test account", currency: "USD", openingBalance: 100)]
        var mapping = CSVMapping(headers: table.headers)
        mapping.defaultCurrency = "USD"
        let preview = try CSVImporter.prepare(table, mapping: mapping, ledger: ledger)
        XCTAssertTrue(ledger.transactions.isEmpty)
        XCTAssertEqual(preview.imported, 1)
        XCTAssertEqual(preview.ledger.balance(ledger.accounts[0]), Decimal(string: "96.80"))
        let retry = try CSVImporter.prepare(table, mapping: mapping, ledger: preview.ledger)
        XCTAssertEqual(retry.imported, 0)
        XCTAssertEqual(retry.duplicates, 1)
    }
}
