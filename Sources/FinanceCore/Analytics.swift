import Foundation

public struct CategoryTotal: Identifiable, Sendable {
    public var id: UUID?
    public var name: String
    public var color: String
    public var icon: String
    public var amount: Decimal
}
public struct MonthTotal: Identifiable, Sendable {
    public var id: Date { date }
    public var date: Date
    public var income: Decimal
    public var expense: Decimal
}

public struct Summary: Sendable {
    public init() {}
    public var income: Decimal = 0
    public var expense: Decimal = 0
    public var count: Int = 0
    public var net: Decimal { income - expense }
    public var savingRate: Double { income > 0 ? (net / income).double : 0 }
}

public extension Ledger {
    func transactions(in month: Date) -> [Transaction] {
        let start = Dates.month(month)
        let end = Calendar.current.date(byAdding: .month, value: 1, to: start)!
        return transactions.filter { $0.date >= start && $0.date < end }
    }
    func summary(in month: Date) -> Summary {
        var result = Summary()
        for t in reportingTransactions(in: month) where t.kind != .transfer {
            guard let amount = value(t) else { continue }
            if t.kind == .income { result.income += amount } else { result.expense -= amount }
            result.count += 1
        }
        return result
    }
    func categoryTotals(in month: Date) -> [CategoryTotal] {
        let expenses = reportingTransactions(in: month).filter { $0.kind == .expense }
        return Dictionary(grouping: expenses, by: \.categoryID).map { id, rows in
            let c = category(id)
            return CategoryTotal(id: id, name: c?.name ?? "Без категории", color: c?.color ?? "gray", icon: c?.icon ?? "questionmark", amount: rows.reduce(Decimal(0)) { $0 - (value($1) ?? 0) })
        }.filter { $0.amount > 0 }.sorted { $0.amount > $1.amount }
    }
    func trend(ending month: Date, count: Int = 6) -> [MonthTotal] {
        (0..<count).reversed().map { offset in
            let date = Calendar.current.date(byAdding: .month, value: -offset, to: Dates.month(month))!
            let sum = summary(in: date)
            return MonthTotal(date: date, income: sum.income, expense: sum.expense)
        }
    }
    func spent(category id: UUID, in month: Date) -> Decimal {
        reportingTransactions(in: month).filter { $0.kind == .expense && $0.categoryID == id }.reduce(0) { $0 - (value($1) ?? 0) }
    }
    var netWorth: Decimal { accounts.filter { !$0.archived }.reduce(0) { $0 + (convert(balance($1), currency: $1.currency) ?? 0) } }
    var monthlyRecurring: Decimal {
        recurring.filter(\.active).reduce(0) { total, p in
            guard let account = account(p.accountID), !account.archived else { return total }
            return total + (convert(p.amount, currency: account.currency) ?? 0) * p.frequency.months
        }
    }
    func insights(in month: Date) -> [String] {
        let s = summary(in: month)
        let currency = preferences.baseCurrency
        var texts: [String] = []
        if !missingCurrencies.isEmpty { texts.append("Задайте курсы \(missingCurrencies.joined(separator: ", ")). Эти счета пока не включены в итоговые суммы.") }
        if s.count == 0 { return texts + ["Добавьте операции или импортируйте CSV — здесь появится обзор ваших финансов."] }
        if s.income > 0 {
            texts.append(s.net >= 0 ? "За месяц осталось \(Money.string(s.net, currency: currency)) — \(Int(s.savingRate * 100))% дохода." : "Расходы превысили доходы на \(Money.string(-s.net, currency: currency)).")
        }
        if let top = categoryTotals(in: month).first { texts.append("Больше всего расходов: \(top.name.lowercased()) — \(Money.string(top.amount, currency: currency)).") }
        let previous = summary(in: Calendar.current.date(byAdding: .month, value: -1, to: month)!)
        if previous.expense > 0 {
            let change = ((s.expense - previous.expense) / previous.expense * 100).rounded
            let partial = Dates.month(month) == Dates.month(Date()) ? "Текущий месяц еще не завершен. " : ""
            texts.append("\(partial)Расходы \(change >= 0 ? "выше" : "ниже") прошлого месяца на \(Money.plain(abs(change)))%.")
        }
        let exceeded = budgets.filter { spent(category: $0.categoryID, in: month) > $0.limit }
        if preferences.showBudgets && !exceeded.isEmpty { texts.append("Превышен бюджет: \(exceeded.compactMap { category($0.categoryID)?.name }.joined(separator: ", ")).") }
        if preferences.showRecurring && monthlyRecurring > 0 { texts.append("Регулярные платежи: в среднем \(Money.string(monthlyRecurring, currency: currency)) в месяц.") }
        return texts
    }
}
