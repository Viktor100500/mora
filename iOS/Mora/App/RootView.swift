import SwiftUI
import UIKit
import FinanceCore

struct RootView: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var cloud: CloudSync
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var categorizer: MerchantCategorizer
    @EnvironmentObject private var reviewQueue: WalletReviewQueue
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("mora.didSeeWelcome") private var didSeeWelcome = false

    private var colorScheme: ColorScheme? {
        switch store.ledger.preferences.appearance { case "light": .light; case "dark": .dark; default: nil }
    }

    var body: some View {
        TabView(selection: Binding(get: { router.tab }, set: { router.select($0) })) {
            OverviewScreen()
                .modifier(ManagedTabBarVisibility())
                .tabItem { Label(L("Обзор"), systemImage: "square.grid.2x2") }.tag(AppTab.overview)
            TransactionsScreen()
                .modifier(ManagedTabBarVisibility())
                .tabItem { Label(L("Операции"), systemImage: "arrow.left.arrow.right") }.tag(AppTab.transactions)
            AnalyticsScreen()
                .modifier(ManagedTabBarVisibility())
                .tabItem { Label(L("Аналитика"), systemImage: "chart.xyaxis.line") }.tag(AppTab.analytics)
            AccountsScreen()
                .modifier(ManagedTabBarVisibility())
                .tabItem { Label(L("Счета"), systemImage: "wallet.bifold") }.tag(AppTab.accounts)
            MoreScreen()
                .modifier(ManagedTabBarVisibility())
                .tabItem { Label(L("Ещё"), systemImage: "ellipsis.circle") }.tag(AppTab.more)
                .badge(reviewQueue.count(with: cloud))
        }
        .modifier(StableSystemTabBar(router: router, reviewCount: reviewQueue.count(with: cloud)))
        .tint(.moraGreen)
        .environment(\.locale, L10n.locale)
        .preferredColorScheme(colorScheme)
        .overlay(alignment: .top) { ToastBanner() }
        .overlay { if store.isLoading { ProgressView().controlSize(.large) } }
        .modifier(PrivacyShield())
        .sheet(item: $router.sheet) { sheet in
            SheetContent(sheet: sheet)
                .environmentObject(store).environmentObject(cloud).environmentObject(router).environmentObject(categorizer).environmentObject(reviewQueue)
                .environment(\.locale, L10n.locale)
                .tint(.moraGreen)
                .modifier(ErrorAlert())
        }
        .modifier(ErrorAlert(active: router.sheet == nil))
        .task {
            await store.load()
            if store.isDemo && !didSeeWelcome && !ProcessInfo.processInfo.arguments.contains("--demo") { router.sheet = .welcome }
            #if DEBUG
            applyDebugLaunchArguments()
            #endif
            await cloud.prepare(store: store)
        }
        .onChange(of: store.revision) { cloud.localChanged() }
        .onChange(of: router.sheet == nil) { _, closed in if closed { reviewQueue.reload() } }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            cloud.finishInBackground()
            Task { await WalletBackgroundDelivery.scheduleIfNeeded() }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            reviewQueue.reload()
            await store.reloadFromDisk()
            // Purchases saved while offline go out as soon as Mora is opened.
            async let wallet: Void = { await WalletBackgroundDelivery.run(); await reviewQueue.reload() }()
            async let rates: Void = rateLoop()
            async let sync: Void = cloud.run()
            // Purchases booked by the server or another device arrive without a category.
            async let categories: Void = categorizer.run(store: store)
            _ = await (wallet, rates, sync, categories)
        }
        .onOpenURL { url in
            guard url.isFileURL else { return }
            Task { @MainActor in
                if url.pathExtension.lowercased() == "csv", let file = await store.readCSV(at: url) {
                    router.open(.csv(file.0, file.1))
                }
            }
        }
    }

    #if DEBUG
    /// `--tab analytics`, `--sheet transaction|account|first-transaction` and `--more settings|categories|cloud`
    /// open a screen directly for screenshots and manual checks in the simulator.
    private func applyDebugLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        switch value("--tab") {
        case "transactions": router.tab = .transactions
        case "analytics": router.tab = .analytics
        case "accounts": router.tab = .accounts
        case "more": router.tab = .more
        default: break
        }
        router.debugMoreDestination = value("--more")
        switch value("--sheet") {
        case "transaction": router.sheet = .transaction(nil)
        case "first-transaction": router.sheet = store.ledger.transactions.max { $0.date < $1.date }.map { .transaction($0) }
        case "account": router.sheet = .account(nil)
        case "category": router.sheet = .category(nil, .expense)
        case "welcome": router.sheet = .welcome
        case "wallet-guide": router.sheet = .walletGuide
        case "sms-guide": router.sheet = .automationGuide(.bankSMS)
        default: break
        }
    }
    #endif

    private func rateLoop() async {
        while !Task.isCancelled {
            await store.refreshExchangeRates()
            do { try await Task.sleep(for: .seconds(900)) } catch { return }
        }
    }
}

