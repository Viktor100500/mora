import SwiftUI
import FinanceCore
import Security
import CryptoKit

@MainActor
final class CloudSync: ObservableObject {
    @Published private(set) var configured = false
    @Published private(set) var signedIn = false
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var email = ""
    @Published private(set) var householdName = ""
    @Published private(set) var householdID: UUID?
    @Published private(set) var households: [CloudHousehold] = []
    @Published private(set) var phoneTokens: [CloudPhoneToken] = []
    @Published private(set) var pending: [CloudCapture] = []
    @Published private(set) var walletCards: [CloudWalletCard] = []
    @Published private(set) var lastSync: Date?
    @Published private(set) var conflict = false
    private var walletProgressID: UUID?
    private var stagedPending: [CloudCapture]?
    private var stagedSyncDate: Date?
    private var importedBatchIDs: [UUID] = []
    var preparePresentation: (@MainActor (FinanceStore) async -> Void)?
    private var suppressErrorNotification = false
    @Published var error: String? {
        didSet {
            if !suppressErrorNotification, let error, error != oldValue { store?.notifications.record(error, kind: .error, actions: [.inbox]) }
        }
    }
    @Published var invitation: String?
    @Published var issuedToken: String?
    private weak var store: FinanceStore?
    private let walletRate: @MainActor @Sendable (Decimal, String, String, Date) async throws -> CardConversion
    private let transport: URLSession
    private let sessionWriter: @Sendable (Data, String) throws -> Void
    private var operationInProgress = false
    private var operationContactedCloud = false
    private var lastOperationConnectionFailure = false
    private var stopping = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var session: CloudSession?
    private var settings: Settings?
    private var failureCount = 0
    private var nextAttempt = Date.distantPast
    init(store: FinanceStore? = nil, transport: URLSession = .shared,
         walletRate: @escaping @MainActor @Sendable (Decimal, String, String, Date) async throws -> CardConversion = {
             try await VisaRateClient.shared.conversion(amount: $0, from: $1, to: $2, date: $3)
         },
         sessionWriter: @escaping @Sendable (Data, String) throws -> Void = { try CloudKeychain.write($0, account: $1) }) {
        self.store = store
        self.transport = transport
        self.walletRate = walletRate
        self.sessionWriter = sessionWriter
    }
    private struct Settings: Codable, Sendable {
        var configuration: CloudConfiguration
        var email: String
        var userID: UUID
        var householdID: UUID?
        var householdName: String
        var enabled: Bool
    }
    private struct Checkpoint: Codable, Sendable {
        let projectURL: URL
        let userID: UUID
        let envelope: CloudEnvelope
    }
    private struct HouseholdBody: Encodable, Sendable { let p_household_id: UUID }
    private struct WalletImportResult: Decodable, Sendable { let envelope: CloudEnvelope; let batch_id: UUID? }
    private struct Status: Decodable, Sendable { let version: Int64; let pending_count: Int }
    private struct CreateBody: Encodable, Sendable { let p_name: String; let p_snapshot: Ledger }
    private struct SaveBody: Encodable, Sendable { let p_household_id: UUID; let p_version: Int64; let p_snapshot: Ledger }
    private struct TokenBody: Encodable, Sendable { let p_household_id: UUID; let p_account_id: UUID; let p_label: String }
    private struct ResolveBody: Encodable, Sendable {
        let p_household_id: UUID; let p_capture_id: UUID; let p_account_id: UUID
        let p_amount: String; let p_merchant: String; let p_dismiss: Bool
    }
    private struct LinkCardBody: Encodable, Sendable {
        let p_household_id: UUID; let p_card_id: UUID; let p_account_id: UUID?
        // Explicit null: PostgREST matches functions by argument names.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(p_household_id, forKey: .p_household_id); try c.encode(p_card_id, forKey: .p_card_id)
            if let p_account_id { try c.encode(p_account_id, forKey: .p_account_id) } else { try c.encodeNil(forKey: .p_account_id) }
        }
        private enum CodingKeys: String, CodingKey { case p_household_id, p_card_id, p_account_id }
    }
    private struct ReviewBody: Encodable, Sendable {
        let p_household_id: UUID; let p_capture_id: UUID; let p_transaction: Transaction
    }
    var projectURL: String { settings?.configuration.projectURL.absoluteString ?? "" }
    var publicKey: String { settings?.configuration.publicKey ?? "" }
    var captureURL: String { projectURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/rest/v1/rpc/mora_capture_payment" }
    private var directory: URL? { store?.fileURL.deletingLastPathComponent() }
    private var configURL: URL? { directory?.appendingPathComponent("cloud-settings.json") }
    private var checkpointURL: URL? { directory?.appendingPathComponent("cloud-checkpoint.json") }
    private var keychainAccount: String {
        "session-" + SHA256.hash(data: Data((directory?.path ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func prepare(store: FinanceStore) async {
        self.store = store
        await store.load()
        await load()
        if enabled && signedIn && !store.isDemo { await synchronize(inBackground: true) }
    }
    func run(store: FinanceStore) async {
        while !Task.isCancelled {
            if enabled && signedIn && !store.isDemo && Date() >= nextAttempt { await synchronize(inBackground: true) }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
        }
    }
    private func load() async {
        guard let configURL else { return }
        let account = keychainAccount
        do {
            let loaded: (Settings, CloudSession?)? = try await BackgroundWork.credentials.perform {
                guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
                let stored = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: configURL))
                _ = try CloudConfiguration(projectURL: stored.configuration.projectURL, publicKey: stored.configuration.publicKey)
                let session = try CloudKeychain.read(account: account).map { try JSONDecoder().decode(CloudSession.self, from: $0) }
                if let session, session.user.id != stored.userID { throw LedgerError.invalid("Облачная сессия относится к другому пользователю. Войдите повторно.") }
                return (stored, session)
            }
            guard let (stored, loadedSession) = loaded else { return }
            settings = stored; configured = true; email = stored.email; householdID = stored.householdID
            householdName = stored.householdName; enabled = stored.enabled
            session = loadedSession; signedIn = loadedSession != nil
        } catch { self.error = error.localizedDescription }
    }
    private func write<T: Encodable & Sendable>(_ value: T, to url: URL) async throws {
        try await BackgroundWork.shared.perform {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
    private func persistSettings() async throws {
        guard let settings, let configURL else { return }
        try await write(settings, to: configURL)
    }
    private func persistSession(_ value: CloudSession) async throws {
        let writer = sessionWriter, account = keychainAccount
        try await BackgroundWork.credentials.perform { try writer(JSONEncoder().encode(value), account) }
        session = value
        if !signedIn { signedIn = true }
    }
    func finishPendingWrites() async {
        stopping = true
        while operationInProgress { await withCheckedContinuation { operationWaiters.append($0) } }
    }
    private func operation(inBackground: Bool = false, _ action: () async throws -> Void) async {
        guard !stopping else { return }
        if inBackground && operationInProgress { return }
        // A click during a background request waits instead of being dropped.
        while operationInProgress {
            await withCheckedContinuation { operationWaiters.append($0) }
            if Task.isCancelled || stopping { return }
        }
        guard !Task.isCancelled, !stopping else { return }
        operationInProgress = true
        operationContactedCloud = false
        lastOperationConnectionFailure = false
        if !inBackground { busy = true }
        defer {
            operationInProgress = false
            if !inBackground { busy = false }
            let waiters = operationWaiters
            operationWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        do {
            try await action()
            if operationContactedCloud { store?.notifications.connectionRestored() }
            if error != nil { error = nil }
        }
        catch is CancellationError { }
        catch {
            if Self.isConnectionError(error) {
                lastOperationConnectionFailure = true
                store?.notifications.connectionLost()
                suppressErrorNotification = true
                self.error = error.localizedDescription
                suppressErrorNotification = false
                return
            }
            if self.error != error.localizedDescription { self.error = error.localizedDescription }
        }
    }
    private static func isConnectionError(_ error: Error) -> Bool {
        let value = error as NSError
        if value.domain == NSURLErrorDomain {
            return [NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut,
                    NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed].contains(value.code)
        }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error { return isConnectionError(underlying) }
        return false
    }
    private func rpc<B: Encodable & Sendable, R: Decodable & Sendable>(_ function: String, _ body: B) async throws -> R {
        guard let settings, var session else { throw CloudAPIError.unauthorized }
        let api = CloudAPI(configuration: settings.configuration, transport: transport)
        if session.expires_at < Date().timeIntervalSince1970 + 60 {
            session = try await refreshedSession(api, token: session.refresh_token); try await persistSession(session)
        }
        do {
            let result: R = try await api.rpc(function, body, accessToken: session.access_token)
            operationContactedCloud = true
            return result
        }
        catch CloudAPIError.unauthorized {
            let refreshed = try await refreshedSession(api, token: session.refresh_token); try await persistSession(refreshed)
            let result: R = try await api.rpc(function, body, accessToken: refreshed.access_token)
            operationContactedCloud = true
            return result
        }
    }
    private func refreshedSession(_ api: CloudAPI, token: String) async throws -> CloudSession {
        do { return try await api.refresh(token) }
        catch CloudAPIError.unauthorized { signedIn = false; throw CloudAPIError.unauthorized }
        catch CloudAPIError.response(let code, let detail) {
            if code == 400 || code == 403 { signedIn = false }
            throw CloudAPIError.response(code, detail)
        }
    }

    func signIn(url: String, key: String, email: String, password: String) async {
        await operation {
            guard let projectURL = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw CloudAPIError.invalidResponse }
            let configuration = try CloudConfiguration(projectURL: projectURL, publicKey: key)
            let value = try await CloudAPI(configuration: configuration, transport: self.transport).signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            // Reauthentication may resume only the same user's same project.
            let sameIdentity = self.settings?.userID == value.user.id && self.settings?.configuration == configuration
            if self.settings?.householdID != nil && !sameIdentity {
                throw LedgerError.invalid("Сначала отключите текущую общую базу, чтобы войти в другой проект или аккаунт.")
            }
            try await self.persistSession(value)
            if !sameIdentity {
                self.settings = Settings(configuration: configuration, email: value.user.email ?? email, userID: value.user.id,
                                         householdID: nil, householdName: "", enabled: false)
            }
            self.configured = true; self.email = value.user.email ?? email
            try await self.persistSettings()
            self.households = try await self.rpc("mora_list_households", [String: String]())
        }
    }
    func refreshLists() async {
        await operation {
            self.households = try await self.rpc("mora_list_households", [String: String]())
            if let id = self.householdID { try await self.loadLists(id) }
        }
    }
    private func loadLists(_ id: UUID) async throws {
        let tokens: [CloudPhoneToken] = try await rpc("mora_list_phone_tokens", HouseholdBody(p_household_id: id))
        if phoneTokens != tokens { phoneTokens = tokens }
        try await loadWalletCards(id)
        _ = try await loadPending(id)
    }
    /// Cards need the Wallet cards migration; an older server simply has none.
    private func loadWalletCards(_ id: UUID) async throws {
        do {
            let cards: [CloudWalletCard] = try await rpc("mora_list_wallet_cards", HouseholdBody(p_household_id: id))
            if walletCards != cards { walletCards = cards }
        } catch CloudAPIError.response(let code, _) where code == 404 {
            if !walletCards.isEmpty { walletCards = [] }
        }
    }
    @discardableResult
    private func loadPending(_ id: UUID) async throws -> Bool {
        let captures: [CloudCapture] = try await rpc("mora_list_pending", HouseholdBody(p_household_id: id))
        let knownCards = Set(walletCards.map(\.id))
        if captures.contains(where: { $0.card_id.map { !knownCards.contains($0) } ?? false }) { try await loadWalletCards(id) }
        if let previous = stagedPending {
            stagedPending = captures
            let known = Set(store?.notifications.events.filter { $0.householdID == id }.compactMap(\.sourceID) ?? [])
            if captures.contains(where: { !previous.contains($0) && !known.contains($0.id) }) { showSyncProgress() }
            return previous != captures
        }
        // Also reconcile an empty first response against history from a previous launch.
        store?.reconcileWallet(captures, householdID: id)
        guard pending != captures else { return false }
        pending = captures
        return true
    }
    private func diskLedger() async throws -> Ledger {
        guard let store, !store.isDemo else { throw LedgerError.invalid("Сначала начните свой учет и создайте счет. Демо в облако не загружается.") }
        let url = store.fileURL
        return try await BackgroundWork.shared.perform { try LedgerFile.decode(Data(contentsOf: url)) }
    }
    private func saveCheckpoint(_ envelope: CloudEnvelope) async throws {
        guard let settings, let checkpointURL else { throw CloudAPIError.invalidResponse }
        try await write(Checkpoint(projectURL: settings.configuration.projectURL, userID: settings.userID, envelope: envelope), to: checkpointURL)
    }
    private func checkpoint() async throws -> Checkpoint {
        guard let settings, let checkpointURL else { throw CloudAPIError.invalidResponse }
        let cp = try await BackgroundWork.shared.perform {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Checkpoint.self, from: Data(contentsOf: checkpointURL))
        }
        guard cp.projectURL == settings.configuration.projectURL, cp.userID == settings.userID,
              cp.envelope.household_id == householdID else {
            throw LedgerError.invalid("Снимок синхронизации не соответствует общей базе. Отключите облако и заново подключитесь к выбранной базе.")
        }
        return cp
    }
    private func attach(_ envelope: CloudEnvelope) async throws {
        try await BackgroundWork.shared.perform { try envelope.snapshot.validate() }
        // Checkpoint precedes activation: missing checkpoint never uploads local data blindly.
        try await saveCheckpoint(envelope)
        settings?.householdID = envelope.household_id; settings?.householdName = envelope.name; settings?.enabled = true
        try await persistSettings()
        householdID = envelope.household_id; householdName = envelope.name; enabled = true
        lastSync = Date(); conflict = false; nextAttempt = .distantPast; failureCount = 0
        await store?.reloadFromDisk()
    }
    func createHousehold(name: String) async {
        await operation {
            let initial = try await self.diskLedger()
            let envelope: CloudEnvelope = try await self.rpc("mora_create_household", CreateBody(p_name: name, p_snapshot: CloudMerge.shared(initial)))
            // Edits made while creating remain as local deltas for the next sync.
            try await self.attach(envelope)
            try await self.loadLists(envelope.household_id)
        }
    }
    func join(code: String) async {
        await operation {
            _ = try await self.diskLedger()
            let envelope: CloudEnvelope = try await self.rpc("mora_join_household", ["p_code": code.trimmingCharacters(in: .whitespacesAndNewlines)])
            try await self.adopt(envelope)
            try await self.loadLists(envelope.household_id)
        }
    }
    func openHousehold(_ id: UUID) async {
        await operation {
            _ = try await self.diskLedger()
            let envelope: CloudEnvelope = try await self.rpc("mora_get_household", HouseholdBody(p_household_id: id))
            try await self.adopt(envelope)
            try await self.loadLists(id)
        }
    }
    private func adopt(_ envelope: CloudEnvelope) async throws {
        guard let store else { return }
        let url = store.fileURL
        _ = try await BackgroundWork.shared.perform { try LedgerFile.adoptCloud(envelope.snapshot, at: url) }
        try await attach(envelope)
    }

    private func showSyncProgress() {
        guard walletProgressID == nil, let store else { return }
        walletProgressID = store.beginProgressNotice(L("Загружаем покупки из Wallet…"), householdID: householdID)
    }
    private func markSynced() {
        if stagedPending != nil { stagedSyncDate = Date() }
        else { lastSync = Date() }
    }
    func synchronize(inBackground: Bool = false) async {
        guard enabled, householdID != nil else { return }
        await operation(inBackground: inBackground) {
            guard let store = self.store, let id = self.householdID else { return }
            let originalIDs = Set(store.ledger.transactions.map(\.id))
            store.beginDeferredUpdates()
            self.stagedPending = self.pending
            self.importedBatchIDs = []
            self.stagedSyncDate = nil
            var failure: Error?
            do {
                while true {
                    try Task.checkCancellation()
                    try await self.syncNow()
                    let attempted = self.stagedPending ?? []
                    try await self.bookWalletPurchases()
                    if self.walletProgressID != nil { await self.preparePresentation?(store) }
                    // Recheck both the snapshot version and capture contents. Equal
                    // counts can hide a new/corrected purchase while rates were loading.
                    let saved = try await self.checkpoint().envelope
                    _ = try await self.loadPending(id)
                    let status: Status = try await self.rpc("mora_get_status", HouseholdBody(p_household_id: id))
                    if status.version == saved.version,
                       status.pending_count == (self.stagedPending ?? []).count,
                       (self.stagedPending ?? []).allSatisfy({ attempted.contains($0) }) { break }
                }
                self.failureCount = 0; self.nextAttempt = Date().addingTimeInterval(8)
            } catch {
                failure = error
                self.failureCount += 1
                self.nextAttempt = Date().addingTimeInterval(min(300, 8 * pow(2, Double(min(self.failureCount, 5)))))
            }
            // Disk writes stay durable throughout; only their presentation waits.
            await store.endDeferredUpdates()
            let captures = self.stagedPending ?? self.pending
            self.stagedPending = nil
            if self.pending != captures { self.pending = captures }
            store.reconcileWallet(captures, householdID: id)
            if failure == nil, let date = self.stagedSyncDate { self.lastSync = date }
            let progressID = self.walletProgressID
            self.walletProgressID = nil
            if let failure {
                if let progressID {
                    if failure is CancellationError || Self.isConnectionError(failure) { store.finishProgressNotice(progressID) }
                    else {
                        store.finishProgressNotice(progressID, message: L("Не удалось загрузить покупки из Wallet"),
                            detail: failure.localizedDescription, kind: .error, actions: [.inbox])
                    }
                }
                throw failure
            }
            if let progressID {
                let added = store.ledger.transactions.filter { !originalIDs.contains($0.id) && $0.externalID?.hasPrefix("wallet:") == true }.count
                var actions: [AppNotificationAction] = []
                if self.importedBatchIDs.count == 1 { actions.append(.rollbackImport(self.importedBatchIDs[0])) }
                if !self.importedBatchIDs.isEmpty { actions.append(.imports) }
                if !captures.isEmpty { actions.append(.inbox) }
                store.finishProgressNotice(progressID,
                    message: added > 0 ? L("Загружено из Apple Shortcuts: \(added)") : nil,
                    detail: captures.isEmpty ? nil : L("Покупок на проверке: \(captures.count)"),
                    kind: captures.isEmpty ? .success : .warning, actions: actions)
            }
        }
    }
    private func bookWalletPurchases() async throws {
        guard let id = householdID, let store else { return }
        var firstError: Error?
        for capture in (stagedPending ?? pending).sorted(by: { $0.date < $1.date }) {
            try Task.checkCancellation()
            do {
                let local = try await diskLedger()
                let fetch = walletRate
                guard let transaction = try await WalletReviewDraft.automaticTransaction(for: capture, in: local,
                    fetch: { [weak self] amount, from, to, date in
                        await self?.showSyncProgress()
                        return try await fetch(amount, from, to, date)
                    }) else { continue }
                showSyncProgress()
                // The editor may have changed local data while the quote was loading.
                let current = try await diskLedger()
                let value = try await BackgroundWork.shared.perform { try WalletReviewDraft.transaction(transaction, for: capture, in: current) }
                let envelope: CloudEnvelope = try await rpc("mora_review_capture",
                    ReviewBody(p_household_id: id, p_capture_id: capture.id, p_transaction: value))
                guard envelope.household_id == id else { throw CloudAPIError.invalidResponse }
                try await BackgroundWork.shared.perform { try envelope.snapshot.validate() }
                let url = store.fileURL
                _ = try await BackgroundWork.shared.perform { try LedgerFile.applyCloud(envelope.snapshot, at: url, mergeAgainst: current) }
                try await saveCheckpoint(envelope)
                await store.reloadFromDisk()
                stagedPending?.removeAll { $0.id == capture.id }
                markSynced()
            } catch is CancellationError { throw CancellationError() }
            catch { if firstError == nil { firstError = error } }
        }
        // Keep failed captures in the server inbox and use the normal sync backoff.
        // Other valid purchases in the batch are still allowed to finish.
        // Also recovers purchases committed before a lost response or an older Mora version.
        try await collectWalletImport()
        _ = try await loadPending(id)
        if let firstError { throw firstError }
    }

    private func collectWalletImport() async throws {
        guard let id = householdID, let store else { return }
        let local = try await diskLedger()
        let previouslyBatched = Set(local.importHistory.flatMap { $0.transactions.map(\.id) })
        guard local.transactions.contains(where: { transaction in
            transaction.importBatchID == nil && !previouslyBatched.contains(transaction.id) &&
                transaction.externalID == "wallet:" + transaction.id.uuidString.lowercased()
        }) else { return }
        let result: WalletImportResult = try await rpc("mora_collect_wallet_import", HouseholdBody(p_household_id: id))
        guard result.envelope.household_id == id else { throw CloudAPIError.invalidResponse }
        let url = store.fileURL
        _ = try await BackgroundWork.shared.perform { try LedgerFile.applyCloud(result.envelope.snapshot, at: url, mergeAgainst: local, recordWalletImport: result.batch_id) }
        try await saveCheckpoint(result.envelope)
        await store.reloadFromDisk()
        if let batchID = result.batch_id {
            if stagedPending != nil {
                if !importedBatchIDs.contains(batchID) { importedBatchIDs.append(batchID) }
            } else if let batch = store.ledger.importHistory.first(where: { $0.id == batchID }) {
                store.showNotice(L("Загружено из Apple Shortcuts: \(batch.transactions.count)"),
                    detail: batch.transactions.prefix(3).map(\.merchant).joined(separator: " · "),
                    actions: [.rollbackImport(batchID), .imports])
            }
        }
    }

    private func syncNow() async throws {
        guard let id = householdID, let store else { return }
        let saved = try await checkpoint().envelope
        let base = saved.snapshot
        let status: Status = try await rpc("mora_get_status", HouseholdBody(p_household_id: id))
        let initial = try await diskLedger()
        if status.version == saved.version, try await BackgroundWork.shared.perform({ try CloudMerge.same(initial, base) }) {
            // Equal counts can hide a replaced capture or a corrected reason.
            if try await loadPending(id) { markSynced() }
            if conflict { conflict = false }
            return
        }
        for _ in 0..<3 {
            try Task.checkCancellation()
            let local = try await diskLedger()
            var remote: CloudEnvelope = try await rpc("mora_get_household", HouseholdBody(p_household_id: id))
            let remoteSnapshot = remote.snapshot
            try await BackgroundWork.shared.perform { try remoteSnapshot.validate() }
            let merged: Ledger
            do { merged = try await BackgroundWork.shared.perform { try CloudMerge.merge(base: base, local: local, remote: remoteSnapshot) } }
            catch {
                if !conflict { conflict = true }
                if let directory { try await write(remote, to: directory.appendingPathComponent("cloud-conflict-remote.json")) }
                throw error
            }
            if try await BackgroundWork.shared.perform({ try !CloudMerge.same(merged, remoteSnapshot) }) {
                let success: Bool = try await rpc("mora_save_household", SaveBody(p_household_id: id, p_version: remote.version, p_snapshot: CloudMerge.shared(merged)))
                if !success { continue }
                remote.version += 1; remote.snapshot = CloudMerge.shared(merged)
            }
            let committedRemote = remote.snapshot, url = store.fileURL
            let snapshotChanged = try await BackgroundWork.shared.perform { try !CloudMerge.same(base, committedRemote) }
            if stagedPending != nil, committedRemote.transactions.contains(where: { transaction in
                transaction.externalID?.hasPrefix("wallet:") == true && !local.transactions.contains(where: { $0.id == transaction.id })
            }) { showSyncProgress() }
            _ = try await BackgroundWork.shared.perform { try LedgerFile.applyCloud(committedRemote, at: url, mergeAgainst: local) }
            try await saveCheckpoint(remote)
            await store.reloadFromDisk()
            let capturesChanged = try await loadPending(id)
            if capturesChanged || snapshotChanged { markSynced() }
            if conflict { conflict = false }
            return
        }
        throw LedgerError.invalid("Общая база сейчас изменяется с другого устройства. Повторим синхронизацию автоматически.")
    }
    func keepLocalVersion() async {
        await operation {
            guard let id = self.householdID else { return }
            let local = try await self.diskLedger()
            var remote: CloudEnvelope = try await self.rpc("mora_get_household", HouseholdBody(p_household_id: id))
            if let directory = self.directory {
                try await self.write(remote, to: directory.appendingPathComponent("before-cloud-overwrite-\(UUID().uuidString).json"))
            }
            let success: Bool = try await self.rpc("mora_save_household", SaveBody(p_household_id: id, p_version: remote.version, p_snapshot: CloudMerge.shared(local)))
            guard success else { throw LedgerError.invalid("Общая база снова изменилась. Проверьте версии и повторите выбор.") }
            remote.version += 1; remote.snapshot = CloudMerge.shared(local)
            try await self.saveCheckpoint(remote); self.conflict = false; self.lastSync = Date()
        }
    }
    func invite() async {
        await operation {
            guard let id = self.householdID else { return }
            self.invitation = try await self.rpc("mora_create_invitation", HouseholdBody(p_household_id: id))
        }
    }
    /// A one-time invitation for an iPhone the user approved on this Mac.
    /// It replaces any code shown for another participant, as a new code always does.
    func pairingInvitation() async -> PairingInvitation? {
        var result: PairingInvitation?
        await operation {
            guard let id = self.householdID, let configuration = self.settings?.configuration else { return }
            let code: String = try await self.rpc("mora_create_invitation", HouseholdBody(p_household_id: id))
            self.invitation = nil
            result = PairingInvitation(projectURL: configuration.projectURL, publicKey: configuration.publicKey,
                                       invitation: code, householdName: self.householdName)
        }
        return result
    }
    func issueToken(account: UUID, label: String) async {
        await operation {
            guard let id = self.householdID else { return }
            try await self.syncNow()
            let value: CloudIssuedToken = try await self.rpc("mora_create_phone_token", TokenBody(p_household_id: id, p_account_id: account, p_label: label))
            self.issuedToken = value.token
            try await self.loadLists(id)
        }
    }
    func revokeToken(_ id: UUID) async {
        await operation {
            let _: Bool = try await self.rpc("mora_revoke_phone_token", ["p_token_id": id])
            if let h = self.householdID { try await self.loadLists(h) }
            self.issuedToken = nil
        }
    }
    /// Choose the account for a Wallet card (nil unlinks). Its waiting purchases move to
    /// that account and complete ones are booked by the next synchronization.
    func linkCard(_ card: UUID, account: UUID?) async {
        await operation {
            guard let id = self.householdID else { return }
            let _: Int = try await self.rpc("mora_link_wallet_card", LinkCardBody(p_household_id: id, p_card_id: card, p_account_id: account))
            try await self.loadWalletCards(id)
            _ = try await self.loadPending(id)
        }
        nextAttempt = .distantPast
        if account != nil { await synchronize(inBackground: true) }
    }
    func resolve(_ capture: CloudCapture, account: UUID, amount: String, merchant: String, dismiss: Bool = false) async {
        await operation {
            guard let h = self.householdID else { return }
            let _: Bool = try await self.rpc("mora_resolve_capture", ResolveBody(p_household_id: h, p_capture_id: capture.id,
                p_account_id: account, p_amount: amount, p_merchant: merchant, p_dismiss: dismiss))
            try await self.syncNow()
        }
    }
    func review(_ capture: CloudCapture, transaction: Transaction, reportError: Bool = true) async -> Bool {
        var saved = false
        await operation {
            guard let id = self.householdID, let store = self.store else { throw CloudAPIError.unauthorized }
            try await self.syncNow()
            let local = try await self.diskLedger()
            let value = try await BackgroundWork.shared.perform {
                var reviewed = transaction
                if reviewed.categoryID == nil && reviewed.kind != .transfer { reviewed.categoryID = local.suggestedCategory(merchant: reviewed.merchant, kind: reviewed.kind) }
                return try WalletReviewDraft.transaction(reviewed, for: capture, in: local)
            }
            // The first reviewed purchase of a new card also chooses that card's account.
            // Use the latest inbox state: the card may have been linked while the form was open.
            let current = self.pending.first { $0.id == capture.id } ?? capture
            // The server links a new card and commits this review atomically.
            // Another Mac must not auto-book the purchase between those steps.
            let envelope: CloudEnvelope = try await self.rpc("mora_review_capture",
                ReviewBody(p_household_id: id, p_capture_id: capture.id, p_transaction: value))
            guard envelope.household_id == id else { throw CloudAPIError.invalidResponse }
            try await BackgroundWork.shared.perform { try envelope.snapshot.validate() }
            let url = store.fileURL
            _ = try await BackgroundWork.shared.perform { try LedgerFile.applyCloud(envelope.snapshot, at: url, mergeAgainst: local) }
            try await self.saveCheckpoint(envelope)
            await store.reloadFromDisk()
            if current.awaitsCardLink { try await self.loadWalletCards(id); self.nextAttempt = .distantPast }
            _ = try await self.loadPending(id)
            self.lastSync = Date()
            // The purchase is already committed; collecting history can safely retry later.
            saved = true
            try await self.collectWalletImport()
        }
        if reportError, !saved, let error, !lastOperationConnectionFailure { store?.error = error }
        return saved
    }
    func pause(_ paused: Bool) async {
        await operation {
            enabled = !paused; settings?.enabled = enabled
            try await persistSettings()
        }
    }
    func disconnect() async {
        await operation {
            let account = keychainAccount
            try await BackgroundWork.credentials.perform { try CloudKeychain.delete(account: account) }
            settings?.enabled = false; settings?.householdID = nil; settings?.householdName = ""
            try await persistSettings()
            session = nil; signedIn = false; enabled = false; householdID = nil; householdName = ""
            households = []; pending = []; phoneTokens = []; walletCards = []; invitation = nil; issuedToken = nil; conflict = false; error = nil
        }
    }
}

private enum CloudKeychain {
    static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.mora.finance.cloud", kSecAttrAccount as String: account]
    }
    static func read(account: String) throws -> Data? {
        var q = query(account: account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw keychainError(status) }
        return result as? Data
    }
    static func write(_ data: Data, account: String) throws {
        let q = query(account: account)
        let updated = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecItemNotFound {
            var item = q; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw keychainError(status) }
        } else if updated != errSecSuccess { throw keychainError(updated) }
    }
    static func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }
    static func keychainError(_ status: OSStatus) -> LedgerError {
        .invalid("Не удалось сохранить или прочитать сессию в Связке ключей macOS (\(status)). Разрешите Mora доступ и повторите вход.")
    }
}
