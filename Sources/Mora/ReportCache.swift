import Foundation
import FinanceCore

/// Keep the last rendered values while a new generation calculates. Freshness
/// is tracked separately from values; older tasks cannot publish into a newer cache.
@MainActor final class ReportCache {
    var summaries: [Date: Summary] = [:]
    var categories: [Date: [CategoryTotal]] = [:]
    var trends: [String: [MonthTotal]] = [:]
    var analytics: [String: AnalyticsReport] = [:]
    var insights: [Date: [String]] = [:]
    var transactions: [Date: [Transaction]] = [:]
    var balances: [UUID: Decimal] = [:]
    var spending: [Date: [UUID: Decimal]] = [:]
    var recent: [Date: [Transaction]] = [:]
    var netWorth: Decimal?
    var monthlyRecurring: Decimal?
    var pending: Set<String> = []
    var completed: Set<String> = []
    var tasks: [String: Task<Void, Never>] = [:]

    init(previous: ReportCache? = nil) {
        guard let previous else { return }
        summaries = previous.summaries; categories = previous.categories; trends = previous.trends
        analytics = previous.analytics; insights = previous.insights; transactions = previous.transactions
        balances = previous.balances; spending = previous.spending; recent = previous.recent
        netWorth = previous.netWorth; monthlyRecurring = previous.monthlyRecurring
    }
}

private struct PreparedReport: Sendable {
    let summary: Summary
    let categories: [CategoryTotal]
    let trend: [MonthTotal]
    let insights: [String]
    let transactions: [Transaction]
    let recent: [Transaction]
    let balances: [UUID: Decimal]
    let spending: [UUID: Decimal]
    let netWorth: Decimal
    let monthlyRecurring: Decimal
}

extension FinanceStore {
    func prepareInitialReports() async { await prepareReportsForPresentation(in: Date()) }

    func prepareReportsForPresentation(in month: Date, includingAllScopes: Bool = false) async {
        while !Task.isCancelled {
            let cache = reports
            await prepareReports(in: month)?.value
            for detail in includingAllScopes ? TrendDetail.allCases : [.months] {
                _ = reportAnalytics(in: month, detail: detail, selectedDays: [])
                if includingAllScopes { _ = reportTrend(ending: month, detail: detail) }
            }
            for task in Array(cache.tasks.values) { await task.value }
            if reports === cache { return }
        }
    }

    func prepareAnalyticsForPresentation(in month: Date, detail: TrendDetail, selectedDays: Set<Int>) async {
        while !Task.isCancelled {
            let cache = reports
            _ = reportAnalytics(in: month, detail: detail, selectedDays: selectedDays)
            for task in Array(cache.tasks.values) { await task.value }
            if reports === cache { return }
        }
    }

    func prepareTrendForPresentation(in month: Date, detail: TrendDetail) async {
        while !Task.isCancelled {
            let cache = reports
            _ = reportTrend(ending: month, detail: detail)
            for task in Array(cache.tasks.values) { await task.value }
            if reports === cache { return }
        }
    }

    @discardableResult private func prepareReports(in month: Date, count: Int = 6) -> Task<Void, Never>? {
        let cache = reports, key = Dates.month(month), trendKey = "\(key.timeIntervalSince1970)-\(count)"
        guard !cache.completed.contains(trendKey) else { return nil }
        if let task = cache.tasks[trendKey] { return task }
        cache.pending.insert(trendKey)
        let snapshot = ledger.withoutChangeHistory()
        let task = Task { @MainActor [weak self] in
            let result = await BackgroundWork.shared.perform {
                PreparedReport(summary: snapshot.summary(in: key), categories: snapshot.categoryTotals(in: key),
                    trend: snapshot.trend(ending: key, count: count), insights: snapshot.insights(in: key),
                    transactions: snapshot.transactions(in: key).sorted { $0.date > $1.date },
                    recent: Array(snapshot.transactions(in: key).filter(snapshot.isActive).sorted { $0.date > $1.date }.prefix(5)),
                    balances: Dictionary(uniqueKeysWithValues: snapshot.accounts.map { ($0.id, snapshot.balance($0)) }),
                    spending: Dictionary(uniqueKeysWithValues: snapshot.budgets.map { ($0.categoryID, snapshot.spent(category: $0.categoryID, in: key)) }),
                    netWorth: snapshot.netWorth, monthlyRecurring: snapshot.monthlyRecurring)
            }
            guard let self, self.reports === cache, !Task.isCancelled else { return }
            AppMotion.update {
                self.objectWillChange.send()
                cache.summaries[key] = result.summary; cache.categories[key] = result.categories
                cache.trends[trendKey] = result.trend; cache.insights[key] = result.insights
                cache.transactions[key] = result.transactions; cache.recent[key] = result.recent; cache.balances = result.balances
                cache.spending[key] = result.spending; cache.netWorth = result.netWorth
                cache.monthlyRecurring = result.monthlyRecurring
                cache.completed.insert(trendKey); cache.pending.remove(trendKey); cache.tasks[trendKey] = nil
            }
        }
        cache.tasks[trendKey] = task
        return task
    }

