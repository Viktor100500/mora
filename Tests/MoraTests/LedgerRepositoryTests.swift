import XCTest
import FinanceCore
import Darwin
@testable import Mora

@MainActor
final class LedgerRepositoryTests: XCTestCase {
    private func fixture() async throws -> (FinanceStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraActorTest-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var ledger = Ledger.empty
        ledger.preferences.automaticRates = false
        ledger.accounts = [Account(name: "Original")]
        try LedgerFile.encode(ledger).write(to: directory.appendingPathComponent("ledger.json"))
        let store = FinanceStore(directory: directory)
        await store.load()
        return (store, directory)
    }

    func testConcurrentCommitsPreserveEveryEditAndPublishTheNewestSnapshot() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = store.ledger
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<16 {
                group.addTask { await store.update { $0.accounts.append(Account(name: "Account \(index)")) } }
            }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        await store.reloadFromDisk()
        XCTAssertEqual(successes, 16)
        XCTAssertEqual(store.ledger.accounts.count, 17)
        XCTAssertEqual(original.accounts.count, 1)
        let saved = try LedgerFile.decode(Data(contentsOf: store.fileURL))
        XCTAssertEqual(saved, store.ledger)
        XCTAssertEqual(saved.undoCount, 16)
        await store.notifications.flush()
    }

    func testExternalEditIsReadBeforeTheNextCommitAndFailureDoesNotWrite() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = store.fileURL
        _ = try await BackgroundWork.shared.perform {
            try LedgerFile.mutate(at: url) { $0.accounts.append(Account(name: "External")) }
        }
        expectTrue(await store.update { $0.accounts[0].name = "Local" })
        XCTAssertEqual(store.ledger.accounts.map(\.name), ["Local", "External"])
        let before = try Data(contentsOf: url)
        expectFalse(await store.update { $0.accounts[0].name = "" })
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(store.ledger.accounts[0].name, "Local")
        await store.notifications.flush()
    }

    func testRepositoryMutationsAndBackgroundCalculationsLeaveTheMainThread() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LedgerRepository(fileURL: store.fileURL, forcedDemo: false)
        let mutation = try await repository.mutate { _ in Thread.isMainThread }
        XCTAssertFalse(mutation.value)
        let calculationUsedMain = await BackgroundWork.shared.perform { Thread.isMainThread }
        XCTAssertFalse(calculationUsedMain)
        await store.notifications.flush()
    }

    func testTransactionSaveWaitsForDiskLockWithoutBlockingUIOrPublishingEarly() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = Darwin.open(store.fileURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        // A bounded fallback also makes a regression fail instead of hanging.
        let release = DispatchWorkItem { flock(descriptor, LOCK_UN) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: release)
        defer { release.cancel(); flock(descriptor, LOCK_UN) }
        let value = FinanceCore.Transaction(date: Date(), merchant: "Synthetic purchase", amount: -12,
                                            accountID: store.ledger.accounts[0].id)
        let began = ContinuousClock.now
        let save = Task { await store.saveTransaction(value) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertLessThan(began.duration(to: .now), .seconds(1), "The UI actor must run while the writer waits")
        XCTAssertTrue(store.ledger.transactions.isEmpty, "Publish only after the durable write completes")
        release.cancel()
        flock(descriptor, LOCK_UN)
        expectTrue(await save.value)
        XCTAssertEqual(store.ledger.transactions.map(\.id), [value.id])
        let saved = try LedgerFile.decode(Data(contentsOf: store.fileURL))
        XCTAssertEqual(saved.transactions.map(\.id), [value.id])
        await store.notifications.flush()
    }

    func testAutomaticRefreshDoesNotConsumeAnUndoStep() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LedgerRepository(fileURL: store.fileURL, forcedDemo: false)
        _ = try await repository.mutate(recordHistory: false) { $0.preferences.rates["USD"] = 90 }
        let edited = try await repository.mutate { $0.accounts[0].name = "Renamed" }
        XCTAssertEqual(edited.snapshot.ledger.undoCount, 1)
        let undo = try await repository.moveHistory(undo: true)
        XCTAssertEqual(undo.ledger.accounts[0].name, "Original")
        XCTAssertEqual(undo.ledger.preferences.rates["USD"], 90)
        await store.notifications.flush()
    }

    func testTerminationDrainsWritesAndRejectsNewEdits() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        expectTrue(await store.update { $0.accounts[0].name = "Accepted" })
        store.beginTermination()
        await store.finishPendingWrites()
        expectFalse(await store.update { $0.accounts[0].name = "Too late" })
        let saved = try LedgerFile.decode(Data(contentsOf: store.fileURL))
        XCTAssertEqual(saved.accounts[0].name, "Accepted")
        XCTAssertEqual(store.ledger, saved)
    }

    func testHistoryDoesNotUndoANewerChangeAfterSuspension() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LedgerRepository(fileURL: store.fileURL, forcedDemo: false)
        let first = try await repository.mutate { $0.accounts[0].name = "First edit" }
        _ = try await repository.mutate { $0.accounts[0].name = "Newer edit" }
        do {
            _ = try await repository.moveHistory(undo: true, expectedToken: first.snapshot.token)
            XCTFail("An old Undo must not undo a newer change")
        } catch { }
        let latest = try await repository.load()
        XCTAssertEqual(latest.ledger.accounts[0].name, "Newer edit")
        XCTAssertEqual(latest.ledger.undoCount, 2)
        await store.notifications.flush()
    }
}
