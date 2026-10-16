import XCTest
@testable import FinanceCore

final class ChangeHistoryTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("ledger.json") }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraHistory-\(UUID())")
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "Account", openingBalance: 100)]
        try LedgerFile.save(ledger, to: file)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func read() throws -> Ledger { try LedgerFile.decode(Data(contentsOf: file)) }

    func testTwentyChangesUndoAndRedoSurviveEveryRestart() throws {
        for value in 1...25 { _ = try LedgerFile.mutate(at: file) { $0.accounts[0].openingBalance = Decimal(value) } }
        XCTAssertEqual(try read().undoCount, 20)
        for value in (5...24).reversed() {
            _ = try LedgerFile.undo(at: file, expected: read())
            XCTAssertEqual(try read().accounts[0].openingBalance, Decimal(value))
        }
        XCTAssertEqual(try read().undoCount, 0)
        XCTAssertEqual(try read().redoCount, 20)
        for value in 6...25 {
            _ = try LedgerFile.redo(at: file, expected: read())
            XCTAssertEqual(try read().accounts[0].openingBalance, Decimal(value))
        }
        XCTAssertEqual(try read().undoCount, 20)
        XCTAssertEqual(try read().redoCount, 0)
        XCTAssertEqual(try read().schemaVersion, 4)
        XCTAssertTrue(try read().changeHistory!.undo.allSatisfy { $0.changeHistory == nil })
    }

    func testNewEditClearsRedoAndNoOpPreservesIt() throws {
        _ = try LedgerFile.mutate(at: file) { $0.accounts[0].name = "Changed" }
        let undone = try LedgerFile.undo(at: file, expected: read())
        _ = try LedgerFile.save(undone, to: file, expected: undone)
        _ = try LedgerFile.mutate(at: file) { _ in }
        XCTAssertEqual(try read().redoCount, 1)
        _ = try LedgerFile.mutate(at: file) { $0.accounts[0].name = "New branch" }
        XCTAssertEqual(try read().redoCount, 0)
        XCTAssertThrowsError(try LedgerFile.redo(at: file, expected: read()))
    }

    func testBackupRetainsBothStacksAndRestoringDataCanBeUndone() throws {
        _ = try LedgerFile.mutate(at: file) { $0.accounts[0].name = "First" }
        _ = try LedgerFile.mutate(at: file) { $0.accounts[0].name = "Second" }
        let undone = try LedgerFile.undo(at: file, expected: read())
        let backup = try LedgerFile.decode(LedgerFile.encode(undone))
        XCTAssertEqual(backup.undoCount, 1)
        XCTAssertEqual(backup.redoCount, 1)
        let copiedFile = directory.appendingPathComponent("copy.json")
        try LedgerFile.save(backup, to: copiedFile)
        XCTAssertEqual(try LedgerFile.redo(at: copiedFile, expected: backup).accounts[0].name, "Second")
        let restored = try LedgerFile.save(Ledger.empty, to: file, expected: undone)
        XCTAssertTrue(restored.accounts.isEmpty)
        XCTAssertEqual(try LedgerFile.undo(at: file, expected: restored).accounts[0].name, "First")
    }

    func testStaleUndoAndRedoCannotOverwriteExternalChanges() throws {
        _ = try LedgerFile.mutate(at: file) { $0.accounts[0].name = "First" }
        let stale = try read()
        _ = try LedgerFile.mutate(at: file) { $0.accounts.append(Account(name: "External")) }
        let data = try Data(contentsOf: file)
        XCTAssertThrowsError(try LedgerFile.undo(at: file, expected: stale))
        XCTAssertThrowsError(try LedgerFile.redo(at: file, expected: stale))
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(try LedgerFile.undo(at: file, expected: read()).accounts.count, 1)
    }

    func testAutomaticRatesDoNotConsumeHistoryOrClearRedo() throws {
        _ = try LedgerFile.mutate(at: file) { $0.accounts[0].name = "Changed" }
        _ = try LedgerFile.undo(at: file, expected: read())
        let before = try read()
        let now = Date(timeIntervalSince1970: 1_791_705_600)
        let response = Data(#"{"result":"success","base_code":"USD","time_last_update_unix":1791676800,"time_next_update_unix":1791763200,"rates":{"USD":1,"RUB":100,"EUR":0.8}}"#.utf8)
        let snapshot = try ExchangeRateSnapshot.decodeResponse(response, fetchedAt: now)
        var updated = before
        try updated.applyExchangeRates(snapshot)
        let downloaded = try LedgerFile.save(updated, to: file, expected: before, recordHistory: false)
        XCTAssertEqual(downloaded.undoCount, 0)
        XCTAssertEqual(downloaded.redoCount, 1)
        let redone = try LedgerFile.redo(at: file, expected: read())
        XCTAssertEqual(redone.preferences.exchangeRateSnapshot, snapshot)
        XCTAssertEqual(redone.preferences.rates["EUR"], 125)
        let undone = try LedgerFile.undo(at: file, expected: read())
        XCTAssertEqual(undone.preferences.exchangeRateSnapshot, snapshot)
    }

    func testLegacySettingsDefaultToHiddenWithoutLosingOptionalData() throws {
        var legacy = try read()
        legacy.budgets = [Budget(categoryID: legacy.categories[0].id, limit: 100)]
        legacy.goals = [Goal(name: "Goal", target: 200, deadline: Date(timeIntervalSince1970: 1_800_000_000))]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: LedgerFile.encode(legacy)) as? [String: Any])
        var preferences = try XCTUnwrap(object["preferences"] as? [String: Any])
        for key in ["showBudgets", "showGoals", "showRecurring", "aiAgent"] { preferences.removeValue(forKey: key) }
        object["preferences"] = preferences
        let decoded = try LedgerFile.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(decoded.preferences.showBudgets)
        XCTAssertFalse(decoded.preferences.showGoals)
        XCTAssertFalse(decoded.preferences.showRecurring)
        XCTAssertEqual(decoded.preferences.aiAgent, "chatgpt")
        XCTAssertEqual(decoded.budgets, legacy.budgets)
        XCTAssertEqual(decoded.goals, legacy.goals)
    }

    func testInvalidNestedOrOversizedHistoryIsRejected() throws {
        var ledger = try read()
        var history = LedgerChangeHistory()
        history.undo = Array(repeating: ledger, count: 21)
        ledger.changeHistory = history
        XCTAssertThrowsError(try LedgerFile.encode(ledger))
        history.undo = []
        var nested = try read()
        nested.changeHistory = history
        history.undo = [nested]
        ledger.changeHistory = history
        XCTAssertThrowsError(try LedgerFile.encode(ledger))
    }
    func testPrivacyMasksAbsoluteValuesAndKeepsDatesAndPercentages() {
        XCTAssertEqual(FinancialPrivacy.mask("28\u{00a0}094,64 $"), "••• $")
        XCTAssertEqual(FinancialPrivacy.mask("-481,60 $"), "••• $")
        XCTAssertEqual(FinancialPrivacy.mask("112,42 $ · Visa 0.893894 · 2026-10-10"), "••• $ · Visa ••• · 2026-10-10")
        XCTAssertEqual(FinancialPrivacy.mask("Осталось 200 $ — 32% дохода."), "Осталось ••• $ — 32% дохода.")
        XCTAssertEqual(FinancialPrivacy.mask("Расходы ниже на 12,5%."), "Расходы ниже на 12,5%.")
        XCTAssertEqual(FinancialPrivacy.mask("0 $"), "••• $")
    }
}
