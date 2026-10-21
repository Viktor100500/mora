import XCTest
import FinanceCore
@testable import Mora

@MainActor
final class ChangeDescriptionTests: XCTestCase {
    private func fixture() -> Ledger {
        var ledger = Ledger.empty
        ledger.preferences.automaticRates = false
        ledger.accounts = [Account(name: "Synthetic EUR", currency: "EUR")]
        ledger.transactions = [FinanceCore.Transaction(date: Date(timeIntervalSince1970: 1_792_368_000), merchant: "Synthetic cafe", amount: -14.70,
                                                       accountID: ledger.accounts[0].id, categoryID: ledger.categories[0].id)]
        return ledger
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoraDescriptionTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testCategoryChangeNamesPurchaseAndBothCategories() async {
        let before = fixture(); var after = before
        after.transactions[0].categoryID = after.categories[1].id
        let result = ChangeDescriptions.between(before, after)
        XCTAssertEqual(result.title, L("Изменение категории операции"))
        XCTAssertTrue(result.detail.contains("Synthetic cafe"))
        XCTAssertTrue(result.detail.contains("Продукты → Кафе и рестораны"))
        XCTAssertTrue(result.detail.contains("€"))
    }
    func testDeletionAndMultipleAdditionsHaveAccurateCountsAndBoundedExamples() async {
        let before = fixture(); var removed = before
        removed.transactions = []
        XCTAssertEqual(ChangeDescriptions.between(before, removed).title, L("Удаление операции"))
        var after = before
        for index in 0..<5 { var t = before.transactions[0]; t.id = UUID(); t.merchant = "Synthetic \(index)"; after.transactions.append(t) }
        let result = ChangeDescriptions.between(before, after)
        XCTAssertTrue(result.title.contains("5"))
        XCTAssertTrue(result.detail.contains("Synthetic 0"))
        XCTAssertTrue(result.detail.contains("Synthetic 1"))
        XCTAssertFalse(result.detail.contains("Synthetic 4"))
        XCTAssertTrue(result.detail.contains("3"))
    }
    func testAccountAndPreferenceChangesAreDescribedInsteadOfPretendingTheyArePurchases() async {
        let before = fixture(); var after = before
        after.accounts[0].archived = true
        let account = ChangeDescriptions.between(before, after)
        XCTAssertEqual(account.title, L("Изменение счета"))
        XCTAssertTrue(account.detail.contains("Synthetic EUR"))
        XCTAssertTrue(account.detail.contains(L("Перемещен в архив")))
        after = before; after.preferences.showGoals = true
        XCTAssertEqual(ChangeDescriptions.between(before, after).title, L("Раздел «Цели»"))
        after.accounts[0].name = "Renamed"
        XCTAssertEqual(ChangeDescriptions.between(before, after).title, L("Несколько изменений"))
    }
    func testPersistedLegacySnapshotsDescribeUndoAndRedoAndConcreteNotices() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ledger.json")
        let before = fixture(); try LedgerFile.save(before, to: file)
        var after = before; after.transactions[0].amount = -20
        try LedgerFile.save(after, to: file, expected: before)
        let store = FinanceStore(directory: directory)
        await store.load()
        let summary = try XCTUnwrap(store.undoDescription)
        XCTAssertTrue(summary.detail.contains("Synthetic cafe"))
        XCTAssertTrue(summary.detail.contains("→"))
        await store.undo()
        XCTAssertEqual(store.ledger.transactions[0].amount, -14.70)
        XCTAssertEqual(store.redoDescription, summary)
        XCTAssertEqual(store.activeNotice?.message, L("Отменено: \(summary.title)"))
        XCTAssertEqual(store.activeNotice?.detail, summary.detail)
        let restarted = FinanceStore(directory: directory)
        await restarted.load()
        XCTAssertEqual(restarted.redoDescription, summary)
        await restarted.redo()
        XCTAssertEqual(restarted.ledger.transactions[0].amount, -20)
        XCTAssertEqual(restarted.activeNotice?.message, L("Возвращено: \(summary.title)"))
        XCTAssertEqual(restarted.activeNotice?.detail, summary.detail)
        XCTAssertEqual(restarted.notifications.events.first?.detail, summary.detail)
    }
    func testHistoryListsStepsInOrderAndNewBranchClearsRedo() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ledger.json")
        try LedgerFile.save(fixture(), to: file)
        let store = FinanceStore(directory: directory)
        await store.load()
        expectTrue(await store.update { $0.transactions[0].note = "Changed" })
        let first = try XCTUnwrap(store.undoDescription)
        expectTrue(await store.update { $0.accounts[0].name = "Renamed" })
        let second = try XCTUnwrap(store.undoDescription)
        XCTAssertEqual(store.undoDescriptions, [second, first])
        await store.undo(); await store.undo()
        XCTAssertEqual(store.redoDescriptions, [first, second])
        expectTrue(await store.update { $0.transactions[0].merchant = "New branch" })
        XCTAssertNil(store.redoDescription)
        XCTAssertTrue(store.redoDescriptions.isEmpty)
    }
    func testSimilarPurchaseIsNewAndOriginalMayBeDeletedWithoutBlockingSave() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ledger.json")
        var ledger = fixture()
        ledger.transactions[0].externalID = "wallet:" + ledger.transactions[0].id.uuidString.lowercased()
        ledger.transactions[0].recurrenceID = UUID()
        ledger.transactions[0].importBatchID = UUID()
        try LedgerFile.save(ledger, to: file)
        let original = ledger.transactions[0]
        let copy = original.similarTransaction()
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertNil(copy.externalID); XCTAssertNil(copy.recurrenceID); XCTAssertNil(copy.importBatchID)
        XCTAssertEqual(copy.amount, original.amount); XCTAssertEqual(copy.merchant, original.merchant)
        let store = FinanceStore(directory: directory)
        await store.deleteTransaction(original.id)
        expectTrue(await store.saveTransaction(copy))
        XCTAssertEqual(store.ledger.transactions.map(\.id), [copy.id])
        XCTAssertEqual(store.undoDescription?.title, L("Добавление операции"))
        await store.undo()
        XCTAssertTrue(store.ledger.transactions.isEmpty)
        await store.redo()
        XCTAssertEqual(store.ledger.transactions.map(\.id), [copy.id])
    }
    func testEditingADeletedPurchaseStillFailsAndCreatingOnArchivedAccountIsRejected() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ledger.json")
        try LedgerFile.save(fixture(), to: file)
        let store = FinanceStore(directory: directory)
        await store.load()
        let original = store.ledger.transactions[0]
        await store.deleteTransaction(original.id)
        expectFalse(await store.saveTransaction(original, replacing: original.id))
        XCTAssertTrue(store.ledger.transactions.isEmpty)
        expectTrue(await store.update { $0.accounts[0].archived = true })
        expectFalse(await store.saveTransaction(original.similarTransaction()))
        XCTAssertTrue(store.ledger.transactions.isEmpty)
    }
}
