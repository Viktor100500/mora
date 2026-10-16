import SwiftUI
import FinanceCore

/// Replaces financial digits before rendering, including the accessibility text.
/// Only the short crossfade is animated; there is no continuously running effect.
struct FinancialText: View {
    @AppStorage("mora.hideAmounts") private var hidden = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: String
    init(_ value: String) { self.value = value }
    var body: some View {
        let translated = L(value)
        Text(hidden ? FinancialPrivacy.mask(translated) : translated)
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: hidden)
    }
}

private struct FinancialFieldPrivacy: ViewModifier {
    @AppStorage("mora.hideAmounts") private var hidden = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.disabled(hidden).opacity(hidden ? 0 : 1).accessibilityHidden(hidden)
            .overlay(alignment: .leading) { if hidden { Text("•••").foregroundStyle(.secondary).padding(.horizontal, 8).allowsHitTesting(false) } }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: hidden)
    }
}

private struct FinancialChartPrivacy: ViewModifier {
    @AppStorage("mora.hideAmounts") private var hidden = false
    func body(content: Content) -> some View { content.accessibilityHidden(hidden) }
}

extension View {
    func financialField() -> some View { modifier(FinancialFieldPrivacy()) }
    func financialChart() -> some View { modifier(FinancialChartPrivacy()) }
}
