import XCTest
import Combine
import FinanceCore
@testable import Mora

@MainActor
final class AppNotificationsTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoraNotifications-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func store(in directory: URL) throws -> FinanceStore {
        var ledger = Ledger.empty
        ledger.preferences.automaticRates = false
        ledger.accounts = [Account(name: "Test account")]
        try LedgerFile.encode(ledger).write(to: directory.appendingPathComponent("ledger.json"))
        return FinanceStore(directory: directory)
    }

    private func capture(_ id: UUID = UUID(), reason: String = "Review test purchase") throws -> CloudCapture {
        let object: [String: Any] = ["id": id.uuidString, "merchant": "Test cafe", "amount": "$31.54", "currency": "",
                                   "account_id": UUID().uuidString, "date": "2026-10-18T12:00:00Z", "reason": reason, "label": "Test phone"]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CloudCapture.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testHistoryAndActionsSurviveRestartAndReadStateDoesNotRemoveEvents() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notification-history.json")
        let history = AppNotifications(fileURL: file)
        let id = UUID()
        history.record("Imported", actions: [.rollbackImport(id), .imports])
        history.record("Copied")
        history.record("Copied")
        XCTAssertEqual(history.unreadCount, 3)
        let restored = AppNotifications(fileURL: file)
        XCTAssertEqual(restored.events.map(\.message), ["Copied", "Copied", "Imported"])
        XCTAssertEqual(restored.events.last?.actions, [.rollbackImport(id), .imports])
        restored.markAllRead()
        let read = AppNotifications(fileURL: file)
        XCTAssertEqual(read.events.count, 3)
        XCTAssertEqual(read.unreadCount, 0)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testHistoryKeepsEveryEventAndReadNoOpDoesNotPublish() {
        let history = AppNotifications()
        for i in 0..<300 { history.record("Event \(i)") }
        XCTAssertEqual(history.events.count, 300)
        history.markAllRead()
        var updates = 0
        let observation = history.objectWillChange.sink { updates += 1 }
        history.markAllRead()
        XCTAssertEqual(updates, 0)
        withExtendedLifetime(observation) {}
    }

    func testDamagedHistoryIsPreserved() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notification-history.json")
        let original = Data("damaged test history".utf8)
        try original.write(to: file)
        let history = AppNotifications(fileURL: file)
        history.record("A new event")
        XCTAssertNotNil(history.storageError)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(history.events.count, 1)
    }

    func testWalletPollingDoesNotDuplicateEventsAndTracksResolutionAndReappearance() throws {
        let history = AppNotifications()
        let household = UUID(), purchase = try capture()
        history.reconcileWallet([purchase], householdID: household)
        history.markAllRead()
        var updates = 0
        let observation = history.objectWillChange.sink { updates += 1 }
        history.reconcileWallet([purchase], householdID: household)
        XCTAssertEqual(updates, 0)
        history.reconcileWallet([], householdID: household)
        XCTAssertTrue(try XCTUnwrap(history.events.first).isResolved)
        history.reconcileWallet([purchase], householdID: household)
        XCTAssertEqual(history.events.count, 1)
        XCTAssertFalse(try XCTUnwrap(history.events.first).isResolved)
        XCTAssertEqual(history.unreadCount, 1)
        XCTAssertEqual(history.events.first?.actions, [.review(purchase.id)])
        withExtendedLifetime(observation) {}
    }

    func testWalletResolutionDoesNotAffectAnotherHousehold() throws {
        let history = AppNotifications()
        let first = UUID(), second = UUID()
        history.reconcileWallet([try capture()], householdID: first)
        history.reconcileWallet([try capture()], householdID: second)
        history.reconcileWallet([], householdID: first)
        XCTAssertTrue(try XCTUnwrap(history.events.first { $0.householdID == first }).isResolved)
        XCTAssertFalse(try XCTUnwrap(history.events.first { $0.householdID == second }).isResolved)
    }

    func testClosingBannerKeepsHistoryAndAccountUndoSurvivesRestart() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try store(in: directory), id = try XCTUnwrap(store.ledger.accounts.first?.id)
        store.setAccountArchived(id, archived: true)
        let action = try XCTUnwrap(store.activeNotice?.actions.first)
        store.notice = nil
        XCTAssertNil(store.activeNotice)
        XCTAssertEqual(store.notifications.events.count, 1)
        let reopened = FinanceStore(directory: directory)
        XCTAssertTrue(reopened.canPerformNotificationAction(action))
        reopened.performHistoryAction(action)
        XCTAssertFalse(try XCTUnwrap(reopened.ledger.account(id)).archived)
        let redo = try XCTUnwrap(reopened.activeNotice?.actions.first)
        XCTAssertTrue(reopened.canPerformNotificationAction(redo))
        reopened.performHistoryAction(redo)
        XCTAssertTrue(try XCTUnwrap(reopened.ledger.account(id)).archived)
    }

    func testOldUndoCannotUndoANewerUnrelatedChange() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try store(in: directory), id = try XCTUnwrap(store.ledger.accounts.first?.id)
        store.setAccountArchived(id, archived: true)
        let oldUndo = try XCTUnwrap(store.activeNotice?.actions.first)
        XCTAssertTrue(store.update { $0.accounts[0].name = "Newer edit" })
        XCTAssertFalse(store.canPerformNotificationAction(oldUndo))
        store.performHistoryAction(oldUndo)
        XCTAssertEqual(store.ledger.accounts[0].name, "Newer edit")
        XCTAssertTrue(store.ledger.accounts[0].archived)
        XCTAssertEqual(store.notifications.events.first?.kind, .error)
    }

    func testNoOpNotificationDoesNotOfferUndoForAnEarlierChange() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try store(in: directory)
        XCTAssertTrue(store.update { $0.accounts[0].name = "An earlier edit" })
        XCTAssertGreaterThan(store.undoCount, 0)
        store.applyRules()
        XCTAssertEqual(store.activeNotice?.actions, [])
    }

    func testEachImportKeepsItsOwnRollbackAction() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try store(in: directory)
        func importCSV(_ merchant: String) throws {
            let table = try CSVTable.parse("date,merchant,amount,currency\n2026-10-18,\(merchant),-10,RUB\n")
            let mapping = CSVMapping(headers: table.headers, defaultAccountID: store.ledger.accounts[0].id)
            XCTAssertTrue(store.importCSV(table, mapping: mapping, filename: "test.csv", expected: store.ledger))
        }
        try importCSV("First")
        let firstAction = try XCTUnwrap(store.activeNotice?.actions.first)
        guard case .rollbackImport(let firstID) = firstAction else { return XCTFail("Missing import action") }
        try importCSV("Second")
        XCTAssertTrue(store.canPerformNotificationAction(firstAction))
        store.rollbackImport(firstID)
        XCTAssertEqual(store.ledger.transactions.map(\.merchant), ["Second"])
        XCTAssertFalse(store.canPerformNotificationAction(firstAction))
        XCTAssertEqual(store.notifications.events.count, 3)
    }
}
