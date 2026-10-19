import SwiftUI
import FinanceCore

private enum NotificationStyle {
    static let attention = Color(red: 0.78, green: 0.25, blue: 0.17)
}

struct AppNotificationBell: View {
    @ObservedObject var notifications: AppNotifications
    @EnvironmentObject private var cloud: CloudSync
    @State private var presented = false

    var body: some View {
        let needsReview = !cloud.pending.isEmpty
        Button { presented.toggle() } label: {
            Image(systemName: needsReview ? "bell.fill" : "bell")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(needsReview ? NotificationStyle.attention : Color.primary)
                .frame(width: 36, height: 36)
                .background(needsReview ? NotificationStyle.attention.opacity(0.12) : .clear,
                            in: Circle())
                .contentShape(Circle())
                .overlay(alignment: .topTrailing) {
                    if needsReview {
                        Image(systemName: "exclamationmark").font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(.white).frame(width: 13, height: 13)
                            .background(NotificationStyle.attention, in: Circle())
                    } else if notifications.unreadCount > 0 {
                        Circle().fill(Color.moraGreen).frame(width: 7, height: 7).padding(2)
                    }
                }
        }
        .modifier(ToolbarGlassStyle(shape: Circle()))
        .help(L("Уведомления приложения"))
        .accessibilityLabel(L("Уведомления приложения"))
        .accessibilityValue(needsReview ? L("Покупок на проверке: \(cloud.pending.count)") : L("Непрочитанных: \(notifications.unreadCount)"))
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            NotificationsPanel(notifications: notifications, close: { presented = false })
        }
    }
}

struct ToolbarGlassStyle<S: InsettableShape>: ViewModifier {
    let shape: S
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.plain).background(.regularMaterial, in: shape)
                .glassEffect(.regular.interactive(), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5).allowsHitTesting(false))
        } else {
            content.buttonStyle(.plain).background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1).allowsHitTesting(false))
        }
    }
}

private struct NotificationsPanel: View {
    @ObservedObject var notifications: AppNotifications
    @EnvironmentObject private var cloud: CloudSync
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Уведомления приложения")).font(.headline)
                    Text(L("История событий на этом Mac")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                    .buttonStyle(.plain).accessibilityLabel(L("Закрыть"))
            }.padding(18)
            Divider()
            if !cloud.pending.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle.fill").font(.title2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("Покупок на проверке: \(cloud.pending.count)")).font(.callout.weight(.semibold))
                        NotificationActionButton(action: .inbox, onNavigate: close)
                    }
                    Spacer()
                }.foregroundStyle(NotificationStyle.attention).padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(NotificationStyle.attention.opacity(0.08))
                Divider()
            }
            if notifications.events.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bell").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(L("Пока нет уведомлений")).font(.callout.weight(.medium))
                    Text(L("Здесь появятся события приложения и доступные действия."))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(notifications.events) { event in
                            NotificationRow(event: event, onNavigate: close)
                            Divider().padding(.leading, 48)
                        }
                    }
                }
            }
            if let error = notifications.storageError {
                Text(error).font(.caption).foregroundStyle(NotificationStyle.attention).padding(12)
            }
        }
        .frame(width: 420, height: 500)
        .onAppear { notifications.markAllRead() }
        .onChange(of: notifications.events.map(\.id)) { _, _ in notifications.markAllRead() }
    }
}

private struct NotificationRow: View {
    let event: AppNotification
    var onNavigate: () -> Void
    private var icon: String {
        switch event.kind {
        case .success: return "checkmark.circle.fill"
        case .information: return "info.circle.fill"
        case .warning, .error: return "exclamationmark.circle.fill"
        case .review: return event.isResolved ? "checkmark.circle.fill" : "creditcard.fill"
        }
    }
    private var color: Color {
        event.kind == .error || event.kind == .warning || (event.kind == .review && !event.isResolved)
            ? NotificationStyle.attention : .moraGreen
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                Text(L(event.message)).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                if let detail = event.detail { FinancialText(detail).font(.caption).foregroundStyle(.secondary) }
                if event.isResolved { Text(L("Больше не требует проверки")).font(.caption).foregroundStyle(Color.moraGreen) }
                Text(event.date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(L10n.locale)))
                    .font(.caption2).foregroundStyle(.tertiary)
                NotificationActions(event: event, onNavigate: onNavigate)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(16)
    }
}

struct NotificationActions: View {
    let event: AppNotification
    var onNavigate: () -> Void = {}
    var body: some View {
        HStack(spacing: 12) {
            ForEach(event.actions) { action in
                NotificationActionButton(action: action, onNavigate: onNavigate)
            }
        }.font(.caption)
    }
}

struct NotificationActionButton: View {
    let action: AppNotificationAction
    var onNavigate: () -> Void = {}
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var cloud: CloudSync
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingRollback = false
    private var available: Bool {
        if case .review(let id) = action { return cloud.pending.contains { $0.id == id } }
        return store.canPerformNotificationAction(action)
    }

    var body: some View {
        Button(action.title, action: perform).buttonStyle(.link).disabled(!available)
            .help(available ? action.title : L("Действие больше недоступно"))
            .confirmationDialog(L("Отменить импорт с измененными операциями?"), isPresented: $confirmingRollback,
                                titleVisibility: .visible) {
                Button(L("Отменить импорт"), role: .destructive) {
                    if case .rollbackImport(let id) = action { store.rollbackImport(id, allowModified: true) }
                }
                Button(L("Сохранить операции"), role: .cancel) {}
            } message: {
                if case .rollbackImport(let id) = action, let preview = try? store.ledger.importRollbackPreview(id) {
                    Text(L("Будет удалено операций: \(preview.remaining). Из них изменено или создано разделением: \(preview.modified). Остальные операции, счета и категории сохранятся. Отмену можно вернуть через меню «Финансы»."))
                }
            }
    }

    private func perform() {
        switch action {
        case .undo, .redo: store.performHistoryAction(action)
        case .rollbackImport(let id):
            store.reloadFromDisk()
            do {
                let preview = try store.ledger.importRollbackPreview(id)
                if preview.modified > 0 { confirmingRollback = true }
                else { store.rollbackImport(id) }
            } catch { store.error = error.localizedDescription }
        case .imports: navigate(.page(.imports), window: "main")
        case .settings: navigate(.page(.settings), window: "main")
        case .inbox: navigate(.inbox, window: "cloud")
        case .review(let id): navigate(.capture(id), window: "cloud")
        }
    }
    private func navigate(_ destination: NotificationNavigation.Destination, window: String) {
        onNavigate()
        store.notifications.request(destination)
        openWindow(id: window)
    }
}
