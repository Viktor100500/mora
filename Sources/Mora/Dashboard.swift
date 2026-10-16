import SwiftUI
import Charts
import FinanceCore

struct DashboardView: View {
    @EnvironmentObject var store: FinanceStore
    var month: Date
    @Binding var page: Page
    @Binding var sheet: EditorSheet?
    private var ledger: Ledger { store.ledger }
    private var currency: String { ledger.preferences.baseCurrency }

    var body: some View {
        let summary = store.reportSummary(in: month)
        VStack(spacing: 20) {
            if ledger.accounts.isEmpty {
                Card { EmptyState(icon: "wallet.bifold", title: L("Нет счетов"), text: L("Добавьте счет и начальный остаток. Для импорта истории укажите остаток перед первой операцией."), button: L("Добавить счет")) { sheet = .account(nil) } }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: 4), spacing: 20) {
                MetricCard(title: L("Общий капитал"), value: DisplayMoney.string(store.reportNetWorth, currency: currency), icon: "wallet.bifold", note: L("На сегодня · активные счета"), color: "green")
                MetricCard(title: L("Доходы"), value: DisplayMoney.string(summary.income, currency: currency), icon: "arrow.down.left", note: L("За выбранный месяц"), color: "green")
                MetricCard(title: L("Расходы"), value: DisplayMoney.string(summary.expense, currency: currency), icon: "arrow.up.right", note: L("Без переводов между счетами"), color: "orange")
                MetricCard(title: L("Разница"), value: DisplayMoney.string(summary.net, currency: currency), icon: "equal", note: L("Доходы минус расходы"), color: summary.net >= 0 ? "green" : "red")
            }
            BalancedColumns {
                Card(fillsHeight: true) {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack { SectionHeading(title: L("Денежный поток"), subtitle: L("Доходы и расходы за 6 месяцев")); Spacer(); Image(systemName: "chart.xyaxis.line").foregroundStyle(.secondary) }
                        TrendChart(ledger: ledger, month: month, cachedTrend: store.reportTrend(ending: month)).frame(minHeight: 250, maxHeight: .infinity)
                        HStack(spacing: 18) { ChartLegend(color: .moraGreen, title: L("Доходы")); ChartLegend(color: .token("orange"), title: L("Расходы")); Spacer(); Text(currency).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Card(fillsHeight: true) { CategoryChart(ledger: ledger, month: month, cachedTotals: store.reportCategories(in: month), cachedExpense: store.reportSummary(in: month).expense, openAnalytics: { page = .analytics }) }
            }
            Card {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { SectionHeading(title: L("Последние операции")); Spacer(); Button(L("Все операции →")) { page = .transactions }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.moraGreen) }
                    let rows = Array(store.reportTransactions(in: month).filter(ledger.isActive).sorted { $0.date > $1.date }.prefix(5))
                    if rows.isEmpty { Text(L("В этом месяце нет операций")).foregroundStyle(.secondary).padding(.vertical, 28) }
                    ForEach(rows) { transaction in
                        TransactionRow(transaction: transaction, ledger: ledger).contentShape(Rectangle()).onTapGesture { sheet = .transaction(transaction) }
                        if transaction.id != rows.last?.id { Divider().opacity(0.55) }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeading(title: L("Сводка за месяц"))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 20, alignment: .topLeading)], alignment: .leading, spacing: 16) {
                        ForEach(Array(store.reportInsights(in: month).prefix(3).enumerated()), id: \.offset) { _, text in
                            FinancialText(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            if ledger.preferences.showRecurring {
                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack { SectionHeading(title: L("Ближайший платеж")); Spacer(); Button(L("Все платежи →")) { page = .recurring }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.moraGreen) }
                        if let payment = ledger.recurring.filter({ $0.active && ledger.account($0.accountID)?.archived == false }).sorted(by: { $0.nextDate < $1.nextDate }).first {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) { Text(payment.name).font(.callout.weight(.medium)); Text(payment.nextDate.formatted(.dateTime.day().month(.wide).locale(L10n.locale))).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                FinancialText(DisplayMoney.string(payment.amount, currency: ledger.account(payment.accountID)?.currency ?? currency)).font(.system(size: 17, weight: .semibold))
                            }
                        } else { Text(L("Регулярных платежей нет")).font(.callout).foregroundStyle(.secondary) }
                    }
                }
            }
            if ledger.preferences.showBudgets && !ledger.budgets.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack { SectionHeading(title: L("Бюджеты")); Spacer(); Button(L("Все бюджеты →")) { page = .budgets }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.moraGreen) }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 20)], spacing: 20) {
                            ForEach(Array(ledger.budgets.prefix(3))) { budget in BudgetMini(budget: budget, ledger: ledger, month: month) }
                        }
                    }
                }
            }
        }
    }
}

