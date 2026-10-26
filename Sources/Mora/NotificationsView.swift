import SwiftUI
import FinanceCore

private enum NotificationStyle {
    static let attention = Color(red: 0.78, green: 0.25, blue: 0.17)
    static let review = Color(red: 0.72, green: 0.49, blue: 0.05)
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
                .foregroundStyle(needsReview ? NotificationStyle.review : Color.primary)
                .frame(width: 36, height: 36)
                .background(needsReview ? NotificationStyle.review.opacity(0.12) : .clear,
                            in: Circle())
                .contentShape(Circle())
                .overlay(alignment: .topTrailing) {
                    if needsReview {
                        Image(systemName: "exclamationmark").font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(.white).frame(width: 13, height: 13)
                            .background(NotificationStyle.review, in: Circle())
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
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.openWindow) private var openWindow
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
                Button {
                    close()
                    store.notifications.request(.inbox)
                    openWindow(id: "cloud")
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.circle.fill").font(.title2)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L("Покупок на проверке: \(cloud.pending.count)")).font(.callout.weight(.semibold))
                            Text(AppNotificationAction.inbox.title)
                        }
                        Spacer()
                    }.foregroundStyle(NotificationStyle.review).padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(NotificationStyle.review.opacity(0.15))
                        .overlay(Rectangle().stroke(NotificationStyle.review.opacity(0.26), lineWidth: 1))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
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
        .onChange(of: notifications.events) { _, _ in notifications.markAllRead() }
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
        if event.kind == .error { return NotificationStyle.attention }
        if event.kind == .warning || (event.kind == .review && !event.isResolved) { return NotificationStyle.review }
        return .moraGreen
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if event.isInProgress { ProgressView().controlSize(.small) }
                else { Image(systemName: icon).foregroundStyle(color) }
            }.frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                Text(L(event.message)).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                if let detail = event.detail { FinancialText(detail).font(.caption).foregroundStyle(.primary.opacity(0.78)) }
                if event.isResolved { Text(L("Больше не требует проверки")).font(.caption.weight(.medium)).foregroundStyle(Color.moraGreen) }
                Text(event.date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(L10n.locale)))
                    .font(.caption2).foregroundStyle(.secondary)
                NotificationActions(event: event, onNavigate: onNavigate)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(16).background(color.opacity(0.055))
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
                Button(L("Отменить импорт"), role: .destructive) { Task { @MainActor in
                    if case .rollbackImport(let id) = action { await store.rollbackImport(id, allowModified: true) }
                 } }
                Button(L("Сохранить операции"), role: .cancel) {}
            } message: {
                if case .rollbackImport(let id) = action, let preview = store.imports.previews[id] {
                    Text(L("Будет удалено операций: \(preview.remaining). Из них изменено или создано разделением: \(preview.modified). Остальные операции, счета и категории сохранятся. Отмену можно вернуть через меню «Финансы»."))
                }
            }
    }

    private func perform() { Task { @MainActor in
        switch action {
        case .undo, .redo: await store.performHistoryAction(action)
        case .rollbackImport(let id):
            await store.reloadFromDisk()
            do {
                guard let preview = store.imports.previews[id] else { throw LedgerError.invalid(L("Этот импорт уже отменен или не найден.")) }
                if preview.modified > 0 { confirmingRollback = true }
                else { await store.rollbackImport(id) }
            } catch { store.error = error.localizedDescription }
        case .imports: navigate(.page(.imports), window: "main")
        case .settings: navigate(.page(.settings), window: "main")
        case .inbox: navigate(.inbox, window: "cloud")
        case .review(let id): navigate(.capture(id), window: "cloud")
        case .retryTransaction(let id): store.retryTransactionSave(id)
        }
     } }
    private func navigate(_ destination: NotificationNavigation.Destination, window: String) {
        onNavigate()
        store.notifications.request(destination)
        openWindow(id: window)
    }
}

/// A window overlay never contributes a safe-area inset or participates in page layout.
struct FloatingNotificationOverlay: ViewModifier {
    var event: AppNotification?
    var close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            ZStack(alignment: .topTrailing) {
                if let event {
                    AppNoticeBanner(event: event, close: close)
                        .id(event.id)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -8)))
                }
            }
            .padding(.horizontal, 24).padding(.top, 12)
            .animation(reduceMotion ? nil : AppMotion.notification, value: event)
        }
    }
}

private struct AppNoticeBanner: View {
    let event: AppNotification
    let close: () -> Void
    private var noticeColor: Color {
        switch event.kind {
        case .warning: Color(red: 0.72, green: 0.49, blue: 0.05)
        case .error: Color.token("red")
        case .information: Color.accentColor
        default: Color.moraGreen
        }
    }
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if event.isInProgress { ProgressView().controlSize(.small).transition(.opacity) }
                else {
                    Image(systemName: event.kind == .error || event.kind == .warning
                          ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(noticeColor).transition(.opacity)
                }
            }.frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.message).font(.callout.weight(.medium)).lineLimit(1).contentTransition(.opacity)
                if let detail = event.detail {
                    FinancialText(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).transition(.opacity)
                }
            }
            Spacer(minLength: 8)
            NotificationActions(event: event)
            if !event.isInProgress {
                Button(action: close) { Image(systemName: "xmark").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(L("Закрыть уведомление"))
            }
        }
        .frame(minHeight: 34)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 680, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(noticeColor.opacity(0.24), lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}
