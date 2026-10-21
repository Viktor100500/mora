import Foundation
import CryptoKit
import FinanceCore

struct ImportPresentation: Sendable {
    var batches: [ImportBatch] = []
    var transactions: [UUID: Transaction] = [:]
    var previews: [UUID: ImportRollbackPreview] = [:]
}

struct LedgerSnapshot: Sendable {
    let ledger: Ledger
    let revision: UInt64
    let token: String
    let isDemo: Bool
    let writeBlocked: Bool
    let warning: String?
    let undoDescriptions: [ChangeDescription]
    let redoDescriptions: [ChangeDescription]
    let imports: ImportPresentation
}

struct LedgerMutation<Value: Sendable>: Sendable {
    let snapshot: LedgerSnapshot
    let value: Value
    let changed: Bool
}

/// The actor owns the loaded version. Each disk transaction has no await inside
/// its file lock; unrelated GUI, cloud and MCP edits are read before mutation.
/// Revisioned results prevent a late UI continuation from publishing older data.
actor LedgerRepository {
    let fileURL: URL
    private let forcedDemo: Bool
    private var current: LedgerSnapshot?
    private var revision: UInt64 = 0
    private var presentationLanguage: AppLanguage?
    private var diskVersion: DiskVersion?
    private struct DiskVersion: Equatable {
        let modified: Date
        let size: UInt64
        let inode: UInt64
    }

    init(fileURL: URL, forcedDemo: Bool) { self.fileURL = fileURL; self.forcedDemo = forcedDemo }

    func load() throws -> LedgerSnapshot {
        if forcedDemo { return try current ?? snapshot(.demo(), demo: true) }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return try current ?? snapshot(.demo(), demo: true)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let version = DiskVersion(modified: attributes[.modificationDate] as? Date ?? .distantPast,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
        if version == diskVersion, let current { return try snapshot(current.ledger, demo: current.isDemo, blocked: current.writeBlocked, warning: current.warning) }
        do {
            let ledger = try LedgerFile.decode(Data(contentsOf: fileURL))
            diskVersion = version
            return try snapshot(ledger)
        } catch {
            if current != nil { throw error }
            let backup = try? LedgerFile.decode(Data(contentsOf: fileURL.appendingPathExtension("backup")))
            return try snapshot(backup ?? .empty, blocked: true,
                warning: "Не удалось открыть данные. Исходный файл сохранен; восстановите резервную копию в настройках.")
        }
    }

    private func snapshot(_ ledger: Ledger, demo: Bool = false, blocked: Bool = false, warning: String? = nil) throws -> LedgerSnapshot {
        let language = L10n.language
        if let current, current.ledger == ledger, current.isDemo == demo, current.writeBlocked == blocked, presentationLanguage == language { return current }
        revision &+= 1
        let token = SHA256.hash(data: try LedgerFile.encode(ledger)).map { String(format: "%02x", $0) }.joined()
        let undo = ledger.changeHistory?.undo ?? [], redo = ledger.changeHistory?.redo ?? []
        let undoDescriptions = undo.indices.reversed().map { index in
            ChangeDescriptions.between(undo[index], index + 1 < undo.count ? undo[index + 1] : ledger, language: language)
        }
        let redoDescriptions = redo.indices.reversed().map { index in
            ChangeDescriptions.between(index + 1 < redo.count ? redo[index + 1] : ledger, redo[index], language: language)
        }
        var imports = ImportPresentation(batches: ledger.importHistory.sorted { $0.createdAt > $1.createdAt },
            transactions: Dictionary(uniqueKeysWithValues: ledger.transactions.map { ($0.id, $0) }))
        for batch in imports.batches { imports.previews[batch.id] = try? ledger.importRollbackPreview(batch.id) }
        let result = LedgerSnapshot(ledger: ledger, revision: revision, token: token,
            isDemo: demo, writeBlocked: blocked, warning: warning,
            undoDescriptions: undoDescriptions, redoDescriptions: redoDescriptions, imports: imports)
        presentationLanguage = language
        current = result
        return result
    }

    func mutate<Value: Sendable>(recordHistory: Bool = true, _ action: @Sendable (inout Ledger) throws -> Value) throws -> LedgerMutation<Value> {
        let previous = try load()
        guard !previous.writeBlocked else { throw LedgerError.invalid("Исходный файл не удалось прочитать. Сначала восстановите исправную резервную копию в настройках; текущий файл не будет перезаписан.") }
        let next: Ledger
        let value: Value
        if previous.isDemo {
            var edited = previous.ledger
            value = try action(&edited); try edited.validate()
            if recordHistory && edited != previous.ledger { edited.recordChange(from: previous.ledger) }
            next = edited
        } else {
            // The result is assigned only by LedgerFile's synchronous locked closure.
            var result: Value?
            next = try LedgerFile.mutate(at: fileURL, recordHistory: recordHistory) { result = try action(&$0) }
            value = result!
        }
        diskVersion = nil
        return try LedgerMutation(snapshot: snapshot(next, demo: previous.isDemo), value: value, changed: next != previous.ledger)
    }

    func moveHistory(undo: Bool, expectedToken: String? = nil) throws -> LedgerSnapshot {
        let latest = try load()
        guard expectedToken == nil || expectedToken == latest.token else {
            throw LedgerError.invalid("Данные изменились в другом окне или через MCP. Повторите действие с обновленными данными.")
        }
        let result: Ledger
        if latest.isDemo {
            var edited = latest.ledger
            if undo { try edited.undoLastChange() } else { try edited.redoLastChange() }
            result = edited
        } else {
            result = try undo ? LedgerFile.undo(at: fileURL, expected: latest.ledger) : LedgerFile.redo(at: fileURL, expected: latest.ledger)
        }
        diskVersion = nil
        return try snapshot(result, demo: latest.isDemo)
    }

    func initialize(baseCurrency: String) throws -> (LedgerSnapshot, Bool) {
        var empty = try Ledger.personal(baseCurrency: baseCurrency)
        if let rates = current?.ledger.preferences.exchangeRateSnapshot {
            try empty.applyExchangeRates(rates)
        }
        var existing = false
        let result = try LedgerFile.mutate(at: fileURL) { ledger in
            if FileManager.default.fileExists(atPath: fileURL.path) { existing = true }
            else { ledger = empty }
        }
        diskVersion = nil
        return try (snapshot(result), existing)
    }

    func restore(_ ledger: Ledger) throws -> LedgerSnapshot {
        if current?.writeBlocked == true, FileManager.default.fileExists(atPath: fileURL.path) {
            try Data(contentsOf: fileURL).write(to: fileURL.deletingLastPathComponent()
                .appendingPathComponent("ledger-unreadable-\(Int(Date().timeIntervalSince1970)).json"), options: .atomic)
        }
        let saved = try LedgerFile.save(ledger, to: fileURL)
        diskVersion = nil
        return try snapshot(saved)
    }
}
