import XCTest
@testable import FinanceCore

final class SameCurrencyFeeTests: XCTestCase {
    func testExistingExpensesRepriceFromOriginalAndCanBeRestored() throws {
        var ledger = Ledger.empty; let account = Account(name: "USD", currency: "USD")
        ledger.accounts = [account]
        ledger.transactions = [Transaction(date: .now, merchant: "Transit", amount: -3, accountID: account.id),
            Transaction(date: .now, merchant: "Income", amount: 100, accountID: account.id, kind: .income)]
        try ledger.setPurchaseFee(2, accountID: account.id)
        XCTAssertEqual(ledger.transactions[0].amount, Decimal(string: "-3.06"))
        XCTAssertEqual(ledger.transactions[0].sameCurrencyFee?.originalAmount, -3)
        XCTAssertEqual(ledger.transactions[1].amount, 100)
        try ledger.setPurchaseFee(3, accountID: account.id)
        XCTAssertEqual(ledger.transactions[0].amount, Decimal(string: "-3.09"))
        try ledger.setPurchaseFee(0, accountID: account.id)
        XCTAssertEqual(ledger.transactions[0].amount, -3)
        XCTAssertNil(ledger.transactions[0].sameCurrencyFee)
        try ledger.validate()
    }

    func testApplicationIsIdempotentAndRoundTrips() throws {
        var ledger = Ledger.empty; var account = Account(name: "USD", currency: "USD"); account.sameCurrencyFeePercent = 2
        ledger.accounts = [account]
        let value = Transaction(date: .now, merchant: "Transit", amount: Decimal(string: "-4.20")!, accountID: account.id)
        let applied = try ledger.applyingPurchaseFee(to: value)
        XCTAssertEqual(applied.amount, Decimal(string: "-4.28"))
        XCTAssertEqual(try ledger.applyingPurchaseFee(to: applied), applied)
        ledger.transactions = [applied]; try ledger.validate()
        let decoded = try LedgerFile.decode(LedgerFile.encode(ledger))
        XCTAssertEqual(decoded.schemaVersion, 5)
        XCTAssertEqual(decoded.transactions[0].sameCurrencyFee, applied.sameCurrencyFee)
    }

    func testCloudMergeNeverDowngradesNewFeeMetadata() throws {
        var base = Ledger.empty; let account = Account(name: "USD", currency: "USD"); base.accounts = [account]
        base.transactions = [Transaction(date: .now, merchant: "Test", amount: -3, accountID: account.id)]
        var changed = base
        try changed.setPurchaseFee(2, accountID: account.id)
        let merged = try CloudMerge.merge(base: base, local: changed, remote: base)
        XCTAssertEqual(CloudMerge.shared(merged).schemaVersion, 5)
        XCTAssertEqual(merged.transactions[0].amount, Decimal(string: "-3.06"))
        XCTAssertNotNil(merged.transactions[0].sameCurrencyFee)
    }

    func testForeignRateChangeUsesSavedRateAndDoesNotApplySameCurrencyFee() throws {
        var ledger = Ledger.empty; let account = Account(name: "EUR", currency: "EUR"); ledger.accounts = [account]
        var value = Transaction(date: .now, merchant: "Test", amount: -9, accountID: account.id)
        value.conversion = CardConversion(originalAmount: -10, originalCurrency: "USD", accountCurrency: "EUR", rate: Decimal(string: "0.9")!, date: value.date)
        ledger.transactions = [value]
        try ledger.setPurchaseFee(3, accountID: account.id)
        XCTAssertEqual(ledger.transactions[0], value)
        try ledger.setConversionFee(2, accountID: account.id)
        XCTAssertEqual(ledger.transactions[0].amount, Decimal(string: "-9.18"))
        try ledger.setConversionFee(1, accountID: account.id)
        XCTAssertEqual(ledger.transactions[0].amount, Decimal(string: "-9.09")); try ledger.validate()
    }

    func testImportSnapshotsRepriceWithoutBreakingRollback() throws {
        var ledger = Ledger.empty; let account = Account(name: "USD", currency: "USD"); ledger.accounts = [account]
        let value = Transaction(date: .now, merchant: "Test", amount: -10, accountID: account.id)
        ledger.transactions = [value]
        let batch = try XCTUnwrap(ledger.recordImport(addedIDs: [value.id], filename: "test.csv", totalRows: 1))
        try ledger.setPurchaseFee(2, accountID: account.id)
        XCTAssertEqual(try ledger.importRollbackPreview(batch.id).modified, 0)
        XCTAssertEqual(try ledger.rollbackImport(batch.id), 1)
    }

