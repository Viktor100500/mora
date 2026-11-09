import SwiftUI
import Charts
import FinanceCore

/// Include the curve crossing each viewport edge, not just its dated vertices.
/// A peak leaving the viewport then decreases continuously as its tail leaves.
struct CashFlowScale: Equatable {
    var lower: Double
    var upper: Double
    var domain: ClosedRange<Double> { min(0, lower)...max(1, upper) }

    init(lower: Double = 0, upper: Double = 1) {
        self.lower = lower; self.upper = upper
    }

    init(buckets: [MonthTotal]) {
        let values = buckets.flatMap { [$0.income.double, $0.expense.double] }
        self.init(lower: min(0, values.min() ?? 0), upper: max(1, (values.max() ?? 0) * 1.1))
    }

    init(buckets: [MonthTotal], start: Date, duration: TimeInterval) {
        guard let first = buckets.first, let last = buckets.last else {
            self.init(); return
        }
        let span = max(1, last.date.timeIntervalSince(first.date))
        let positions = buckets.map { $0.date.timeIntervalSince(first.date) / span }
        let end = start.addingTimeInterval(duration)
        var values = buckets.filter { $0.date >= start && $0.date <= end }
            .flatMap { [$0.income.double, $0.expense.double] }
        let boundaries = [start, end].filter { $0 >= first.date && $0 <= last.date }
            .map { $0.timeIntervalSince(first.date) / span }
        for amounts in [buckets.map { $0.income.double }, buckets.map { $0.expense.double }] {
            values += TrendCurveGeometry.interpolate(x: positions, y: amounts, at: boundaries)
        }
        self.init(lower: min(0, values.min() ?? 0), upper: max(1, (values.max() ?? 0) * 1.1))
    }
}

/// Interpolate only the Y domain. Scroll position, dated marks and hover tracking
/// update immediately, rather than inheriting an animation of the entire chart.
nonisolated struct CashFlowScaleModifier: AnimatableModifier {
    var scale: CashFlowScale
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(scale.lower, scale.upper) }
        set { scale = CashFlowScale(lower: newValue.first, upper: newValue.second) }
    }

    func body(content: Content) -> some View {
        content.chartYScale(domain: scale.domain)
            .transaction { $0.animation = nil }
    }
}
