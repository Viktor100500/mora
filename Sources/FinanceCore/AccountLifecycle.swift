import Foundation

public extension Ledger {
    func isActive(_ transaction: Transaction) -> Bool {
        account(transaction.accountID)?.archived == false ||
        (transaction.kind == .transfer && transaction.destinationAccountID.flatMap(account)?.archived == false)
    }

    func reportingTransactions(in month: Date) -> [Transaction] {
        transactions(in: month).filter(isActive)
    }

    mutating func setAccountArchived(_ id: UUID, archived: Bool) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw LedgerError.invalid("Счет не найден.")
        }
        accounts[index].archived = archived
    }

    mutating func deleteArchivedAccount(_ id: UUID) throws {
        guard let removed = account(id), removed.archived else {
            throw LedgerError.invalid("Перед удалением архивируйте счет.")
        }
        transactions = transactions.compactMap { transaction in
            var remaining = transaction
            if transaction.kind == .transfer && !transaction.isStandaloneTransfer {
                if transaction.accountID == id {
                    guard let destination = transaction.destinationAccountID, let amount = transaction.destinationAmount else { return nil }
                    remaining.accountID = destination
                    remaining.amount = amount
                } else if transaction.destinationAccountID != id { return transaction }
                remaining.destinationAccountID = nil
                remaining.destinationAmount = nil
                remaining.removedTransferAccountName = removed.name
                return remaining
            }
            return transaction.accountID == id ? nil : transaction
        }
        recurring.removeAll { $0.accountID == id }
        accounts.removeAll { $0.id == id }
        // Import snapshots remain as an audit trail; undo restores all originals.
        try validate()
    }
}
