import SwiftUI
import FinanceCore

/// Every aggregation uses the same path topology, so SwiftUI can interpolate
/// the existing contour instead of removing and inserting dated chart marks.
struct TrendCurveVector: VectorArithmetic {
    static let count = 128
    var values: [Double]
    init(_ values: [Double]) {
        precondition(values.count == Self.count)
        self.values = values
    }
    static var zero: Self { Self(Array(repeating: 0, count: count)) }
    static func + (lhs: Self, rhs: Self) -> Self { Self(zip(lhs.values, rhs.values).map(+)) }
    static func - (lhs: Self, rhs: Self) -> Self { Self(zip(lhs.values, rhs.values).map(-)) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}

struct TrendCurveGeometry: Equatable {
    let income: TrendCurveVector
    let expense: TrendCurveVector
    let lower: Double
    let upper: Double
    let baseline: Double
    let start: Date
    let duration: TimeInterval
    var domain: ClosedRange<Double> { lower...upper }

    init(_ trend: [MonthTotal]) {
        let trend = trend.sorted { $0.date < $1.date }
        let amounts = trend.flatMap { [$0.income.double, $0.expense.double] }
        lower = min(0, amounts.min() ?? 0)
        upper = max(1, (amounts.max() ?? 0) * 1.1)
        baseline = (0 - lower) / (upper - lower)
        start = trend.first?.date ?? .distantPast
        duration = max(1, (trend.last?.date ?? start).timeIntervalSince(start))
        let start = start, duration = duration, lower = lower, span = upper - lower
        let positions = trend.map { $0.date.timeIntervalSince(start) / duration }
        income = Self.sample(x: positions, y: trend.map { ($0.income.double - lower) / span })
        expense = Self.sample(x: positions, y: trend.map { ($0.expense.double - lower) / span })
    }

    func position(_ date: Date) -> Double { date.timeIntervalSince(start) / duration }

    /// Monotone cubic Hermite interpolation retains the real bucket values
    /// without introducing peaks or negative spending between neighboring points.
    static func sample(x: [Double], y: [Double]) -> TrendCurveVector {
        guard !y.isEmpty else { return .zero }
        guard y.count > 1 else { return TrendCurveVector(Array(repeating: y[0], count: TrendCurveVector.count)) }
        let widths = zip(x, x.dropFirst()).map { max($1 - $0, Double.ulpOfOne) }
        let slopes = y.indices.dropLast().map { (y[$0 + 1] - y[$0]) / widths[$0] }
        var tangents = Array(repeating: 0.0, count: y.count)
        tangents[0] = slopes[0]; tangents[y.count - 1] = slopes[slopes.count - 1]
        for index in y.indices.dropFirst().dropLast() where slopes[index - 1] * slopes[index] > 0 {
            let firstWeight = 2 * widths[index] + widths[index - 1]
            let secondWeight = widths[index] + 2 * widths[index - 1]
            tangents[index] = (firstWeight + secondWeight) / (firstWeight / slopes[index - 1] + secondWeight / slopes[index])
        }
        for index in slopes.indices {
            if slopes[index] == 0 { tangents[index] = 0; tangents[index + 1] = 0; continue }
            let a = tangents[index] / slopes[index], b = tangents[index + 1] / slopes[index]
            let length = hypot(a, b)
            if length > 3 {
                tangents[index] = 3 * a * slopes[index] / length
                tangents[index + 1] = 3 * b * slopes[index] / length
            }
        }
        var segment = 0
        let samples = (0..<TrendCurveVector.count).map { index -> Double in
            let position = Double(index) / Double(TrendCurveVector.count - 1)
            while segment < y.count - 2 && position > x[segment + 1] { segment += 1 }
            let t = max(0, min(1, (position - x[segment]) / widths[segment]))
            let t2 = t * t, t3 = t2 * t
            let value = (2 * t3 - 3 * t2 + 1) * y[segment]
                + (t3 - 2 * t2 + t) * widths[segment] * tangents[segment]
                + (-2 * t3 + 3 * t2) * y[segment + 1]
                + (t3 - t2) * widths[segment] * tangents[segment + 1]
            return min(max(y[segment], y[segment + 1]), max(min(y[segment], y[segment + 1]), value))
        }
        return TrendCurveVector(samples)
    }
}

struct TrendCurveShape: Shape {
    var samples: TrendCurveVector
    var baseline: Double
    var filled = false
    var animatableData: AnimatablePair<TrendCurveVector, Double> {
        get { AnimatablePair(samples, baseline) }
        set { samples = newValue.first; baseline = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let points = samples.values.enumerated().map { index, value in
            CGPoint(x: rect.minX + rect.width * Double(index) / Double(TrendCurveVector.count - 1),
                    y: rect.maxY - rect.height * value)
        }
        var path = Path()
        path.addLines(points)
        if filled {
            let y = rect.maxY - rect.height * baseline
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            path.addLine(to: CGPoint(x: rect.minX, y: y)); path.closeSubpath()
        }
        return path
    }
}

struct TrendLinePlot: View {
    let geometry: TrendCurveGeometry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            TrendCurveShape(samples: geometry.income, baseline: geometry.baseline, filled: true)
                .fill(LinearGradient(colors: [.moraGreen.opacity(0.18), .moraGreen.opacity(0.01)], startPoint: .top, endPoint: .bottom))
            TrendCurveShape(samples: geometry.income, baseline: geometry.baseline)
                .stroke(Color.moraGreen, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            TrendCurveShape(samples: geometry.expense, baseline: geometry.baseline)
                .stroke(Color.token("orange"), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .animation(reduceMotion ? nil : AppMotion.curve, value: geometry)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
