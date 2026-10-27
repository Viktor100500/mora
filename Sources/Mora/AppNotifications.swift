import Foundation
import Combine
import FinanceCore

enum AppNotificationAction: Codable, Equatable, Identifiable, Sendable {
    case undo(String), redo(String), rollbackImport(UUID)
    case imports, settings, inbox, review(UUID)
    case retryTransaction(UUID)

    var id: String {
        switch self {
        case .undo(let token): return "undo:\(token)"
        case .redo(let token): return "redo:\(token)"
        case .rollbackImport(let id): return "import:\(id)"
        case .imports: return "imports"
        case .settings: return "settings"
        case .inbox: return "inbox"
        case .review(let id): return "review:\(id)"
        case .retryTransaction(let id): return "retryTransaction:\(id)"
        }
    }
    var title: String {
        switch self {
        case .undo: return L("Отменить")
        case .redo: return L("Вернуть")
        case .rollbackImport: return L("Отменить импорт")
        case .imports: return L("История импортов")
        case .settings: return L("Настройки")
        case .inbox: return L("Кликните для проверки")
        case .review: return L("Проверить…")
        case .retryTransaction: return L("Повторить сохранение")
        }
    }
}

struct AppNotification: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case success, information, warning, error, review }
    enum ConnectionState: String, Codable, Sendable { case lost, restored }
    var id = UUID()
    var date = Date()
    var message: String
    var detail: String? = nil
    var kind: Kind = .success
    var actions: [AppNotificationAction] = []
    var isRead = false
    var sourceID: UUID? = nil
    var householdID: UUID? = nil
    var isResolved = false
    var progress: Bool? = nil
    var connectionState: ConnectionState? = nil
    var isInProgress: Bool { progress == true }
}

struct NotificationNavigation: Identifiable {
    enum Destination { case page(Page), inbox, capture(UUID) }
    let id = UUID()
    let destination: Destination
}

/// Computer-local history. It never enters ledger snapshots, exports or cloud sync.
@MainActor
final class AppNotifications: ObservableObject {
    @Published private(set) var events: [AppNotification] = []
    @Published private(set) var navigation: NotificationNavigation?
    private(set) var storageError: String?
    private let fileURL: URL?
    private var canPersist = true

