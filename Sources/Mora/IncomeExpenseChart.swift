import SwiftUI
import Charts
import FinanceCore

struct ChartPlotInsetKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct IncomeExpenseChart: View {
    var trend: [MonthTotal]
    var detail: TrendDetail

    var body: some View {
        Chart {
            ForEach(trend) { item in
                BarMark(x: .value(L("Период"), detail.axisLabel(item.date)), y: .value(L("Сумма"), item.income.double))
                    .foregroundStyle(Color.moraGreen).position(by: .value(L("Тип"), L("Доходы"))).cornerRadius(3)
                BarMark(x: .value(L("Период"), detail.axisLabel(item.date)), y: .value(L("Сумма"), item.expense.double))
                    .foregroundStyle(Color.token("orange")).position(by: .value(L("Тип"), L("Расходы"))).cornerRadius(3)
            }
        }
        .chartLegend(.hidden).financialChart()
        .smoothUpdates(value: trend.map { [$0.income, $0.expense] })
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel { if let amount = value.as(Double.self) { FinancialText(amount.formatted(.number.notation(.compactName))) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: detail.axisDates(trend).map { detail.axisLabel($0) }) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel { if let label = value.as(String.self) { Text(label).font(.system(size: 10)).fixedSize() } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear.preference(key: ChartPlotInsetKey.self, value: proxy.plotFrame.map { geometry[$0].minX } ?? 0)
                    .allowsHitTesting(false)
            }
        }
    }
}
