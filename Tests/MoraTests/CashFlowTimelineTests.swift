import XCTest
import FinanceCore
@testable import Mora

final class CashFlowTimelineTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "America/New_York")!
        return result
    }
    private func date(_ year: Int, _ month: Int, _ day: Int = 1) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testNavigationLimitsAndInitialWindowUseCalendarMonths() {
        let months = CashFlowTimeline(month: date(2026, 11, 8), detail: .months, calendar: calendar)
        XCTAssertEqual(months.domain.lowerBound, date(2016, 11))
        XCTAssertEqual(months.domain.upperBound, date(2036, 12))
        XCTAssertEqual(months.initialStart, date(2026, 6))
        XCTAssertEqual(months.initialStart.addingTimeInterval(months.visibleDuration), date(2026, 12))
        for detail: TrendDetail in [.days, .weeks] {
            let timeline = CashFlowTimeline(month: date(2028, 2, 15), detail: detail, calendar: calendar)
            XCTAssertEqual(timeline.domain.lowerBound, date(2027, 2))
            XCTAssertEqual(timeline.domain.upperBound, date(2029, 3))
            XCTAssertEqual(timeline.initialStart.addingTimeInterval(timeline.visibleDuration), date(2028, 3))
        }
    }

    func testEveryAggregationMatchesReportsIncludingSplitWeeksAndTransfers() {
        var ledger = Ledger.empty
        ledger.preferences.baseCurrency = "USD"; ledger.preferences.rates = ["USD": 1, "EUR": 2]
        let account = Account(name: "Synthetic", currency: "EUR", archived: true)
        ledger.accounts = [account]
        for (day, amount) in [(1, -10), (2, 50), (8, -20), (29, -30), (30, -40)] {
            ledger.transactions.append(Transaction(date: date(2026, 11, day), merchant: "Synthetic", amount: Decimal(amount),
                accountID: account.id, kind: amount > 0 ? .income : .expense))
        }
        ledger.transactions.append(Transaction(date: date(2026, 11, 2), merchant: "Transfer", amount: -999,
            accountID: account.id, kind: .transfer))
        ledger.transactions.append(Transaction(date: date(2026, 12), merchant: "Next month", amount: -123,
            accountID: account.id))
        for detail: TrendDetail in [.months, .weeks, .days] {
            let timeline = CashFlowTimeline(ledger: ledger, month: date(2026, 11), detail: detail, calendar: calendar)
            let visible = timeline.visibleBuckets(from: timeline.initialStart)
            let november = visible.filter { $0.date >= date(2026, 11) }
            XCTAssertEqual(november.reduce(Decimal(0)) { $0 + $1.income }, 100)
            XCTAssertEqual(november.reduce(Decimal(0)) { $0 + $1.expense }, 200)
            XCTAssertEqual(Set(visible.map(\.date)).count, visible.count)
            XCTAssertEqual(timeline.buckets.first?.date, timeline.domain.lowerBound)
            XCTAssertLessThan(timeline.buckets.last!.date, timeline.domain.upperBound)
        }
    }

    func testNearestSelectionUsesVisibleBucketsAndFutureBucketsAreZero() {
        let timeline = CashFlowTimeline(ledger: .empty, month: date(2026, 11), detail: .days, calendar: calendar)
        let nearEndOfDay = date(2026, 11, 8).addingTimeInterval(20 * 3600)
        XCTAssertEqual(timeline.nearest(to: nearEndOfDay, from: timeline.initialStart)?.date, date(2026, 11, 9))
        XCTAssertEqual(timeline.nearest(to: date(2030, 1), from: timeline.initialStart)?.date, date(2026, 11, 30))
        let future = timeline.visibleBuckets(from: date(2027, 11))
        XCTAssertFalse(future.isEmpty)
        XCTAssertTrue(future.allSatisfy { $0.income == 0 && $0.expense == 0 })
    }

    func testTrackpadPanningPreservesScaleAndClampsBothEnds() {
        for detail: TrendDetail in [.months, .days, .weeks] {
            let timeline = CashFlowTimeline(month: date(2026, 11), detail: detail, calendar: calendar)
            let next = timeline.scrolledStart(from: timeline.initialStart, horizontalDelta: -300, width: 600)
            XCTAssertEqual(next.timeIntervalSince(timeline.initialStart), timeline.visibleDuration / 2, accuracy: 0.001)
            XCTAssertEqual(timeline.scrolledStart(from: next, horizontalDelta: 300, width: 600), timeline.initialStart)
            XCTAssertEqual(timeline.scrolledStart(from: next, horizontalDelta: 1e9, width: 600), timeline.domain.lowerBound)
            XCTAssertEqual(timeline.scrolledStart(from: next, horizontalDelta: -1e9, width: 600), timeline.domain.upperBound.addingTimeInterval(-timeline.visibleDuration))
        }
    }
}
