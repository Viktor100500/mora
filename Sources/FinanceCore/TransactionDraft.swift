import Foundation

public enum TransactionDateEditing {
    /// Set the local hour and minute without changing the event's calendar day.
    /// Merely opening the picker must not discard seconds from imported events.
    public static func changingTime(of timestamp: Date, to time: Date, calendar: Calendar = .current) -> Date {
        let before = calendar.dateComponents([.hour, .minute], from: timestamp)
        let selected = calendar.dateComponents([.hour, .minute], from: time)
        guard before != selected else { return timestamp }
        return calendar.date(bySettingHour: selected.hour!, minute: selected.minute!, second: 0, of: timestamp,
            matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: .first) ?? timestamp
    }

    /// A date-only editor changes the calendar day, retaining the event's clock
    /// time. Returning the original value also preserves subsecond precision.
    public static func changingDay(of timestamp: Date, to day: Date, calendar: Calendar = .current) -> Date {
        guard !calendar.isDate(timestamp, inSameDayAs: day) else { return timestamp }
        let time = calendar.dateComponents([.hour, .minute, .second], from: timestamp)
        let fraction = timestamp.timeIntervalSince1970 - floor(timestamp.timeIntervalSince1970)
        let result = calendar.date(bySettingHour: time.hour!, minute: time.minute!, second: time.second!, of: day,
            matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: .first) ?? calendar.startOfDay(for: day)
        return result.addingTimeInterval(fraction)
    }
}

public extension Ledger {
    /// Balance after applying a draft once. Editing removes the latest stored
    /// contribution, including either leg of a transfer and calendar-day cutoff.
    /// `base` is an already computed `balance(account, through: date)`.
    func projectedBalance(_ account: Account, replacing originalID: UUID?, with draft: Transaction, through date: Date, base: Decimal? = nil) -> Decimal {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date))!
        func contribution(_ value: Transaction) -> Decimal {
            guard value.date < end else { return 0 }
            var result: Decimal = value.accountID == account.id ? value.amount : 0
            if value.kind == .transfer, value.destinationAccountID == account.id { result += value.destinationAmount ?? 0 }
            return result
        }
        let previous = originalID.flatMap { id in transactions.first { $0.id == id } }.map(contribution) ?? 0
        return (base ?? balance(account, through: date)) - previous + contribution(draft)
    }
}

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
        try apply(\.destinationAccountID); try apply(\.destinationAmount); try apply(\.conversion); try apply(\.sameCurrencyFee)
        return merged
    }

    /// A template for a new purchase, without any link to the source's import or Wallet event.
    /// Conversion is retained only to prefill the purchase currency/amount; the editor requotes the new date.
    func similarTransaction(date: Date = Date(), calendar: Calendar = .current) -> Transaction {
        var value = self
        value.id = UUID()
        value.date = date
        value.externalID = nil
        value.recurrenceID = nil
        value.importBatchID = nil
        return value
    }
}
