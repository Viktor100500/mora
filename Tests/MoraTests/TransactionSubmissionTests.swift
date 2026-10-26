import XCTest
import FinanceCore
@testable import Mora

@MainActor
final class TransactionSubmissionTests: XCTestCase {
    private func fixture() async throws -> (FinanceStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraSubmission-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var ledger = Ledger.empty
        ledger.preferences.automaticRates = false
        ledger.preferences.baseCurrency = "USD"; ledger.preferences.rates = ["USD": 1]
        ledger.accounts = [Account(name: "Synthetic", currency: "USD", openingBalance: 100)]
        try LedgerFile.encode(ledger).write(to: directory.appendingPathComponent("ledger.json"))
        let store = FinanceStore(directory: directory)
        await store.load()
        return (store, directory)
    }

    func testSubmissionReturnsBeforeRateLoadsAndTerminationDrainsAcceptedSave() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let value = FinanceCore.Transaction(date: Date(), merchant: "Pending quote", amount: -10, accountID: store.ledger.accounts[0].id)
        var resume: CheckedContinuation<Void, Never>?
        XCTAssertTrue(store.enqueueTransaction(value, prepare: { value in
            await withCheckedContinuation { resume = $0 }
            var prepared = value; prepared.amount = -12
            return prepared
        }))
        XCTAssertTrue(store.activeNotice?.isInProgress == true)
        XCTAssertTrue(store.ledger.transactions.isEmpty)
        XCTAssertFalse(store.enqueueTransaction(value), "A repeated submission cannot commit twice")
        for _ in 0..<100 where resume == nil { try await Task.sleep(for: .milliseconds(5)) }
        let continuation = try XCTUnwrap(resume)
        store.beginTermination()
        var drained = false
        let drain = Task { await store.finishPendingWrites(); drained = true }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(drained, "Quit must wait for the already accepted quote and disk write")
        continuation.resume()
        await drain.value
        XCTAssertEqual(store.ledger.transactions.map(\.amount), [-12])
        let saved = try LedgerFile.decode(Data(contentsOf: store.fileURL))
        XCTAssertEqual(saved.transactions.map(\.id), [value.id])
        XCTAssertEqual(store.notifications.events.count, 1)
        XCTAssertFalse(try XCTUnwrap(store.activeNotice).isInProgress)
        XCTAssertEqual(store.activeNotice?.kind, .success)
        XCTAssertEqual(store.activeNotice?.actions, store.undoNotificationActions)
    }

    func testFailedRateKeepsSubmissionForRetryWithoutAlertOrPartialWrite() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let value = FinanceCore.Transaction(date: Date(), merchant: "Retain me", amount: -10, accountID: store.ledger.accounts[0].id, note: "Original note")
        var attempts = 0
        XCTAssertTrue(store.enqueueTransaction(value, prepare: { value in
            attempts += 1
            if attempts == 1 { throw URLError(.notConnectedToInternet) }
            return value
        }))
        await store.finishPendingWrites()
        XCTAssertTrue(store.ledger.transactions.isEmpty)
        XCTAssertNil(store.error, "Background failure belongs in standard notifications")
        XCTAssertEqual(store.activeNotice?.kind, .error)
        let action = try XCTUnwrap(store.activeNotice?.actions.first)
        XCTAssertTrue(store.canPerformNotificationAction(action))
        store.retryTransactionSave(value.id)
        XCTAssertFalse(store.canPerformNotificationAction(action), "Retry is unavailable during submission")
        await store.finishPendingWrites()
        XCTAssertEqual(store.ledger.transactions.first?.note, "Original note")
        XCTAssertEqual(store.ledger.transactions.first?.id, value.id)
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(store.canPerformNotificationAction(action))
        XCTAssertEqual(store.activeNotice?.kind, .success)
    }

    func testQueuedEditMergesWithConcurrentChangeAndWalletCommitUsesSameProgress() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = FinanceCore.Transaction(date: Date(), merchant: "Before", amount: -10, accountID: store.ledger.accounts[0].id)
        expectTrue(await store.saveTransaction(original))
        var edited = original; edited.merchant = "After"
        XCTAssertTrue(store.enqueueTransaction(edited, original: original, prepare: { value in
            expectTrue(await store.update { $0.transactions[0].note = "Concurrent note" })
            return value
        }))
        await store.finishPendingWrites()
        XCTAssertEqual(store.ledger.transactions[0].merchant, "After")
        XCTAssertEqual(store.ledger.transactions[0].note, "Concurrent note")
        var reviewed: FinanceCore.Transaction?
        let value = FinanceCore.Transaction(date: Date(), merchant: "Wallet", amount: -5, accountID: original.accountID)
        XCTAssertTrue(store.enqueueTransaction(value, review: { reviewed = $0 }))
        await store.finishPendingWrites()
        XCTAssertEqual(reviewed, value)
        XCTAssertEqual(store.ledger.transactions.count, 1, "Wallet commits go through the review operation")
        XCTAssertEqual(store.activeNotice?.kind, .success)
        XCTAssertEqual(store.activeNotice?.actions, [])
    }
}
