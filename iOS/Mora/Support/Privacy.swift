import SwiftUI
import FinanceCore

/// Replaces financial digits before rendering, including the accessibility text.
struct FinancialText: View {
    @AppStorage("mora.hideAmounts") private var hidden = false
    let value: String
    init(_ value: String) { self.value = value }
    var body: some View {
        let translated = L(value)
        Text(hidden ? FinancialPrivacy.mask(translated) : translated)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.easeInOut(duration: 0.2), value: hidden)
    }
}

private struct FinancialFieldPrivacy: ViewModifier {
    @AppStorage("mora.hideAmounts") private var hidden = false
    func body(content: Content) -> some View {
        content.opacity(hidden ? 0 : 1).disabled(hidden).accessibilityHidden(hidden)
            .overlay(alignment: .leading) { if hidden { Text("•••").foregroundStyle(.secondary).allowsHitTesting(false) } }
    }
}

extension View {
    func financialField() -> some View { modifier(FinancialFieldPrivacy()) }
}

/// The app switcher snapshot never shows balances.
struct PrivacyShield: ViewModifier {
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View {
        content.overlay {
            if phase != .active {
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    Image(systemName: "leaf.fill").font(.system(size: 44)).foregroundStyle(Color.moraGreen)
                }.ignoresSafeArea().transition(.opacity)
            }
        }
    }
}
