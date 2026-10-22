import Foundation

public struct TransactionSearch: Equatable, Sendable {
    public var startDate: Date
    public var endDate: Date
    public var accountID: UUID?
    public var kind: String
    public var category: String
    public var text: String
    public init(startDate: Date, endDate: Date, accountID: UUID?, kind: String, category: String, text: String) {
        self.startDate = startDate; self.endDate = endDate; self.accountID = accountID
        self.kind = kind; self.category = category; self.text = text
    }
    public struct Result: Sendable {
        public let rows: [Transaction]
        public let ids: Set<UUID>
        public let income: Decimal
        public let expense: Decimal
    }
    public func prepare(in ledger: Ledger) throws -> Result {
        try Task.checkCancellation()
        let start = Calendar.current.startOfDay(for: startDate)
        let lastDay = Calendar.current.startOfDay(for: endDate)
        guard start <= lastDay else { throw LedgerError.invalid("Дата начала не может быть позже даты окончания.") }
        let end = Calendar.current.date(byAdding: .day, value: 1, to: lastDay)!
        var rows: [Transaction] = [], income: Decimal = 0, expense: Decimal = 0
        for (index, transaction) in ledger.transactions.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard transaction.date >= start && transaction.date < end,
                  accountID == nil || transaction.accountID == accountID || transaction.destinationAccountID == accountID,
                  kind == "all" || transaction.kind.rawValue == kind,
                  category == "all" || (category == "none" ? transaction.categoryID == nil && transaction.kind != .transfer : transaction.categoryID?.uuidString == category),
                  text.isEmpty || (transaction.merchant + " " + transaction.note + " " + transaction.tags.joined(separator: " ")).localizedCaseInsensitiveContains(text) else { continue }
            rows.append(transaction)
            if ledger.isActive(transaction), let value = ledger.value(transaction) {
                if transaction.kind == .income { income += value }
                else if transaction.kind == .expense { expense -= value }
            }
        }
        rows.sort {
            if $0.date != $1.date { return $0.date > $1.date }
            if $0.merchant != $1.merchant { return $0.merchant < $1.merchant }
            return $0.id.uuidString < $1.id.uuidString
        }
        try Task.checkCancellation()
        return Result(rows: rows, ids: Set(rows.map(\.id)), income: income, expense: expense)
    }
}
