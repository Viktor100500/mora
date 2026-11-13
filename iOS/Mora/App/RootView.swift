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
        // Keyed on foreground/background only: a brief `.inactive` (Control Center, a
        // notification banner, the app switcher) must not restart every sync and loop.
        .task(id: scenePhase != .background) {
            guard scenePhase != .background else { return }
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

/// Each tab hides the controller-owned bar. The floating bar reserves its height
/// itself, in the tab controllers' safe area (see `GlassTabBar.applyContentInset`).
private struct ManagedTabBarVisibility: ViewModifier {
    /// The bottom safe area this tab actually receives from UIKit, before our own inset.
    @State private var receivedBottom: CGFloat = 0

    func body(content: Content) -> some View {
        if #available(iOS 26, *), UIDevice.current.userInterfaceIdiom == .phone {
            content
                .toolbar(.hidden, for: .tabBar)
                // Whatever room UIKit's inset did not provide is added as content margins.
                // iOS 26 passes `additionalSafeAreaInsets` on and this stays 0. iOS 27's
                // TabView resets that inset, and no safe-area inset reaches scroll views
                // inside its NavigationStack; content margins travel through the
                // environment instead, to every List and ScrollView of the tab, pushed
                // screens included.
                .contentMargins(.bottom, missingRoom, for: .scrollContent)
                .contentMargins(.bottom, missingRoom, for: .scrollIndicators)
                .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { receivedBottom = $0 }
        } else { content }
    }

    @available(iOS 26, *)
    private var missingRoom: CGFloat {
        max(0, GlassTabBar.reservedHeight(homeInset: Self.homeInset) - receivedBottom)
    }

    private static var homeInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        return window?.safeAreaInsets.bottom ?? 34
    }
}

private struct StableSystemTabBar: ViewModifier {
    @ObservedObject var router: AppRouter
    let reviewCount: Int
    @State private var keyboardVisible = false

    func body(content: Content) -> some View {
        if #available(iOS 26, *), UIDevice.current.userInterfaceIdiom == .phone {
            content
                .background {
                    // A zero-size host: the bar itself lives in the tab controller's view.
                    if !keyboardVisible {
                        SystemTabBar(selection: Binding(get: { router.tab }, set: { router.select($0) }),
                                     reviewCount: reviewCount)
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        } else { content }
    }
}

@available(iOS 26, *)
private struct SystemTabBar: UIViewRepresentable {
    @Binding var selection: AppTab
    let reviewCount: Int
    private static let tabs: [(AppTab, String, String)] = [
        (.overview, "Обзор", "square.grid.2x2"),
        (.transactions, "Операции", "arrow.left.arrow.right"),
        (.analytics, "Аналитика", "chart.xyaxis.line"),
        (.accounts, "Счета", "wallet.bifold"),
        (.more, "Ещё", "ellipsis.circle")
    ]

    final class Coordinator {
        var selection: Binding<AppTab>
        init(selection: Binding<AppTab>) { self.selection = selection }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    /// Puts the bar into TabView's UITabBarController view, where UIKit's own tab bar
    /// lives: it then spans the real bottom edge of the screen, whatever SwiftUI frame
    /// this host gets, and shares its coordinates with the tab screens' safe area.
    final class Host: UIView {
        let bar: GlassTabBar
        init(bar: GlassTabBar) {
            self.bar = bar
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isHidden = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            install(attempt: 0)
        }
        private func install(attempt: Int) {
            guard let window else { bar.removeFromSuperview(); return }
            if let tabs = GlassTabBar.tabBarController(in: window.rootViewController) {
                bar.install(in: tabs)
            } else if attempt < 10 {
                DispatchQueue.main.async { [weak self] in self?.install(attempt: attempt + 1) }
            }
        }
    }

    func makeUIView(context: Context) -> Host {
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
        let host = Host(bar: view)
        updateUIView(host, context: context)
        return host
    }

