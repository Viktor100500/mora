import SwiftUI
import AppKit
import FinanceCore

/// Width limits for the main window's sidebar and the font size of the
/// net worth amount in its card.
///
/// The amount is sized explicitly from its measured width instead of relying
/// on `minimumScaleFactor`, and the sidebar never becomes narrower than the
/// width at which the amount still fits at the smallest allowed size, so it is
/// never cut off with an ellipsis.
@MainActor enum SidebarLayout {
    static let preferredMinimumWidth: CGFloat = 236
    static let idealWidth: CGFloat = 248
    static let preferredMaximumWidth: CGFloat = 300

    static let netWorthFontSize: CGFloat = 22
    static let netWorthMinimumScale: CGFloat = 0.6
    /// Outer card padding (16 on each side) plus inner card padding (16 on each side).
    static let netWorthHorizontalInset: CGFloat = 64
    /// Navigation row: outer padding 12×2, inner padding 13×2, icon 20, spacing 12.
    static let navigationRowInset: CGFloat = 82
    static let navigationFontSize: CGFloat = 13
    /// Room for font rounding so that measured text is never laid out a hair too wide.
    static let slack: CGFloat = 6

    struct Limits: Equatable {
        var minimum: CGFloat
        var ideal: CGFloat
        var maximum: CGFloat
    }

    static func limits(netWorth: String, navigationTitles: [String]) -> Limits {
        let longestTitle = navigationTitles.map { textWidth($0, font: navigationFont) }.max() ?? 0
        let menuMinimum = ceil(longestTitle + navigationRowInset + slack)
        let amountMinimum = ceil(amountWidth(netWorth) * netWorthMinimumScale + netWorthHorizontalInset + slack)
        let minimum = max(preferredMinimumWidth, menuMinimum, amountMinimum)
        let maximum = max(preferredMaximumWidth, minimum)
        return Limits(minimum: minimum, ideal: min(max(idealWidth, minimum), maximum), maximum: maximum)
    }

    /// Font size that lets the amount fit into a card inside a sidebar of `sidebarWidth`.
    static func netWorthFontSize(for value: String, sidebarWidth: CGFloat) -> CGFloat {
        let natural = amountWidth(value)
        guard natural > 0 else { return netWorthFontSize }
        let available = max(sidebarWidth - netWorthHorizontalInset - slack, 1)
        let scale = min(1, max(netWorthMinimumScale, available / natural))
        return (netWorthFontSize * scale * 2).rounded(.down) / 2
    }

    /// Width of the amount at the base font size, also covering its masked form
    /// so that hiding amounts never changes the layout.
    static func amountWidth(_ value: String) -> CGFloat {
        let translated = L(value)
        return max(textWidth(translated, font: netWorthFont(size: netWorthFontSize)), textWidth(FinancialPrivacy.mask(translated), font: netWorthFont(size: netWorthFontSize)))
    }

    static func netWorthFont(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        let rounded = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        let digits = rounded.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
        ]]])
        return NSFont(descriptor: digits, size: size) ?? base
    }

    private static var navigationFont: NSFont { NSFont.systemFont(ofSize: navigationFontSize, weight: .semibold) }

    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }
}

/// Enforces the sidebar width limits on the AppKit split view that backs
/// `NavigationSplitView`. `navigationSplitViewColumnWidth` only seeds the
/// column on macOS, so the divider could otherwise be dragged past it.
struct SidebarWidthLimiter: NSViewRepresentable {
    let limits: SidebarLayout.Limits

    func makeNSView(context: Context) -> LimiterView { LimiterView() }

    func updateNSView(_ view: LimiterView, context: Context) {
        view.limits = limits
        view.apply()
    }

    final class LimiterView: NSView {
        var limits = SidebarLayout.Limits(minimum: SidebarLayout.preferredMinimumWidth, ideal: SidebarLayout.idealWidth, maximum: SidebarLayout.preferredMaximumWidth)
        private var widthConstraints: [NSLayoutConstraint] = []
        private weak var constrainedView: NSView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            guard window != nil, let splitView = enclosingSplitView() else { return }
            if let controller = splitView.delegate as? NSSplitViewController, let item = controller.splitViewItems.first {
                item.minimumThickness = limits.minimum
                item.maximumThickness = limits.maximum
                item.canCollapse = false
            }
            guard let sidebar = splitView.arrangedSubviews.first else { return }
            if constrainedView !== sidebar || widthConstraints.count != 2 {
                NSLayoutConstraint.deactivate(widthConstraints)
                widthConstraints = [
                    sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: limits.minimum),
                    sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: limits.maximum)
                ]
                widthConstraints.forEach { $0.priority = .init(999) }
                NSLayoutConstraint.activate(widthConstraints)
                constrainedView = sidebar
            } else {
                widthConstraints[0].constant = limits.minimum
                widthConstraints[1].constant = limits.maximum
            }
            let width = sidebar.frame.width
            if width > 0, width < limits.minimum || width > limits.maximum {
                splitView.setPosition(min(max(width, limits.minimum), limits.maximum), ofDividerAt: 0)
            }
        }

        private func enclosingSplitView() -> NSSplitView? {
            var view: NSView? = superview
            while let current = view {
                if let split = current as? NSSplitView, split.isVertical, split.arrangedSubviews.count >= 2,
                   split.arrangedSubviews.first.map({ isDescendant(of: $0) }) == true {
                    return split
                }
                view = current.superview
            }
            return nil
        }
    }
}
