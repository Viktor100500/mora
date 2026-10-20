import XCTest
@testable import FinanceCore

final class WalletImportHistoryTests: XCTestCase {
    func testWalletCollectionIsOneUndoStepAndPreservesIndependentEditsAndNeverResurrectsPurchases() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraWalletBatchTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ledger.json")
        var initial = Ledger.empty
        initial.preferences.automaticRates = false
        initial.accounts = [Account(name: "Synthetic account")]
        try LedgerFile.save(initial, to: file)
        let localEdit = try LedgerFile.mutate(at: file) { $0.accounts[0].name = "Independent local edit" }
        var booked = localEdit
        var t1 = Transaction(date: Date(timeIntervalSince1970: 1_792_368_000), merchant: "First phone", amount: -10, accountID: initial.accounts[0].id)
        var t2 = Transaction(date: t1.date.addingTimeInterval(-172800), merchant: "Other phone, other day", amount: -20, accountID: initial.accounts[0].id)
        t1.externalID = "wallet:" + t1.id.uuidString.lowercased()
        t2.externalID = "wallet:" + t2.id.uuidString.lowercased()
        booked.transactions = [t1, t2]
        let applied = try LedgerFile.applyCloud(CloudMerge.shared(booked), at: file, mergeAgainst: localEdit)
        // A background category assignment during loading should be folded into the new import.
        let categorized = try LedgerFile.mutate(at: file) { $0.transactions[0].categoryID = $0.categories[1].id }
        var remote = CloudMerge.shared(applied)
        let batch = try XCTUnwrap(remote.recordImport(addedIDs: [t1.id, t2.id], filename: "Покупки из Apple Shortcuts", source: "Apple Shortcuts", totalRows: 2))
        let collected = try LedgerFile.applyCloud(remote, at: file, mergeAgainst: applied, recordWalletImport: batch.id)
        XCTAssertEqual(collected.transactions.count, 2)
        XCTAssertEqual(collected.importHistory.count, 1)
        XCTAssertEqual(collected.accounts[0].name, "Independent local edit")
        XCTAssertEqual(collected.transactions[0].categoryID, categorized.transactions[0].categoryID)
        XCTAssertEqual(collected.undoCount, 2)
        let undone = try LedgerFile.undo(at: file, expected: collected)
        XCTAssertTrue(undone.transactions.isEmpty); XCTAssertTrue(undone.importHistory.isEmpty)
        XCTAssertEqual(undone.accounts[0].name, "Independent local edit")
        let undoneTwice = try LedgerFile.undo(at: file, expected: undone)
        XCTAssertTrue(undoneTwice.transactions.isEmpty)
        XCTAssertEqual(undoneTwice.accounts[0].name, "Synthetic account")
        let firstRedo = try LedgerFile.redo(at: file, expected: undoneTwice)
        let redone = try LedgerFile.redo(at: file, expected: firstRedo)
        XCTAssertEqual(redone.transactions.count, 2)
        XCTAssertEqual(redone.importHistory.first?.id, batch.id)
        var rollback = redone
        XCTAssertEqual(try rollback.rollbackImport(batch.id, allowModified: true), 2)
        XCTAssertTrue(rollback.transactions.isEmpty)
        XCTAssertEqual(rollback.accounts, redone.accounts)
    }
}
