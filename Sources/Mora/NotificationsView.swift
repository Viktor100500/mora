import SwiftUI
import FinanceCore

private struct NotificationWindowOpenerKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (String) -> Void)? = nil
}

private extension EnvironmentValues {
    var notificationWindowOpener: (@MainActor @Sendable (String) -> Void)? {
        get { self[NotificationWindowOpenerKey.self] }
        set { self[NotificationWindowOpenerKey.self] = newValue }
    }
}

private enum NotificationStyle {
    static let attention = Color(red: 0.78, green: 0.25, blue: 0.17)
    static let review = Color(red: 0.72, green: 0.49, blue: 0.05)
}

struct AppNotificationBell: View {
    @ObservedObject var notifications: AppNotifications
    @EnvironmentObject private var cloud: CloudSync
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow
    @StateObject private var presenter = NotificationPopoverPresenter()

    private func panel(_ rows: [NotificationListEntry], close: @escaping () -> Void) -> AnyView {
        let openWindow = openWindow
        return AnyView(NotificationsPanel(notifications: notifications, initialRows: rows, close: close)
            .environmentObject(store).environmentObject(cloud)
            .environment(\.colorScheme, scheme)
            .environment(\.notificationWindowOpener, { id in openWindow(id: id) })
            .environment(\.locale, L10n.locale).tint(.moraGreen))
    }

    var body: some View {
        let needsReview = !cloud.pending.isEmpty
        Button {
            let history = notifications, store = store, cloud = cloud
            let scheme = scheme, openWindow = openWindow
            presenter.toggle(notifications: history) { rows, close in
                AnyView(NotificationsPanel(notifications: history, initialRows: rows, close: close)
                    .environmentObject(store).environmentObject(cloud)
                    .environment(\.colorScheme, scheme)
                    .environment(\.notificationWindowOpener, { id in openWindow(id: id) })
                    .environment(\.locale, L10n.locale).tint(.moraGreen))
            }
        } label: {
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
        .background(NotificationPopoverAnchor(presenter: presenter).allowsHitTesting(false))
        .task(id: notifications.recentEvents) {
            await presenter.warmUp(notifications: notifications, content: panel)
        }
    }
}

/// AppKit owns the hosting controller for the entire presentation. A closing popover
/// cannot remove the contents of a newer one, and size never depends on optional SwiftUI state.
@MainActor
final class NotificationPopoverPresenter: NSObject, ObservableObject, NSPopoverDelegate {
    weak var anchor: NSView?
    private(set) var popover: NSPopover?
    private var preparation: Task<Void, Never>?
    private var requestID: UUID?
    private var cachedController: NSHostingController<AnyView>?
    private var cachedEvents: [AppNotification] = []
    private var queuedOpen: (@MainActor () -> Void)?
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private(set) var isOpening = false
    private(set) var isClosing = false
    var isPreparing: Bool { preparation != nil }

    private func displayEvents(_ notifications: AppNotifications) -> [AppNotification] {
        notifications.recentEvents.map { var event = $0; event.isRead = true; return event }
    }

    func warmUp(notifications: AppNotifications,
                content: @escaping @MainActor ([NotificationListEntry], @escaping () -> Void) -> AnyView) async {
        if popover != nil {
            if !isClosing { notifications.markRecentRead() }
            return
        }
        let key = displayEvents(notifications)
        guard cachedController == nil || cachedEvents != key else { return }
        let rows = await notifications.preparePage()
        guard !Task.isCancelled, popover == nil, displayEvents(notifications) == key else { return }
        let controller = NSHostingController(rootView: content(rows, { [weak self] in self?.close() }))
        controller.preferredContentSize = NSSize(width: 420, height: 500)
        controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        controller.view.layoutSubtreeIfNeeded()
        cachedController = controller
        cachedEvents = key
    }