    func updateUIView(_ host: Host, context: Context) {
        let view = host.bar
        context.coordinator.selection = $selection
        view.tintColor = UIColor(Color.moraGreen)
        view.semanticContentAttribute = context.environment.layoutDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        view.setTitles(Self.tabs.map { L($0.1) })
        if let index = Self.tabs.firstIndex(where: { $0.0 == selection }) {
            view.setSelectedIndex(index, animated: view.window != nil)
        }
        view.setBadge(reviewCount > 0 ? String(reviewCount) : nil,
                      accessibilityValue: reviewCount > 0 ? L("Покупок на проверке: \(reviewCount)") : nil)
    }

    static func dismantleUIView(_ host: Host, coordinator: Coordinator) {
        host.bar.removeFromSuperview()
    }
}

/// A floating Liquid Glass tab bar built the way Telegram builds its own: UIKit's lens
/// (`_UILiquidLensView`, the view UITabBar uses for its selection) is driven here directly.
/// UITabBar stops lifting its lens when Reduce Motion is on; a lens we lift and move
/// ourselves keeps its full glass animation. Without the lens class, a plain pill slides.
@available(iOS 26, *)
private final class GlassTabBar: UIView {
    static let capsuleHeight: CGFloat = 62
    static let topRoom: CGFloat = 14
    /// Narrow phones (mini, SE) get more width per tab, as UIKit's own bar does.
    static func sideMargin(width: CGFloat) -> CGFloat { width < 390 ? 12 : 18 }
    static let maxBottomMargin: CGFloat = 21
    /// The view reaches the bottom of the screen; the capsule floats above it.
    static let height = topRoom + capsuleHeight + maxBottomMargin
    static func bottomMargin(homeInset: CGFloat) -> CGFloat { homeInset > 0 ? maxBottomMargin : 10 }
    /// The room content needs from the bottom of the screen: the capsule and a small gap.
    static func reservedHeight(homeInset: CGFloat) -> CGFloat {
        capsuleHeight + bottomMargin(homeInset: homeInset) + 8
    }
    /// How far the capsule (plus a small gap) rises above the bottom safe area.
    static func contentInset(homeInset: CGFloat) -> CGFloat {
        max(0, reservedHeight(homeInset: homeInset) - homeInset)
    }

    /// `_UILiquidLensViewLargeVariantSpec`: minimum lifted time and the lift spring's response.
    private static let hangTime: Double = 0.22
    private static let liftResponse: Double = 0.25
    private static let moveDuration: Double = 0.4

    var onSelect: ((Int) -> Void)?

    private let glassContainer: UIVisualEffectView = {
        let effect = UIGlassContainerEffect()
        effect.spacing = 7
        return UIVisualEffectView(effect: effect)
    }()
    /// The lens draws itself here while lifted, above the bar's glass.
    private let liftedContainer = UIView()
    private let background: UIVisualEffectView = {
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = false
        return UIVisualEffectView(effect: glass)
    }()
    /// Content the lens shows through itself: the tinted copies of the items and the resting selection.
    private let liftedContent = UIView()
    private let restingSelection = UIView()
    private let itemsView = UIView()
    /// Cuts the regular items out under the lens, so the tinted copies show there.
    private let punchout = UIView()
    private let punchoutSink = UIView()
    private let punchoutTarget = UIView()
    private let lens: UIView?
    private let fallbackPill = UIView()

    private var items: [ItemView] = []
    private var selectedItems: [ItemView] = []
    private var selectedIndex = 0
    private var trackedTouch: UITouch?
    private var dragStartLensX: CGFloat = 0
    private var dragStartTouchX: CGFloat = 0
    private var dragIndex = 0
    private var isLensLifted = false
    private var liftTimestamp: CFTimeInterval = 0
    private var pendingUnlift: DispatchWorkItem?
    /// The tab controller whose screens reserve room for this bar.
    private weak var insetController: UITabBarController?
    private weak var fadingContent: UIView?

