import Foundation

public extension Transaction {
    /// Apply only fields changed in the editor. A simultaneous change to a
    /// different field (for example background categorization) is preserved.
    /// Conflicting changes to the same field are never silently overwritten.
    func mergingEditorChanges(from original: Transaction, into latest: Transaction) throws -> Transaction {
        guard id == original.id, id == latest.id else { throw LedgerError.invalid("Идентификатор операции изменился.") }
        var merged = latest
        func apply<Value: Equatable>(_ field: WritableKeyPath<Transaction, Value>) throws {
            let before = original[keyPath: field], edited = self[keyPath: field], current = latest[keyPath: field]
            guard edited != before else { return }
            guard current == before || current == edited else {
                throw LedgerError.invalid("Данные изменились в другом окне или через MCP. Повторите действие с обновленными данными.")
            }
            merged[keyPath: field] = edited
        }
        try apply(\.date); try apply(\.merchant); try apply(\.amount); try apply(\.accountID)
        try apply(\.categoryID); try apply(\.kind); try apply(\.note); try apply(\.tags)
        try apply(\.destinationAccountID); try apply(\.destinationAmount); try apply(\.conversion)
        return merged
    }

    /// A template for a new purchase, without any link to the source's import or Wallet event.
    /// Conversion is retained only to prefill the purchase currency/amount; the editor requotes the new date.
    func similarTransaction(date: Date = Date(), calendar: Calendar = .current) -> Transaction {
        var value = self
        value.id = UUID()
        value.date = calendar.startOfDay(for: date)
        value.externalID = nil
        value.recurrenceID = nil
        value.importBatchID = nil
        return value
    }
}
