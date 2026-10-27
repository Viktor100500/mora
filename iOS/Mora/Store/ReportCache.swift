import Foundation
import FinanceCore

/// Report values for the current ledger revision. Every screen asks the store,
/// and each value is computed once per ledger change instead of on every body pass.
@MainActor final class ReportCache {
    fileprivate var summaries: [Date: Summary] = [:]
    fileprivate var categories: [Date: [CategoryTotal]] = [:]
    fileprivate var trends: [String: [MonthTotal]] = [:]
    fileprivate var analytics: [String: AnalyticsReport] = [:]
    fileprivate var insights: [Date: [String]] = [:]
    fileprivate var transactions: [Date: [Transaction]] = [:]
    fileprivate var balances: [UUID: Decimal]?
    fileprivate var spending: [Date: [UUID: Decimal]] = [:]
    fileprivate var netWorth: Decimal?
    fileprivate var monthlyRecurring: Decimal?
    fileprivate var language: AppLanguage?

    func reset() {
        summaries = [:]; categories = [:]; trends = [:]; analytics = [:]; insights = [:]
        transactions = [:]; balances = nil; spending = [:]; netWorth = nil; monthlyRecurring = nil
    }
}

extension FinanceStore {
    func summary(in month: Date) -> Summary {
        let key = Dates.month(month)
        if let value = reports.summaries[key] { return value }
        let value = ledger.summary(in: key)
        reports.summaries[key] = value
        return value
    }
    func categoryTotals(in month: Date) -> [CategoryTotal] {
        let key = Dates.month(month)
        if let value = reports.categories[key] { return value }
        let value = ledger.categoryTotals(in: key).map { total in
            var total = total
            if total.id == nil { total.name = L(total.name) }
            return total
        }
        reports.categories[key] = value
        return value
    }
    func trend(ending month: Date, count: Int = 6, detail: TrendDetail = .months, selectedDays: Set<Int> = []) -> [MonthTotal] {
        let key = "\(Dates.month(month).timeIntervalSince1970)-\(count)-\(detail.rawValue)-\(selectedDays.sorted())"
        if let value = reports.trends[key] { return value }
        let value = ledger.trend(ending: Dates.month(month), count: count, detail: detail, selectedDays: selectedDays)
        reports.trends[key] = value
        return value
    }
    func analyticsReport(in month: Date, detail: TrendDetail, selectedDays: Set<Int>) -> AnalyticsReport {
        let key = "\(Dates.month(month).timeIntervalSince1970)-\(detail.rawValue)-\(selectedDays.sorted())"
        if let value = reports.analytics[key] { return value }
        var value = ledger.analyticsReport(ending: Dates.month(month), detail: detail, selectedDays: selectedDays)
        value.categories = value.categories.map { total in
            var total = total
            if total.id == nil { total.name = L(total.name) }
            return total
        }
        reports.analytics[key] = value
        return value
    }
    func insights(in month: Date) -> [String] {
        let key = Dates.month(month)
        if reports.language != L10n.language { reports.insights = [:]; reports.language = L10n.language }
        if let value = reports.insights[key] { return value }
        let value = ledger.insights(in: key)
        reports.insights[key] = value
        return value
    }
    /// All transactions of the month, newest first.
    func transactions(in month: Date) -> [Transaction] {
        let key = Dates.month(month)
        if let value = reports.transactions[key] { return value }
        let value = ledger.transactions(in: key).sorted { $0.date > $1.date }
        reports.transactions[key] = value
        return value
    }
    func recentTransactions(in month: Date, limit: Int = 5) -> [Transaction] {
        Array(transactions(in: month).lazy.filter(ledger.isActive).prefix(limit))
    }
    func balance(_ account: Account) -> Decimal {
        if reports.balances == nil {
            reports.balances = Dictionary(uniqueKeysWithValues: ledger.accounts.map { ($0.id, ledger.balance($0)) })
        }
        return reports.balances?[account.id] ?? account.openingBalance
    }
    var netWorth: Decimal {
        if let value = reports.netWorth { return value }
        let value = ledger.accounts.filter { !$0.archived }.reduce(Decimal(0)) { $0 + (ledger.convert(balance($1), currency: $1.currency) ?? 0) }
        reports.netWorth = value
        return value
    }
    func spent(category: UUID, in month: Date) -> Decimal {
        let key = Dates.month(month)
        if reports.spending[key] == nil {
            reports.spending[key] = Dictionary(uniqueKeysWithValues: ledger.budgets.map { ($0.categoryID, ledger.spent(category: $0.categoryID, in: key)) })
        }
        return reports.spending[key]?[category] ?? ledger.spent(category: category, in: key)
    }
    var monthlyRecurring: Decimal {
        if let value = reports.monthlyRecurring { return value }
        let value = ledger.monthlyRecurring
        reports.monthlyRecurring = value
        return value
    }
    /// Expense per day of month, in the base currency, for the spending calendar.
    func dailyExpenses(in month: Date) -> [Int: Decimal] {
        var result: [Int: Decimal] = [:]
        for transaction in transactions(in: month) where transaction.kind == .expense && ledger.isActive(transaction) {
            result[Calendar.current.component(.day, from: transaction.date), default: 0] -= ledger.value(transaction) ?? 0
        }
        return result
    }
}