    init(symbols: [String]) {
        lens = Self.makeLens()
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = false
        isMultipleTouchEnabled = false
        isAccessibilityElement = false
        accessibilityTraits = .tabBar

        addSubview(glassContainer)
        liftedContainer.layer.zPosition = 1
        glassContainer.contentView.addSubview(liftedContainer)
        background.cornerConfiguration = .capsule()
        liftedContainer.addSubview(background)
        let container = background.contentView

        items = symbols.enumerated().map { index, symbol in
            let item = ItemView(symbol: symbol, tinted: false)
            item.activate = { [weak self] in self?.commit(index) }
            return item
        }
        selectedItems = symbols.map { symbol in
            let item = ItemView(symbol: symbol, tinted: true)
            item.isAccessibilityElement = false
            item.accessibilityElementsHidden = true
            return item
        }
        [liftedContent, restingSelection, itemsView, punchout, punchoutSink, punchoutTarget, fallbackPill].forEach { $0.isUserInteractionEnabled = false }
        let selectionColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.075) }

        if let lens {
            restingSelection.backgroundColor = selectionColor
            liftedContent.addSubview(restingSelection)
            selectedItems.forEach(liftedContent.addSubview)
            items.forEach(itemsView.addSubview)
            punchout.backgroundColor = .black
            punchout.layer.compositingFilter = "destOut"
            punchoutSink.isHidden = true
            punchoutSink.addSubview(punchoutTarget)
            lens.layer.zPosition = 10
            container.addSubview(liftedContent)
            container.addSubview(lens)
            container.addSubview(itemsView)
            container.addSubview(punchout)
            container.addSubview(punchoutSink)
            Self.send(lens, "setLiftedContainerView:", liftedContainer)
            Self.send(lens, "setLiftedContentView:", liftedContent)
            Self.send(lens, "setOverridePunchoutView:", punchoutTarget)
            Self.send(lens, "setLiftedContentMode:", int32: 1)
            Self.send(lens, "setStyle:", int32: 1)
            Self.send(lens, "setWarpsContentBelow:", bool: true)
        } else {
            fallbackPill.backgroundColor = selectionColor
            fallbackPill.layer.cornerCurve = .continuous
            container.addSubview(fallbackPill)
            container.addSubview(itemsView)
            items.forEach(itemsView.addSubview)
        }