/// Measures both cards at their actual widths, then gives them the same height.
/// The category column grows with the window instead of staying at 310 points.
struct BalancedColumns: Layout {
    var spacing: CGFloat = 20
    private func widths(_ width: CGFloat) -> [CGFloat] {
        let secondary = min(400, max(280, (width - spacing) / 3))
        return [max(0, width - spacing - secondary), secondary]
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 1040
        let widths = widths(width)
        let height = zip(subviews, widths).map { $0.sizeThatFits(.init(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = widths(bounds.width)
        var x = bounds.minX
        for (view, width) in zip(subviews, widths) {
            view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: .init(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

struct MetricCard: View {
    var title: String; var value: String; var icon: String; var note: String; var color: String
    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(title).font(.system(size: 12)).foregroundStyle(.secondary); Spacer(minLength: 4); IconTile(icon: icon, color: color, size: 29) }
                FinancialText(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                Text(note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).frame(height: 25, alignment: .topLeading)
            }
        }
    }
}

struct ChartLegend: View {
    var color: Color; var title: String
    var body: some View { HStack(spacing: 6) { Circle().fill(color).frame(width: 7, height: 7); Text(title).font(.caption).foregroundStyle(.secondary) } }
}

struct TrendChart: View {
    var ledger: Ledger; var month: Date
    var cachedTrend: [MonthTotal]? = nil
    var body: some View {
        let trend = cachedTrend ?? ledger.trend(ending: month)
        let amounts = trend.flatMap { [$0.income.double, $0.expense.double] }
        Chart {
            ForEach(trend) { item in
                AreaMark(x: .value(L("Месяц"), item.date, unit: .month), y: .value(L("Доход"), item.income.double))
                    .foregroundStyle(LinearGradient(colors: [.moraGreen.opacity(0.18), .moraGreen.opacity(0.01)], startPoint: .top, endPoint: .bottom)).interpolationMethod(.monotone)
                LineMark(x: .value(L("Месяц"), item.date, unit: .month), y: .value(L("Сумма"), item.income.double), series: .value(L("Тип"), L("Доход")))
                    .foregroundStyle(Color.moraGreen).lineStyle(StrokeStyle(lineWidth: 2.5)).interpolationMethod(.monotone)
                LineMark(x: .value(L("Месяц"), item.date, unit: .month), y: .value(L("Сумма"), item.expense.double), series: .value(L("Тип"), L("Расход")))
                    .foregroundStyle(Color.token("orange")).lineStyle(StrokeStyle(lineWidth: 2.5)).interpolationMethod(.monotone)
                PointMark(x: .value(L("Месяц"), item.date, unit: .month), y: .value(L("Доход"), item.income.double)).foregroundStyle(Color.moraGreen).symbolSize(22)
            }
        }
        .chartYScale(domain: min(0, amounts.min() ?? 0)...max(1, (amounts.max() ?? 0) * 1.1))
        .chartLegend(.hidden)
        .chartXAxis { AxisMarks(values: .stride(by: .month)) { value in AxisValueLabel { if let date = value.as(Date.self) { Text(date.formatted(.dateTime.month(.abbreviated).locale(L10n.locale))).font(.system(size: 10)) } } } }
        .chartYAxis { AxisMarks(position: .leading) { value in AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4])).foregroundStyle(Color.secondary.opacity(0.16)); AxisValueLabel { if let amount = value.as(Double.self) { FinancialText(amount.formatted(.number.notation(.compactName))).font(.system(size: 9)) } } } }
        .accessibilityLabel(L("Доходы и расходы за последние шесть месяцев")).financialChart()
    }
}

struct CategoryChart: View {
    var ledger: Ledger; var month: Date
    var cachedTotals: [CategoryTotal]? = nil
    var cachedExpense: Decimal? = nil
    var openAnalytics: (() -> Void)? = nil
    var body: some View {
        let totals = cachedTotals ?? ledger.categoryTotals(in: month)
        let expense = cachedExpense ?? ledger.summary(in: month).expense
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                SectionHeading(title: L("Расходы по категориям"), subtitle: L("За выбранный месяц"))
                if let openAnalytics {
                    Spacer(minLength: 8)
                    Button(L("Вся аналитика →"), action: openAnalytics)
                        .buttonStyle(.plain).font(.caption).foregroundStyle(Color.moraGreen).fixedSize()
                }
            }
            if totals.isEmpty { EmptyState(icon: "chart.pie", title: L("Пока нет расходов"), text: L("Диаграмма появится после первой операции")) }
            else {
                Chart(totals) { total in SectorMark(angle: .value(L("Сумма"), total.amount.double), innerRadius: .ratio(0.76), angularInset: 2).cornerRadius(4).foregroundStyle(Color.token(total.color)) }
                    .chartLegend(.hidden).frame(height: 180)
                    .chartBackground { proxy in GeometryReader { geometry in if let anchor = proxy.plotFrame { let frame = geometry[anchor]; VStack(spacing: 5) { Text(L("Всего")).font(.caption).foregroundStyle(.secondary); FinancialText(DisplayMoney.string(expense, currency: ledger.preferences.baseCurrency)).font(.system(size: 17, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6) }.frame(width: frame.width * 0.7).position(x: frame.midX, y: frame.midY) } } }
                    .accessibilityLabel(L("Распределение расходов по категориям")).financialChart()
                ForEach(Array(totals.prefix(4))) { total in
                    HStack(spacing: 7) {
                        Circle().fill(Color.token(total.color)).frame(width: 7, height: 7)
                        Text(total.name).font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 4)
                        FinancialText(DisplayMoney.string(total.amount, currency: ledger.preferences.baseCurrency)).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        Text("\(Int((expense > 0 ? (total.amount / expense).double : 0) * 100))%").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).fixedSize()
                    }
                }
            }
        }
    }
}

