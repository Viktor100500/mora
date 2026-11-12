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

/// The content stays in TabView; the visible control is a real UITabBar with
/// stable constraints, rather than resizing the controller-owned bar after a switch.
private struct ManagedTabBarVisibility: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *), UIDevice.current.userInterfaceIdiom == .phone {
            content.toolbar(.hidden, for: .tabBar)
        } else { content }
    }
}

private struct StableSystemTabBar: ViewModifier {
    @ObservedObject var router: AppRouter
    let reviewCount: Int
    @State private var keyboardVisible = false

    func body(content: Content) -> some View {
        if #available(iOS 26, *), UIDevice.current.userInterfaceIdiom == .phone {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !keyboardVisible {
                        SystemTabBar(selection: Binding(get: { router.tab }, set: { router.select($0) }), reviewCount: reviewCount)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        } else { content }
    }
}

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

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeUIView(context: Context) -> Container {
        let view = Container()
        view.bar.delegate = context.coordinator
        view.bar.items = Self.tabs.enumerated().map { index, tab in
            let image = UIImage(systemName: tab.2 + ".fill") ?? UIImage(systemName: tab.2)
            let item = UITabBarItem(title: L(tab.1), image: image, tag: index)
            item.selectedImage = image
            return item
        }
        updateUIView(view, context: context)
        return view
    }
    func updateUIView(_ view: Container, context: Context) {
        context.coordinator.selection = $selection
        view.bar.tintColor = UIColor(Color.moraGreen)
        view.semanticContentAttribute = context.environment.layoutDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        var titlesChanged = false
        for (index, tab) in Self.tabs.enumerated() {
            let title = L(tab.1)
            if view.bar.items?[index].title != title {
                view.bar.items?[index].title = title
                titlesChanged = true
            }
        }
        if titlesChanged { view.refreshItems() }
        if let index = Self.tabs.firstIndex(where: { $0.0 == selection }), let item = view.bar.items?[index], view.bar.selectedItem !== item {
            view.bar.selectedItem = item
        }
        let badge = reviewCount > 0 ? String(reviewCount) : nil
        if view.bar.items?.last?.badgeValue != badge { view.bar.items?.last?.badgeValue = badge }
        view.bar.items?.last?.accessibilityValue = reviewCount > 0 ? L("Покупок на проверке: \(reviewCount)") : nil
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Container, context: Context) -> CGSize? {
        let width = proposal.width ?? 375
        // sizeThatFits includes the home-indicator inset even for a standalone bar.
        // Reserve that part below SwiftUI's safe area, rather than counting it twice.
        let nativeHeight = uiView.bar.sizeThatFits(CGSize(width: width + 16, height: 0)).height - (uiView.window?.safeAreaInsets.bottom ?? 0)
        return CGSize(width: width, height: nativeHeight + 14)
    }

    final class Coordinator: NSObject, UITabBarDelegate {
        var selection: Binding<AppTab>
        init(selection: Binding<AppTab>) { self.selection = selection }
        func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
            guard SystemTabBar.tabs.indices.contains(item.tag) else { return }
            selection.wrappedValue = SystemTabBar.tabs[item.tag].0
        }
    }

    final class Container: UIView {
        let bar = UITabBar()
        private var itemsWidth: CGFloat = 0
        private var bottom: NSLayoutConstraint!
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            clipsToBounds = false
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)
            bottom = bar.bottomAnchor.constraint(equalTo: bottomAnchor)
            NSLayoutConstraint.activate([
                bar.centerXAnchor.constraint(equalTo: centerXAnchor),
                bar.widthAnchor.constraint(equalTo: widthAnchor, constant: 16),
                // Leave room above the bar for the system's morphing glass lens.
                bar.topAnchor.constraint(equalTo: topAnchor, constant: 14),
                bottom
            ])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews()
            // iOS 26 otherwise retains title measurements made at an initial zero
            // width. Rebuild only for a real width change, never for tab selection.
            if bar.bounds.width > 0, abs(itemsWidth - bar.bounds.width) > 0.5 {
                itemsWidth = bar.bounds.width
                refreshItems()
            }
        }
        func refreshItems() {
            let items = bar.items
            let selected = bar.selectedItem
            let delegate = bar.delegate
            bar.delegate = nil
            UIView.performWithoutAnimation { bar.items = nil; bar.items = items; bar.selectedItem = selected }
            bar.delegate = delegate
        }
        override func didMoveToWindow() { super.didMoveToWindow(); updateBottomInset() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); updateBottomInset() }
        private func updateBottomInset() {
            let inset = window?.safeAreaInsets.bottom ?? 0
            if bottom.constant != inset { bottom.constant = inset; invalidateIntrinsicContentSize() }
        }
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
