import Foundation

public struct ImportBatch: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var filename: String
    public var source: String
    public var createdAt: Date
    public var totalRows: Int
    public var excluded: Int
    public var duplicates: Int
    public var invalid: Int
    public var transactions: [Transaction]
    public var accountNames: [String: String]
    public var currencies: [String: String]
    public var categoryNames: [String: String]
    public var rolledBackAt: Date?
}

public struct ImportRollbackPreview: Sendable {
    public var remaining: Int
    public var modified: Int
    public var missing: Int
}

extension Ledger {
    @discardableResult
    public mutating func recordImport(addedIDs: Set<UUID>, filename: String, source: String = "CSV", totalRows: Int,
                                      excluded: Int = 0, duplicates: Int = 0, invalid: Int = 0, now: Date = Date(), batchID: UUID = UUID()) throws -> ImportBatch? {
        guard !addedIDs.isEmpty else { return nil }
        let indices = transactions.indices.filter { addedIDs.contains(transactions[$0].id) }
        guard indices.count == addedIDs.count, indices.allSatisfy({ transactions[$0].importBatchID == nil }) else {
            throw LedgerError.invalid("Не удалось определить новые операции импорта.")
        }
        let id = batchID
        guard !importHistory.contains(where: { $0.id == id }) else { throw LedgerError.invalid("Идентификатор импорта уже использован.") }
        // Older writers must reject ledgers carrying import history instead of dropping it.
        schemaVersion = max(schemaVersion, 2)
        for i in indices { transactions[i].importBatchID = id }
        let batch = ImportBatch(id: id, filename: filename, source: source, createdAt: now, totalRows: totalRows,
                                excluded: excluded, duplicates: duplicates, invalid: invalid,
                                transactions: indices.map { transactions[$0] },
                                accountNames: Dictionary(uniqueKeysWithValues: accounts.map { ($0.id.uuidString, $0.name) }),
                                currencies: Dictionary(uniqueKeysWithValues: accounts.map { ($0.id.uuidString, $0.currency) }),
                                categoryNames: Dictionary(uniqueKeysWithValues: categories.map { ($0.id.uuidString, $0.name) }), rolledBackAt: nil)
        importHistory.append(batch)
        try validate()
        return batch
    }

    public func transactions(from batch: ImportBatch) -> [Transaction] {
        let ids = Set(batch.transactions.map(\.id))
        return transactions.filter { $0.importBatchID == batch.id || ids.contains($0.id) }
    }

    public func importRollbackPreview(_ id: UUID) throws -> ImportRollbackPreview {
        guard let batch = importHistory.first(where: { $0.id == id }), batch.rolledBackAt == nil else {
            throw LedgerError.invalid("Этот импорт уже отменен или не найден.")
        }
        let current = transactions(from: batch)
        let originals = Dictionary(uniqueKeysWithValues: batch.transactions.map { ($0.id, $0) })
        let modified = current.filter { originals[$0.id] != $0 }.count
        let ids = Set(current.map(\.id))
        return ImportRollbackPreview(remaining: current.count, modified: modified,
                                     missing: batch.transactions.filter { !ids.contains($0.id) }.count)
    }

    @discardableResult
    public mutating func rollbackImport(_ id: UUID, allowModified: Bool = false, now: Date = Date()) throws -> Int {
        let preview = try importRollbackPreview(id)
        guard allowModified || preview.modified == 0 else {
            throw LedgerError.invalid("После импорта изменены или разделены операции: \(preview.modified). Подтвердите отмену в истории импортов.")
        }
        let batch = importHistory.first { $0.id == id }!
        let ids = Set(transactions(from: batch).map(\.id))
        transactions.removeAll { ids.contains($0.id) }
        if let index = importHistory.firstIndex(where: { $0.id == id }) { importHistory[index].rolledBackAt = now }
        try validate()
        return ids.count
    }
}