        accessibilityElements = items
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Private lens API (as in Telegram's LiquidLensView)

    private static func makeLens() -> UIView? {
        guard let lensClass = NSClassFromString("_UILiquidLensView") as AnyObject as? NSObjectProtocol,
              let allocated = lensClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              allocated.responds(to: NSSelectorFromString("initWithRestingBackground:")) else { return nil }
        guard let lens = allocated.perform(NSSelectorFromString("initWithRestingBackground:"), with: UIView())?.takeUnretainedValue() as? UIView,
              lens.responds(to: NSSelectorFromString("setLifted:animated:alongsideAnimations:completion:")) else { return nil }
        return lens
    }
    private static func send(_ target: NSObject, _ name: String, _ value: Any) {
        let selector = NSSelectorFromString(name)
        if target.responds(to: selector) { _ = target.perform(selector, with: value) }
    }
    private static func send(_ target: NSObject, _ name: String, int32 value: Int32) {
        let selector = NSSelectorFromString(name)
        guard target.responds(to: selector), let method = target.method(for: selector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, Int32) -> Void
        unsafeBitCast(method, to: Function.self)(target, selector, value)
    }
    private static func send(_ target: NSObject, _ name: String, bool value: Bool) {
        let selector = NSSelectorFromString(name)
        guard target.responds(to: selector), let method = target.method(for: selector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method, to: Function.self)(target, selector, value)
    }
    private func setLensLifted(_ lifted: Bool) {
        guard let lens else { return }
        isLensLifted = lifted
        if lifted { liftTimestamp = CACurrentMediaTime() }
        let selector = NSSelectorFromString("setLifted:animated:alongsideAnimations:completion:")
        if let method = lens.method(for: selector) {
            typealias Function = @convention(c) (AnyObject, Selector, Bool, Bool, (@convention(block) () -> Void)?, (@convention(block) () -> Void)?) -> Void
            unsafeBitCast(method, to: Function.self)(lens, selector, lifted, true, nil, nil)
        }
        UIView.animate(springDuration: Self.liftResponse, bounce: 0, initialSpringVelocity: 0, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.setLensBounds(self.lensSize(lifted: lifted))
            self.restingSelection.alpha = lifted ? 0 : 1
            let scale: CGFloat = lifted ? 1.15 : 1
            self.selectedItems.forEach { $0.transform = CGAffineTransform(scaleX: scale, y: scale) }
        }
    }

    // MARK: Layout

    private var homeInset: CGFloat { window?.safeAreaInsets.bottom ?? 34 }
    private var isRTL: Bool { effectiveUserInterfaceLayoutDirection == .rightToLeft }
    private var capsuleSize: CGSize { glassContainer.bounds.size }
    /// Room between the capsule's ends and the first and last tab. The resting lens is
    /// 2 points wider than a tab on each side, so it stays centred on every tab and
    /// still keeps 4 points from the capsule's rounded ends.
    private static let innerPadding: CGFloat = 6
    private static let lensOverhang: CGFloat = 2
    private var itemWidth: CGFloat { max(1, (capsuleSize.width - Self.innerPadding * 2) / CGFloat(max(items.count, 1))) }

    /// The visual slot of an item, in the capsule's coordinates.
    private func slot(_ index: Int) -> CGRect {
        let visual = isRTL ? items.count - 1 - index : index
        return CGRect(x: Self.innerPadding + CGFloat(visual) * itemWidth, y: 0, width: itemWidth, height: capsuleSize.height)
    }
    private func lensSize(lifted: Bool) -> CGSize {
        lifted ? CGSize(width: itemWidth + 16, height: capsuleSize.height + 8)
               : CGSize(width: itemWidth + Self.lensOverhang * 2, height: capsuleSize.height - 8)
    }
    /// Where the resting lens sits for a tab: centred on it, but never closer than
    /// 4 points to the capsule's ends, so the first and last tabs stay inside the bar.
    private func restX(_ index: Int) -> CGFloat { clampedX(slot(index).midX) }
    private func clampedX(_ x: CGFloat) -> CGFloat {
        let half = lensSize(lifted: false).width / 2
        return min(max(x, 4 + half), capsuleSize.width - 4 - half)
    }
    private func index(atX x: CGFloat) -> Int {
        let visual = min(max(Int((x - Self.innerPadding) / itemWidth), 0), items.count - 1)
        return isRTL ? items.count - 1 - visual : visual
    }
    private func setLensBounds(_ size: CGSize) {
        guard let lens else { return }
        let bounds = CGRect(origin: .zero, size: size)
        lens.bounds = bounds
        punchout.bounds = bounds
        punchout.layer.cornerRadius = min(size.width, size.height) / 2
    }
    private func setLensCenterX(_ x: CGFloat) {
        let center = CGPoint(x: x, y: capsuleSize.height / 2)
        if let lens {
            lens.center = center
            punchout.center = center
        } else {
            let size = lensSize(lifted: false)
            fallbackPill.frame = CGRect(x: x - size.width / 2, y: 4, width: size.width, height: size.height)
            fallbackPill.layer.cornerRadius = size.height / 2
        }
    }
    private func moveLens(toX x: CGFloat, animated: Bool) {
        guard animated else { return UIView.performWithoutAnimation { setLensCenterX(x) } }
        UIView.animate(springDuration: Self.moveDuration, bounce: 0, initialSpringVelocity: 0, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) { self.setLensCenterX(x) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bottom = Self.bottomMargin(homeInset: homeInset)
        let side = Self.sideMargin(width: bounds.width)
        let frame = CGRect(x: side, y: bounds.height - bottom - Self.capsuleHeight,
                           width: max(0, bounds.width - side * 2), height: Self.capsuleHeight)
        if glassContainer.frame != frame {
            UIView.performWithoutAnimation {
                glassContainer.frame = frame
                let local = CGRect(origin: .zero, size: frame.size)
                liftedContainer.frame = local
                background.frame = local
                [liftedContent, restingSelection, itemsView].forEach { $0.frame = local }
                for index in items.indices {
                    items[index].frame = slot(index)
                    selectedItems[index].transform = .identity
                    selectedItems[index].frame = slot(index)
                }
                setLensBounds(lensSize(lifted: false))
                setLensCenterX(restX(selectedIndex))
            }
        }
        applyContentInset()
    }

    func install(in tabs: UITabBarController) {
        insetController = tabs
        let container = tabs.view!
        if superview !== container {
            container.addSubview(self)
        } else {
            container.bringSubviewToFront(self)
        }
        autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        frame = CGRect(x: 0, y: container.bounds.height - Self.height, width: container.bounds.width, height: Self.height)
        setNeedsLayout()
    }

    /// A SwiftUI `safeAreaInset` does not reach the screens inside TabView's
    /// UITabBarController. UIKit's own `additionalSafeAreaInsets` on each tab does,
    /// and passes on to navigation stacks and pushed screens, so every scroll view
    /// ends above the bar. The inset is removed when the bar leaves (keyboard shown).
    private func applyContentInset() {
        let controller = window.flatMap { Self.tabBarController(in: $0.rootViewController) } ?? insetController
        if controller !== insetController { Self.setInset(0, in: insetController) }
        insetController = controller
        Self.setInset(window == nil ? 0 : Self.contentInset(homeInset: homeInset), in: controller)
    }
    private func keepOnTop() {
        if let superview, superview.subviews.last !== self { superview.bringSubviewToFront(self) }
    }
    private static func setInset(_ inset: CGFloat, in controller: UITabBarController?) {
        #if DEBUG
        // Reproduces iOS 27, which resets this inset, in an iOS 26 simulator.
        if ProcessInfo.processInfo.arguments.contains("--no-uikit-tab-inset") { return }
        #endif
        for child in controller?.viewControllers ?? [] where abs(child.additionalSafeAreaInsets.bottom - inset) > 0.5 {
            child.additionalSafeAreaInsets.bottom = inset
        }
    }
    static func tabBarController(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let found = tabBarController(in: child) { return found }
        }
        return nil
    }
    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); setNeedsLayout() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        // UIKit drops a lens's lifted state when it leaves the window.
        if window == nil { pendingUnlift?.cancel(); isLensLifted = false }
        applyContentInset()
        setNeedsLayout()
    }

