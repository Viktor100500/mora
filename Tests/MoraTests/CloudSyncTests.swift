import XCTest
import os
import Combine
import AppKit
import SwiftUI
@testable import FinanceCore
@testable import Mora

private final class SyncStubProtocol: URLProtocol {
    // Test callbacks are installed before requests and executed under this lock.
    private static let handlers = OSAllocatedUnfairLock<((URLRequest) throws -> (Int, Data))?>(uncheckedState: nil)
    static var handler: ((URLRequest) throws -> (Int, Data))? {
        get { handlers.withLockUnchecked { $0 } }
        set { handlers.withLockUnchecked { $0 = newValue } }
    }
    static func requestBody(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: 1024)
            if count < 0 { throw stream.streamError ?? CloudAPIError.invalidResponse }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = request
        do {
            let (status, data) = try Self.handlers.withLockUnchecked { try $0!(request) }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private func walletImportResponse(_ remote: inout Ledger, version: inout Int, householdID: UUID) throws -> Data {
    let ids = Set(remote.transactions.filter { $0.importBatchID == nil }.map(\.id))
    let batch = try remote.recordImport(addedIDs: ids, filename: "Покупки из Apple Shortcuts", source: "Apple Shortcuts", totalRows: ids.count)
    if batch != nil { version += 1 }
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let snapshot = String(decoding: try encoder.encode(remote), as: UTF8.self)
    let batchJSON = batch.map { "\"\($0.id)\"" } ?? "null"
    return Data("{\"batch_id\":\(batchJSON),\"envelope\":{\"household_id\":\"\(householdID)\",\"name\":\"Test\",\"version\":\(version),\"snapshot\":\(snapshot)}}".utf8)
}

@MainActor
final class CloudSyncTests: XCTestCase {
    private var directory: URL!
    private var store: FinanceStore!
    private var cloud: CloudSync!
    private let householdID = UUID()

    func testPairingPromptRendersForConnectedHouseholdWithoutAmbientStore() async throws {
        defer { try? cleanup() }
        try await prepare()
        XCTAssertTrue(cloud.signedIn)
        XCTAssertNotNil(cloud.householdID)
        XCTAssertFalse(store.isDemo)
        _ = NSApplication.shared
        let pairing = PairingServer()
        defer { pairing.update(active: false, cloud: cloud) }
        // The prompt sits outside ContentView's environment modifiers at launch.
        // A connected household must render even without an ambient FinanceStore.
        let host = NSHostingView(rootView: Text("Connected Mora")
            .modifier(PairingPrompt(pairing: pairing, cloud: cloud, store: store)))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
    }

    func testConnectionOutageIsReportedOnceAndRecoveryOnce() async throws {
        defer { try? cleanup() }
        try await prepare()
        SyncStubProtocol.handler = { _ in throw URLError(.networkConnectionLost) }
        await cloud.synchronize(inBackground: true)
        await cloud.synchronize(inBackground: true)
        XCTAssertEqual(store.notifications.events.filter { $0.connectionState == .lost }.count, 1)
        XCTAssertEqual(store.notifications.events.count, 1)
        await cloud.pause(false)
        XCTAssertEqual(store.notifications.events.count, 1)
        SyncStubProtocol.handler = { request in
            (200, Data((request.url!.lastPathComponent == "mora_get_status" ? "{\"version\":1,\"pending_count\":0}" : "[]").utf8))
        }
        await cloud.synchronize(inBackground: true)
        await cloud.synchronize(inBackground: true)
        XCTAssertEqual(store.notifications.events.filter { $0.connectionState == .restored }.count, 1)
        XCTAssertEqual(store.notifications.events.count, 2)
        SyncStubProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await cloud.synchronize(inBackground: true)
        XCTAssertEqual(store.notifications.events.filter { $0.connectionState == .lost }.count, 2)
    }

    private func prepare(ledger: Ledger = .empty,
        walletRate: @escaping @MainActor @Sendable (Decimal, String, String, Date) async throws -> CardConversion = {
            _, _, _, _ in throw LedgerError.invalid("Test rate unavailable")
        }) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraSyncTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try LedgerFile.encode(ledger).write(to: directory.appendingPathComponent("ledger.json"))
        store = FinanceStore(directory: directory)
        await store.load()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyncStubProtocol.self]
        cloud = CloudSync(store: store, transport: URLSession(configuration: config), walletRate: walletRate, sessionWriter: { _, _ in })
        let snapshot = String(decoding: try LedgerFile.encode(CloudMerge.shared(store.ledger)), as: UTF8.self)
        let envelope = "{\"household_id\":\"\(householdID)\",\"name\":\"Test\",\"version\":1,\"snapshot\":\(snapshot)}"
        SyncStubProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "token":
                return (200, Data("{\"access_token\":\"test-access\",\"refresh_token\":\"test-refresh\",\"expires_at\":4102444800,\"user\":{\"id\":\"\(UUID())\"}}".utf8))
            case "mora_create_household": return (200, Data(envelope.utf8))
            default: return (200, Data("[]".utf8))
            }
        }
        await cloud.signIn(url: "https://test-mora.supabase.co", key: "sb_publishable_test", email: "test@example.test", password: "test")
        await cloud.createHousehold(name: "Test")
        XCTAssertNil(cloud.error)
        XCTAssertTrue(cloud.enabled)
    }

    private func cleanup() throws {
        SyncStubProtocol.handler = nil
        cloud = nil
        store = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testAutomaticForeignWalletBookingRetriesWithoutPartialWritesOrDuplicates() async throws {
        defer { try? cleanup() }
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "EUR test", currency: "EUR", conversionFeePercent: Decimal(string: "0.23"))]
        var quoteCalls = 0
        try await prepare(ledger: ledger, walletRate: { amount, from, to, date in
            quoteCalls += 1
            return CardConversion(originalAmount: amount, originalCurrency: from, accountCurrency: to, rate: Decimal(string: "0.9")!, date: date)
        })
        let id = UUID(), account = ledger.accounts[0].id
        let captures = "[{\"id\":\"\(id)\",\"merchant\":\"Test store\",\"amount\":\"$14.70\",\"currency\":\"\",\"account_id\":\"\(account)\",\"date\":\"2026-10-19T20:00:00Z\",\"label\":\"Test phone\"}]"
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        struct Request: Decodable { let p_capture_id: UUID; let p_transaction: FinanceCore.Transaction }
        var remote = CloudMerge.shared(store.ledger), attempts = 0, recorded = false, version = 1
        SyncStubProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "mora_get_status":
                return (200, Data("{\"version\":\(version),\"pending_count\":\(recorded ? 0 : 1)}".utf8))
            case "mora_collect_wallet_import":
                return (200, try walletImportResponse(&remote, version: &version, householdID: self.householdID))
            case "mora_review_capture":
                attempts += 1
                let body = try decoder.decode(Request.self, from: SyncStubProtocol.requestBody(request))
                XCTAssertEqual(body.p_capture_id, id); XCTAssertEqual(body.p_transaction.id, id)
                XCTAssertEqual(body.p_transaction.amount, Decimal(string: "-13.26"))
                XCTAssertEqual(body.p_transaction.conversion?.feePercent, Decimal(string: "0.23"))
                if attempts == 1 { return (503, Data("{\"message\":\"Test unavailable\"}".utf8)) }
                recorded = true; version = 2; remote.transactions = [body.p_transaction]
                let snapshot = String(decoding: try encoder.encode(remote), as: UTF8.self)
                return (200, Data("{\"household_id\":\"\(self.householdID)\",\"name\":\"Test\",\"version\":2,\"snapshot\":\(snapshot)}".utf8))
            default: return (200, Data((recorded ? "[]" : captures).utf8))
            }
        }
        await cloud.synchronize(inBackground: true)
        XCTAssertTrue(store.ledger.transactions.isEmpty)
        XCTAssertEqual(cloud.pending.count, 1); XCTAssertNotNil(cloud.error)
        await cloud.synchronize(inBackground: true)
        XCTAssertEqual(store.ledger.transactions.count, 1); XCTAssertTrue(cloud.pending.isEmpty)
        XCTAssertEqual(store.ledger.transactions.first?.externalID, "wallet:" + id.uuidString.lowercased())
        XCTAssertNil(cloud.error)
        await cloud.synchronize(inBackground: true)
        XCTAssertEqual(attempts, 2); XCTAssertEqual(quoteCalls, 2)
        XCTAssertEqual(store.ledger.transactions.count, 1)
    }

    func testUnchangedBackgroundPollsPublishNothing() async throws {
        defer { try? cleanup() }
        try await prepare()
        SyncStubProtocol.handler = { request in
            (200, Data((request.url!.lastPathComponent == "mora_get_status" ? "{\"version\":1,\"pending_count\":0}" : "[]").utf8))
        }
        var updates = 0
        let subscription = cloud.objectWillChange.sink { updates += 1 }
        let lastSync = cloud.lastSync
        for _ in 0..<3 { await cloud.synchronize(inBackground: true) }
        XCTAssertEqual(updates, 0)
        XCTAssertEqual(cloud.lastSync, lastSync)
        XCTAssertFalse(cloud.busy)
        withExtendedLifetime(subscription) {}
    }

    func testCaptureReplacementWithSameCountRefreshesOnce() async throws {
        defer { try? cleanup() }
        try await prepare()
        func capture(_ id: UUID, reason: String) -> String {
            "[{\"id\":\"\(id)\",\"merchant\":\"Test cafe\",\"amount\":\"$31.54\",\"currency\":\"\",\"account_id\":\"\(UUID())\",\"date\":\"2026-10-18T12:00:00Z\",\"reason\":\"\(reason)\",\"label\":\"Test phone\"}]"
        }
        var response = capture(UUID(), reason: "Не получена положительная сумма")
        SyncStubProtocol.handler = { request in
            (200, Data((request.url!.lastPathComponent == "mora_get_status" ? "{\"version\":1,\"pending_count\":1}" : response).utf8))
        }
        await cloud.synchronize(inBackground: true)
        let oldID = cloud.pending.first?.id
        XCTAssertEqual(store.notifications.events.filter { $0.kind == .review }.count, 1)
        response = capture(UUID(), reason: "Не получена валюта покупки")
        await cloud.synchronize(inBackground: true)
        XCTAssertNotEqual(cloud.pending.first?.id, oldID)
        XCTAssertEqual(cloud.pending.first?.reason, "Не получена валюта покупки")
        XCTAssertEqual(store.notifications.events.filter { $0.kind == .review }.count, 2)
        XCTAssertTrue(try XCTUnwrap(store.notifications.events.first { $0.sourceID == oldID }).isResolved)
        var updates = 0
        let subscription = cloud.objectWillChange.sink { updates += 1 }
        await cloud.synchronize(inBackground: true)
        XCTAssertEqual(updates, 0)
        withExtendedLifetime(subscription) {}
    }

    func testNewRemoteVersionWithIdenticalDataPublishesNothing() async throws {
        defer { try? cleanup() }
        try await prepare()
        let snapshot = String(decoding: try LedgerFile.encode(CloudMerge.shared(store.ledger)), as: UTF8.self)
        let envelope = "{\"household_id\":\"\(householdID)\",\"name\":\"Test\",\"version\":2,\"snapshot\":\(snapshot)}"
        SyncStubProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "mora_get_status": return (200, Data("{\"version\":2,\"pending_count\":0}".utf8))
            case "mora_get_household": return (200, Data(envelope.utf8))
            default: return (200, Data("[]".utf8))
            }
        }
        var updates = 0
        let subscription = cloud.objectWillChange.sink { updates += 1 }
        await cloud.synchronize(inBackground: true)
        XCTAssertEqual(updates, 0)
        XCTAssertNil(cloud.error)
        withExtendedLifetime(subscription) {}
    }

    func testDismissCaptureUsesItsOwnIDAndNeedsNoAmountOrNewAccount() async throws {
        defer { try? cleanup() }
        try await prepare()
        let captureID = UUID(), accountID = UUID()
        let captureJSON = "[{\"id\":\"\(captureID)\",\"merchant\":\"\",\"amount\":\"\",\"currency\":\"\",\"account_id\":\"\(accountID)\",\"date\":\"2026-10-18T12:00:00Z\",\"reason\":\"Missing amount\",\"label\":\"Test phone\"}]"
        var dismissed = false
        SyncStubProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "mora_get_status": return (200, Data("{\"version\":1,\"pending_count\":\(dismissed ? 0 : 1)}".utf8))
            case "mora_resolve_capture":
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: SyncStubProtocol.requestBody(request)) as? [String: Any])
                XCTAssertEqual((body["p_capture_id"] as? String)?.lowercased(), captureID.uuidString.lowercased())
                XCTAssertEqual((body["p_account_id"] as? String)?.lowercased(), accountID.uuidString.lowercased())
                XCTAssertEqual(body["p_amount"] as? String, "")
                XCTAssertEqual(body["p_dismiss"] as? Bool, true)
                dismissed = true
                return (200, Data("true".utf8))
            default: return (200, Data((dismissed ? "[]" : captureJSON).utf8))
            }
        }
        await cloud.synchronize(inBackground: true)
        let capture = try XCTUnwrap(cloud.pending.first)
        let ledger = store.ledger
        await cloud.resolve(capture, account: capture.account_id, amount: "", merchant: capture.merchant, dismiss: true)
        XCTAssertTrue(dismissed)
        XCTAssertTrue(cloud.pending.isEmpty)
        XCTAssertEqual(store.ledger, ledger)
        XCTAssertTrue(try XCTUnwrap(store.notifications.events.first { $0.sourceID == captureID }).isResolved)
        XCTAssertNil(cloud.error)
    }

    func testRepeatedBackgroundErrorsDoNotFlashAndRecoveryPublishesOnce() async throws {
        defer { try? cleanup() }
        try await prepare()
        SyncStubProtocol.handler = { _ in (503, Data("{\"message\":\"Test offline\"}".utf8)) }
        await cloud.synchronize(inBackground: true)
        XCTAssertNotNil(cloud.error)
        var updates = 0
        let subscription = cloud.objectWillChange.sink { updates += 1 }
        await cloud.synchronize(inBackground: true)
        XCTAssertEqual(updates, 0)
        SyncStubProtocol.handler = { request in
            (200, Data((request.url!.lastPathComponent == "mora_get_status" ? "{\"version\":1,\"pending_count\":0}" : "[]").utf8))
        }
        await cloud.synchronize(inBackground: true)
        XCTAssertNil(cloud.error)
        XCTAssertEqual(updates, 1)
        withExtendedLifetime(subscription) {}
    }

    func testUserActionWaitsForBackgroundRequestInsteadOfDisappearing() async throws {
        defer { try? cleanup() }
        try await prepare()
        let started = expectation(description: "Background request started")
        started.assertForOverFulfill = false // A completed batch verifies status again.
        SyncStubProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "mora_get_status":
                started.fulfill()
                Thread.sleep(forTimeInterval: 0.15)
                return (200, Data("{\"version\":1,\"pending_count\":0}".utf8))
            case "mora_create_invitation": return (200, Data("\"test-invitation\"".utf8))
            default: return (200, Data("[]".utf8))
            }
        }
        let polling = Task { await cloud.synchronize(inBackground: true) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(cloud.busy)
        await cloud.invite()
        await polling.value
        XCTAssertEqual(cloud.invitation, "test-invitation")
        XCTAssertFalse(cloud.busy)
        XCTAssertNil(cloud.error)
    }

    func testBatchPublishesOnceAndDrainsPurchasesArrivingDuringConversion() async throws {
        defer { try? cleanup() }
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "EUR test", currency: "EUR")]
        let first = UUID(), second = UUID(), late = UUID(), incomplete = UUID()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        func capture(_ id: UUID, amount: String = "$10") throws -> CloudCapture {
            let data = try JSONSerialization.data(withJSONObject: ["id": id.uuidString,
                "merchant": "Test shop", "amount": amount, "currency": "USD",
                "account_id": ledger.accounts[0].id.uuidString, "date": "2026-10-23T12:00:00Z", "label": "Test phone"])
            return try decoder.decode(CloudCapture.self, from: data)
        }
        var remaining = try [capture(first), capture(second), capture(incomplete, amount: "")]
        var quoteCalls = 0
        try await prepare(ledger: ledger, walletRate: { amount, from, to, date in
            quoteCalls += 1
            XCTAssertEqual(self.store.activeNotice?.isInProgress, true)
            XCTAssertTrue(self.store.isDeferringUpdates)
            XCTAssertTrue(self.store.ledger.transactions.isEmpty)
            XCTAssertTrue(self.cloud.pending.isEmpty)
            XCTAssertFalse(self.store.notifications.events.contains { $0.kind == .review })
            if quoteCalls == 2 {
                // Simulate the two-second disk watcher seeing the first durable write.
                XCTAssertEqual(try LedgerFile.decode(Data(contentsOf: self.store.fileURL)).transactions.count, 1)
                await self.store.reloadFromDisk()
                XCTAssertTrue(self.store.ledger.transactions.isEmpty)
                remaining.append(try capture(late))
            }
            return CardConversion(originalAmount: amount, originalCurrency: from, accountCurrency: to, rate: 1, date: date)
        })
        var remote = CloudMerge.shared(store.ledger), version = 1
        func envelope() throws -> Data {
            let snapshot = String(decoding: try encoder.encode(remote), as: UTF8.self)
            return Data("{\"household_id\":\"\(householdID)\",\"name\":\"Test\",\"version\":\(version),\"snapshot\":\(snapshot)}".utf8)
        }
        struct Review: Decodable { let p_capture_id: UUID; let p_transaction: FinanceCore.Transaction }
        struct Save: Decodable { let p_snapshot: Ledger }
        SyncStubProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "mora_get_status": return (200, Data("{\"version\":\(version),\"pending_count\":\(remaining.count)}".utf8))
            case "mora_get_household": return (200, try envelope())
            case "mora_save_household":
                remote = try decoder.decode(Save.self, from: SyncStubProtocol.requestBody(request)).p_snapshot
                version += 1
                return (200, Data("true".utf8))
            case "mora_review_capture":
                let body = try decoder.decode(Review.self, from: SyncStubProtocol.requestBody(request))
                remote.transactions.append(body.p_transaction)
                let reviewedID = body.p_capture_id
                remaining.removeAll { @Sendable in $0.id == reviewedID }
                version += 1
                return (200, try envelope())
            case "mora_collect_wallet_import":
                return (200, try walletImportResponse(&remote, version: &version, householdID: self.householdID))
            default: return (200, try encoder.encode(remaining))
            }
        }
        var visibleCounts: [Int] = [], pendingCounts: [Int] = []
        cloud.preparePresentation = { store in
            XCTAssertTrue(store.ledger.transactions.isEmpty)
            XCTAssertFalse(store.latestLedger.transactions.isEmpty)
            await store.update { ledger in
                ledger.accounts[0].name = "Edited during sync"
                let categoryID = ledger.categories.first { $0.name == "Покупки" }!.id
                for index in ledger.transactions.indices { ledger.transactions[index].categoryID = categoryID }
            }
        }
        let ledgerObservation = store.$ledger.dropFirst().sink { visibleCounts.append($0.transactions.count) }
        let pendingObservation = cloud.$pending.dropFirst().sink { pendingCounts.append($0.count) }
        await cloud.synchronize(inBackground: true)
        XCTAssertNil(cloud.error)
        XCTAssertEqual(quoteCalls, 3)
        XCTAssertEqual(visibleCounts, [3])
        XCTAssertEqual(store.ledger.accounts[0].name, "Edited during sync")
        XCTAssertTrue(store.ledger.transactions.allSatisfy { $0.categoryID != nil })
        XCTAssertEqual(pendingCounts, [1])
        XCTAssertEqual(cloud.pending.map(\.id), [incomplete])
        XCTAssertEqual(store.notifications.events.filter { $0.kind == .review }.map(\.sourceID), [incomplete])
        XCTAssertEqual(store.activeNotice?.message, "Загружено из Apple Shortcuts: 3")
        XCTAssertEqual(store.activeNotice?.kind, .warning)
        XCTAssertFalse(store.isDeferringUpdates)
        XCTAssertFalse(store.activeNotice?.isInProgress == true)
        withExtendedLifetime((ledgerObservation, pendingObservation)) {}
    }

    func testFailedBatchReleasesPresentationAndDoesNotReportSuccess() async throws {
        defer { try? cleanup() }
        try await prepare()
        SyncStubProtocol.handler = { _ in (503, Data("{\"message\":\"Test offline\"}".utf8)) }
        await cloud.synchronize(inBackground: true)
        XCTAssertFalse(store.isDeferringUpdates)
        XCTAssertFalse(store.activeNotice?.isInProgress == true)
        XCTAssertNotNil(cloud.error)
        XCTAssertNil(store.activeNotice)
        XCTAssertFalse(store.notifications.events.contains { $0.message == "Синхронизация завершена" })
    }

    func testReloadReportsSuccessEvenWhenDataIsUnchanged() async throws {
        defer { try? cleanup() }
        try await prepare()
        SyncStubProtocol.handler = { request in
            let response = request.url!.lastPathComponent == "mora_get_status" ? "{\"version\":1,\"pending_count\":0}" : "[]"
            return (200, Data(response.utf8))
        }
        await cloud.synchronize(notifyResult: true)
        XCTAssertEqual(store.activeNotice?.message, "Синхронизация с облаком завершена")
        XCTAssertEqual(store.activeNotice?.kind, .success)
        XCTAssertEqual(store.notifications.events.count, 1)
        XCTAssertFalse(cloud.busy)
    }

    func testReloadReportsEachServerFailureWithoutDuplicateErrors() async throws {
        defer { try? cleanup() }
        try await prepare()
        SyncStubProtocol.handler = { _ in (503, Data("{\"message\":\"Test offline\"}".utf8)) }
        for _ in 0..<2 {
            await cloud.synchronize(notifyResult: true)
            XCTAssertEqual(store.activeNotice?.message, "Не удалось синхронизироваться с облаком")
            XCTAssertEqual(store.activeNotice?.kind, .error)
            XCTAssertEqual(store.activeNotice?.detail, cloud.error)
            XCTAssertFalse(store.isDeferringUpdates)
        }
        XCTAssertEqual(store.notifications.events.count, 2)
        XCTAssertTrue(store.notifications.events.allSatisfy { $0.kind == .error })
    }

    func testReloadReportsRepeatedConnectionFailuresAndThenRecovery() async throws {
        defer { try? cleanup() }
        try await prepare()
        SyncStubProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        for _ in 0..<2 {
            await cloud.synchronize(notifyResult: true)
            XCTAssertEqual(store.activeNotice?.message, "Не удалось синхронизироваться с облаком")
            XCTAssertEqual(store.activeNotice?.kind, .error)
        }
        XCTAssertEqual(store.notifications.events.filter { $0.connectionState == .lost }.count, 1)
        XCTAssertEqual(store.notifications.events.filter { $0.message == "Не удалось синхронизироваться с облаком" }.count, 2)
        SyncStubProtocol.handler = { request in
            let response = request.url!.lastPathComponent == "mora_get_status" ? "{\"version\":1,\"pending_count\":0}" : "[]"
            return (200, Data(response.utf8))
        }
        await cloud.synchronize(notifyResult: true)
        XCTAssertEqual(store.activeNotice?.message, "Синхронизация с облаком завершена")
        XCTAssertEqual(store.activeNotice?.kind, .success)
        XCTAssertNil(cloud.error)
        XCTAssertEqual(store.notifications.events.filter { $0.connectionState == .restored }.count, 1)
    }

    func testEmptyManualAndBackgroundChecksDoNotCreateNotices() async throws {
        defer { try? cleanup() }
        try await prepare()
        SyncStubProtocol.handler = { request in
            let response = request.url!.lastPathComponent == "mora_get_status" ? "{\"version\":1,\"pending_count\":0}" : "[]"
            return (200, Data(response.utf8))
        }
        var displayed: [AppNotification] = []
        let observation = store.$activeNotice.compactMap { $0 }.sink { displayed.append($0) }
        await cloud.synchronize()
        await cloud.synchronize(inBackground: true)
        XCTAssertTrue(displayed.isEmpty)
        XCTAssertTrue(store.notifications.events.isEmpty)
        XCTAssertNil(store.activeNotice)
        withExtendedLifetime(observation) {}
    }

    func testPreviouslyReportedIncompleteWalletPurchaseDoesNotReannounce() async throws {
        defer { try? cleanup() }
        try await prepare()
        let data = Data("[{\"id\":\"\(UUID())\",\"merchant\":\"\",\"amount\":\"\",\"currency\":\"\",\"account_id\":\"\(UUID())\",\"date\":\"2026-10-23T12:00:00Z\",\"label\":\"Test phone\"}]".utf8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let captures = try decoder.decode([CloudCapture].self, from: data)
        store.reconcileWallet(captures, householdID: householdID)
        store.notifications.markAllRead()
        SyncStubProtocol.handler = { request in
            (200, request.url!.lastPathComponent == "mora_get_status"
                ? Data("{\"version\":1,\"pending_count\":1}".utf8) : data)
        }
        var displayed: [AppNotification] = []
        let observation = store.$activeNotice.compactMap { $0 }.sink { displayed.append($0) }
        await cloud.synchronize()
        await cloud.synchronize(inBackground: true)
        XCTAssertTrue(displayed.isEmpty)
        XCTAssertEqual(cloud.pending.count, 1)
        XCTAssertEqual(store.notifications.events.count, 1)
        XCTAssertEqual(store.notifications.unreadCount, 0)
        withExtendedLifetime(observation) {}
    }

    func testCancelledBatchClearsProgressAndReleasesDeferredUpdates() async throws {
        defer { try? cleanup() }
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "EUR test", currency: "EUR")]
        let quoting = expectation(description: "Conversion started")
        try await prepare(ledger: ledger, walletRate: { _, _, _, _ in
            quoting.fulfill()
            try await Task.sleep(for: .seconds(10))
            throw CancellationError()
        })
        let captures = "[{\"id\":\"\(UUID())\",\"merchant\":\"Test\",\"amount\":\"$10\",\"currency\":\"USD\",\"account_id\":\"\(ledger.accounts[0].id)\",\"date\":\"2026-10-23T12:00:00Z\",\"label\":\"Test phone\"}]"
        SyncStubProtocol.handler = { request in
            (200, Data((request.url!.lastPathComponent == "mora_get_status" ? "{\"version\":1,\"pending_count\":1}" : captures).utf8))
        }
        let syncing = Task { await cloud.synchronize(inBackground: true) }
        await fulfillment(of: [quoting], timeout: 2)
        XCTAssertEqual(store.activeNotice?.isInProgress, true)
        syncing.cancel()
        await syncing.value
        XCTAssertFalse(store.isDeferringUpdates)
        XCTAssertFalse(store.activeNotice?.isInProgress == true)
        XCTAssertNil(cloud.error)
        XCTAssertFalse(store.notifications.events.contains { $0.message == "Синхронизация завершена" })
    }

    func testDeferredPresentationPreservesConcurrentEditsAndPublishesLatestSnapshot() async throws {
        defer { try? cleanup() }
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "Original")]
        try await prepare(ledger: ledger)
        var visibleNames: [String] = []
        let observation = store.$ledger.dropFirst().sink { visibleNames.append($0.accounts[0].name) }
        store.beginDeferredUpdates()
        expectTrue(await store.update { $0.accounts[0].name = "First edit" })
        await store.reloadFromDisk()
        expectTrue(await store.update { $0.accounts[0].name = "Latest edit" })
        XCTAssertEqual(store.ledger.accounts[0].name, "Original")
        await store.endDeferredUpdates()
        XCTAssertEqual(visibleNames, ["Latest edit"])
        XCTAssertEqual(store.ledger.accounts[0].name, "Latest edit")
        withExtendedLifetime(observation) {}
    }

    func testFullReviewSavesAllFieldsAndCanRetryWithoutDuplicating() async throws {
        defer { try? cleanup() }
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "EUR test", currency: "EUR")]
        try await prepare(ledger: ledger)
        let id=UUID(), account=ledger.accounts[0].id
        let captureJSON="[{\"id\":\"\(id)\",\"merchant\":\"Test cafe\",\"amount\":\"$31.54\",\"currency\":\"\",\"account_id\":\"\(account)\",\"date\":\"2026-10-16T20:19:00Z\",\"label\":\"Test phone\"}]"
        let decoder=JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let capture=try decoder.decode([CloudCapture].self, from: Data(captureJSON.utf8))[0]
        var transaction=FinanceCore.Transaction(date:capture.date, merchant:"Edited · Apple Wallet · Test phone · 20:19", amount:Decimal(string:"-28.39")!,
            accountID:account, categoryID:ledger.categories[0].id, note:"Reviewed note", tags:["Apple Wallet","custom"])
        transaction.conversion=try decoder.decode(CardConversion.self, from: Data("{\"originalAmount\":-31.54,\"originalCurrency\":\"USD\",\"accountCurrency\":\"EUR\",\"rate\":0.9,\"date\":\"2026-10-16T20:19:00Z\",\"provider\":\"Visa\"}".utf8))
        let prepared=try WalletReviewDraft.transaction(transaction, for:capture, in:store.ledger)
        var remote=CloudMerge.shared(store.ledger); remote.transactions=[prepared]
        var version = 1
        func envelope() throws -> Data {
            let snapshot = String(decoding: try LedgerFile.encode(remote), as: UTF8.self)
            return Data("{\"household_id\":\"\(householdID)\",\"name\":\"Test\",\"version\":\(version),\"snapshot\":\(snapshot)}".utf8)
        }
        struct Request: Decodable { let p_capture_id:UUID; let p_transaction:FinanceCore.Transaction }
        var reviewed=false, saves=0
        SyncStubProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "mora_get_status": return (200,Data("{\"version\":\(version),\"pending_count\":\(reviewed ? 0 : 1)}".utf8))
            case "mora_review_capture":
                let body=try decoder.decode(Request.self,from:SyncStubProtocol.requestBody(request))
                XCTAssertEqual(body.p_capture_id,id); XCTAssertEqual(body.p_transaction,prepared)
                if !reviewed { version = 2 }
                reviewed=true; saves += 1
                return (200, try envelope())
            case "mora_collect_wallet_import":
                return (200, try walletImportResponse(&remote, version: &version, householdID: self.householdID))
            default: return (200,Data((reviewed ? "[]" : captureJSON).utf8))
            }
        }
        await cloud.synchronize(inBackground:true)
        let first=await cloud.review(capture,transaction:transaction)
        XCTAssertTrue(first); XCTAssertEqual(store.ledger.transactions.map { value in var original = value; original.importBatchID = nil; return original },[prepared]); XCTAssertTrue(cloud.pending.isEmpty)
        let retry=await cloud.review(capture,transaction:transaction)
        XCTAssertTrue(retry); XCTAssertEqual(saves,2); XCTAssertEqual(store.ledger.transactions.map { value in var original = value; original.importBatchID = nil; return original },[prepared])
        XCTAssertNil(cloud.error)
    }

    func testFailedReviewKeepsTheCaptureAndDoesNotSaveAPartialLocalTransaction() async throws {
        defer { try? cleanup() }
        var ledger=Ledger.empty; ledger.accounts=[Account(name:"Test")]
        try await prepare(ledger:ledger)
        let captureJSON="[{\"id\":\"\(UUID())\",\"merchant\":\"Test\",\"amount\":\"10\",\"currency\":\"RUB\",\"account_id\":\"\(ledger.accounts[0].id)\",\"date\":\"2026-10-16T20:19:00Z\",\"label\":\"Test phone\"}]"
        SyncStubProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "mora_get_status": return (200,Data("{\"version\":1,\"pending_count\":1}".utf8))
            case "mora_review_capture": return (503,Data("{\"message\":\"Test offline\"}".utf8))
            default: return (200,Data(captureJSON.utf8))
            }
        }
        await cloud.synchronize(inBackground:true)
        let capture=try XCTUnwrap(cloud.pending.first), before=store.ledger
        let value=FinanceCore.Transaction(date:capture.date,merchant:"Test",amount:-10,accountID:ledger.accounts[0].id)
        let result=await cloud.review(capture,transaction:value)
        XCTAssertFalse(result); XCTAssertEqual(store.ledger,before); XCTAssertEqual(cloud.pending,[capture])
        XCTAssertNotNil(store.error)
    }
}
