import Foundation
import FinanceCore

/// Only immutable results are published on MainActor. A replaced cache is also
/// a generation token, so an old task cannot refill a newer ledger's cache.
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
    private func prepareReports(in month: Date, count: Int = 6) {
        let cache = reports, key = Dates.month(month), trendKey = "\(key.timeIntervalSince1970)-\(count)"
        guard cache.trends[trendKey] == nil, cache.pending.insert(trendKey).inserted else { return }
        let snapshot = ledger.withoutChangeHistory()
        Task { @MainActor [weak self] in
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
            self.objectWillChange.send()
            cache.summaries[key] = result.summary; cache.categories[key] = result.categories
            cache.trends[trendKey] = result.trend; cache.insights[key] = result.insights
            cache.transactions[key] = result.transactions; cache.recent[key] = result.recent; cache.balances = result.balances
            cache.spending[key] = result.spending; cache.netWorth = result.netWorth
            cache.monthlyRecurring = result.monthlyRecurring; cache.pending.remove(trendKey)
        }
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
        if let trend = cache.trends[key] { return trend }
        if cache.pending.insert(key).inserted {
            let snapshot = ledger.withoutChangeHistory()
            Task { @MainActor [weak self] in
                let trend = await BackgroundWork.shared.perform { snapshot.trend(ending: month, detail: detail, selectedDays: selectedDays) }
                guard let self, self.reports === cache, !Task.isCancelled else { return }
                self.objectWillChange.send()
                cache.trends[key] = trend
                cache.pending.remove(key)
            }
        }
        return []
    }
    func reportInsights(in month: Date) -> [String] {
        prepareReports(in: month); return reports.insights[Dates.month(month)] ?? []
    }
    func reportAnalytics(in month: Date, detail: TrendDetail, selectedDays: Set<Int>) -> AnalyticsReport {
        let cache = reports, month = Dates.month(month)
        let daysKey = detail == .selectedDates ? selectedDays.sorted().map(String.init).joined(separator: ",") : ""
        let key = "analytics-\(month.timeIntervalSince1970)-\(detail.rawValue)-\(daysKey)"
        if let report = cache.analytics[key] { return report }
        if cache.pending.insert(key).inserted {
            let snapshot = ledger.withoutChangeHistory()
            Task { @MainActor [weak self] in
                let report = await BackgroundWork.shared.perform {
                    snapshot.analyticsReport(ending: month, detail: detail, selectedDays: selectedDays)
                }
                guard let self, self.reports === cache, !Task.isCancelled else { return }
                self.objectWillChange.send()
                cache.analytics[key] = report
                cache.pending.remove(key)
            }
        }
        return AnalyticsReport()
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
