import AppKit
import SwiftUI

/// A plot-sized input surface keeps trackpad momentum and hover working together
/// on macOS. Swift Charts owns the axes, marks and scroll-position rendering.
struct CashFlowInteractionLayer: NSViewRepresentable {
    var onHover: (CGPoint?) -> Void
    var onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.onHover = onHover; view.onScroll = onScroll
    }

    final class InputView: NSView {
        var onHover: (CGPoint?) -> Void = { _ in }
        var onScroll: (CGFloat) -> Void = { _ in }
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
        override func mouseDown(with event: NSEvent) { mouseMoved(with: event) }
        override func mouseMoved(with event: NSEvent) { onHover(convert(event.locationInWindow, from: nil)) }
        override func mouseExited(with event: NSEvent) { onHover(nil) }

        override func scrollWheel(with event: NSEvent) {
            let horizontal = event.scrollingDeltaX
            if horizontal != 0 {
                onScroll(horizontal * (event.hasPreciseScrollingDeltas ? 1 : 10))
            } else if event.modifierFlags.contains(.shift), event.scrollingDeltaY != 0 {
                onScroll(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10))
            }
            // Consume all wheel events over the plot, including vertical jitter
            // and momentum. Outside this view, Overview scrolls normally.
        }
    }
}
