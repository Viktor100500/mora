import Foundation
import FinanceCore

/// Calendar buckets across the navigable range, computed once per report generation.
/// Scrolling and hovering only read this snapshot; neither scans the ledger.
struct CashFlowTimeline: Sendable {
    let month: Date
    let detail: TrendDetail
    let domain: ClosedRange<Date>
    let initialStart: Date
    let visibleDuration: TimeInterval
    let buckets: [MonthTotal]

    init(month: Date, detail: TrendDetail, buckets: [MonthTotal] = [], calendar: Calendar = .current) {
        let month = calendar.dateInterval(of: .month, for: month)!.start
        self.month = month; self.detail = detail; self.buckets = buckets
        let radius = detail == .months ? 120 : 12
        let start = calendar.date(byAdding: .month, value: -radius, to: month)!
        let end = calendar.date(byAdding: .month, value: radius + 1, to: month)!
        domain = start...end
        initialStart = calendar.date(byAdding: .month, value: detail == .months ? -5 : 0, to: month)!
        visibleDuration = calendar.date(byAdding: .month, value: 1, to: month)!.timeIntervalSince(initialStart)
    }

    init(ledger: Ledger, month: Date, detail: TrendDetail, calendar: Calendar = .current) {
        let range = Self(month: month, detail: detail, calendar: calendar)
        var calendar = calendar
        calendar.firstWeekday = 2
        func bucket(_ date: Date) -> Date {
            switch detail {
            case .months: return calendar.dateInterval(of: .month, for: date)!.start
            case .weeks:
                // Match the existing report: a week crossing a month boundary is split.
                return max(calendar.dateInterval(of: .month, for: date)!.start,
                           calendar.dateInterval(of: .weekOfYear, for: date)!.start)
            case .days, .selectedDates: return calendar.startOfDay(for: date)
            }
        }
        var totals: [Date: Summary] = [:]
        for row in ledger.transactions where row.date >= range.domain.lowerBound && row.date < range.domain.upperBound && row.kind != .transfer {
            guard let amount = ledger.value(row) else { continue }
            let key = bucket(row.date)
            if row.kind == .income { totals[key, default: Summary()].income += amount }
            else { totals[key, default: Summary()].expense -= amount }
        }
        var buckets: [MonthTotal] = []
        var date = range.domain.lowerBound
        while date < range.domain.upperBound {
            let total = totals[date] ?? Summary()
            buckets.append(MonthTotal(date: date, income: total.income, expense: total.expense))
            switch detail {
            case .months: date = calendar.date(byAdding: .month, value: 1, to: date)!
            case .weeks:
                date = min(calendar.dateInterval(of: .weekOfYear, for: date)!.end,
                           calendar.dateInterval(of: .month, for: date)!.end)
            case .days, .selectedDates: date = calendar.date(byAdding: .day, value: 1, to: date)!
            }
        }
        self.init(month: month, detail: detail, buckets: buckets, calendar: calendar)
    }

    func visibleBuckets(from start: Date) -> [MonthTotal] {
        let end = start.addingTimeInterval(visibleDuration)
        return buckets.filter { $0.date >= start && $0.date < end }
    }

    func plotBuckets(from start: Date) -> [MonthTotal] {
        let first = buckets.firstIndex { $0.date >= start } ?? buckets.endIndex
        let end = buckets.firstIndex { $0.date >= start.addingTimeInterval(visibleDuration) } ?? buckets.endIndex
        // Two neighboring buckets preserve the monotone curve at either edge
        // while keeping twenty years of offscreen marks out of each redraw.
        return Array(buckets[max(0, first - 2)..<min(buckets.endIndex, end + 2)])
    }

    func nearest(to date: Date, from start: Date) -> MonthTotal? {
        visibleBuckets(from: start).min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    func scrolledStart(from start: Date, horizontalDelta: Double, width: Double) -> Date {
        guard width > 0, horizontalDelta.isFinite else { return start }
        let date = start.addingTimeInterval(-horizontalDelta / width * visibleDuration)
        return min(domain.upperBound.addingTimeInterval(-visibleDuration), max(domain.lowerBound, date))
    }
}
