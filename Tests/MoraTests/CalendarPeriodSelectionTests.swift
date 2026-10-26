import AppKit
import SwiftUI
import XCTest
import FinanceCore
@testable import Mora

final class CalendarPeriodSelectionTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        value.firstWeekday = 2
        return value
    }
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testRangeSelectionWorksBackwardsAcrossYearAndHoverDoesNotCommit() {
        var selection = CalendarPeriodSelection(start: date(2026, 12, 1), end: date(2026, 12, 31), calendar: calendar)
        selection.select(date(2027, 1, 3))
        XCTAssertEqual(selection.start, date(2027, 1, 3))
        XCTAssertEqual(selection.end, date(2027, 1, 3))
        XCTAssertEqual(selection.preview(hovering: date(2026, 12, 29)), date(2026, 12, 29)...date(2027, 1, 3))
        XCTAssertEqual(selection.end, date(2027, 1, 3))
        selection.select(date(2026, 12, 29))
        XCTAssertEqual(selection.start, date(2026, 12, 29))
        XCTAssertEqual(selection.end, date(2027, 1, 3))
        XCTAssertNil(selection.anchor)
        selection.select(date(2026, 10, 25)); selection.select(date(2026, 10, 25))
        XCTAssertEqual(selection.start, selection.end)
        XCTAssertNil(selection.anchor)
    }

    func testCalendarGridIncludesLeapDayAndUsesCalendarDaysAcrossDST() {
        let leap = CalendarPeriodSelection.days(in: date(2028, 2, 1), calendar: calendar)
        XCTAssertEqual(leap.count, 42)
        XCTAssertEqual(calendar.component(.weekday, from: leap[0]), 2)
        XCTAssertTrue(leap.contains(date(2028, 2, 29)))
        let fall = CalendarPeriodSelection.days(in: date(2026, 11, 1), calendar: calendar)
        XCTAssertEqual(Set(fall).count, 42)
        XCTAssertEqual(fall.filter { calendar.component(.hour, from: $0) != 0 }.count, 0)
        for index in 1..<fall.count {
            XCTAssertEqual(calendar.dateComponents([.day], from: fall[index - 1], to: fall[index]).day, 1)
        }
    }

    @MainActor func testCalendarLayoutFitsCompactPopover() throws {
        _ = NSApplication.shared
        let panel = TransactionPeriodCalendar(start: date(2026, 10, 12), end: date(2026, 10, 24), cancel: {}) { _, _ in }
        let host = NSHostingView(rootView: panel.background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light).tint(.moraGreen))
        let size = host.fittingSize
        XCTAssertEqual(size.width, 342, accuracy: 1)
        XCTAssertLessThan(size.height, 580)
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded()
        if let path = ProcessInfo.processInfo.environment["MORA_CALENDAR_SNAPSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
