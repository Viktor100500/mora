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
    @Published private(set) var lastSync: Date?
    @Published private(set) var conflict = false
    @Published var error: String? {
        didSet {
            if let error, error != oldValue { store?.notifications.record(error, kind: .error, actions: [.inbox]) }
        }
    }
    @Published var invitation: String?
    @Published var issuedToken: String?
    private weak var store: FinanceStore?
    private let transport: URLSession
    private let sessionWriter: (Data, String) throws -> Void
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var session: CloudSession?
    private var settings: Settings?
    private var failureCount = 0
    private var nextAttempt = Date.distantPast
    init(store: FinanceStore? = nil, transport: URLSession = .shared,
         sessionWriter: @escaping (Data, String) throws -> Void = { try CloudKeychain.write($0, account: $1) }) {
        self.store = store
        self.transport = transport
        self.sessionWriter = sessionWriter
    }
    private struct Settings: Codable {
        var configuration: CloudConfiguration
        var email: String
        var userID: UUID
        var householdID: UUID?
        var householdName: String
        var enabled: Bool
    }
    private struct Checkpoint: Codable {
        let projectURL: URL
        let userID: UUID
        let envelope: CloudEnvelope
    }
    private struct HouseholdBody: Encodable { let p_household_id: UUID }
    private struct Status: Decodable { let version: Int64; let pending_count: Int }
    private struct CreateBody: Encodable { let p_name: String; let p_snapshot: Ledger }
    private struct SaveBody: Encodable { let p_household_id: UUID; let p_version: Int64; let p_snapshot: Ledger }
    private struct TokenBody: Encodable { let p_household_id: UUID; let p_account_id: UUID; let p_label: String }
    private struct ResolveBody: Encodable {
        let p_household_id: UUID; let p_capture_id: UUID; let p_account_id: UUID
        let p_amount: String; let p_merchant: String; let p_dismiss: Bool
    }
    private struct ReviewBody: Encodable {
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

    func run(store: FinanceStore) async {
        self.store = store
        load()
        while !Task.isCancelled {
            if enabled && signedIn && !store.isDemo && Date() >= nextAttempt { await synchronize(inBackground: true) }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
        }
    }
    private func load() {
        guard let configURL, let data = try? Data(contentsOf: configURL) else { return }
        do {
            let stored = try JSONDecoder().decode(Settings.self, from: data)
            _ = try CloudConfiguration(projectURL: stored.configuration.projectURL, publicKey: stored.configuration.publicKey)
            settings = stored; configured = true; email = stored.email; householdID = stored.householdID
            householdName = stored.householdName; enabled = stored.enabled
            if let bytes = try CloudKeychain.read(account: keychainAccount) {
                let loaded = try JSONDecoder().decode(CloudSession.self, from: bytes)
                guard loaded.user.id == stored.userID else { throw LedgerError.invalid("Облачная сессия относится к другому пользователю. Войдите повторно.") }
                session = loaded; signedIn = true
            }
        } catch { self.error = error.localizedDescription }
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func persistSettings() throws {
        guard let settings, let configURL else { return }
        try write(settings, to: configURL)
    }
    private func persistSession(_ value: CloudSession) throws {
        try sessionWriter(JSONEncoder().encode(value), keychainAccount)
        session = value
        if !signedIn { signedIn = true }
    }
    private func operation(inBackground: Bool = false, _ action: () async throws -> Void) async {
        if inBackground && operationInProgress { return }
        // A click during a background request waits instead of being dropped.
        while operationInProgress {
            await withCheckedContinuation { operationWaiters.append($0) }
            if Task.isCancelled { return }
        }
        guard !Task.isCancelled else { return }
        operationInProgress = true
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
            if error != nil { error = nil }
        }
        catch is CancellationError { }
        catch {
            if self.error != error.localizedDescription { self.error = error.localizedDescription }
        }
    }
    private func rpc<B: Encodable, R: Decodable>(_ function: String, _ body: B) async throws -> R {
        guard let settings, var session else { throw CloudAPIError.unauthorized }
        let api = CloudAPI(configuration: settings.configuration, transport: transport)
        if session.expires_at < Date().timeIntervalSince1970 + 60 {
            session = try await refreshedSession(api, token: session.refresh_token); try persistSession(session)
        }
        do { return try await api.rpc(function, body, accessToken: session.access_token) }
        catch CloudAPIError.unauthorized {
            let refreshed = try await refreshedSession(api, token: session.refresh_token); try persistSession(refreshed)
            return try await api.rpc(function, body, accessToken: refreshed.access_token)
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
            try self.persistSession(value)
            if !sameIdentity {
                self.settings = Settings(configuration: configuration, email: value.user.email ?? email, userID: value.user.id,
                                         householdID: nil, householdName: "", enabled: false)
            }
            self.configured = true; self.email = value.user.email ?? email
            try self.persistSettings()
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
        _ = try await loadPending(id)
    }
    @discardableResult
    private func loadPending(_ id: UUID) async throws -> Bool {
        let captures: [CloudCapture] = try await rpc("mora_list_pending", HouseholdBody(p_household_id: id))
        // Also reconcile an empty first response against history from a previous launch.
        store?.notifications.reconcileWallet(captures, householdID: id)
        guard pending != captures else { return false }
        pending = captures
        return true
    }
    private func diskLedger() throws -> Ledger {
        guard let store, !store.isDemo else { throw LedgerError.invalid("Сначала начните свой учет и создайте счет. Демо в облако не загружается.") }
        return try LedgerFile.decode(Data(contentsOf: store.fileURL))
    }
    private func saveCheckpoint(_ envelope: CloudEnvelope) throws {
        guard let settings, let checkpointURL else { throw CloudAPIError.invalidResponse }
        try write(Checkpoint(projectURL: settings.configuration.projectURL, userID: settings.userID, envelope: envelope), to: checkpointURL)
    }
    private func checkpoint() throws -> Checkpoint {
        guard let settings, let checkpointURL else { throw CloudAPIError.invalidResponse }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let cp = try decoder.decode(Checkpoint.self, from: Data(contentsOf: checkpointURL))
        guard cp.projectURL == settings.configuration.projectURL, cp.userID == settings.userID,
              cp.envelope.household_id == householdID else {
            throw LedgerError.invalid("Снимок синхронизации не соответствует общей базе. Отключите облако и заново подключитесь к выбранной базе.")
        }
        return cp
    }
    private func attach(_ envelope: CloudEnvelope) throws {
        try envelope.snapshot.validate()
        // Checkpoint precedes activation: missing checkpoint never uploads local data blindly.
        try saveCheckpoint(envelope)
        settings?.householdID = envelope.household_id; settings?.householdName = envelope.name; settings?.enabled = true
        try persistSettings()
        householdID = envelope.household_id; householdName = envelope.name; enabled = true
        lastSync = Date(); conflict = false; nextAttempt = .distantPast; failureCount = 0
        store?.reloadFromDisk()
    }
    func createHousehold(name: String) async {
        await operation {
            let initial = try self.diskLedger()
            let envelope: CloudEnvelope = try await self.rpc("mora_create_household", CreateBody(p_name: name, p_snapshot: CloudMerge.shared(initial)))
            // Edits made while creating remain as local deltas for the next sync.
            try self.attach(envelope)
            try await self.loadLists(envelope.household_id)
        }
    }
    func join(code: String) async {
        await operation {
            _ = try self.diskLedger()
            let envelope: CloudEnvelope = try await self.rpc("mora_join_household", ["p_code": code.trimmingCharacters(in: .whitespacesAndNewlines)])
            try self.adopt(envelope)
            try await self.loadLists(envelope.household_id)
        }
    }
    func openHousehold(_ id: UUID) async {
        await operation {
            _ = try self.diskLedger()
            let envelope: CloudEnvelope = try await self.rpc("mora_get_household", HouseholdBody(p_household_id: id))
            try self.adopt(envelope)
            try await self.loadLists(id)
        }
    }
    private func adopt(_ envelope: CloudEnvelope) throws {
        guard let store else { return }
        _ = try LedgerFile.adoptCloud(envelope.snapshot, at: store.fileURL)
        try attach(envelope)
    }

    func synchronize(inBackground: Bool = false) async {
        guard enabled, householdID != nil else { return }
        await operation(inBackground: inBackground) {
            do {
                try await self.syncNow()
                self.failureCount = 0; self.nextAttempt = Date().addingTimeInterval(8)
            } catch {
                self.failureCount += 1
                self.nextAttempt = Date().addingTimeInterval(min(300, 8 * pow(2, Double(min(self.failureCount, 5)))))
                throw error
            }
        }
    }
    private func syncNow() async throws {
        guard let id = householdID, let store else { return }
        let saved = try checkpoint().envelope
        let base = saved.snapshot
        let status: Status = try await rpc("mora_get_status", HouseholdBody(p_household_id: id))
        if status.version == saved.version, try CloudMerge.same(diskLedger(), base) {
            // Equal counts can hide a replaced capture or a corrected reason.
            if try await loadPending(id) { lastSync = Date() }
            if conflict { conflict = false }
            return
        }
        for _ in 0..<3 {
            try Task.checkCancellation()
            let local = try diskLedger()
            var remote: CloudEnvelope = try await rpc("mora_get_household", HouseholdBody(p_household_id: id))
            try remote.snapshot.validate()
            let merged: Ledger
            do { merged = try CloudMerge.merge(base: base, local: local, remote: remote.snapshot) }
            catch {
                if !conflict { conflict = true }
                if let directory { try write(remote, to: directory.appendingPathComponent("cloud-conflict-remote.json")) }
                throw error
            }
            if try !CloudMerge.same(merged, remote.snapshot) {
                let success: Bool = try await rpc("mora_save_household", SaveBody(p_household_id: id, p_version: remote.version, p_snapshot: CloudMerge.shared(merged)))
                if !success { continue }
                remote.version += 1; remote.snapshot = CloudMerge.shared(merged)
            }
            _ = try LedgerFile.applyCloud(remote.snapshot, at: store.fileURL, mergeAgainst: local)
            try saveCheckpoint(remote)
            store.reloadFromDisk()
            let capturesChanged = try await loadPending(id)
            if try capturesChanged || !CloudMerge.same(base, remote.snapshot) { lastSync = Date() }
            if conflict { conflict = false }
            return
        }
        throw LedgerError.invalid("Общая база сейчас изменяется с другого устройства. Повторим синхронизацию автоматически.")
    }
    func keepLocalVersion() async {
        await operation {
            guard let id = self.householdID else { return }
            let local = try self.diskLedger()
            var remote: CloudEnvelope = try await self.rpc("mora_get_household", HouseholdBody(p_household_id: id))
            if let directory = self.directory {
                try self.write(remote, to: directory.appendingPathComponent("before-cloud-overwrite-\(UUID().uuidString).json"))
            }
            let success: Bool = try await self.rpc("mora_save_household", SaveBody(p_household_id: id, p_version: remote.version, p_snapshot: CloudMerge.shared(local)))
            guard success else { throw LedgerError.invalid("Общая база снова изменилась. Проверьте версии и повторите выбор.") }
            remote.version += 1; remote.snapshot = CloudMerge.shared(local)
            try self.saveCheckpoint(remote); self.conflict = false; self.lastSync = Date()
        }
    }
    func invite() async {
        await operation {
            guard let id = self.householdID else { return }
            self.invitation = try await self.rpc("mora_create_invitation", HouseholdBody(p_household_id: id))
        }
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
    func resolve(_ capture: CloudCapture, account: UUID, amount: String, merchant: String, dismiss: Bool = false) async {
        await operation {
            guard let h = self.householdID else { return }
            let _: Bool = try await self.rpc("mora_resolve_capture", ResolveBody(p_household_id: h, p_capture_id: capture.id,
                p_account_id: account, p_amount: amount, p_merchant: merchant, p_dismiss: dismiss))
            try await self.syncNow()
        }
    }
    func review(_ capture: CloudCapture, transaction: Transaction) async -> Bool {
        var saved = false
        await operation {
            guard let id = self.householdID, let store = self.store else { throw CloudAPIError.unauthorized }
            try await self.syncNow()
            let local = try self.diskLedger()
            let value = try WalletReviewDraft.transaction(transaction, for: capture, in: local)
            let envelope: CloudEnvelope = try await self.rpc("mora_review_capture",
                ReviewBody(p_household_id: id, p_capture_id: capture.id, p_transaction: value))
            guard envelope.household_id == id else { throw CloudAPIError.invalidResponse }
            try envelope.snapshot.validate()
            _ = try LedgerFile.applyCloud(envelope.snapshot, at: store.fileURL, mergeAgainst: local)
            try self.saveCheckpoint(envelope)
            store.reloadFromDisk()
            _ = try await self.loadPending(id)
            self.lastSync = Date()
            store.showNotice(L("Покупка из Wallet добавлена в операции"))
            saved = true
        }
        if !saved, let error { store?.error = error }
        return saved
    }
    func pause(_ paused: Bool) {
        enabled = !paused; settings?.enabled = enabled
        do { try persistSettings() } catch { self.error = error.localizedDescription }
    }
    func disconnect() async {
        await operation {
            try CloudKeychain.delete(account: keychainAccount)
            settings?.enabled = false; settings?.householdID = nil; settings?.householdName = ""
            try persistSettings()
            session = nil; signedIn = false; enabled = false; householdID = nil; householdName = ""
            households = []; pending = []; phoneTokens = []; invitation = nil; issuedToken = nil; conflict = false; error = nil
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
