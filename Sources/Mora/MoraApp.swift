import SwiftUI
import AppKit
import FinanceCore

@main
struct MoraApp: App {
    @NSApplicationDelegateAdaptor(MoraApplicationDelegate.self) private var appDelegate
    @StateObject private var store = FinanceStore()
    @StateObject private var cloud = CloudSync()
    @StateObject private var categorizer = MerchantCategorizer()
    @StateObject private var pairing = PairingServer()
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.exportFilteredTransactions) private var exportFilteredTransactions
    @AppStorage("mora.language") private var language = "ru"
    @State private var page: Page = .overview
    @State private var sheet: EditorSheet?
    var body: some Scene {
        Window("Mora", id: "main") {
            ContentView(page: $page, sheet: $sheet).environmentObject(store).environmentObject(cloud).environmentObject(categorizer)
                .modifier(PairingPrompt(pairing: pairing, cloud: cloud))
                .tint(.moraGreen)
                .environment(\.locale, L10n.locale)
                .preferredColorScheme(store.ledger.preferences.appearance == "light" ? .light : store.ledger.preferences.appearance == "dark" ? .dark : nil)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular); NSApplication.shared.activate(ignoringOtherApps: true)
                    appDelegate.finishPendingWrites = {
                        store.beginTermination()
                        // Accepted reviews may still be waiting for a Visa quote;
                        // let them enter CloudSync before stopping new cloud work.
                        await store.finishPendingWrites()
                        await cloud.finishPendingWrites()
                        await categorizer.finishPendingWrites()
                        await store.finishPendingWrites()
                    }
                }
                .onOpenURL { url in Task { @MainActor in
                    guard url.isFileURL, url.pathExtension.lowercased() == "csv" else { return }
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    if let file = await readCSV(at: url, store: store) { sheet = .csv(file.0, file.1) }
                } }
                .task {
                    cloud.preparePresentation = { [categorizer] store in await categorizer.process(store: store, duringSync: true) }
                    await cloud.prepare(store: store)
                    async let sync: Void = cloud.run(store: store)
                    async let categories: Void = categorizer.run(store: store)
                    _ = await (sync, categories)
                }
        }
        .defaultSize(width: 1320, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .help) {
                FeedbackButton()
            }
            CommandGroup(replacing: .newItem) {
                Button(L("Новая операция")) { sheet = .transaction(nil) }.keyboardShortcut("n")
                Button(L("Импортировать CSV…")) { importFile() }.keyboardShortcut("i")
                Button(L("Экспортировать операции…")) {
                    if let exportFilteredTransactions { exportFilteredTransactions() }
                    else { Task { @MainActor in await store.exportCSV() } }
                }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu(L("Финансы")) {
                Button(L("Добавить счет")) { sheet = .account(nil) }
                if store.ledger.preferences.showBudgets { Button(L("Создать бюджет")) { sheet = .budget(nil) } }
                if store.ledger.preferences.showGoals { Button(L("Создать цель")) { sheet = .goal(nil) } }
                Divider()
                Button(store.undoDescription.map { L("Отменить: \($0.title)") } ?? L("Отменить последнее изменение")) { Task { @MainActor in  await store.undo()  } }.keyboardShortcut("z", modifiers: [.command, .option]).disabled(store.undoCount == 0)
                Button(store.redoDescription.map { L("Вернуть: \($0.title)") } ?? L("Вернуть последнее изменение")) { Task { @MainActor in  await store.redo()  } }.keyboardShortcut("z", modifiers: [.command, .option, .shift]).disabled(store.redoCount == 0)
                Button(L("Сохранить резервную копию…")) { Task { @MainActor in  await store.backup()  } }
                Button(L("Общая база и Apple Pay…")) { openWindow(id: "cloud") }
            }
        }
        Window(L("Mora — общая база и Apple Pay"), id: "cloud") {
            CloudSettingsView().environmentObject(store).environmentObject(cloud).environmentObject(categorizer).tint(.moraGreen).environment(\.locale, L10n.locale).id(language)
        }.defaultSize(width: 760, height: 800)
    }
    private func importFile() { Task { @MainActor in
        if let file = await openCSV(store: store) { sheet = .csv(file.0, file.1) }
    } }
}

