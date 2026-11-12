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
                .background(NativeTabSpacing().frame(width: 0, height: 0))
                .tabItem { Label(L("Обзор"), systemImage: "square.grid.2x2") }.tag(AppTab.overview)
            TransactionsScreen()
                .background(NativeTabSpacing().frame(width: 0, height: 0))
                .tabItem { Label(L("Операции"), systemImage: "arrow.left.arrow.right") }.tag(AppTab.transactions)
            AnalyticsScreen()
                .background(NativeTabSpacing().frame(width: 0, height: 0))
                .tabItem { Label(L("Аналитика"), systemImage: "chart.xyaxis.line") }.tag(AppTab.analytics)
            AccountsScreen()
                .background(NativeTabSpacing().frame(width: 0, height: 0))
                .tabItem { Label(L("Счета"), systemImage: "wallet.bifold") }.tag(AppTab.accounts)
            MoreScreen()
                .background(NativeTabSpacing().frame(width: 0, height: 0))
                .tabItem { Label(L("Ещё"), systemImage: "ellipsis.circle") }.tag(AppTab.more)
                .badge(reviewQueue.count(with: cloud))
        }
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

/// Give only the system tab bar a little more room between its items.
/// Screen layout, native labels, selection and switching remain UIKit's own.
private struct NativeTabSpacing: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.updateSpacing() }

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); updateSpacing() }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); updateSpacing() }
        func updateSpacing() {
            func findTabs(in controller: UIViewController) -> UITabBarController? {
                if let tabs = controller as? UITabBarController { return tabs }
                return controller.children.lazy.compactMap { findTabs(in: $0) }.first
            }
            let tabs = tabBarController ?? view.window?.rootViewController.flatMap { findTabs(in: $0) }
            guard let bar = tabs?.tabBar, let container = bar.superview,
                  traitCollection.userInterfaceIdiom == .phone, container.bounds.width > 0 else { return }
            let extra: CGFloat = container.bounds.width < 600 ? 8 : 0
            let width = container.bounds.width + extra * 2
            guard abs(bar.frame.width - width) > 0.5 || abs(bar.frame.minX + extra) > 0.5 else { return }
            bar.frame = CGRect(x: -extra, y: bar.frame.minY, width: width, height: bar.frame.height)
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