    // MARK: State

    func setTitles(_ titles: [String]) {
        for (index, title) in titles.enumerated() where items.indices.contains(index) && items[index].title != title {
            items[index].title = title
            selectedItems[index].title = title
        }
    }
    func setBadge(_ badge: String?, accessibilityValue: String?) {
        items.last?.badge = badge
        selectedItems.last?.badge = badge
        items.last?.accessibilityValue = accessibilityValue
    }
    func setSelectedIndex(_ index: Int, animated: Bool) {
        guard items.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        updateAccessibility()
        guard trackedTouch == nil, !capsuleSize.equalTo(.zero) else { return }
        moveLens(toX: restX(index), animated: animated)
    }
    private func updateAccessibility() {
        for (index, item) in items.enumerated() {
            item.accessibilityTraits = index == selectedIndex ? [.button, .selected] : .button
            if lens == nil { item.isHighlightedTab = index == selectedIndex }
        }
    }
    private func commit(_ index: Int) {
        guard items.indices.contains(index) else { return }
        setSelectedIndex(index, animated: true)
        onSelect?(index)
        DispatchQueue.main.async { [weak self] in self?.keepOnTop(); self?.applyContentInset() }
    }

    // MARK: Touches

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        glassContainer.frame.insetBy(dx: -4, dy: -6).contains(point)
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        self.point(inside: point, with: event) && !isHidden && alpha > 0.01 ? self : nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackedTouch == nil, let touch = touches.first else { return }
        trackedTouch = touch
        let x = touch.location(in: glassContainer).x
        dragIndex = index(atX: clampedX(x))
        dragStartLensX = restX(dragIndex)
        dragStartTouchX = x
        pendingUnlift?.cancel()
        if lens != nil, !isLensLifted { setLensLifted(true) }
        if lens == nil { items.enumerated().forEach { $0.element.isHighlightedTab = $0.offset == dragIndex } }
        moveLens(toX: dragStartLensX, animated: true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        let x = trackedTouch.location(in: glassContainer).x
        dragIndex = index(atX: clampedX(x))
        if lens == nil { items.enumerated().forEach { $0.element.isHighlightedTab = $0.offset == dragIndex } }
        // The lens follows the finger directly, as UITabBar's does.
        let lensX = clampedX(dragStartLensX + x - dragStartTouchX)
        if let lens, let move = lens.layer.presentation()?.position, lens.layer.animation(forKey: "position") != nil {
            // Take over from a running spring where it is, so the lens never jumps.
            lens.layer.removeAnimation(forKey: "position")
            punchout.layer.removeAnimation(forKey: "position")
            lens.center = move
        }
        moveLens(toX: lensX, animated: false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        let location = trackedTouch.location(in: glassContainer)
        let inside = CGRect(origin: .zero, size: capsuleSize).insetBy(dx: -8, dy: -24).contains(location)
        finishTouch(selecting: inside ? index(atX: clampedX(location.x)) : nil)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        finishTouch(selecting: nil)
    }

    private func finishTouch(selecting index: Int?) {
        trackedTouch = nil
        if let index { selectedIndex = index }
        updateAccessibility()
        moveLens(toX: restX(selectedIndex), animated: true)
        if lens != nil, isLensLifted {
            // UIKit keeps a tapped lens lifted for its hang time, so a tap shows the lift.
            let remaining = liftTimestamp + Self.hangTime - CACurrentMediaTime()
            let unlift = DispatchWorkItem { [weak self] in
                guard let self, self.trackedTouch == nil, self.isLensLifted else { return }
                self.setLensLifted(false)
            }
            pendingUnlift = unlift
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, remaining), execute: unlift)
        }
        if let index { onSelect?(index) }
        DispatchQueue.main.async { [weak self] in self?.keepOnTop(); self?.applyContentInset() }
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
        let barTop = convert(glassContainer.frame, to: root).minY - 8
        let overlay = UIView(frame: CGRect(x: root.bounds.minX, y: root.bounds.minY, width: root.bounds.width,
                                           height: max(0, min(root.bounds.height, barTop))))
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
        private let tinted: Bool
        var activate: (() -> Void)?