private struct MoraTabBarInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private extension EnvironmentValues {
    /// Height the floating tab bar covers above the bottom safe area.
    var moraTabBarInset: CGFloat {
        get { self[MoraTabBarInsetKey.self] }
        set { self[MoraTabBarInsetKey.self] = newValue }
    }
}

/// Each tab hides the controller-owned bar and reserves the floating bar's height
/// in its own safe area, so lists, scroll views and pushed screens stop above it.
/// The inset is applied inside the tab: UITabBarController does not pass an outer
/// SwiftUI inset on to its children.
private struct ManagedTabBarVisibility: ViewModifier {
    @Environment(\.moraTabBarInset) private var inset
    func body(content: Content) -> some View {
        if #available(iOS 26, *), UIDevice.current.userInterfaceIdiom == .phone {
            content
                .toolbar(.hidden, for: .tabBar)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: inset).allowsHitTesting(false).accessibilityHidden(true)
                }
        } else { content }
    }
}

private struct StableSystemTabBar: ViewModifier {
    @ObservedObject var router: AppRouter
    let reviewCount: Int
    @State private var keyboardVisible = false
    @State private var barInset: CGFloat = 57

    func body(content: Content) -> some View {
        if #available(iOS 26, *), UIDevice.current.userInterfaceIdiom == .phone {
            content
                .environment(\.moraTabBarInset, keyboardVisible ? 0 : barInset)
                .overlay(alignment: .bottom) {
                    if !keyboardVisible {
                        SystemTabBar(selection: Binding(get: { router.tab }, set: { router.select($0) }),
                                     reviewCount: reviewCount,
                                     onContentInset: { if abs(barInset - $0) > 0.5 { barInset = $0 } })
                            .frame(height: GlassTabBar.height)
                            .ignoresSafeArea(.all, edges: .bottom)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        } else { content }
    }
}

/// A floating Liquid Glass tab bar. The selection pill and the glass lens are moved
/// with explicit UIKit animations, so they keep animating with Reduce Motion on,
/// unlike UITabBar, whose lens morph the system turns off in that mode.
@available(iOS 26, *)
private struct SystemTabBar: UIViewRepresentable {
    @Binding var selection: AppTab
    let reviewCount: Int
    let onContentInset: (CGFloat) -> Void
    private static let tabs: [(AppTab, String, String)] = [
        (.overview, "Обзор", "square.grid.2x2"),
        (.transactions, "Операции", "arrow.left.arrow.right"),
        (.analytics, "Аналитика", "chart.xyaxis.line"),
        (.accounts, "Счета", "wallet.bifold"),
        (.more, "Ещё", "ellipsis.circle")
    ]

    final class Coordinator {
        var selection: Binding<AppTab>
        var onContentInset: (CGFloat) -> Void
        init(selection: Binding<AppTab>, onContentInset: @escaping (CGFloat) -> Void) {
            self.selection = selection
            self.onContentInset = onContentInset
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, onContentInset: onContentInset) }

