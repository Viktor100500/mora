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
    func testExistingWholeFoodsBankPurchaseIsCategorizedOfflineAndUndoIsPreserved() async throws {
        let (store, preferences, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let groceries = store.ledger.categories.first { $0.name == "Продукты" }!.id
        let dining = store.ledger.categories.first { $0.name == "Кафе и рестораны" }!.id
        await store.update { ledger in
            ledger.transactions = [
                Transaction(date: Date(), merchant: "Wholefds Hkn 12345", amount: -10, accountID: ledger.accounts[0].id),
                Transaction(date: Date(), merchant: "Wholefds MKT #67890", amount: -5,
                    accountID: ledger.accounts[0].id, categoryID: dining)
            ]
        }
        let worker = MerchantCategorizer(preferences: preferences) { _ in XCTFail("A built-in brand must avoid network lookups"); return nil }
        worker.onlineEnabled = false
        await worker.process(store: store)
        XCTAssertEqual(store.ledger.transactions[0].categoryID, groceries)
        XCTAssertEqual(store.ledger.transactions[1].categoryID, dining)
        await store.undo()
        await worker.process(store: store)
        XCTAssertNil(store.ledger.transactions[0].categoryID)
        XCTAssertEqual(store.ledger.transactions[1].categoryID, dining)
    }
    func testRegionalDatasetCategorizesExistingPurchasesOfflineAndHistoryWins() async throws {
        let (store, preferences, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let cases: [(String, String)] = [("Chapel Deli", "Продукты"), ("Wildberry", "Кафе и рестораны"),
            ("Net Cost 3100 Ocean Ave", "Продукты"), ("Laghman Express", "Кафе и рестораны"),
            ("TST* 7th Street Burger- W", "Кафе и рестораны"),
            ("SQ * Thisbowl Noho", "Кафе и рестораны"), ("The Wild-New", "Покупки"),
            ("Theperkhouse", "Кафе и рестораны")]
        await store.update { ledger in
            ledger.transactions = cases.map { Transaction(date: Date(timeIntervalSince1970: 1234), merchant: $0.0,
                amount: -10, accountID: ledger.accounts[0].id) }
        }
        let worker = MerchantCategorizer(preferences: preferences) { _ in XCTFail("Built-in public data should avoid the network"); return nil }
        await worker.process(store: store)
        for (merchant, category) in cases {
            let transaction = store.ledger.transactions.first { $0.merchant == merchant }!
            XCTAssertEqual(store.ledger.category(transaction.categoryID)?.name, category, merchant)
        }
        await store.undo()
        await worker.process(store: store)
        XCTAssertTrue(store.ledger.transactions.allSatisfy { $0.categoryID == nil })
    }
    func testCatalogStatusDistinguishesUnknownMerchantFromMissingCategory() async throws {
        let (store, preferences, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let unknown = MerchantCategorizer(preferences: preferences) { _ in nil }
        await unknown.process(store: store)
        XCTAssertTrue(unknown.status?.contains("Продавцов без совпадения") == true)
        let missing = MerchantCategorizer(preferences: preferences) { _ in .pets }
        await missing.process(store: store)
        XCTAssertTrue(missing.status?.contains("нет подходящей категории расходов") == true)
        XCTAssertNil(store.ledger.transactions[0].categoryID)
    }
    func testFailureDoesNotAffectSavedPurchaseAndBacksOff() async throws {
        let (store, preferences, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let worker = MerchantCategorizer(preferences: preferences) { _ in calls += 1; throw URLError(.notConnectedToInternet) }
        let before = store.ledger
        await worker.process(store: store); await worker.process(store: store)
        XCTAssertEqual(store.ledger, before); XCTAssertEqual(calls, 1); XCTAssertNotNil(worker.status)
    }
    func testRegionalCatalogWorksDuringNetworkBackoffAndRespectsToggle() async throws {
        let (store, preferences, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let worker = MerchantCategorizer(preferences: preferences) { _ in calls += 1; throw URLError(.notConnectedToInternet) }
        await worker.process(store: store)
        await store.update { ledger in
            ledger.transactions.append(Transaction(date: Date(), merchant: "TST* 7th Street Burger- W", amount: -10,
                accountID: ledger.accounts[0].id))
        }
        worker.onlineEnabled = false
        await worker.process(store: store)
        XCTAssertNil(store.ledger.transactions.last?.categoryID)
        worker.onlineEnabled = true
        await worker.process(store: store)
        XCTAssertEqual(store.ledger.category(store.ledger.transactions.last?.categoryID)?.name, "Кафе и рестораны")
        XCTAssertEqual(calls, 1)
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
    func testCategoriesAreAppliedInOnePublicationAfterAllLookups() async throws {
        let (store, preferences, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.update { ledger in
            ledger.transactions.append(Transaction(date: Date(), merchant: "Second unknown shop", amount: -5,
                accountID: ledger.accounts[0].id))
        }
        var lookups = 0, visibleCounts: [Int] = []
        let worker = MerchantCategorizer(preferences: preferences) { _ in
            lookups += 1
            XCTAssertTrue(store.ledger.transactions.allSatisfy { $0.categoryID == nil })
            return .shopping
        }
        let observation = store.$ledger.dropFirst().sink { visibleCounts.append($0.transactions.filter { $0.categoryID != nil }.count) }
        await worker.process(store: store)
        XCTAssertEqual(lookups, 2)
        XCTAssertEqual(visibleCounts, [2])
        await store.undo()
        await worker.process(store: store)
        XCTAssertTrue(store.ledger.transactions.allSatisfy { $0.categoryID == nil })
        withExtendedLifetime(observation) {}
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
