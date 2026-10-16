import XCTest
@testable import FinanceCore

final class ImportHistoryTests: XCTestCase {
    private func ledger() -> Ledger {
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "Основной", openingBalance: 100), Account(name: "Сбережения")]
        return ledger
    }
    private func prepare(_ csv: String, ledger: Ledger, excluded: Set<Int> = []) throws -> CSVImportResult {
        let table = try CSVTable.parse(csv)
        var mapping = CSVMapping(headers: table.headers, defaultAccountID: ledger.accounts[0].id)
        mapping.excludedRows = excluded
        return try CSVImporter.prepare(table, mapping: mapping, ledger: ledger)
    }
    private func apply(_ csv: String, to ledger: inout Ledger, filename: String = "test.csv") throws -> ImportBatch {
        let existing = Set(ledger.transactions.map(\.id))
        let result = try prepare(csv, ledger: ledger)
        ledger = result.ledger
        return try XCTUnwrap(ledger.recordImport(addedIDs: Set(ledger.transactions.map(\.id)).subtracting(existing), filename: filename,
                                                totalRows: result.rows.count, duplicates: result.duplicates, invalid: result.invalid))
    }
    func testExcludedRowsCreateNoAccountsCategoriesOrErrors() throws {
        let base = ledger()
        let csv = "date,merchant,amount,account,currency,category\n2026-10-10,Skipped,-5,New,RUB,NewCategory\ninvalid,Skipped too,bad,Other,RUB,OtherCategory\n2026-10-10,Included,-3,Основной,RUB,Продукты\n"
        let result = try prepare(csv, ledger: base, excluded: [2, 3])
        XCTAssertEqual(result.imported, 1); XCTAssertEqual(result.excluded, 2); XCTAssertEqual(result.invalid, 0)
        XCTAssertEqual(result.ledger.accounts, base.accounts); XCTAssertEqual(result.ledger.categories, base.categories)
        XCTAssertEqual(result.ledger.transactions.map(\.merchant), ["Included"])
        XCTAssertNotNil(result.rows[1].error); XCTAssertTrue(result.rows[1].excluded)
    }
    func testExcludedIdenticalRowDoesNotConsumeAnExistingMatch() throws {
        var base = ledger()
        _ = try apply("date,merchant,amount\n2026-10-10,MTA,-3\n", to: &base)
        let csv = "date,merchant,amount\n2026-10-10,MTA,-3\n2026-10-10,MTA,-3\n2026-10-10,MTA,-3\n"
        let result = try prepare(csv, ledger: base, excluded: [2])
        XCTAssertEqual(result.excluded, 1); XCTAssertEqual(result.duplicates, 1); XCTAssertEqual(result.imported, 1)
        XCTAssertTrue(result.rows[1].duplicate); XCTAssertFalse(result.rows[2].duplicate)
        let excluded = try prepare(csv, ledger: base, excluded: [2, 3, 4])
        XCTAssertEqual(excluded.imported, 0); XCTAssertEqual(excluded.duplicates, 0); XCTAssertEqual(excluded.ledger, base)
    }
    func testExcludedExternalIDDoesNotSuppressAnIncludedRow() throws {
        let csv = "date,merchant,amount,id\n2026-10-10,MTA,-3,a\n2026-10-10,MTA,-3,a\n"
        let result = try prepare(csv, ledger: ledger(), excluded: [2])
        XCTAssertEqual(result.imported, 1); XCTAssertEqual(result.duplicates, 0)
    }
    func testRowsBeyondOneHundredCanBeExcluded() throws {
        let csv = "date,merchant,amount\n" + (0..<125).map { "2026-10-10,Purchase \($0),-1" }.joined(separator: "\n")
        let result = try prepare(csv, ledger: ledger(), excluded: [126])
        XCTAssertEqual(result.imported, 124); XCTAssertEqual(result.excluded, 1)
        XCTAssertFalse(result.ledger.transactions.contains { $0.merchant == "Purchase 124" })
    }
    func testLegacyLedgerStillLoadsWithoutHistory() throws {
        let legacy = ledger()
        let data = try LedgerFile.encode(legacy)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["imports"])
        let decoded = try LedgerFile.decode(data)
        XCTAssertEqual(decoded, legacy); XCTAssertTrue(decoded.importHistory.isEmpty)
    }
    func testHistorySurvivesRestartAndRollbackOnlyRemovesItsBatch() throws {
        var current = ledger()
        let first = try apply("date,merchant,amount\n2026-10-10,First,-5\n", to: &current, filename: "first.csv")
        let second = try apply("date,merchant,amount\n2026-10-10,Second,-7\n", to: &current, filename: "second.csv")
        let manual = Transaction(date: Dates.parse("2026-10-10")!, merchant: "Manual", amount: -2, accountID: current.accounts[0].id)
        current.transactions.append(manual)
        current = try LedgerFile.decode(LedgerFile.encode(current))
        XCTAssertEqual(current.schemaVersion, 2); XCTAssertEqual(current.importHistory.count, 2)
        let removed = try current.rollbackImport(first.id)
        XCTAssertEqual(removed, 1); XCTAssertEqual(Set(current.transactions.map(\.id)), Set([second.transactions[0].id, manual.id]))
        XCTAssertNotNil(current.importHistory.first { $0.id == first.id }?.rolledBackAt)
        XCTAssertNil(current.importHistory.first { $0.id == second.id }?.rolledBackAt)
        XCTAssertThrowsError(try current.rollbackImport(first.id))
    }
    func testEditedAndSplitOperationsRequireExplicitRollbackAndAreTracked() throws {
        var current = ledger()
        let batch = try apply("date,merchant,amount\n2026-10-10,Target,-20\n", to: &current)
        current.transactions[0].categoryID = current.categories[0].id
        var split = current.transactions[0]; split.id = UUID(); split.amount = -8
        current.transactions[0].amount = -12
        current.transactions.append(split)
        let unrelated = Transaction(date: Dates.parse("2026-10-10")!, merchant: "Another", amount: -4, accountID: current.accounts[0].id)
        current.transactions.append(unrelated)
        let before = current
        let preview = try current.importRollbackPreview(batch.id)
        XCTAssertEqual(preview.remaining, 2); XCTAssertEqual(preview.modified, 2)
        XCTAssertThrowsError(try current.rollbackImport(batch.id)); XCTAssertEqual(current, before)
        XCTAssertEqual(try current.rollbackImport(batch.id, allowModified: true), 2)
        XCTAssertEqual(current.transactions, [unrelated])
    }
    func testRollbackOfTransferRestoresBothBalancesAndAllowsReimport() throws {
        var current = ledger()
        let csv = "date,merchant,amount,account,type,to_account\n2026-10-10,Move,-10,Основной,transfer,Сбережения\n"
        let batch = try apply(csv, to: &current)
        XCTAssertEqual(current.balance(current.accounts[0]), 90); XCTAssertEqual(current.balance(current.accounts[1]), 10)
        XCTAssertEqual(try current.rollbackImport(batch.id), 1)
        XCTAssertEqual(current.balance(current.accounts[0]), 100); XCTAssertEqual(current.balance(current.accounts[1]), 0)
        let reimported = try apply(csv, to: &current)
        XCTAssertNotEqual(reimported.id, batch.id); XCTAssertEqual(current.importHistory.count, 2)
    }
    func testRollbackDoesNotRecreateDeletedOperationsOrRemoveCreatedAccounts() throws {
        var current = ledger()
        let batch = try apply("date,merchant,amount,account,currency\n2026-10-10,Purchase,-10,New,RUB\n", to: &current)
        current.transactions = []
        let preview = try current.importRollbackPreview(batch.id)
        XCTAssertEqual(preview.remaining, 0); XCTAssertEqual(preview.missing, 1)
        XCTAssertEqual(try current.rollbackImport(batch.id), 0)
        XCTAssertTrue(current.transactions.isEmpty); XCTAssertNotNil(current.accounts.first { $0.name == "New" })
        XCTAssertNoThrow(try LedgerFile.decode(LedgerFile.encode(current)))
    }
}
