import Foundation
import Combine
import FinanceCore

enum AppNotificationAction: Codable, Equatable, Identifiable {
    case undo(String), redo(String), rollbackImport(UUID)
    case imports, settings, inbox, review(UUID)

    var id: String {
        switch self {
        case .undo(let token): return "undo:\(token)"
        case .redo(let token): return "redo:\(token)"
        case .rollbackImport(let id): return "import:\(id)"
        case .imports: return "imports"
        case .settings: return "settings"
        case .inbox: return "inbox"
        case .review(let id): return "review:\(id)"
        }
    }
    var title: String {
        switch self {
        case .undo: return L("Отменить")
        case .redo: return L("Вернуть")
        case .rollbackImport: return L("Отменить импорт")
        case .imports: return L("История импортов")
        case .settings: return L("Настройки")
        case .inbox: return L("Открыть входящие")
        case .review: return L("Проверить…")
        }
    }
}

struct AppNotification: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case success, information, warning, error, review }
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

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            events = try decoder.decode([AppNotification].self, from: Data(contentsOf: fileURL))
        } catch {
            // Preserve a damaged file rather than replacing its history on the next event.
            storageError = L("Не удалось прочитать историю уведомлений.")
            canPersist = false
        }
    }

    var unreadCount: Int { events.filter { !$0.isRead }.count }

    @discardableResult
    func record(_ message: String, detail: String? = nil, kind: AppNotification.Kind = .success,
                actions: [AppNotificationAction] = []) -> AppNotification {
        let event = AppNotification(message: message, detail: detail, kind: kind, actions: actions)
        events.insert(event, at: 0)
        persist()
        return event
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
            if !next[index].isResolved && next[index].sourceID.map(ids.contains) != true { next[index].isResolved = true }
        }
        for capture in captures {
            let detail = [capture.merchant.isEmpty ? L("Продавец не получен") : capture.merchant,
                          "\(capture.amount) \(capture.currency) · \(capture.label)",
                          L(capture.reason ?? "Проверьте покупку")].joined(separator: "\n")
            if let index = next.firstIndex(where: { $0.sourceID == capture.id && $0.householdID == householdID }) {
                if next[index].detail != detail || next[index].isResolved {
                    next[index].detail = detail
                    next[index].isResolved = false
                    next[index].isRead = false
                }
            } else {
                let event = AppNotification(message: L("Покупка из Wallet требует проверки"), detail: detail,
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
        guard canPersist, let fileURL else { return }
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(events).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            storageError = nil
        } catch { storageError = L("Не удалось сохранить историю уведомлений.") }
    }
}