@MainActor
func openCSV(store: FinanceStore) async -> (CSVTable, String)? {
    let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .plainText]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return await readCSV(at: url, store: store)
}

@MainActor
func readCSV(at url: URL, store: FinanceStore) async -> (CSVTable, String)? {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
        return try await BackgroundWork.shared.perform {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 20_000_000 else { throw LedgerError.invalid(L("Файл больше 20 МБ. Разделите его на части.")) }
            return (try CSVTable.read(Data(contentsOf: url)), url.lastPathComponent)
        }
    } catch { store.error = error.localizedDescription; return nil }
}

struct ContentView: View {
    @EnvironmentObject private var categorizer: MerchantCategorizer
    @EnvironmentObject var store: FinanceStore
    @EnvironmentObject private var cloud: CloudSync
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Binding var page: Page
    @Binding var sheet: EditorSheet?
    @AppStorage("mora.language") private var language = "ru"
    @State private var month = Dates.month(Date())
    @State private var requestedMonth: Date?
    @State private var monthPreparation: Task<Void, Never>?
    @State private var transactionFilters = TransactionSearch()
    @AppStorage("mora.didSeeWelcome") private var didSeeWelcome = false
    @State private var confirmStart = false
    @State private var rollbackRequest: UUID?
    @AppStorage("mora.hideAmounts") private var hideAmounts = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var currency: String { store.ledger.preferences.baseCurrency }
    private let dataRefresh = Timer.publish(every: 2, on: .main, in: .default).autoconnect()