struct TransactionRow: View {
    var transaction: Transaction; var ledger: Ledger
    var merchantLines: Int? = 1
    var body: some View {
        let category = ledger.category(transaction.categoryID)
        HStack(spacing: 12) {
            IconTile(icon: transaction.kind == .transfer ? "arrow.left.arrow.right" : category?.icon ?? "tag", color: category?.color ?? (transaction.kind == .income ? "green" : "gray"), size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.merchant).font(.system(size: 13, weight: .medium)).lineLimit(merchantLines).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) { Text(transaction.kind == .transfer ? L("Перевод") : category?.name ?? L("Без категории")); Text("·"); Text(ledger.account(transaction.accountID)?.name ?? ""); if let removed = transaction.removedTransferAccountName { Text(L("· удаленный счет: \(removed)")) } else if transaction.kind == .transfer { Text("→ \(transaction.destinationAccountID.flatMap { ledger.account($0)?.name } ?? "")") } }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                if let conversion = transaction.conversion {
                    FinancialText("\(DisplayMoney.string(abs(conversion.originalAmount), currency: conversion.originalCurrency)) · Visa \(Money.plain(conversion.rate))\(conversion.feePercent == 0 ? "" : " + " + Money.plain(conversion.feePercent) + "%")").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                FinancialText((transaction.kind == .income ? "+" : "") + DisplayMoney.string(transaction.amount, currency: ledger.account(transaction.accountID)?.currency ?? "RUB")).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(transaction.kind == .income ? Color.moraGreen : .primary).monospacedDigit()
                Text(transaction.date.formatted(.dateTime.day().month(.abbreviated).locale(L10n.locale))).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
        }.padding(.vertical, 3)
    }
}

