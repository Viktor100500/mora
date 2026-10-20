import Foundation
import Darwin

public enum LedgerFile {
    public static func encode(_ ledger: Ledger) throws -> Data {
        var ledger = ledger
        if ledger.transactions.contains(where: { $0.conversion != nil }) || ledger.importHistory.contains(where: { $0.transactions.contains(where: { $0.conversion != nil }) }) { ledger.schemaVersion = max(ledger.schemaVersion, 3) }
        if ledger.changeHistory != nil { ledger.schemaVersion = max(ledger.schemaVersion, 4) }
        try ledger.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(ledger)
    }
    public static func decode(_ data: Data) throws -> Ledger {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let ledger = try decoder.decode(Ledger.self, from: data)
        try ledger.validate()
        return ledger
    }
    public static func equivalent(_ lhs: Ledger, _ rhs: Ledger) throws -> Bool {
        if lhs == rhs { return true }
        var lhs = lhs.withoutChangeHistory(), rhs = rhs.withoutChangeHistory()
        lhs.schemaVersion = max(lhs.schemaVersion, rhs.schemaVersion)
        rhs.schemaVersion = lhs.schemaVersion
        // JSON stores ISO dates to whole seconds; compare the persisted representation.
        return try encode(lhs) == encode(rhs)
    }
    @discardableResult
    public static func save(_ ledger: Ledger, to url: URL, expected: Ledger? = nil, recordHistory: Bool = true) throws -> Ledger {
        try withLock(at: url) {
            let previous = (try? Data(contentsOf: url)).flatMap { try? decode($0) }
            if let expected, FileManager.default.fileExists(atPath: url.path) {
                guard try equivalent(decode(Data(contentsOf: url)), expected) else {
                    throw LedgerError.invalid("Данные изменились в другом окне или через MCP. Повторите действие с обновленными данными.")
                }
            } else if expected != nil {
                throw LedgerError.invalid("Файл данных изменился. Повторите действие.")
            }
            var next = ledger
            if let previous {
                if try equivalent(previous, next) { return previous }
                if recordHistory { next.recordChange(from: previous) }
                else { next.changeHistory = previous.changeHistory; next.schemaVersion = max(next.schemaVersion, previous.schemaVersion) }
            }
            try write(next, to: url)
            return next
        }
    }
    public static func mutate(at url: URL, _ action: (inout Ledger) throws -> Void) throws -> Ledger {
        try withLock(at: url) {
            var ledger = FileManager.default.fileExists(atPath: url.path) ? try decode(Data(contentsOf: url)) : .empty
            let previous = ledger
            try action(&ledger)
            try ledger.validate()
            if ledger != previous || !FileManager.default.fileExists(atPath: url.path) {
                if FileManager.default.fileExists(atPath: url.path) { ledger.recordChange(from: previous) }
                try write(ledger, to: url)
            }
            return ledger
        }
    }
    public static func undo(at url: URL, expected: Ledger) throws -> Ledger { try moveHistory(at: url, expected: expected, undoing: true) }
    public static func redo(at url: URL, expected: Ledger) throws -> Ledger { try moveHistory(at: url, expected: expected, undoing: false) }
    /// Merge cloud results with edits made on disk while the request was in flight.
    /// Rebase local history over independent remote edits; conflicting history is
    /// discarded rather than allowing undo to overwrite another person's work.
    public static func applyCloud(_ remote: Ledger, at url: URL, mergeAgainst base: Ledger, recordWalletImport batchID: UUID? = nil) throws -> Ledger {
        try withLock(at: url) {
            let current = try decode(Data(contentsOf: url))
            var next = try CloudMerge.merge(base: base, local: current, remote: remote)
            if try equivalent(current, next) { return current }
            if let history = current.changeHistory {
                func rebase(_ snapshots: [Ledger]) -> [Ledger] {
                    var safe: [Ledger] = []
                    for snapshot in snapshots.reversed() {
                        do { safe.append(try CloudMerge.merge(base: current, local: snapshot, remote: next).withoutChangeHistory()) }
                        catch { break }
                    }
                    return safe.reversed()
                }
                var rebased = LedgerChangeHistory()
                rebased.undo = rebase(history.undo)
                rebased.redo = rebase(history.redo)
                next.changeHistory = rebased.undo.isEmpty && rebased.redo.isEmpty ? nil : rebased
            }
            if let batchID, !current.importHistory.contains(where: { $0.id == batchID }),
               let batch = next.importHistory.first(where: { $0.id == batchID && $0.source == "Apple Shortcuts" }) {
                // Purchases were committed individually by the server. Expose their collection
                // as one undoable import while preserving independent edits made during loading.
                let ids = Set(batch.transactions.map(\.id))
                var beforeImport = next
                beforeImport.transactions.removeAll { ids.contains($0.id) }
                beforeImport.importHistory.removeAll { $0.id == batchID }
                // A category assignment during loading must not resurrect the imported
                // purchase if the user undoes another step after undoing this batch.
                if var history = beforeImport.changeHistory {
                    func clean(_ snapshots: [Ledger]) throws -> [Ledger] {
                        var result: [Ledger] = [], previous = beforeImport.withoutChangeHistory()
                        for var snapshot in snapshots.reversed() {
                            snapshot.transactions.removeAll { ids.contains($0.id) }
                            snapshot.importHistory.removeAll { $0.id == batchID }
                            if try !equivalent(snapshot, previous) { result.append(snapshot); previous = snapshot }
                        }
                        return result.reversed()
                    }
                    history.undo = try clean(history.undo)
                    history.redo = try clean(history.redo)
                    beforeImport.changeHistory = history
                }
                next.recordChange(from: beforeImport)
            }
            try write(next, to: url)
            return next
        }
    }
    /// Explicitly attach a computer to a household. Archive its current data first.
    public static func adoptCloud(_ remote: Ledger, at url: URL) throws -> Ledger {
        try withLock(at: url) {
            let current = try decode(Data(contentsOf: url))
            let archive = url.deletingLastPathComponent().appendingPathComponent("before-cloud-\(UUID().uuidString).json")
            try encode(current).write(to: archive, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
            var next = remote.withoutChangeHistory()
            next.preferences.appearance = current.preferences.appearance
            next.preferences.showBudgets = current.preferences.showBudgets
            next.preferences.showGoals = current.preferences.showGoals
            next.preferences.showRecurring = current.preferences.showRecurring
            next.preferences.aiAgent = current.preferences.aiAgent
            try write(next, to: url)
            return next
        }
    }
    private static func moveHistory(at url: URL, expected: Ledger, undoing: Bool) throws -> Ledger {
        try withLock(at: url) {
            var ledger = try decode(Data(contentsOf: url))
            guard try equivalent(ledger, expected) else { throw LedgerError.invalid("Данные изменились в другом окне или через MCP. Повторите действие.") }
            if undoing { try ledger.undoLastChange() } else { try ledger.redoLastChange() }
            try write(ledger, to: url)
            return ledger
        }
    }
    private static func withLock<T>(at url: URL, _ action: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LedgerError.invalid("Не удалось открыть файл блокировки данных.") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw LedgerError.invalid("Не удалось заблокировать данные для записи.") }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }
    private static func write(_ ledger: Ledger, to url: URL) throws {
        let data = try encode(ledger)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = try Data(contentsOf: url)
            // Never replace the last good backup with an unreadable file.
            if (try? decode(previous)) != nil { try previous.write(to: url.appendingPathExtension("backup"), options: .atomic) }
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if FileManager.default.fileExists(atPath: url.appendingPathExtension("backup").path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.appendingPathExtension("backup").path)
        }
    }
}