    func toggle(notifications: AppNotifications,
                content: @escaping @MainActor ([NotificationListEntry], @escaping () -> Void) -> AnyView) {
        if isClosing {
            if queuedOpen == nil {
                queuedOpen = { [weak self] in self?.toggle(notifications: notifications, content: content) }
            } else { queuedOpen = nil }
            return
        }
        if isPreparing || popover != nil { close(); return }
        notifications.markRecentRead()
        if let cachedController, cachedEvents == displayEvents(notifications) {
            show(cachedController)
            return
        }
        let id = UUID()
        requestID = id
        preparation = Task { @MainActor [weak self] in
            defer {
                if self?.requestID == id { self?.preparation = nil; self?.requestID = nil }
            }
            await self?.warmUp(notifications: notifications, content: content)
            guard let self, self.requestID == id, !Task.isCancelled, let controller = self.cachedController else { return }
            self.show(controller)
        }
    }

    private func show(_ controller: NSHostingController<AnyView>) {
        guard let anchor, anchor.window != nil else { return }
        let popover = NSPopover()
        // Handle outside clicks ourselves so a bell mouse-down does not dismiss
        // the popover before the same click's button action can toggle it closed.
        popover.behavior = .applicationDefined
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 420, height: 500)
        self.popover = popover
        isOpening = true
        installDismissalObservers()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover.contentSize = NSSize(width: 420, height: 500)
    }

    func close() {
        queuedOpen = nil
        requestID = nil
        preparation?.cancel(); preparation = nil
        guard let current = popover else { removeDismissalObservers(); return }
        guard !isClosing else { return }
        isClosing = true
        current.performClose(nil)
    }

    func detach() {
        queuedOpen = nil; requestID = nil
        preparation?.cancel(); preparation = nil
        removeDismissalObservers()
        let current = popover
        popover = nil; isOpening = false; isClosing = false
        current?.animates = false
        current?.performClose(nil)
        current?.contentViewController = nil
    }

    func popoverDidShow(_ notification: Notification) {
        guard let shown = notification.object as? NSPopover, shown === popover else { return }
        isOpening = false
        if isClosing { shown.performClose(nil) }
    }

    func popoverWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSPopover, closing === popover else { return }
        isClosing = true
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        popover = nil; isOpening = false; isClosing = false
        closed.contentViewController = nil
        removeDismissalObservers()
        let reopen = queuedOpen
        queuedOpen = nil
        reopen?()
    }

    private func installDismissalObservers() {
        removeDismissalObservers()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.close(); return true }
                } else { self.dismissIfOutside(event) }
                return false
            }
            return consumed ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
    }

    private func removeDismissalObservers() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
    }

    private func dismissIfOutside(_ event: NSEvent) {
        guard let popover else { return }
        if event.window === popover.contentViewController?.view.window { return }
        if event.type == .leftMouseDown, let anchor, event.window === anchor.window,
           anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return }
        close()
    }
}

private struct NotificationPopoverAnchor: NSViewRepresentable {
    let presenter: NotificationPopoverPresenter
    func makeNSView(context: Context) -> NotificationPopoverAnchorView {
        let view = NotificationPopoverAnchorView()
        view.presenter = presenter; presenter.anchor = view
        return view
    }
    func updateNSView(_ nsView: NotificationPopoverAnchorView, context: Context) {
        presenter.anchor = nsView
    }
}

private final class NotificationPopoverAnchorView: NSView {
    weak var presenter: NotificationPopoverPresenter?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { presenter?.detach() }
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

struct NotificationsPanel: View {
    @ObservedObject var notifications: AppNotifications
    @EnvironmentObject private var cloud: CloudSync
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.notificationWindowOpener) private var notificationWindowOpener
    var close: () -> Void
    @State private var rows: [NotificationListEntry]

