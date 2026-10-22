import SwiftUI
import Charts
import FinanceCore

enum CategoryRingHitTest {
    static func tooltipCenter(in frame: CGRect, width: CGFloat) -> CGPoint {
        let radius = min(frame.width, frame.height) / 2
        return CGPoint(x: frame.midX - radius - 12 - width / 2, y: frame.midY)
    }

    static func index(at point: CGPoint, in frame: CGRect, amounts: [Double]) -> Int? {
        let dx = point.x - frame.midX, dy = point.y - frame.midY
        let radius = min(frame.width, frame.height) / 2
        let distance = hypot(dx, dy)
        guard radius > 0, distance >= radius * 0.76, distance <= radius else { return nil }
        let total = amounts.reduce(0, +)
        guard total > 0 else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        var start = 0.0
        for (index, amount) in amounts.enumerated() {
            let end = start + amount / total * 2 * .pi
            if angle >= start && angle < end { return index }
            start = end
        }
        return nil
    }
}

private struct CategoryRingHover {
    var bounds: Anchor<CGRect>
    var total: CategoryTotal
    var expense: Decimal
    var currency: String
}

private struct CategoryRingHoverKey: PreferenceKey {
    static var defaultValue: CategoryRingHover? { nil }
    static func reduce(value: inout CategoryRingHover?, nextValue: () -> CategoryRingHover?) {
        if let next = nextValue() { value = next }
    }
}

/// The overlay belongs to the screen, so the card cannot clip the tooltip.
/// It sits beside the circle, clear of every sector and the pointer.
struct CategoryRingTooltipLayer: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(CategoryRingHoverKey.self) { hover in
            GeometryReader { geometry in
                if let hover {
                    HStack(spacing: 10) {
                        IconTile(icon: hover.total.icon, color: hover.total.color, size: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hover.total.name).font(.system(size: 12, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                            FinancialText(DisplayMoney.string(hover.total.amount, currency: hover.currency) + " · \(Int((hover.expense > 0 ? hover.total.amount / hover.expense : 0).double * 100))%")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12).frame(width: 210, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
                    .position(CategoryRingHitTest.tooltipCenter(in: geometry[hover.bounds], width: 210))
                }
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

struct CategoryRingChart: View {
    var totals: [CategoryTotal]
    var expense: Decimal
    var currency: String
    @State private var hoveredIndex: Int?

    var body: some View {
        Chart(totals) { total in
            SectorMark(angle: .value(L("Сумма"), total.amount.double), innerRadius: .ratio(0.76), angularInset: 2)
                .cornerRadius(4).foregroundStyle(Color.token(total.color))
                .accessibilityLabel(total.name)
                .accessibilityValue(DisplayMoney.string(total.amount, currency: currency))
        }
        .chartLegend(.hidden)
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    VStack(spacing: 5) {
                        Text(L("Всего")).font(.caption).foregroundStyle(.secondary)
                        FinancialText(DisplayMoney.string(expense, currency: currency))
                            .font(.system(size: 17, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                    }.frame(width: frame.width * 0.7).position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoveredIndex = proxy.plotFrame.flatMap {
                                CategoryRingHitTest.index(at: location, in: geometry[$0], amounts: totals.map { $0.amount.double })
                            }
                        case .ended: hoveredIndex = nil
                        }
                    }
            }
        }
        .anchorPreference(key: CategoryRingHoverKey.self, value: .bounds) { bounds in
            hoveredIndex.flatMap { index in
                totals.indices.contains(index) ? CategoryRingHover(bounds: bounds, total: totals[index], expense: expense, currency: currency) : nil
            }
        }
        .accessibilityLabel(L("Распределение расходов по категориям")).financialChart()
    }
}