    @ViewBuilder private var currencyWarning: some View {
        if !store.ledger.missingCurrencies.isEmpty && page != .settings {
            HStack {
                Image(systemName: "exclamationmark.circle")
                Text(store.updatingRates ? L("Загружаем курсы валют…") : L("В итогах не учтены валюты без курса: \(store.ledger.missingCurrencies.joined(separator: ", "))")).font(.callout)
                Spacer()
                Button(L("Курсы валют")) { page = .settings }
            }.padding(14)
                .background(Color.orange.opacity(0.17), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.28), lineWidth: 1))
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 210, ideal: 228, max: 260)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                if store.isDemo { demoBanner }
                Group {
                    if page == .transactions {
                        VStack(alignment: .leading, spacing: 20) {
                            header
                            TransactionsView(sheet: $sheet, filters: $transactionFilters)
                        }.padding(24).frame(maxWidth: 1320).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                header
                                switch page {
                                case .overview: DashboardView(month: month, page: $page, sheet: $sheet)
                                case .transactions: EmptyView() // This screen owns its scrolling above.
                                case .accounts: AccountsView(sheet: $sheet)
                                case .budgets: BudgetsView(month: month, sheet: $sheet)
                                case .goals: GoalsView(sheet: $sheet)
                                case .recurring: RecurringView(sheet: $sheet)
                                case .analytics: AnalyticsView(month: month)
                                case .categories: CategoriesView(sheet: $sheet)
                                case .imports: ImportHistoryView(onRollback: requestRollback)
                                case .settings: SettingsView()
                                }
                                HStack(spacing: 5) {
                                    Image(systemName: "lock.shield")
                                    Text(store.isDemo ? L("Демонстрационный режим · изменения не сохраняются") : cloud.householdID == nil ? L("Данные хранятся на вашем Mac") : L("Локальная копия общей базы · \(cloud.enabled ? L("синхронизация включена") : L("синхронизация на паузе"))"))
                                    if !store.isDemo, store.ledger.preferences.exchangeRateSnapshot != nil {
                                        Text("·")
                                        Link(L("Курсы: ExchangeRate-API"), destination: ExchangeRateSnapshot.providerURL).foregroundStyle(.tertiary)
                                    }
                                }.font(.caption).foregroundStyle(.tertiary).lineLimit(1).frame(maxWidth: .infinity).padding(.top, 4)
                            }.padding(24).frame(maxWidth: 1320).frame(maxWidth: .infinity)
                        }.modifier(ConsistentScrollEdges())
                    }
                }
                .id(language)
                .background(scheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(red: 0.965, green: 0.965, blue: 0.95))
            }
        }
        .frame(minWidth: 1040, minHeight: 700)
        .disabled(store.isLoading || store.isTerminating)
        .overlay { if store.isLoading { ProgressView().controlSize(.large) } }
        .overlay(alignment: .bottomTrailing) {
            currencyWarning.frame(maxWidth: 680).padding(24).transition(.opacity)
        }
        .modifier(FloatingNotificationOverlay(event: store.activeNotice, close: { store.notice = nil }))
        .smoothUpdates(value: page)
        .smoothUpdates(value: month)
        .onDisappear { monthPreparation?.cancel() }
        .task {
            await store.load()
            if store.isDemo && !didSeeWelcome && !CommandLine.arguments.contains("--demo") && sheet == nil {
                sheet = .welcome
            }
        }
        .onReceive(dataRefresh) { _ in Task { @MainActor in  await store.reloadFromDisk()  } }
        .onReceive(store.notifications.$navigation) { request in
            if case .page(let destination) = request?.destination { page = destination }
        }
        .task(id: "\(store.ledger.preferences.automaticRates)-\(store.isDemo)") {
            guard store.ledger.preferences.automaticRates else { return }
            while !Task.isCancelled {
                await store.refreshExchangeRates()
                do { try await Task.sleep(for: .seconds(900)) } catch { return }
            }
        }
        .onChange(of: language) { _, _ in Task { await store.reloadFromDisk() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refreshExchangeRates() } }
        }
        .onChange(of: store.ledger.preferences) { _, preferences in
            if !page.isVisible(in: preferences) { page = .overview }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 10) { importControl; transactionControls }
                }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItemGroup(placement: .primaryAction) {
                    HStack(spacing: 10) { importControl; transactionControls }
                }
            }
        }
        .sheet(item: $sheet) { value in
            Group {
                switch value {
                case .welcome:
                    WelcomeView(start: { currency in Task { @MainActor in
                        if await store.startClean(baseCurrency: currency) {
                            didSeeWelcome = true; page = .accounts
                            sheet = nil
                            Task { @MainActor in
                                await Task.yield()
                                sheet = .account(nil)
                            }
                        }
                     } }, explore: { didSeeWelcome = true; sheet = nil })
                case .transaction(let t): TransactionEditor(transaction: t, ledger: store.ledger)
                case .similar(let t): TransactionEditor(template: t, ledger: store.ledger)
                case .split(let t): SplitEditor(transaction: t)
                case .account(let a): AccountEditor(account: a)
                case .budget(let b): BudgetEditor(budget: b)
                case .goal(let g): GoalEditor(goal: g)
                case .recurring(let r): RecurringEditor(payment: r)
                case .category(let c): CategoryEditor(category: c)
                case .rule(let r): RuleEditor(rule: r)
                case .csv(let table, let name): ImportView(table: table, filename: name)
                case .aiImport: AIImportView()
                }
            }.modifier(FeedbackFooter()).modifier(FinanceErrorAlert()).environmentObject(store).environmentObject(cloud).environmentObject(categorizer).environment(\.locale, L10n.locale).tint(.moraGreen)
        }
        .modifier(FinanceErrorAlert(active: sheet == nil))
        .confirmationDialog(L("Начать свой учет?"), isPresented: $confirmStart, titleVisibility: .visible) {
            Button(L("Начать с чистого листа")) { Task { @MainActor in  await store.startClean(); page = .accounts; sheet = .account(nil)  } }
        } message: { Text(L("Демонстрационные данные будут убраны. Затем можно добавить счета и импортировать свои операции.")) }
        .confirmationDialog(L("Отменить импорт с измененными операциями?"), isPresented: Binding(get: { rollbackRequest != nil }, set: { if !$0 { rollbackRequest = nil } }), titleVisibility: .visible) {
            if let id = rollbackRequest {
                Button(L("Отменить импорт"), role: .destructive) { Task { @MainActor in  await store.rollbackImport(id, allowModified: true); rollbackRequest = nil  } }
            }
            Button(L("Сохранить операции"), role: .cancel) { rollbackRequest = nil }
        } message: {
            if let id = rollbackRequest, let preview = store.imports.previews[id] {
                Text(L("Будет удалено операций: \(preview.remaining). Из них изменено или создано разделением: \(preview.modified). Остальные операции, счета и категории сохранятся. Отмену можно вернуть через меню «Финансы»."))
            }
        }
    }

    private func requestRollback(_ id: UUID) { Task { @MainActor in
        await store.reloadFromDisk()
        do {
            guard let preview = store.imports.previews[id] else { throw LedgerError.invalid(L("Этот импорт уже отменен или не найден.")) }
            if preview.modified > 0 { rollbackRequest = id }
            else { await store.rollbackImport(id) }
        } catch { store.error = error.localizedDescription }
     } }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "leaf.fill").font(.system(size: 23)).foregroundStyle(.white).frame(width: 42, height: 42).background(Color.moraGreen).clipShape(RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 1) { Text("mora").font(.system(size: 27, weight: .semibold, design: .rounded)); Text(L("ЛИЧНЫЕ ФИНАНСЫ")).font(.system(size: 8, weight: .medium)).tracking(1.5).foregroundStyle(.secondary) }
            }.padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 28)
            Text(L("ВАШИ ФИНАНСЫ")).font(.system(size: 9, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 10)
            ForEach(Page.allCases.filter { $0 != .settings && $0.isVisible(in: store.ledger.preferences) }) { item in
                Button { var transaction = SwiftUI.Transaction(); transaction.disablesAnimations = true; withTransaction(transaction) { page = item } } label: {
                    HStack(spacing: 12) { Image(systemName: item.icon).font(.system(size: 15)).frame(width: 20); Text(L(item.title)).font(.system(size: 13, weight: page == item ? .semibold : .regular)); Spacer() }
                        .foregroundStyle(page == item ? Color.moraGreen : Color.primary.opacity(0.72)).padding(.horizontal, 13).padding(.vertical, 12).background(page == item ? Color.moraGreen.opacity(0.10) : .clear).clipShape(RoundedRectangle(cornerRadius: 10)).contentShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 2)
            }
            Spacer(minLength: 24)
            Button { page = .accounts } label: {
            VStack(alignment: .leading, spacing: 8) {
                Label(L("Общий капитал"), systemImage: "chart.line.uptrend.xyaxis").font(.caption).foregroundStyle(.secondary)
                FinancialText(DisplayMoney.string(store.reportNetWorth, currency: currency)).font(.system(size: 22, weight: .semibold, design: .rounded)).minimumScaleFactor(0.7).lineLimit(1)
                Text(L("\(store.ledger.accounts.count) счетов · \(currency)")).font(.caption2).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.moraGreen.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 14)).contentShape(RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain).help(L("Открыть счета")).padding(16)
            VStack(alignment: .leading, spacing: 12) {
                FeedbackContact(compact: true)
                DonationButton().buttonStyle(.plain).foregroundStyle(.secondary)
            }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 12)
            HStack(spacing: 8) {
                Button { page = .settings } label: { Label(L("Настройки"), systemImage: "slider.horizontal.3").font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { hideAmounts.toggle() } } label: {
                    Image(systemName: hideAmounts ? "eye.slash" : "eye").font(.system(size: 15)).frame(width: 32, height: 32).background(hideAmounts ? Color.moraGreen.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).help(hideAmounts ? L("Показать суммы") : L("Скрыть суммы для скриншота")).accessibilityLabel(hideAmounts ? L("Показать суммы") : L("Скрыть суммы"))
            }.foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 16)
        }
    }
    private var importControl: some View {
        Menu {
            Button(L("Из CSV-файла…"), systemImage: "tablecells") { Task { if let file = await openCSV(store: store) { sheet = .csv(file.0, file.1) } } }
            Button(L("Через AI-агента…"), systemImage: "text.bubble") { sheet = .aiImport }
        } label: {
            HStack(spacing: 8) { Image(systemName: "square.and.arrow.down"); Text(L("Импорт")) }
                .font(.system(size: 14, weight: .medium)).foregroundStyle(Color.primary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .tint(Color.primary).foregroundStyle(Color.primary)
        .padding(.horizontal, 18).frame(height: 36)
        .modifier(ToolbarGlassStyle(shape: Capsule()))
        .help(L("Импорт из CSV или через AI-агента"))
    }
    private var transactionControls: some View {
        HStack(spacing: 10) {
            Button { sheet = .transaction(nil) } label: {
                Image(systemName: "plus").font(.system(size: 16, weight: .medium))
                    .frame(width: 36, height: 36).contentShape(Circle())
            }
            .modifier(ToolbarGlassStyle(shape: Circle()))
            .accessibilityLabel(L("Новая операция"))
            .help(L("Добавить операцию · ⌘N"))
            AppNotificationBell(notifications: store.notifications)
        }.padding(.trailing, 16)
    }
    private var demoBanner: some View {
        HStack { Image(systemName: "sparkles"); Text(L("Это демо: изучите приложение на примере")).font(.system(size: 12)); Spacer(); Button(L("Начать свой учет")) { confirmStart = true }.font(.system(size: 12, weight: .semibold)).buttonStyle(.plain).underline() }.foregroundStyle(Color.moraGreen).padding(.horizontal, 30).padding(.vertical, 12).background(Color.moraGreen.opacity(0.10))
    }
    private func selectMonth(_ date: Date) {
        let next = Dates.month(date)
        requestedMonth = next
        monthPreparation?.cancel()
        monthPreparation = Task { @MainActor in
            await store.prepareReportsForPresentation(in: next, includingAllScopes: true)
            guard !Task.isCancelled else { return }
            AppMotion.update { month = next; requestedMonth = nil }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) { Text(L(page.title)).font(.system(size: 30, weight: .semibold, design: .rounded)).contentTransition(.opacity); Text(page.subtitle).contentTransition(.opacity).font(.system(size: 13)).foregroundStyle(.secondary) }
            Spacer()
            if [.overview, .budgets, .analytics].contains(page) {
                HStack(spacing: 10) {
                    Button { selectMonth(Calendar.current.date(byAdding: .month, value: -1, to: requestedMonth ?? month)!) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).help(L("Предыдущий месяц"))
                    Menu {
                        Button(L("Текущий месяц")) { selectMonth(Dates.month(Date())) }
                        ForEach((-24...12).reversed(), id: \.self) { offset in
                            let date = Calendar.current.date(byAdding: .month, value: offset, to: Dates.month(Date()))!
                            Button(date.formatted(.dateTime.month(.wide).year().locale(L10n.locale))) { selectMonth(date) }
                        }
                    } label: { Text(month.formatted(.dateTime.month(.wide).year().locale(L10n.locale))).font(.system(size: 13, weight: .medium)).frame(minWidth: 125) }.menuStyle(.borderlessButton).fixedSize()
                    Button { selectMonth(Calendar.current.date(byAdding: .month, value: 1, to: requestedMonth ?? month)!) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).help(L("Следующий месяц"))
                }.padding(12).background(scheme == .dark ? Color(nsColor: .controlBackgroundColor) : .white).clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
