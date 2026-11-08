import SwiftUI
import Charts
import FinanceCore

private struct CashFlowPlotWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 600 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct TrendChart: View {
    var ledger: Ledger
    var month: Date
    var cachedTrend: [MonthTotal]
    var detail: TrendDetail = .months
    var timeline: CashFlowTimeline?
    @State private var selectedDate: Date?
    @State private var scrollStart: Date
    @State private var plotWidth: CGFloat = 600

    init(ledger: Ledger, month: Date, cachedTrend: [MonthTotal], detail: TrendDetail = .months, timeline: CashFlowTimeline? = nil) {
        self.ledger = ledger; self.month = month; self.cachedTrend = cachedTrend
        self.detail = detail; self.timeline = timeline
        _scrollStart = State(initialValue: CashFlowTimeline(month: month, detail: detail).initialStart)
    }

    private var data: CashFlowTimeline { timeline ?? CashFlowTimeline(month: month, detail: detail, buckets: cachedTrend) }
    private var selection: MonthTotal? { selectedDate.flatMap { data.nearest(to: $0, from: scrollStart) } }
    private var currency: String { ledger.preferences.baseCurrency }
    private var yDomain: ClosedRange<Double> {
        let values = data.visibleBuckets(from: scrollStart).flatMap { [$0.income.double, $0.expense.double] }
        return min(0, values.min() ?? 0)...max(1, (values.max() ?? 0) * 1.1)
    }