    private let storage: NotificationStorage
    private var loaded = false
    private var loading: Task<Void, Never>?
    private var pendingSave: Task<Void, Never>?
    private var revision: UInt64 = 0
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL; storage = NotificationStorage(fileURL: fileURL)
    }
    func load() async {
        if let loading { await loading.value; return }
        guard !loaded else { return }
        let task = Task { @MainActor in
            do {
                let history = try await storage.load()
                let visibleHistory = history.filter { !Self.isCopyNoise($0.message) && !$0.isInProgress }
                if events.isEmpty {
                    if !visibleHistory.isEmpty { events = visibleHistory }
                } else {
                    let localIDs = Set(events.map(\.id))
                    let missing = visibleHistory.filter { !localIDs.contains($0.id) }; if !missing.isEmpty { events += missing }
                }
            } catch { storageError = L("Не удалось прочитать историю уведомлений."); canPersist = false }
            loaded = true
        }
        loading = task; await task.value; loading = nil
    }
    func flush() async { await pendingSave?.value }

    var unreadCount: Int { events.filter { !$0.isRead }.count }

    func connectionLost() {
        guard events.first(where: { $0.connectionState != nil })?.connectionState != .lost else { return }
        var event = AppNotification(message: L("Связь с облаком потеряна"), detail: L("Повторим подключение автоматически."), kind: .error, actions: [.inbox])
        event.connectionState = .lost
        events.insert(event, at: 0); persist()
    }

    func connectionRestored() {
        guard events.first(where: { $0.connectionState != nil })?.connectionState == .lost else { return }
        var event = AppNotification(message: L("Связь с облаком восстановлена"), kind: .success)
        event.connectionState = .restored
        events.insert(event, at: 0); persist()
    }

    @discardableResult
    func record(_ message: String, detail: String? = nil, kind: AppNotification.Kind = .success,
                actions: [AppNotificationAction] = [], householdID: UUID? = nil, progress: Bool = false) -> AppNotification {
        let event = AppNotification(message: message, detail: detail, kind: kind, actions: actions,
                                    householdID: householdID, progress: progress ? true : nil)
        events.insert(event, at: 0)
        persist()
        return event
    }

    @discardableResult
    func finishProgress(_ id: UUID, message: String, detail: String? = nil,
                        kind: AppNotification.Kind = .success, actions: [AppNotificationAction] = []) -> AppNotification? {
        guard let index = events.firstIndex(where: { $0.id == id && $0.isInProgress }) else { return nil }
        var event = events[index]
        event.message = message; event.detail = detail; event.kind = kind; event.actions = actions
        event.progress = nil; event.date = Date(); event.isRead = false
        events[index] = event
        persist()
        return event
    }

    func removeProgress(_ id: UUID) {
        guard events.contains(where: { $0.id == id && $0.isInProgress }) else { return }
        events.removeAll { $0.id == id && $0.isInProgress }
        persist()
    }

    private static func isCopyNoise(_ message: String) -> Bool {
        ["Адрес почты скопирован", "Почта скопирована", "Email address copied", "Email copied",
         "Промпт скопирован", "Prompt copied"].contains(message)
    }

    func markAllRead() {
        guard unreadCount > 0 else { return }
        events = events.map { var event = $0; event.isRead = true; return event }
        persist()
    }

    func request(_ destination: NotificationNavigation.Destination) {
        navigation = NotificationNavigation(destination: destination)
    }

    func reconcileWallet(_ captures: [CloudCapture], householdID: UUID) {
        let ids = Set(captures.map(\.id))
        var next = events
        for index in next.indices where next[index].householdID == householdID && next[index].kind == .review {
            if next[index].sourceID.map(ids.contains) != true {
                next[index].isResolved = true
                next[index].isRead = true
            }
        }
        // An import's review action describes the current inbox, not a past count.
        for index in next.indices where next[index].householdID == householdID &&
            next[index].sourceID == nil && !next[index].isInProgress && next[index].actions.contains(.inbox) {
            if captures.isEmpty {
                next[index].isResolved = true; next[index].isRead = true
            } else if !next[index].isResolved {
                next[index].detail = L("Покупок на проверке: \(captures.count)")
            }
        }
        for capture in captures {
            let source = [capture.label, capture.card].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
            let detail = [capture.merchant.isEmpty ? L("Продавец не получен") : capture.merchant,
                          "\(capture.amount) \(capture.currency) · \(source)",
                          L(capture.reason ?? "Проверьте покупку")].joined(separator: "\n")
            let message = capture.awaitsCardLink ? L("Новая карта в Wallet: выберите счет") : L("Покупка из Wallet ожидает обработки")
            if let index = next.firstIndex(where: { $0.sourceID == capture.id && $0.householdID == householdID }) {
                if next[index].message != message || next[index].detail != detail || next[index].isResolved {
                    next[index].message = message
                    next[index].detail = detail
                    next[index].isResolved = false
                    next[index].isRead = false
                }
            } else {
                let event = AppNotification(message: message, detail: detail,
                                            kind: .review, actions: [.review(capture.id)], sourceID: capture.id,
                                            householdID: householdID)
                next.insert(event, at: 0)
            }
        }
        guard next != events else { return }
        events = next
        persist()
    }

    private func persist() {
        revision &+= 1
        let version = revision
        pendingSave?.cancel()
        pendingSave = Task { @MainActor in
            guard !Task.isCancelled else { return }
            await load()
            guard !Task.isCancelled else { return }
            guard canPersist else { return }
            let snapshot = events.filter { !$0.isInProgress }
            do {
                try await storage.save(snapshot, revision: version)
                if revision == version { storageError = nil }
            } catch {
                if revision == version { storageError = L("Не удалось сохранить историю уведомлений.") }
            }
        }
    }
}

private actor NotificationStorage {
    private let fileURL: URL?
    private var revision: UInt64 = 0
    init(fileURL: URL?) { self.fileURL = fileURL }
    func load() throws -> [AppNotification] {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([AppNotification].self, from: Data(contentsOf: fileURL))
    }
    func save(_ events: [AppNotification], revision next: UInt64) throws {
        guard next > revision, let fileURL else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(events).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        revision = next
    }
}