    func makeUIView(context: Context) -> GlassTabBar {
        let view = GlassTabBar(symbols: Self.tabs.map(\.2))
        let coordinator = context.coordinator
        view.onSelect = { [weak view] index in
            guard let view, Self.tabs.indices.contains(index) else { return }
            let tab = Self.tabs[index].0
            if coordinator.selection.wrappedValue == tab {
                coordinator.selection.wrappedValue = tab
            } else {
                view.crossfadeContent { coordinator.selection.wrappedValue = tab }
            }
        }
        view.onContentInset = { inset in
            DispatchQueue.main.async { coordinator.onContentInset(inset) }
        }
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: GlassTabBar, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.onContentInset = onContentInset
        view.tintColor = UIColor(Color.moraGreen)
        view.semanticContentAttribute = context.environment.layoutDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        view.setTitles(Self.tabs.map { L($0.1) })
        if let index = Self.tabs.firstIndex(where: { $0.0 == selection }) {
            view.setSelectedIndex(index, animated: view.window != nil)
        }
        view.setBadge(reviewCount > 0 ? String(reviewCount) : nil,
                      accessibilityValue: reviewCount > 0 ? L("Покупок на проверке: \(reviewCount)") : nil)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: GlassTabBar, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 375, height: GlassTabBar.height)
    }
}

@available(iOS 26, *)
private final class GlassTabBar: UIView {
    static let capsuleHeight: CGFloat = 62
    static let topRoom: CGFloat = 14
    static let sideMargin: CGFloat = 20
    static let maxBottomMargin: CGFloat = 21
    /// The view reaches the bottom of the screen; the capsule floats above it.
    static let height = topRoom + capsuleHeight + maxBottomMargin
    static func bottomMargin(homeInset: CGFloat) -> CGFloat { homeInset > 0 ? maxBottomMargin : 10 }
    /// How far the capsule (plus a small gap) rises above the bottom safe area.
    static func contentInset(homeInset: CGFloat) -> CGFloat {
        max(0, capsuleHeight + bottomMargin(homeInset: homeInset) - homeInset + 8)
    }

    var onSelect: ((Int) -> Void)?
    var onContentInset: ((CGFloat) -> Void)?

    private let capsule = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let pill = UIView()
    private let lens = UIVisualEffectView(effect: nil)
    private var items: [ItemView] = []
    private var selectedIndex = 0
    private var trackedTouch: UITouch?
    private var hoverIndex: Int?
    private var reportedInset: CGFloat = -1
    private weak var fadingContent: UIView?