    var body: some View {
        Chart {
            ForEach(data.plotBuckets(from: scrollStart)) { item in
                LineMark(x: .value(L("Период"), item.date), y: .value(L("Сумма"), item.income.double), series: .value(L("Тип"), "income"))
                    .interpolationMethod(.monotone).lineStyle(StrokeStyle(lineWidth: 2.5))
                    .foregroundStyle(Color.moraGreen)
                    .accessibilityLabel(periodLabel(item.date) + " · " + L("Доходы"))
                    .accessibilityValue(DisplayMoney.string(item.income, currency: currency))
                LineMark(x: .value(L("Период"), item.date), y: .value(L("Сумма"), item.expense.double), series: .value(L("Тип"), "expense"))
                    .interpolationMethod(.monotone).lineStyle(StrokeStyle(lineWidth: 2.5))
                    .foregroundStyle(Color.token("orange"))
                    .accessibilityLabel(periodLabel(item.date) + " · " + L("Расходы"))
                    .accessibilityValue(DisplayMoney.string(item.expense, currency: currency))
            }
            if let selection {
                RuleMark(x: .value(L("Период"), selection.date))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityHidden(true)
                PointMark(x: .value(L("Период"), selection.date), y: .value(L("Сумма"), selection.income.double))
                    .foregroundStyle(Color.moraGreen).symbolSize(45).accessibilityHidden(true)
                PointMark(x: .value(L("Период"), selection.date), y: .value(L("Сумма"), selection.expense.double))
                    .foregroundStyle(Color.token("orange")).symbolSize(45).accessibilityHidden(true)
            }
        }
        .chartXScale(domain: data.domain, range: .plotDimension(startPadding: 24, endPadding: 24))
        .chartYScale(domain: yDomain)
        .chartLegend(.hidden)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: data.visibleDuration)
        .chartScrollPosition(x: $scrollStart)
        .chartXAxis {
            AxisMarks(values: axisDates) { value in
                AxisValueLabel(collisionResolution: .greedy(minimumSpacing: 12)) {
                    if let date = value.as(Date.self) {
                        Text(detail.axisLabel(date)).font(.system(size: 10)).fixedSize()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4])).foregroundStyle(Color.secondary.opacity(0.16))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        FinancialText(amount.formatted(.number.notation(.compactName))).font(.system(size: 9))
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let container = proxy.plotContainerFrame, let plot = proxy.plotFrame {
                    let frame = geometry[container], plotFrame = geometry[plot]
                    CashFlowInteractionLayer(onHover: { location in
                        let date = location.flatMap { proxy.value(atX: $0.x + frame.minX - plotFrame.minX, as: Date.self) }
                        selectedDate = date.flatMap { data.nearest(to: $0, from: scrollStart)?.date }
                    }, onScroll: { delta in
                        selectedDate = nil
                        scrollStart = data.scrolledStart(from: scrollStart, horizontalDelta: Double(delta), width: Double(frame.width))
                    })
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .preference(key: ChartPlotInsetKey.self, value: frame.minX)
                    .preference(key: CashFlowPlotWidthKey.self, value: frame.width)
                }
            }
        }
        .onPreferenceChange(CashFlowPlotWidthKey.self) { width in
            if abs(width - plotWidth) > 0.5 { plotWidth = width }
        }
        .safeAreaInset(edge: .bottom, spacing: 4) {
            Text(visiblePeriodLabel).font(.system(size: 9)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        // The tooltip is outside the scrolling chart's content, so it stays legible
        // at both edges and cannot intercept the hover or two-finger scroll.
        .overlay(alignment: .topTrailing) {
            if let selection {
                VStack(alignment: .leading, spacing: 7) {
                    Text(periodLabel(selection.date)).font(.system(size: 12, weight: .medium))
                    tooltipRow(L("Доходы"), amount: selection.income, color: .moraGreen)
                    tooltipRow(L("Расходы"), amount: selection.expense, color: .token("orange"))
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .padding(8).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onChange(of: month) { _, _ in resetPosition() }
        .onChange(of: detail) { _, _ in resetPosition() }
        .onChange(of: scrollStart) { _, _ in selectedDate = nil }
        .accessibilityLabel(L("Денежный поток") + " · " + detail.title)
        .financialChart()
    }

    private func resetPosition() {
        selectedDate = nil
        scrollStart = CashFlowTimeline(month: month, detail: detail).initialStart
    }

    /// Keep entire labels inside the visible window. Offscreen axis marks would
    /// otherwise be partially clipped by the chart's native scroll container.
    private var axisDates: [Date] {
        let calendar = Calendar.current
        let margin = data.visibleDuration * min(0.2, 40 / Double(max(1, plotWidth)))
        let lower = scrollStart.addingTimeInterval(margin)
        let upper = scrollStart.addingTimeInterval(data.visibleDuration - margin)
        var date = calendar.dateInterval(of: detail == .months ? .month : .weekOfYear, for: lower)!.start
        if detail == .months { date = calendar.date(byAdding: .day, value: 14, to: date)! }
        var result: [Date] = []
        while date <= upper {
            if date >= lower { result.append(date) }
            date = calendar.date(byAdding: detail == .months ? .month : .day, value: detail == .months ? 1 : 7, to: date)!
        }
        return result
    }

    private var visiblePeriodLabel: String {
        let end = scrollStart.addingTimeInterval(data.visibleDuration - 1)
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated).year().locale(L10n.locale)
        return scrollStart.formatted(style) + " – " + end.formatted(style)
    }

    private func periodLabel(_ date: Date) -> String {
        if detail == .months { return date.formatted(.dateTime.month(.wide).year().locale(L10n.locale)) }
        if detail == .weeks {
            var calendar = Calendar.current; calendar.firstWeekday = 2
            let end = min(calendar.dateInterval(of: .weekOfYear, for: date)!.end,
                          calendar.dateInterval(of: .month, for: date)!.end).addingTimeInterval(-1)
            return date.formatted(.dateTime.day().month(.abbreviated).locale(L10n.locale)) + " – "
                + end.formatted(.dateTime.day().month(.abbreviated).year().locale(L10n.locale))
        }
        return date.formatted(.dateTime.day().month(.wide).year().locale(L10n.locale))
    }

    private func tooltipRow(_ title: String, amount: Decimal, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            FinancialText(DisplayMoney.string(amount, currency: currency)).font(.caption.weight(.medium))
        }.fixedSize()
    }
}