        var title: String? {
            get { label.text }
            set { label.text = newValue; accessibilityLabel = newValue }
        }
        var badge: String? {
            didSet {
                guard badge != oldValue else { return }
                badgeLabel.text = badge
                badgeLabel.isHidden = badge == nil
                setNeedsLayout()
            }
        }
        var isHighlightedTab = false { didSet { if isHighlightedTab != oldValue { updateColors() } } }

        init(symbol: String, tinted: Bool) {
            self.tinted = tinted
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            icon.image = UIImage(systemName: symbol + ".fill") ?? UIImage(systemName: symbol)
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)
            icon.contentMode = .center
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.75
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
            let color: UIColor = tinted || isHighlightedTab ? tintColor : .label
            icon.tintColor = color
            label.textColor = color
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            icon.frame = CGRect(x: 0, y: bounds.midY - 22, width: bounds.width, height: 28)
            // Narrower than the tab, so the text stays inside the lens's rounded ends.
            label.frame = CGRect(x: 6, y: bounds.midY + 8, width: max(0, bounds.width - 12), height: 13)
            let width = max(18, badgeLabel.sizeThatFits(CGSize(width: 60, height: 18)).width + 10)
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
        case .walletGuide: AutomationGuide(automation: .walletTransaction)
        case .automationGuide(let automation): AutomationGuide(automation: automation)
        case .automationWaiting(let automation): AutomationWaitingView(automation: automation)
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