    init(notifications: AppNotifications, initialRows: [NotificationListEntry] = [], close: @escaping () -> Void) {
        self.notifications = notifications; self.close = close
        _rows = State(initialValue: initialRows)
    }

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
                    if let notificationWindowOpener { notificationWindowOpener("main") }
                    else { openWindow(id: "main") }
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
                        ForEach(rows) { row in
                            NotificationRow(entry: row, onNavigate: close)
                            Divider().padding(.leading, 48)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text(L("Последние 100 событий")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Полная история в настройках")) {
                    close()
                    notifications.request(.page(.settings))
                    if let notificationWindowOpener { notificationWindowOpener("main") }
                    else { openWindow(id: "main") }
                }.buttonStyle(.link).font(.caption)
            }.padding(12)
            if let error = notifications.storageError {
                Text(error).font(.caption).foregroundStyle(NotificationStyle.attention).padding(12)
            }
        }
        .frame(width: 420, height: 500)
        .task(id: notifications.recentEvents) {
            let prepared = await notifications.preparePage()
            guard !Task.isCancelled else { return }
            if rows != prepared { rows = prepared }
        }
    }
}

struct NotificationHistoryView: View {
    @ObservedObject var notifications: AppNotifications
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: [AppNotification] = []
    @State private var rows: [NotificationListEntry] = []
    @State private var loading = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("История уведомлений")).font(.title2.weight(.semibold))
                Spacer()
                Button(L("Закрыть")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        NotificationRow(entry: row, onNavigate: { dismiss() })
                        Divider().padding(.leading, 48)
                    }
                    if loading { ProgressView().padding(20) }
                    else if rows.count < snapshot.count {
                        Button(L("Показать ещё 100")) { Task { await loadNextPage() } }.padding(20)
                    } else if rows.isEmpty {
                        Text(L("Пока нет уведомлений")).foregroundStyle(.secondary).padding(30)
                    }
                }
            }
            Divider()
            Text(L("Все события сохраняются на этом Mac.")).font(.caption).foregroundStyle(.secondary).padding(14)
        }
        .frame(width: 680, height: 640)
        .task {
            snapshot = notifications.events
            await loadNextPage()
        }
    }
    private func loadNextPage() async {
        guard !loading else { return }
        loading = true
        let page = await notifications.preparePage(offset: rows.count, from: snapshot)
        guard !Task.isCancelled else { loading = false; return }
        rows += page
        loading = false
    }
}

private struct NotificationRow: View {
    let entry: NotificationListEntry
    private var event: AppNotification { entry.event }
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
                if event.isInProgress { ProgressView().controlSize(.small).tint(.moraGreen) }
                else { Image(systemName: icon).foregroundStyle(color) }
            }.frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                Text(L(event.message)).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                if let detail = event.detail { FinancialText(detail).font(.caption).foregroundStyle(.primary.opacity(0.78)) }
                if event.isResolved { Text(L("Больше не требует проверки")).font(.caption.weight(.medium)).foregroundStyle(Color.moraGreen) }
                Text(entry.dateLabel)
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
    @Environment(\.notificationWindowOpener) private var notificationWindowOpener
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
        case .inbox: navigate(.inbox, window: "main")
        case .review(let id): navigate(.capture(id), window: "main")
        case .retryTransaction(let id): store.retryTransactionSave(id)
        }
     } }
    private func navigate(_ destination: NotificationNavigation.Destination, window: String) {
        onNavigate()
        store.notifications.request(destination)
        if let notificationWindowOpener { notificationWindowOpener(window) }
        else { openWindow(id: window) }
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
        case .information: Color.moraGreen
        default: Color.moraGreen
        }
    }
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if event.isInProgress { ProgressView().controlSize(.small).tint(.moraGreen).transition(.opacity) }
                else {
                    Image(systemName: event.kind == .error || event.kind == .warning
                          ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(noticeColor).transition(.opacity)
                }
            }.frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.message).font(.callout.weight(.medium)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true).contentTransition(.opacity)
                if let detail = event.detail {
                    FinancialText(detail).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true).transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            NotificationActions(event: event).fixedSize(horizontal: true, vertical: false)
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