    init(symbols: [String]) {
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = false
        isMultipleTouchEnabled = false
        accessibilityTraits = .tabBar

        capsule.cornerConfiguration = .capsule()
        capsule.clipsToBounds = true
        capsule.isUserInteractionEnabled = false
        addSubview(capsule)

        pill.isUserInteractionEnabled = false
        pill.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.07) }
        pill.layer.cornerCurve = .continuous
        capsule.contentView.addSubview(pill)

        items = symbols.enumerated().map { index, symbol in
            let item = ItemView(symbol: symbol)
            item.activate = { [weak self] in self?.commit(index) }
            capsule.contentView.addSubview(item)
            return item
        }

        lens.cornerConfiguration = .capsule()
        lens.clipsToBounds = true
        lens.isUserInteractionEnabled = false
        lens.alpha = 0
        addSubview(lens)

        accessibilityElements = items
        updateItemAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    private var homeInset: CGFloat { window?.safeAreaInsets.bottom ?? 34 }
    private var isRTL: Bool { effectiveUserInterfaceLayoutDirection == .rightToLeft }
    private var itemWidth: CGFloat { max(1, (capsule.bounds.width - 8) / CGFloat(max(items.count, 1))) }

    /// The visual slot of an item, in the capsule's coordinates.
    private func slot(_ index: Int) -> CGRect {
        let visual = isRTL ? items.count - 1 - index : index
        return CGRect(x: 4 + CGFloat(visual) * itemWidth, y: 0, width: itemWidth, height: capsule.bounds.height)
    }
    private func pillFrame(centerX: CGFloat) -> CGRect {
        let height = capsule.bounds.height - 8
        return CGRect(x: centerX - itemWidth / 2, y: 4, width: itemWidth, height: height)
    }
    private func lensFrame(centerX: CGFloat) -> CGRect {
        let width = itemWidth + 14, height = capsule.bounds.height + 12
        let center = CGPoint(x: capsule.frame.minX + centerX, y: capsule.frame.midY)
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }
    private func clampedCenterX(_ x: CGFloat) -> CGFloat {
        min(max(x, 4 + itemWidth / 2), capsule.bounds.width - 4 - itemWidth / 2)
    }
    private func index(atCapsuleX x: CGFloat) -> Int {
        let visual = min(max(Int((x - 4) / itemWidth), 0), items.count - 1)
        return isRTL ? items.count - 1 - visual : visual
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bottom = Self.bottomMargin(homeInset: homeInset)
        let frame = CGRect(x: Self.sideMargin, y: bounds.height - bottom - Self.capsuleHeight,
                           width: max(0, bounds.width - Self.sideMargin * 2), height: Self.capsuleHeight)
        if capsule.frame != frame {
            capsule.frame = frame
            for (index, item) in items.enumerated() { item.frame = slot(index) }
            pill.layer.cornerRadius = (Self.capsuleHeight - 8) / 2
            if trackedTouch == nil { pill.frame = pillFrame(centerX: slot(selectedIndex).midX) }
        }
        let inset = Self.contentInset(homeInset: homeInset)
        if abs(inset - reportedInset) > 0.5 {
            reportedInset = inset
            onContentInset?(inset)
        }
    }
    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); setNeedsLayout() }
    override func didMoveToWindow() { super.didMoveToWindow(); setNeedsLayout() }

    // MARK: State

    func setTitles(_ titles: [String]) {
        for (item, title) in zip(items, titles) where item.title != title { item.title = title }
    }
    func setBadge(_ badge: String?, accessibilityValue: String?) {
        items.last?.badge = badge
        items.last?.accessibilityValue = accessibilityValue
    }
    func setSelectedIndex(_ index: Int, animated: Bool) {
        guard items.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        guard trackedTouch == nil else { return }
        updateItemAppearance()
        let move = { self.pill.frame = self.pillFrame(centerX: self.slot(index).midX) }
        if animated && !capsule.bounds.isEmpty {
            UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState], animations: move)
        } else { move() }
    }
    private func updateItemAppearance() {
        let highlighted = hoverIndex ?? selectedIndex
        for (index, item) in items.enumerated() {
            item.isHighlightedTab = index == highlighted
            item.accessibilityTraits = index == selectedIndex ? [.button, .selected] : .button
        }
    }
    private func commit(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let changed = index != selectedIndex
        if changed { setSelectedIndex(index, animated: true) }
        onSelect?(index)
    }

    // MARK: Touches

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        capsule.frame.insetBy(dx: -4, dy: -6).contains(point)
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        self.point(inside: point, with: event) && !isHidden && alpha > 0.01 ? self : nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackedTouch == nil, let touch = touches.first else { return }
        trackedTouch = touch
        let x = clampedCenterX(touch.location(in: capsule).x)
        hoverIndex = index(atCapsuleX: x)
        updateItemAppearance()
        lens.layer.removeAllAnimations()
        if lens.alpha < 0.01 {
            lens.frame = lensFrame(centerX: slot(selectedIndex).midX)
            lens.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        }
        let glass = UIGlassEffect(style: .clear)
        glass.tintColor = tintColor.withAlphaComponent(0.08)
        UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.68, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.lens.alpha = 1
            self.lens.effect = glass
            self.lens.transform = .identity
            self.lens.frame = self.lensFrame(centerX: x)
            self.pill.alpha = 0
            self.pill.frame = self.pillFrame(centerX: x)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        let x = clampedCenterX(trackedTouch.location(in: capsule).x)
        let index = index(atCapsuleX: x)
        if index != hoverIndex { hoverIndex = index; updateItemAppearance() }
        UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]) {
            self.lens.frame = self.lensFrame(centerX: x)
            self.pill.frame = self.pillFrame(centerX: x)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        let location = trackedTouch.location(in: capsule)
        let inside = capsule.bounds.insetBy(dx: -8, dy: -24).contains(location)
        finishTouch(selecting: inside ? index(atCapsuleX: clampedCenterX(location.x)) : nil)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        finishTouch(selecting: nil)
    }

    private func finishTouch(selecting index: Int?) {
        trackedTouch = nil
        hoverIndex = nil
        if let index, index != selectedIndex { selectedIndex = index }
        updateItemAppearance()
        let target = slot(selectedIndex).midX
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.74, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.pill.frame = self.pillFrame(centerX: target)
            self.pill.alpha = 1
            self.lens.frame = self.lensFrame(centerX: target)
            self.lens.transform = CGAffineTransform(scaleX: 0.86, y: 0.86)
        }
        UIView.animate(withDuration: 0.28, delay: 0.08, options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]) {
            self.lens.effect = nil
            self.lens.alpha = 0
        }
        if let index { onSelect?(index) }
    }

    // MARK: Content transition

    func crossfadeContent(_ changeSelection: () -> Void) {
        fadingContent?.removeFromSuperview()
        guard let root = window?.rootViewController?.view,
              let snapshot = root.snapshotView(afterScreenUpdates: false) else {
            changeSelection()
            return
        }
        // Clip above the bar so only the glass animates there. Only opacity changes.
        let height = max(0, min(root.bounds.height, convert(lensFrame(centerX: 0), to: root).minY))
        let overlay = UIView(frame: CGRect(x: root.bounds.minX, y: root.bounds.minY, width: root.bounds.width, height: height))
        overlay.clipsToBounds = true
        overlay.isUserInteractionEnabled = false
        overlay.accessibilityElementsHidden = true
        snapshot.frame = root.bounds
        overlay.addSubview(snapshot)
        root.addSubview(overlay)
        fadingContent = overlay
        changeSelection()
        DispatchQueue.main.async { [weak root, weak overlay] in
            guard let root, let overlay else { return }
            root.layoutIfNeeded()
            UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                overlay.alpha = 0
            } completion: { _ in overlay.removeFromSuperview() }
        }
    }

    // MARK: Item

    private final class ItemView: UIView {
        private let icon = UIImageView()
        private let label = UILabel()
        private let badgeLabel = UILabel()
        var activate: (() -> Void)?

        var title: String? {
            get { label.text }
            set { label.text = newValue; accessibilityLabel = newValue }
        }
        var badge: String? {
            didSet {
                guard badge != oldValue else { return }
                badgeLabel.text = badge.map { " \($0) " }
                badgeLabel.isHidden = badge == nil
                setNeedsLayout()
            }
        }
        var isHighlightedTab = false { didSet { if isHighlightedTab != oldValue { updateColors() } } }

        init(symbol: String) {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            icon.image = UIImage(systemName: symbol + ".fill") ?? UIImage(systemName: symbol)
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)
            icon.contentMode = .center
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.7
            badgeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            badgeLabel.textColor = .white
            badgeLabel.textAlignment = .center
            badgeLabel.backgroundColor = .systemRed
            badgeLabel.clipsToBounds = true
            badgeLabel.isHidden = true
            [icon, label, badgeLabel].forEach(addSubview)
            updateColors()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func tintColorDidChange() { super.tintColorDidChange(); updateColors() }
        private func updateColors() {
            let color: UIColor = isHighlightedTab ? tintColor : .label
            icon.tintColor = color
            label.textColor = color
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            icon.frame = CGRect(x: 0, y: bounds.midY - 22, width: bounds.width, height: 28)
            label.frame = CGRect(x: 2, y: bounds.midY + 8, width: max(0, bounds.width - 4), height: 13)
            let size = badgeLabel.sizeThatFits(CGSize(width: 60, height: 18))
            let width = max(18, size.width)
            badgeLabel.frame = CGRect(x: bounds.midX + 4, y: bounds.midY - 26, width: width, height: 18)
            badgeLabel.layer.cornerRadius = 9
        }
        override func accessibilityActivate() -> Bool { activate?(); return true }
    }
}

