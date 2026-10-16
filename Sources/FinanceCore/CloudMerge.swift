import Foundation

/// A three-way merge against the last acknowledged cloud snapshot. Never replaces
/// a newer edit to the same record silently. Histories and display settings stay local.
public enum CloudMerge {
    public static func shared(_ ledger: Ledger) -> Ledger {
        var value = ledger.withoutChangeHistory()
        value.schemaVersion = 4
        value.importHistory = ledger.importHistory
        value.preferences.appearance = "system"
        value.preferences.showBudgets = false
        value.preferences.showGoals = false
        value.preferences.showRecurring = false
        value.preferences.aiAgent = "chatgpt"
        return value
    }

    public static func merge(base: Ledger, local: Ledger, remote: Ledger) throws -> Ledger {
        let base = try canonical(shared(base)), left = try canonical(shared(local)), right = try canonical(shared(remote))
        var merged = right
        merged.accounts = try records(base.accounts, left.accounts, right.accounts, name: "счет")
        merged.categories = try records(base.categories, left.categories, right.categories, name: "категория")
        merged.transactions = try records(base.transactions, left.transactions, right.transactions, name: "операция")
        merged.budgets = try records(base.budgets, left.budgets, right.budgets, name: "бюджет")
        merged.goals = try records(base.goals, left.goals, right.goals, name: "цель")
        merged.recurring = try records(base.recurring, left.recurring, right.recurring, name: "регулярный платеж")
        merged.rules = try records(base.rules, left.rules, right.rules, name: "правило")
        merged.importHistory = try records(base.importHistory, left.importHistory, right.importHistory, name: "импорт")
        if left.preferences == base.preferences { merged.preferences = right.preferences }
        else if right.preferences == base.preferences || left.preferences == right.preferences { merged.preferences = left.preferences }
        else if left.preferences.automaticRates, right.preferences.automaticRates,
                left.preferences.baseCurrency == right.preferences.baseCurrency,
                let l = left.preferences.exchangeRateSnapshot, let r = right.preferences.exchangeRateSnapshot {
            merged.preferences = l.quotedAt > r.quotedAt || (l.quotedAt == r.quotedAt && l.fetchedAt > r.fetchedAt) ? left.preferences : right.preferences
        } else { throw conflict("базовая валюта или курсы") }
        // Keep computer-specific choices out of the household's shared preferences.
        merged.preferences.appearance = local.preferences.appearance
        merged.preferences.showBudgets = local.preferences.showBudgets
        merged.preferences.showGoals = local.preferences.showGoals
        merged.preferences.showRecurring = local.preferences.showRecurring
        merged.preferences.aiAgent = local.preferences.aiAgent
        merged.changeHistory = local.changeHistory
        try merged.validate()
        return merged
    }

    public static func same(_ lhs: Ledger, _ rhs: Ledger) throws -> Bool {
        try LedgerFile.encode(shared(lhs)) == LedgerFile.encode(shared(rhs))
    }

    private static func canonical(_ value: Ledger) throws -> Ledger { try LedgerFile.decode(LedgerFile.encode(value)) }
    private static func conflict(_ name: String) -> LedgerError {
        .invalid("Конфликт синхронизации: \(name) изменен на двух компьютерах. Обе версии сохранены. Откройте общую базу в настройках облака, чтобы выбрать версию.")
    }

    private static func records<T: Identifiable & Equatable>(_ base: [T], _ left: [T], _ right: [T], name: String) throws -> [T] where T.ID == UUID {
        let b = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let l = Dictionary(uniqueKeysWithValues: left.map { ($0.id, $0) })
        let r = Dictionary(uniqueKeysWithValues: right.map { ($0.id, $0) })
        var values: [UUID: T] = [:]
        for id in Set(b.keys).union(l.keys).union(r.keys) {
            if l[id] == b[id] { values[id] = r[id] }
            else if r[id] == b[id] || l[id] == r[id] { values[id] = l[id] }
            else { throw conflict("\(name) \(id.uuidString.prefix(8))") }
        }
        // Preserve intentional ordering, especially rule precedence. Independent
        // additions do not count as reorders of existing records.
        let common = Set(base.map(\.id)).intersection(left.map(\.id)).intersection(right.map(\.id))
        let bo = base.map(\.id).filter { common.contains($0) }
        let lo = left.map(\.id).filter { common.contains($0) }
        let ro = right.map(\.id).filter { common.contains($0) }
        if lo != bo && ro != bo && lo != ro { throw conflict("порядок: \(name)") }
        let primary = lo != bo ? left : right
        let secondary = lo != bo ? right : left
        var seen = Set<UUID>()
        return (primary + secondary).compactMap { record in
            guard seen.insert(record.id).inserted else { return nil }
            return values[record.id]
        }
    }
}
