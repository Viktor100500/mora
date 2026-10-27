import SwiftUI
import FinanceCore

struct AnalyticsScreen: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var router: AppRouter
    @State private var detail: TrendDetail = .months
    @State private var selectedDays: Set<Int> = []
    private var ledger: Ledger { store.ledger }
    private var currency: String { store.baseCurrency }

    private var periodDescription: String {
        switch detail {
        case .months:
            let start = Calendar.current.date(byAdding: .month, value: -11, to: Dates.month(router.month))!
            return start.monthTitle + " — " + router.month.monthTitle
        case .weeks, .days: return router.month.monthTitle
        case .selectedDates:
            return selectedDays.isEmpty ? L("Выберите дни в календаре расходов") : dayList + " · " + router.month.monthTitle
        }
    }
    private var dayList: String { selectedDays.sorted().map(String.init).joined(separator: ", ") }

    var body: some View {
        let report = store.analyticsReport(in: router.month, detail: detail, selectedDays: selectedDays)
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    MonthSwitcher(month: $router.month)
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeading(title: "Период анализа", subtitle: periodDescription)
                            Picker(L("Период"), selection: $detail.animation()) {
                                ForEach(TrendDetail.allCases) { Text($0.shortTitle).tag($0) }
                            }.pickerStyle(.segmented)
                        }
                    }
                    // Days are picked only for the "Dates" period, right below the picker.
                    if detail == .selectedDates { calendarCard }
                    HStack(spacing: 10) {
                        MetricTile(title: L("Доходы"), value: DisplayMoney.string(report.summary.income, currency: currency), icon: "arrow.down.left", color: "green")
                        MetricTile(title: L("Расходы"), value: DisplayMoney.string(report.summary.expense, currency: currency), icon: "arrow.up.right", color: "orange")
                        MetricTile(title: L("Разница"), value: DisplayMoney.string(report.summary.net, currency: currency), icon: "equal", color: report.summary.net >= 0 ? "green" : "red")
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeading(title: "Доходы и расходы", subtitle: currency)
                            if detail == .selectedDates && selectedDays.isEmpty {
                                Text(L("Выберите дни в календаре расходов")).font(.subheadline).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity).frame(height: 180)
                            } else {
                                TrendChart(trend: report.trend, detail: detail, currency: currency, bars: true).frame(height: 220)
                            }
                            HStack(spacing: 16) { ChartLegend(color: .moraGreen, title: L("Доходы")); ChartLegend(color: .token("orange"), title: L("Расходы")) }
                            if report.summary.income > 0 {
                                FinancialText(L("Доля сбережений: \(Int((report.summary.savingRate * 100).rounded()))%"))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeading(title: "Расходы по категориям")
                            if report.categories.isEmpty {
                                Text(detail == .selectedDates && selectedDays.isEmpty ? L("Выберите дни в календаре расходов") : L("Пока нет расходов"))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            } else {
                                CategoryDonut(totals: report.categories, expense: report.summary.expense, currency: currency).frame(height: 220)
                                ForEach(report.categories) { total in
                                    Button {
                                        router.transactionFilter = TransactionFilterRequest(month: router.month, categoryID: total.id)
                                        router.tab = .transactions
                                    } label: {
                                        CategoryShareRow(total: total, expense: report.summary.expense, currency: currency)
                                    }.buttonStyle(.plain).disabled(total.id == nil)
                                }
                            }
                        }
                    }
                    if detail == .selectedDates && !selectedDays.isEmpty { selectedTransactions }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .background(Color.moraBackground)
            .navigationTitle(L("Аналитика"))
            .onChange(of: router.month) { _, _ in
                selectedDays = []
            }
        }
    }

    private var calendarCard: some View {
        let month = router.month
        let expenses = store.dailyExpenses(in: month)
        let maximum = expenses.values.max() ?? 0
        let first = Calendar.current.component(.weekday, from: Dates.month(month))
        let padding = (first + 5) % 7
        let days = Calendar.current.range(of: .day, in: .month, for: month)!.count
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeading(title: "Календарь расходов", subtitle: "Нажмите на дни, чтобы выбрать их")
                    Spacer()
                    if !selectedDays.isEmpty {
                        Button(L("Сбросить")) { withAnimation { selectedDays = [] } }.font(.subheadline)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach([L("ПН"), L("ВТ"), L("СР"), L("ЧТ"), L("ПТ"), L("СБ"), L("ВС")], id: \.self) {
                        Text($0).font(.caption2.weight(.medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                    ForEach(-padding..<0, id: \.self) { _ in Color.clear.frame(height: 48) }
                    ForEach(1...days, id: \.self) { day in
                        let expense = expenses[day] ?? 0
                        let selected = selectedDays.contains(day)
                        let intensity = maximum > 0 ? (expense / maximum).double : 0
                        Button { toggle(day) } label: {
                            VStack(spacing: 3) {
                                Text("\(day)").font(.caption.weight(.semibold))
                                FinancialText(expense > 0 ? compact(expense) : "·").font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.6)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(Color.moraGreen.opacity(selected ? 0.32 : 0.04 + 0.22 * intensity), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(selected ? Color.moraGreen : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(day) · \(DisplayMoney.string(expense, currency: currency))")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
    }

    private var selectedTransactions: some View {
        let rows = store.transactions(in: router.month).filter { ledger.isActive($0) && selectedDays.contains(Calendar.current.component(.day, from: $0.date)) }
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: "Операции за выбранные даты", subtitle: dayList + " · " + router.month.monthTitle)
                if rows.isEmpty { Text(L("Операций нет")).font(.subheadline).foregroundStyle(.secondary) }
                ForEach(rows) { row in
                    Button { router.open(.transaction(row)) } label: { TransactionRow(transaction: row, ledger: ledger) }.buttonStyle(.plain)
                    if row.id != rows.last?.id { Divider().padding(.leading, 52) }
                }
            }
        }
    }

    private func toggle(_ day: Int) {
        withAnimation(.snappy) {
            if selectedDays.contains(day) { selectedDays.remove(day) } else { selectedDays.insert(day) }
        }
    }

    private func compact(_ value: Decimal) -> String {
        value.double.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)).locale(L10n.locale))
    }
}
