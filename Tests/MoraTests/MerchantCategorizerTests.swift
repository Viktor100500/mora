import XCTest
import Combine
import FinanceCore
@testable import Mora

@MainActor
final class MerchantCategorizerTests: XCTestCase {
    private func fixture() async throws -> (FinanceStore, UserDefaults, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraCategoryTest-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "Test", currency: "USD")]
        ledger.transactions = [Transaction(date: Date(), merchant: "Test Merchant", amount: -10, accountID: ledger.accounts[0].id)]
        try LedgerFile.encode(ledger).write(to: directory.appendingPathComponent("ledger.json"))
        let preferences = UserDefaults(suiteName: "MoraCategoryTest-\(UUID())")!
        let store = FinanceStore(directory: directory)
        await store.load(); return (store, preferences, directory)
    }
    func testRepeatedUnknownMerchantPollsDoNotPublishOrRepeatLookup() async throws {
        let (store, preferences, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0, updates = 0
        let worker = MerchantCategorizer(preferences: preferences) { _ in calls += 1; return nil }
        await worker.process(store: store)
        let subscription = worker.objectWillChange.sink { updates += 1 }
        for _ in 0..<3 { await worker.process(store: store) }
        XCTAssertEqual(calls, 1); XCTAssertEqual(updates, 0)
        withExtendedLifetime(subscription) {}
    }

    func testHistoryWinsWithoutAnOnlineRequest() async throws {
        let (store, preferences, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let category = store.ledger.categories[0].id
        await store.update { ledger in
            ledger.transactions.append(Transaction(date: Date().addingTimeInterval(-86400), merchant: "TEST MERCHANT", amount: -5,
                accountID: ledger.accounts[0].id, categoryID: category))
        }
        let worker = MerchantCategorizer(preferences: preferences) { _ in XCTFail("History should avoid network"); return nil }
        worker.onlineEnabled = false
        await worker.process(store: store)
        XCTAssertEqual(store.ledger.transactions[0].categoryID, category)
    }
    func testFailureDoesNotAffectSavedPurchaseAndBacksOff() async throws {
        let (store, preferences, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let worker = MerchantCategorizer(preferences: preferences) { _ in calls += 1; throw URLError(.notConnectedToInternet) }
        let before = store.ledger
        await worker.process(store: store); await worker.process(store: store)
        XCTAssertEqual(store.ledger, before); XCTAssertEqual(calls, 1); XCTAssertNotNil(worker.status)
    }
    func testNewHistoryVariantIsUsedEvenAfterACatalogMiss() async throws {
        let (store, preferences, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let worker = MerchantCategorizer(preferences: preferences) { _ in calls += 1; return nil }
        await worker.process(store: store)
        XCTAssertNil(store.ledger.transactions[0].categoryID)
        let category = store.ledger.categories.first { $0.name == "Продукты" }!.id
        await store.update { ledger in
            ledger.transactions.append(Transaction(date: Date().addingTimeInterval(-86400), merchant: "Test Merchant Market", amount: -5,
                accountID: ledger.accounts[0].id, categoryID: category))
        }
        await worker.process(store: store)
        XCTAssertEqual(store.ledger.transactions[0].categoryID, category)
        XCTAssertEqual(calls, 1)
        await store.undo()
        await worker.process(store: store)
        XCTAssertNil(store.ledger.transactions[0].categoryID)
    }
    func testManualEditDuringLookupIsPreserved() async throws {
        let (store, preferences, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let manual = store.ledger.categories[0].id
        let worker = MerchantCategorizer(preferences: preferences) { _ in
            await store.update { $0.transactions[0].categoryID = manual }
            return .shopping
        }
        await worker.process(store: store)
        XCTAssertEqual(store.ledger.transactions[0].categoryID, manual)
    }
    func testUndoIsNotImmediatelyReclassifiedEvenAfterRestart() async throws {
        let (store, preferences, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let worker = MerchantCategorizer(preferences: preferences) { _ in .shopping }
        await worker.process(store: store)
        XCTAssertEqual(store.ledger.transactions[0].categoryID, store.ledger.categories.first { $0.name == "Покупки" }?.id)
        await store.undo(); XCTAssertNil(store.ledger.transactions[0].categoryID)
        let restarted = MerchantCategorizer(preferences: preferences) { _ in XCTFail("Undo is a user choice"); return .shopping }
        await restarted.process(store: store)
        XCTAssertNil(store.ledger.transactions[0].categoryID)
    }
}
