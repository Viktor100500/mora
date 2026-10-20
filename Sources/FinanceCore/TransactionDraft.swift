import Foundation

public extension Transaction {
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
