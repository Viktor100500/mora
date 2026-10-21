import Foundation

public struct LedgerChangeHistory: Codable, Equatable, Sendable {
    public var undo: [Ledger] = []
    public var redo: [Ledger] = []
    public init() {}
}

public extension Ledger {
    var undoCount: Int { changeHistory?.undo.count ?? 0 }
    var redoCount: Int { changeHistory?.redo.count ?? 0 }

    func withoutChangeHistory() -> Ledger {
        var snapshot = self
        snapshot.changeHistory = nil
        return snapshot
    }

    mutating func recordChange(from previous: Ledger) {
        var history = previous.changeHistory ?? LedgerChangeHistory()
        history.undo.append(previous.withoutChangeHistory())
        history.undo = Array(history.undo.suffix(20))
        history.redo = []
        changeHistory = history
        schemaVersion = max(schemaVersion, 4)
    }

    mutating func undoLastChange() throws { try moveHistory(undoing: true) }
    mutating func redoLastChange() throws { try moveHistory(undoing: false) }

    private mutating func moveHistory(undoing: Bool) throws {
        var history = changeHistory ?? LedgerChangeHistory()
        let target = undoing ? history.undo.popLast() : history.redo.popLast()
        guard var target else { throw LedgerError.invalid(undoing ? "Нет изменений для отмены." : "Нет изменений для возврата.") }
        let current = withoutChangeHistory()
        if undoing { history.redo.append(current) } else { history.undo.append(current) }
        history.undo = Array(history.undo.suffix(20))
        history.redo = Array(history.redo.suffix(20))
        // Automatic rate downloads are not user edits and must survive undo/redo.
        if let snapshot = preferences.exchangeRateSnapshot {
            target.preferences.exchangeRateSnapshot = snapshot
            if target.preferences.automaticRates {
                target.preferences.rates = try snapshot.rates(in: target.preferences.baseCurrency)
            }
        }
        target.changeHistory = history
        target.schemaVersion = max(schemaVersion, target.schemaVersion, 4)
        try target.validate()
        self = target
    }
}
