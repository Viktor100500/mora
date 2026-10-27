import SwiftUI
import FinanceCore

struct OverviewScreen: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var router: AppRouter
    @AppStorage("mora.hideAmounts") private var hideAmounts = false
    @State private var trendDetail: TrendDetail = .months
    private var ledger: Ledger { store.ledger }
    private var currency: String { store.baseCurrency }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if store.isDemo { DemoBanner() }
                    MonthSwitcher(month: $router.month)
                    netWorthCard
                    metrics
                    CurrencyWarning()
                    if ledger.accounts.isEmpty {
                        Card { EmptyCard(icon: "wallet.bifold", title: "Нет счетов", text: "Добавьте счет и начальный остаток. Для импорта истории укажите остаток перед первой операцией.", button: "Добавить счет") { router.open(.account(nil)) } }
                    }
                    cashFlowCard
                    categoriesCard
                    recentCard
                    insightsCard
                    if ledger.preferences.showRecurring { recurringCard }
                    if ledger.preferences.showBudgets && !ledger.budgets.isEmpty { budgetsCard }
                    StorageFooter()
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .background(Color.moraBackground)
            .navigationTitle(L("Обзор"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { withAnimation { hideAmounts.toggle() } } label: { Image(systemName: hideAmounts ? "eye.slash" : "eye") }
                        .accessibilityLabel(hideAmounts ? L("Показать суммы") : L("Скрыть суммы"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { router.open(.transaction(nil)) } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                        .accessibilityLabel(L("Новая операция"))
                }
            }
            .refreshable { await store.reloadFromDisk(); await store.refreshExchangeRates() }
        }
    }

    private var netWorthCard: some View {
        Button { router.tab = .accounts } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(L("Общий капитал"), systemImage: "chart.line.uptrend.xyaxis").font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).opacity(0.7)
                }
                FinancialText(DisplayMoney.string(store.netWorth, currency: currency))
                    .font(.system(size: 34, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.5)
                Text(L("На сегодня · активные счета: \(ledger.accounts.filter { !$0.archived }.count)")).font(.caption).opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [Color(red: 0.25, green: 0.51, blue: 0.41), Color(red: 0.11, green: 0.31, blue: 0.23)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }.buttonStyle(.plain)
    }

    private var metrics: some View {
        let summary = store.summary(in: router.month)
        return HStack(spacing: 10) {
            MetricTile(title: L("Доходы"), value: DisplayMoney.string(summary.income, currency: currency), icon: "arrow.down.left", color: "green")
            MetricTile(title: L("Расходы"), value: DisplayMoney.string(summary.expense, currency: currency), icon: "arrow.up.right", color: "orange")
            MetricTile(title: L("Разница"), value: DisplayMoney.string(summary.net, currency: currency), icon: "equal", color: summary.net >= 0 ? "green" : "red")
        }
    }

    private var cashFlowCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "Денежный поток", subtitle: trendDetail == .months ? "Доходы и расходы за 6 месяцев" : "Доходы и расходы за выбранный месяц")
                Picker(L("Период"), selection: $trendDetail.animation()) {
                    ForEach([TrendDetail.months, .weeks, .days]) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                TrendChart(trend: store.trend(ending: router.month, detail: trendDetail), detail: trendDetail, currency: currency, bars: trendDetail == .days)
                    .frame(height: 200)
                HStack(spacing: 16) {
                    ChartLegend(color: .moraGreen, title: L("Доходы"))
                    ChartLegend(color: .token("orange"), title: L("Расходы"))
                    Spacer()
                    Text(currency).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var categoriesCard: some View {
        let totals = store.categoryTotals(in: router.month)
        let expense = store.summary(in: router.month).expense
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeading(title: "Расходы по категориям", subtitle: "За выбранный месяц")
                    Spacer()
                    LinkButton(title: "Аналитика") { router.tab = .analytics }
                }
                if totals.isEmpty {
                    EmptyCard(icon: "chart.pie", title: "Пока нет расходов", text: "Диаграмма появится после первой операции")
                } else {
                    CategoryDonut(totals: totals, expense: expense, currency: currency).frame(height: 210)
                    ForEach(totals.prefix(5)) { total in
                        CategoryShareRow(total: total, expense: expense, currency: currency)
                    }
                }
            }
        }
    }

    private var recentCard: some View {
        let rows = store.recentTransactions(in: router.month)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeading(title: "Последние операции")
                    Spacer()
                    LinkButton(title: "Все") {
                        router.transactionFilter = TransactionFilterRequest(month: router.month)
                        router.tab = .transactions
                    }
                }
                if rows.isEmpty {
                    Text(L("В этом месяце нет операций")).font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 12)
                }
                ForEach(rows) { transaction in
                    Button { router.open(.transaction(transaction)) } label: { TransactionRow(transaction: transaction, ledger: ledger) }
                        .buttonStyle(.plain)
                    if transaction.id != rows.last?.id { Divider().padding(.leading, 52) }
                }
            }
        }
    }

    private var insightsCard: some View {
        let insights = store.insights(in: router.month)
        return Group {
            if !insights.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeading(title: "Сводка за месяц")
                        ForEach(Array(insights.prefix(4).enumerated()), id: \.offset) { _, text in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "sparkle").font(.caption).foregroundStyle(Color.moraGreen).padding(.top, 3)
                                FinancialText(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private var recurringCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeading(title: "Ближайший платеж")
                    Spacer()
                    NavigationLink { RecurringScreen() } label: { Text(L("Все платежи")).font(.subheadline.weight(.medium)) }
                }
                if let payment = ledger.recurring.filter({ $0.active && ledger.account($0.accountID)?.archived == false }).sorted(by: { $0.nextDate < $1.nextDate }).first {
                    HStack {
                        IconTile(icon: ledger.category(payment.categoryID)?.icon ?? "repeat", color: ledger.category(payment.categoryID)?.color ?? "blue", size: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(payment.name).font(.subheadline.weight(.medium))
                            Text(payment.nextDate.dayTitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        FinancialText(DisplayMoney.string(payment.amount, currency: ledger.account(payment.accountID)?.currency ?? currency)).font(.headline)
                    }
                } else {
                    Text(L("Регулярных платежей нет")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var budgetsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeading(title: "Бюджеты")
                    Spacer()
                    NavigationLink { BudgetsScreen() } label: { Text(L("Все бюджеты")).font(.subheadline.weight(.medium)) }
                }
                ForEach(ledger.budgets.prefix(3)) { budget in BudgetProgress(budget: budget, month: router.month) }
            }
        }
    }
}

struct MetricTile: View {
    var title: String; var value: String; var icon: String; var color: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption.weight(.bold)).foregroundStyle(Color.token(color))
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            FinancialText(value).font(.system(.subheadline, design: .rounded).weight(.semibold)).lineLimit(1).minimumScaleFactor(0.55)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.moraCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct BudgetProgress: View {
    @EnvironmentObject private var store: FinanceStore
    let budget: Budget
    let month: Date
    var body: some View {
        let spent = store.spent(category: budget.categoryID, in: month)
        let category = store.ledger.category(budget.categoryID)
        let currency = store.baseCurrency
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                IconTile(icon: category?.icon ?? "tag", color: category?.color ?? "green", size: 28)
                Text(category?.name ?? "").font(.subheadline.weight(.medium))
                Spacer()
                FinancialText(DisplayMoney.string(spent, currency: currency)).font(.subheadline.weight(.semibold))
                FinancialText(L("из \(DisplayMoney.string(budget.limit, currency: currency))")).font(.caption).foregroundStyle(.secondary)
            }
            Meter(progress: (spent / budget.limit).double, color: spent > budget.limit ? .token("red") : .token(category?.color ?? "green"))
        }
    }
}
