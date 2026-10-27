import SwiftUI
import FinanceCore

struct AnalyticsScreen: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var router: AppRouter
    @State private var detail: TrendDetail = .months
    @State private var selectedDays: Set<Int> = []
    @State private var pickMode: DayPickMode = .period
    /// First tapped day of a period that still waits for its last day.
    @State private var periodStart: Int?
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
    private var dayList: String {
        var ranges: [ClosedRange<Int>] = []
        for day in selectedDays.sorted() {
            if let last = ranges.last, last.upperBound + 1 == day { ranges[ranges.count - 1] = last.lowerBound...day } else { ranges.append(day...day) }
        }
        return ranges.map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)–\($0.upperBound)" }.joined(separator: ", ")
    }
    private var calendarHint: String {
        switch pickMode {
        case .days: return "Нажмите на дни, чтобы выбрать их"
        case .period: return periodStart == nil ? "Нажмите на первый и последний день периода" : "Теперь выберите последний день"
        }
    }

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
                periodStart = nil
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
                    SectionHeading(title: "Календарь расходов", subtitle: calendarHint)
                    Spacer()
                    if !selectedDays.isEmpty {
                        Button(L("Сбросить")) { withAnimation { selectedDays = []; periodStart = nil } }.font(.subheadline)
                    }
                }
                Picker(L("Выбор дней"), selection: $pickMode) {
                    Text(L("Период")).tag(DayPickMode.period)
                    Text(L("Отдельные дни")).tag(DayPickMode.days)
                }
                .pickerStyle(.segmented)
                .onChange(of: pickMode) { _, _ in periodStart = nil }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach([L("ПН"), L("ВТ"), L("СР"), L("ЧТ"), L("ПТ"), L("СБ"), L("ВС")], id: \.self) {
                        Text($0).font(.caption2.weight(.medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                    ForEach(-padding..<0, id: \.self) { _ in Color.clear.frame(height: 52) }
                    ForEach(1...days, id: \.self) { day in
                        let expense = expenses[day] ?? 0
                        let selected = selectedDays.contains(day)
                        let intensity = maximum > 0 ? (expense / maximum).double : 0
                        // Ends of a selected run are solid, days inside it are tinted.
                        let edge = selected && !(selectedDays.contains(day - 1) && selectedDays.contains(day + 1))
                        Button { tap(day) } label: {
                            // Selection owns the cell fill; spending is a separate bar so a costly day never looks picked.
                            VStack(spacing: 3) {
                                Text("\(day)").font(.caption.weight(.semibold))
                                    .foregroundStyle(edge ? Color.white : selected ? Color.moraGreen : Color.primary)
                                FinancialText(expense > 0 ? compact(expense) : "·").font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.6)
                                    .foregroundStyle(edge ? Color.white.opacity(0.85) : Color.secondary)
                                Capsule()
                                    .fill(expense > 0 ? (edge ? Color.white.opacity(0.35) : Color.primary.opacity(0.08)) : .clear)
                                    .overlay(alignment: .leading) {
                                        GeometryReader { proxy in
                                            Capsule().fill(edge ? Color.white : Color.token("orange"))
                                                .frame(width: expense > 0 ? max(3, proxy.size.width * intensity) : 0)
                                        }
                                    }
                                    .frame(height: 3).padding(.horizontal, 8)
                            }
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .background(edge ? Color.moraGreen : selected ? Color.moraGreen.opacity(0.16) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(periodStart == day ? Color.moraGreen.opacity(0.45) : .clear, lineWidth: 3).padding(-2))
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

    private func tap(_ day: Int) {
        withAnimation(.snappy) {
            switch pickMode {
            case .days:
                if selectedDays.contains(day) { selectedDays.remove(day) } else { selectedDays.insert(day) }
            case .period:
                if let start = periodStart {
                    selectedDays = Set(min(start, day)...max(start, day))
                    periodStart = nil
                } else {
                    selectedDays = [day]
                    periodStart = day
                }
            }
        }
    }

    private func compact(_ value: Decimal) -> String {
        value.double.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)).locale(L10n.locale))
    }
}

private enum DayPickMode { case period, days }
