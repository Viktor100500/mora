import Foundation

public struct TransactionSearch: Equatable, Sendable {
    public var startDate: Date
    public var endDate: Date
    /// nil means all, while an empty set deliberately matches nothing.
    public var accountIDs: Set<UUID>?
    public var kinds: Set<TransactionKind>?
    public var categoryIDs: Set<UUID>?
    public var includesUncategorized: Bool
    public var text: String

    public init(startDate: Date = Dates.month(Date()), endDate: Date? = nil,
                accountIDs: Set<UUID>? = nil, kinds: Set<TransactionKind>? = nil,
                categoryIDs: Set<UUID>? = nil, includesUncategorized: Bool = false, text: String = "") {
        self.startDate = startDate
        self.endDate = endDate ?? Calendar.current.date(byAdding: .day, value: -1,
            to: Calendar.current.date(byAdding: .month, value: 1, to: Dates.month(startDate))!)!
        self.accountIDs = accountIDs; self.kinds = kinds; self.categoryIDs = categoryIDs
        self.includesUncategorized = includesUncategorized; self.text = text
    }

    public init(startDate: Date, endDate: Date, accountID: UUID?, kind: String, category: String, text: String) {
        self.init(startDate: startDate, endDate: endDate, accountIDs: accountID.map { [$0] },
                  kinds: kind == "all" ? nil : Set(TransactionKind(rawValue: kind).map { [$0] } ?? []),
                  categoryIDs: category == "all" ? nil : Set(UUID(uuidString: category).map { [$0] } ?? []),
                  includesUncategorized: category == "none", text: text)
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
        var matches: [(offset: Int, transaction: Transaction)] = []
        var income: Decimal = 0, expense: Decimal = 0
        for (index, transaction) in ledger.transactions.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard transaction.date >= start && transaction.date < end else { continue }
            let matchesAccount = accountIDs.map { ids in
                ids.contains(transaction.accountID) || transaction.destinationAccountID.map(ids.contains) == true
            } ?? true
            let matchesCategory = categoryIDs.map { ids in
                transaction.categoryID.map(ids.contains) == true || (includesUncategorized && transaction.categoryID == nil && transaction.kind != .transfer)
            } ?? true
            guard matchesAccount, kinds?.contains(transaction.kind) ?? true, matchesCategory,
                  text.isEmpty || (transaction.merchant + " " + transaction.note + " " + transaction.tags.joined(separator: " ")).localizedCaseInsensitiveContains(text) else { continue }
            matches.append((index, transaction))
            if ledger.isActive(transaction), let value = ledger.value(transaction) {
                if transaction.kind == .income { income += value }
                else if transaction.kind == .expense { expense -= value }
            }
        }
        matches.sort {
            if $0.transaction.date != $1.transaction.date { return $0.transaction.date > $1.transaction.date }
            if $0.transaction.merchant != $1.transaction.merchant { return $0.transaction.merchant < $1.transaction.merchant }
            // Preserve insertion order for identical rows; random new UUIDs must
            // not insert copies above an existing row and displace the viewport.
            return $0.offset < $1.offset
        }
        try Task.checkCancellation()
        let rows = matches.map(\.transaction)
        return Result(rows: rows, ids: Set(rows.map(\.id)), income: income, expense: expense)
    }
}
