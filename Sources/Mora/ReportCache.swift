import Foundation
import FinanceCore

/// Survives page changes and is invalidated whenever the ledger changes.
@MainActor final class ReportCache {
    var summaries: [Date: Summary] = [:]
    var categories: [Date: [CategoryTotal]] = [:]
    var trends: [String: [MonthTotal]] = [:]
    var insights: [Date: [String]] = [:]
    var transactions: [Date: [Transaction]] = [:]
    var netWorth: Decimal?
}

extension FinanceStore {
    func reportSummary(in month: Date) -> Summary {
        let key = Dates.month(month)
        if let result = reports.summaries[key] { return result }
        let result = ledger.summary(in: key); reports.summaries[key] = result; return result
    }
    func reportCategories(in month: Date) -> [CategoryTotal] {
        let key = Dates.month(month)
        if let result = reports.categories[key] { return result }
        let result = ledger.categoryTotals(in: key); reports.categories[key] = result; return result
    }
    func reportTransactions(in month: Date) -> [Transaction] {
        let key = Dates.month(month)
        if let result = reports.transactions[key] { return result }
        let result = ledger.transactions(in: key); reports.transactions[key] = result; return result
    }
    func reportTrend(ending month: Date, count: Int = 6) -> [MonthTotal] {
        let key = "\(Dates.month(month).timeIntervalSince1970)-\(count)"
        if let result = reports.trends[key] { return result }
        let result = ledger.trend(ending: month, count: count)
        reports.trends[key] = result; return result
    }
    func reportInsights(in month: Date) -> [String] {
        let key = Dates.month(month)
        if let result = reports.insights[key] { return result }
        let result = ledger.insights(in: key); reports.insights[key] = result; return result
    }
    var reportNetWorth: Decimal {
        if let result = reports.netWorth { return result }
        let result = ledger.netWorth; reports.netWorth = result; return result
    }
}
