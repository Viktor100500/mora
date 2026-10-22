import AppKit
import XCTest
@testable import Mora

@MainActor
final class CalendarDaySelectionTests: XCTestCase {
    func testPlainClickReplacesMultipleDays() {
        var selection = CalendarDaySelection()
        selection.select(9)
        selection.select(13, additive: true)
        selection.select(15)
        XCTAssertEqual(selection.days, [15])
        selection.select(15)
        XCTAssertTrue(selection.days.isEmpty)
        XCTAssertNil(selection.anchor)
        selection.select(20, extending: true)
        XCTAssertEqual(selection.days, [20])
    }

    func testAdditiveClicksToggleIndividualDaysAndCanClearSelection() {
        var selection = CalendarDaySelection()
        selection.select(9, additive: true)
        selection.select(13, additive: true)
        selection.select(9, additive: true)
        XCTAssertEqual(selection.days, [13])
        selection.select(13, additive: true)
        XCTAssertTrue(selection.days.isEmpty)
    }

    func testShiftIncludesBothEndpointsAndKeepsAnchorWhenShrinkingOrReversing() {
        var selection = CalendarDaySelection()
        selection.select(15)
        selection.select(18, extending: true)
        XCTAssertEqual(selection.days, Set(15...18))
        selection.select(16, extending: true)
        XCTAssertEqual(selection.days, [15, 16])
        selection.select(12, extending: true)
        XCTAssertEqual(selection.days, Set(12...15))
        XCTAssertEqual(selection.anchor, 15)
    }

    func testShiftWithoutAnchorStartsSelection() {
        var selection = CalendarDaySelection()
        selection.select(28, extending: true)
        selection.select(31, extending: true)
        XCTAssertEqual(selection.days, Set(28...31))
    }

    func testAdditiveShiftPreservesOtherDaysAndUsesLastIndividualClickAsAnchor() {
        var selection = CalendarDaySelection()
        selection.select(1)
        selection.select(10, additive: true)
        selection.select(12, extending: true, additive: true)
        XCTAssertEqual(selection.days, [1, 10, 11, 12])
        selection.select(8, extending: true)
        XCTAssertEqual(selection.days, [8, 9, 10])
    }

    func testDayListGroupsOnlyAdjacentSelectedDays() {
        var selection = CalendarDaySelection()
        XCTAssertEqual(selection.dayList, "")
        for day in [31, 15, 9, 13, 14, 20] { selection.select(day, additive: true) }
        XCTAssertEqual(selection.dayList, "9, 13–15, 20, 31")
    }

    func testNativeControlClickHandlesBothMacOSEventRoutesAndDisabledState() throws {
        _ = NSApplication.shared
        let button = CalendarDayButton()
        var received: [NSEvent.ModifierFlags] = []
        button.onSelect = { received.append($0) }
        let left = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [.control], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        let right = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [.control, .shift], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        button.mouseDown(with: left)
        button.rightMouseDown(with: right)
        XCTAssertEqual(received, [[.control], [.control, .shift]])
        button.isEnabled = false
        button.mouseDown(with: left)
        button.rightMouseDown(with: right)
        XCTAssertEqual(received.count, 2)
    }
}
