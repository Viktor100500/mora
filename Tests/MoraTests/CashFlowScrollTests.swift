import AppKit
import XCTest
@testable import Mora

@MainActor final class CashFlowScrollTests: XCTestCase {
    private final class WheelEvent: NSEvent {
        var horizontal: CGFloat = 0
        var vertical: CGFloat = 0
        var precise = true
        var shifted = false
        override var scrollingDeltaX: CGFloat { horizontal }
        override var scrollingDeltaY: CGFloat { vertical }
        override var hasPreciseScrollingDeltas: Bool { precise }
        override var modifierFlags: NSEvent.ModifierFlags { shifted ? [.shift] : [] }
    }

    private final class ParentPage: NSResponder {
        var verticalScrolls = 0
        override func scrollWheel(with event: NSEvent) { verticalScrolls += 1 }
    }

    func testVerticalAndDiagonalJitterNeverScrollOverviewWhileOverPlot() {
        let view = CashFlowInteractionLayer.InputView(), page = ParentPage()
        view.nextResponder = page
        var deltas: [CGFloat] = []
        view.onScroll = { deltas.append($0) }
        let event = WheelEvent()
        event.vertical = 30
        view.scrollWheel(with: event)
        event.horizontal = 2
        view.scrollWheel(with: event)
        event.horizontal = -10; event.vertical = 1
        view.scrollWheel(with: event)
        XCTAssertEqual(deltas, [2, -10], "Use horizontal movement even when vertical jitter is larger")
        XCTAssertEqual(page.verticalScrolls, 0, "Vertical-only and diagonal events must both stay inside the plot")
    }

    func testShiftWheelRemainsAvailableWithoutForwardingVerticalEvents() {
        let view = CashFlowInteractionLayer.InputView(), page = ParentPage()
        view.nextResponder = page
        var deltas: [CGFloat] = []
        view.onScroll = { deltas.append($0) }
        let event = WheelEvent()
        event.vertical = -3; event.precise = false; event.shifted = true
        view.scrollWheel(with: event)
        XCTAssertEqual(deltas, [-30])
        XCTAssertEqual(page.verticalScrolls, 0)
    }
}