    func reportSummary(in month: Date) -> Summary {
        prepareReports(in: month); return reports.summaries[Dates.month(month)] ?? Summary()
    }
    func reportCategories(in month: Date) -> [CategoryTotal] {
        prepareReports(in: month); return reports.categories[Dates.month(month)] ?? []
    }
    func reportTransactions(in month: Date) -> [Transaction] {
        prepareReports(in: month); return reports.transactions[Dates.month(month)] ?? []
    }
    func reportRecentTransactions(in month: Date) -> [Transaction] {
        prepareReports(in: month); return reports.recent[Dates.month(month)] ?? []
    }
    func reportTrend(ending month: Date, count: Int = 6, detail: TrendDetail = .months, selectedDays: Set<Int> = []) -> [MonthTotal] {
        if detail == .months {
            prepareReports(in: month, count: count)
            return reports.trends["\(Dates.month(month).timeIntervalSince1970)-\(count)"] ?? []
        }
        let cache = reports, month = Dates.month(month)
        let selectedKey = detail == .selectedDates ? selectedDays.sorted().map(String.init).joined(separator: ",") : ""
        let key = "\(month.timeIntervalSince1970)-\(detail.rawValue)-\(selectedKey)"
        if cache.completed.contains(key), let trend = cache.trends[key] { return trend }
        if cache.pending.insert(key).inserted {
            let snapshot = ledger.withoutChangeHistory()
            let task = Task { @MainActor [weak self] in
                let trend = await BackgroundWork.shared.perform { snapshot.trend(ending: month, detail: detail, selectedDays: selectedDays) }
                guard let self, self.reports === cache, !Task.isCancelled else { return }
                AppMotion.update {
                    self.objectWillChange.send()
                    cache.trends[key] = trend
                    cache.completed.insert(key); cache.pending.remove(key); cache.tasks[key] = nil
                }
            }
            cache.tasks[key] = task
        }
        return cache.trends[key] ?? []
    }
    func reportInsights(in month: Date) -> [String] {
        prepareReports(in: month); return reports.insights[Dates.month(month)] ?? []
    }
    func reportAnalytics(in month: Date, detail: TrendDetail, selectedDays: Set<Int>) -> AnalyticsReport {
        let cache = reports, month = Dates.month(month)
        let daysKey = detail == .selectedDates ? selectedDays.sorted().map(String.init).joined(separator: ",") : ""
        let key = "analytics-\(month.timeIntervalSince1970)-\(detail.rawValue)-\(daysKey)"
        if cache.completed.contains(key), let report = cache.analytics[key] { return report }
        if cache.pending.insert(key).inserted {
            let snapshot = ledger.withoutChangeHistory()
            let task = Task { @MainActor [weak self] in
                let report = await BackgroundWork.shared.perform {
                    snapshot.analyticsReport(ending: month, detail: detail, selectedDays: selectedDays)
                }
                guard let self, self.reports === cache, !Task.isCancelled else { return }
                AppMotion.update {
                    self.objectWillChange.send()
                    cache.analytics[key] = report
                    cache.completed.insert(key); cache.pending.remove(key); cache.tasks[key] = nil
                }
            }
            cache.tasks[key] = task
        }
        return cache.analytics[key] ?? AnalyticsReport()
    }
    func reportBalance(_ account: Account) -> Decimal {
        prepareReports(in: Date()); return reports.balances[account.id] ?? account.openingBalance
    }
    func reportSpending(category: UUID, in month: Date) -> Decimal {
        prepareReports(in: month); return reports.spending[Dates.month(month)]?[category] ?? 0
    }
    var reportNetWorth: Decimal { prepareReports(in: Date()); return reports.netWorth ?? 0 }
    var reportMonthlyRecurring: Decimal { prepareReports(in: Date()); return reports.monthlyRecurring ?? 0 }
}