private struct SheetContent: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var router: AppRouter
    @AppStorage("mora.didSeeWelcome") private var didSeeWelcome = false
    let sheet: AppSheet

    var body: some View {
        switch sheet {
        case .welcome:
            WelcomeView(start: { currency in
                Task { @MainActor in
                    if await store.startClean(baseCurrency: currency) {
                        didSeeWelcome = true
                        router.tab = .accounts
                        router.open(.account(nil))
                    }
                }
            }, explore: { didSeeWelcome = true; router.sheet = nil },
               connected: { didSeeWelcome = true; router.tab = .overview; router.sheet = nil })
            .interactiveDismissDisabled()
        case .transaction(let t): TransactionEditor(transaction: t, ledger: store.ledger)
        case .similar(let t): TransactionEditor(template: t, ledger: store.ledger)
        case .split(let t): SplitEditor(transaction: t)
        case .account(let a): AccountEditor(account: a)
        case .budget(let b): BudgetEditor(budget: b)
        case .goal(let g): GoalEditor(goal: g)
        case .recurring(let r): RecurringEditor(payment: r)
        case .category(let c, let kind): CategoryEditor(category: c, kind: kind)
        case .rule(let r): RuleEditor(rule: r)
        case .csv(let table, let name): CSVImportView(table: table, filename: name)
        case .walletReview(let capture): TransactionEditor(walletCapture: capture, ledger: store.ledger).id(capture.id)
        case .walletRun(let run, let account): TransactionEditor(walletRun: (run, account), ledger: store.ledger).id(run.id)
        case .walletGuide: WalletAutomationGuide()
        case .automationGuide(let automation):
            if automation == .walletTransaction { WalletAutomationGuide() } else { AutomationGuide(automation: automation) }
        }
    }
}

