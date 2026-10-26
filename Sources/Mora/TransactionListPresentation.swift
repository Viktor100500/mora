import Foundation
import FinanceCore

/// Rows, totals and selection publish as one value. During duplication the
/// originals stay selected until the filtered result actually contains the copies.
struct TransactionListPresentation {
    var rows: [Transaction] = []
    var visibleIDs: Set<UUID> = []
    var selection: Set<UUID> = []
    var income: Decimal = 0
    var expense: Decimal = 0
    var hasLoadedRows = false
    private(set) var duplicating = false
    private var pendingCopies: Set<UUID>?

    mutating func beginDuplication() -> Bool {
        guard !duplicating else { return false }
        duplicating = true
        return true
    }

    mutating func completedDuplication(_ ids: Set<UUID>?) {
        guard let ids, !ids.isEmpty else { duplicating = false; return }
        pendingCopies = ids
    }

    mutating func failedRefresh() { pendingCopies = nil; duplicating = false }

    mutating func apply(_ result: TransactionSearch.Result) {
        rows = result.rows; visibleIDs = result.ids
        income = result.income; expense = result.expense
        selection = (pendingCopies ?? selection).intersection(result.ids)
        if pendingCopies != nil { pendingCopies = nil; duplicating = false }
        hasLoadedRows = true
    }
}