    func testLegacyForeignSplitIsNotTreatedAsSameCurrencyAndBlocksConversionRepricing() throws {
        var ledger = Ledger.empty; let account = Account(name: "EUR", currency: "EUR"); ledger.accounts = [account]
        ledger.transactions = [Transaction(date: .now, merchant: "Split", amount: -5, accountID: account.id,
                                           note: "Исходная покупка: -10 USD; Visa 0.9 на 2026-11-01.")]
        let original = ledger.transactions[0]
        try ledger.setPurchaseFee(2, accountID: account.id)
        XCTAssertEqual(ledger.transactions[0], original)
        let afterPurchaseFee = ledger
        XCTAssertThrowsError(try ledger.setConversionFee(2, accountID: account.id))
        XCTAssertEqual(ledger, afterPurchaseFee)
    }

    func testSplittingPreservesTotalAndFeeWithoutCompounding() throws {
        var ledger = Ledger.empty; var account = Account(name: "USD", currency: "USD"); account.sameCurrencyFeePercent = 2
        ledger.accounts = [account]
        let original = try ledger.applyingPurchaseFee(to: Transaction(date: .now, merchant: "Test", amount: -10, accountID: account.id))
        var first = original, second = original
        first.amount = Decimal(string: "-3.33")!; second.id = UUID(); second.amount = original.amount - first.amount
        let parts = try ledger.allocatingPurchaseFee(from: original, first: first, second: second)
        ledger.transactions = [parts.0, parts.1]
        XCTAssertEqual(parts.0.amount + parts.1.amount, original.amount)
        XCTAssertEqual(parts.0.sameCurrencyFee!.originalAmount + parts.1.sameCurrencyFee!.originalAmount, -10)
        try ledger.validate(); XCTAssertEqual(try ledger.applyingPurchaseFee(to: parts.0), parts.0)
        try ledger.setPurchaseFee(0, accountID: account.id)
        XCTAssertEqual(ledger.transactions[0].amount + ledger.transactions[1].amount, -10)
    }

    func testCSVImportAddsFeeAndExportCanBeImportedAgainWithoutCompounding() throws {
        var ledger = Ledger.empty; let account = Account(name: "USD", currency: "USD"); ledger.accounts = [account]
        try ledger.setPurchaseFee(2, accountID: account.id)
        let table = try CSVTable.parse("date,merchant,amount,currency,account\n2026-10-09,Metro,-3,USD,USD\n")
        let result = try CSVImporter.prepare(table, mapping: CSVMapping(headers: table.headers), ledger: ledger)
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.rows[0].amount, Decimal(string: "-3.06"))
        XCTAssertEqual(result.ledger.transactions[0].sameCurrencyFee?.originalAmount, -3)
        let exported = try CSVTable.parse(CSVImporter.export(result.ledger))
        let retry = try CSVImporter.prepare(exported, mapping: CSVMapping(headers: exported.headers), ledger: result.ledger)
        XCTAssertEqual(retry.imported, 0); XCTAssertEqual(retry.duplicates, 1)
        var other = ledger
        other.transactions = []
        let restored = try CSVImporter.prepare(exported, mapping: CSVMapping(headers: exported.headers), ledger: other)
        XCTAssertEqual(restored.imported, 1)
        XCTAssertEqual(restored.ledger.transactions.first?.amount, Decimal(string: "-3.06"))
        XCTAssertEqual(restored.ledger.transactions.first?.sameCurrencyFee?.originalAmount, -3)
    }

    func testAutomationAcceptsFeeAwareCSVAndRetryDoesNotDuplicate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraFeeCSV-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ledger.json")
        var ledger = Ledger.empty; let account = Account(name: "USD", currency: "USD"); ledger.accounts = [account]
        try ledger.setPurchaseFee(2, accountID: account.id)
        let original = try ledger.applyingPurchaseFee(to: Transaction(date: Dates.parse("2026-10-09")!, merchant: "Metro", amount: -3, accountID: account.id))
        var exportedLedger = ledger; exportedLedger.transactions = [original]
        try LedgerFile.encode(ledger).write(to: file)
        let automation = MoraAutomation(fileURL: file)
        let args: [String: Any] = ["csv": CSVImporter.export(exportedLedger), "dry_run": false]
        _ = try await automation.runAsync("import_csv", arguments: args)
        let saved = try LedgerFile.decode(Data(contentsOf: file))
        XCTAssertEqual(saved.transactions.first?.amount, Decimal(string: "-3.06"))
        let retry = try await automation.runAsync("import_csv", arguments: args)
        XCTAssertEqual(retry["duplicates"] as? Int, 1)
    }
}