struct ErrorAlert: ViewModifier {
    @EnvironmentObject private var store: FinanceStore
    var active = true
    func body(content: Content) -> some View {
        content.alert(L("Не удалось выполнить действие"), isPresented: Binding(
            get: { active && store.error != nil },
            set: { if active && !$0 { store.error = nil } }
        )) {
            Button(L("Понятно")) { store.error = nil }
        } message: {
            Text(L(store.error ?? ""))
        }
    }
}

private struct ToastBanner: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var cloud: CloudSync
    var body: some View {
        if store.toast == nil && cloud.processingWallet {
            // Complete purchases are being booked: nothing waits for the user yet.
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(.moraGreen)
                Text(L("Загружаем покупки из Wallet…")).font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
            .transition(.move(edge: .top).combined(with: .opacity))
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        } else if let toast = store.toast {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: toast.kind == .success ? "checkmark.circle.fill" : toast.kind == .warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(toast.kind == .success ? Color.moraGreen : toast.kind == .warning ? .orange : .red)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    FinancialText(toast.message).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    if let detail = toast.detail, !detail.isEmpty {
                        FinancialText(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                Spacer(minLength: 4)
                if toast.undoable {
                    Button(L("Отменить")) { store.dismissToast(); Task { await store.undo() } }
                        .font(.subheadline.weight(.semibold)).buttonStyle(.borderless)
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
            .padding(.horizontal, 14)
            .transition(.move(edge: .top).combined(with: .opacity))
            .gesture(DragGesture(minimumDistance: 8).onEnded { value in if value.translation.height < 0 { store.dismissToast() } })
            .onTapGesture { store.dismissToast() }
            .accessibilityElement(children: .combine)
        }
    }
}