struct BudgetMini: View {
    var budget: Budget; var ledger: Ledger; var month: Date
    var body: some View {
        let spent = ledger.spent(category: budget.categoryID, in: month)
        let c = ledger.category(budget.categoryID)
        VStack(alignment: .leading, spacing: 12) {
            HStack { IconTile(icon: c?.icon ?? "tag", color: c?.color ?? "green", size: 28); Text(c?.name ?? "").font(.system(size: 12, weight: .medium)); Spacer() }
            Meter(progress: (spent / budget.limit).double, color: spent > budget.limit ? .token("red") : .token(c?.color ?? "green"))
            HStack(alignment: .firstTextBaseline) { FinancialText(DisplayMoney.string(spent, currency: ledger.preferences.baseCurrency)).font(.system(size: 14, weight: .semibold, design: .rounded)); Spacer(); FinancialText(L("из \(DisplayMoney.string(budget.limit, currency: ledger.preferences.baseCurrency))")).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
    }
}

struct AnalyticsView: View {
    @EnvironmentObject var store: FinanceStore
    var month: Date
    @State private var selectedDay: Int?
    private var ledger: Ledger { store.ledger }
    var body: some View {
        VStack(spacing: 22) {
            BalancedColumns {
                Card(fillsHeight: true) {
                    VStack(alignment: .leading, spacing: 22) {
                        SectionHeading(title: L("Доходы и расходы"), subtitle: L("Сравнение по месяцам · \(ledger.preferences.baseCurrency)"))
                        Chart {
                            ForEach(store.reportTrend(ending: month, count: 12)) { item in
                                BarMark(x: .value(L("Месяц"), item.date, unit: .month), y: .value(L("Сумма"), item.income.double)).foregroundStyle(Color.moraGreen).position(by: .value(L("Тип"), L("Доходы"))).cornerRadius(3)
                                BarMark(x: .value(L("Месяц"), item.date, unit: .month), y: .value(L("Сумма"), item.expense.double)).foregroundStyle(Color.token("orange")).position(by: .value(L("Тип"), L("Расходы"))).cornerRadius(3)
                            }
                        }.chartLegend(.hidden).frame(height: 250).financialChart()
                        .chartYAxis { AxisMarks(position: .leading) { value in AxisGridLine(); AxisValueLabel { if let amount = value.as(Double.self) { FinancialText(amount.formatted(.number.notation(.compactName))) } } } }
                        HStack { ChartLegend(color: .moraGreen, title: L("Доходы")); ChartLegend(color: .token("orange"), title: L("Расходы")) }
                    }
                }
                Card(fillsHeight: true) { CategoryChart(ledger: ledger, month: month, cachedTotals: store.reportCategories(in: month), cachedExpense: store.reportSummary(in: month).expense) }
            }
            Card {
                VStack(alignment: .leading, spacing: 20) {
                    SectionHeading(title: L("Календарь расходов"), subtitle: L("Нажмите на день, чтобы увидеть операции"))
                    let first = Calendar.current.component(.weekday, from: Dates.month(month))
                    let padding = (first + 5) % 7
                    let days = Calendar.current.range(of: .day, in: .month, for: month)!.count
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
                        ForEach([L("ПН"), L("ВТ"), L("СР"), L("ЧТ"), L("ПТ"), L("СБ"), L("ВС")], id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                        ForEach(-padding..<0, id: \.self) { _ in Color.clear.frame(height: 62) }
                        ForEach(1...days, id: \.self) { day in
                            let rows = store.reportTransactions(in: month).filter { ledger.isActive($0) && Calendar.current.component(.day, from: $0.date) == day }
                            let expense = rows.filter { $0.kind == .expense }.reduce(Decimal(0)) { $0 - (ledger.value($1) ?? 0) }
                            Button { selectedDay = selectedDay == day ? nil : day } label: {
                                VStack(alignment: .leading, spacing: 7) { Text("\(day)").font(.system(size: 11, weight: .medium)); FinancialText(expense > 0 ? DisplayMoney.string(expense, currency: ledger.preferences.baseCurrency) : "—").font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.5).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(10).frame(height: 62).background(Color.moraGreen.opacity(expense > 0 ? min(0.06 + expense.double / 300_000, 0.35) : 0.025)).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedDay == day ? Color.moraGreen : .clear))
                            }.buttonStyle(.plain)
                        }
                    }
                    if let selectedDay {
                        Divider()
                        let rows = store.reportTransactions(in: month).filter { ledger.isActive($0) && Calendar.current.component(.day, from: $0.date) == selectedDay }.sorted { $0.amount < $1.amount }
                        Text(L("Операции за \(selectedDay)-е число")).font(.callout.weight(.medium))
                        if rows.isEmpty { Text(L("Операций нет")).foregroundStyle(.secondary) }
                        ForEach(rows) { row in TransactionRow(transaction: row, ledger: ledger) }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 18) {
                    SectionHeading(title: L("Расходы по категориям"))
                    if store.reportCategories(in: month).isEmpty { Text(L("Добавьте расходные операции для анализа")).foregroundStyle(.secondary) }
                    ForEach(store.reportCategories(in: month)) { total in HStack { IconTile(icon: total.icon, color: total.color, size: 30); Text(total.name).font(.callout); Spacer(); Meter(progress: (total.amount / max(store.reportSummary(in: month).expense, 1)).double, color: .token(total.color)).frame(width: 180); FinancialText(DisplayMoney.string(total.amount, currency: ledger.preferences.baseCurrency)).font(.callout.monospacedDigit()).frame(width: 140, alignment: .trailing) } }
                }
            }
        }
    }
}
