import Foundation
import FinanceCore

/// Derive descriptions from the snapshots themselves, including history written by older apps or MCP.
/// Descriptions are presentation only: undo/redo still use the coordinated ledger operations.
struct ChangeDescription: Equatable {
    let title: String
    let detail: String
}

@MainActor
enum ChangeDescriptions {
    static func between(_ before: Ledger, _ after: Ledger) -> ChangeDescription {
        var groups: [ChangeDescription] = []
        func records<T: Identifiable & Equatable>(_ old: [T], _ new: [T],
                                                 added: (String, String), removed: (String, String), edited: (String, String),
                                                 name: (T) -> String, changes: ((T, T) -> String)? = nil) where T.ID == UUID {
            let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
            let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
            func append(_ values: [String], _ titles: (String, String)) {
                guard !values.isEmpty else { return }
                let title = values.count == 1 ? L(titles.0) : L("\(L(titles.1)): \(values.count)")
                var detail = values.prefix(2).joined(separator: "\n")
                if values.count > 2 { detail += "\n" + L("И ещё: \(values.count - 2)") }
                groups.append(ChangeDescription(title: title, detail: detail))
            }
            append(new.filter { oldByID[$0.id] == nil }.map(name), added)
            append(old.filter { newByID[$0.id] == nil }.map(name), removed)
            append(new.compactMap { value in
                guard let previous = oldByID[value.id], previous != value else { return nil }
                return changes?(previous, value) ?? name(value)
            }, edited)
            if oldByID == newByID, old.map(\.id) != new.map(\.id) {
                groups.append(ChangeDescription(title: L("Изменение порядка записей"), detail: L(edited.1)))
            }
        }
        let previousTransactions = Dictionary(uniqueKeysWithValues: before.transactions.map { ($0.id, $0) })
        let categoryOnly = !after.transactions.isEmpty && after.transactions.allSatisfy { value in
            guard var old = previousTransactions[value.id] else { return false }
            old.categoryID = value.categoryID
            return old == value
        } && Set(before.transactions.map(\.id)) == Set(after.transactions.map(\.id))
        records(before.transactions, after.transactions,
                added: ("Добавление операции", "Добавление операций"), removed: ("Удаление операции", "Удаление операций"),
                edited: categoryOnly ? ("Изменение категории операции", "Изменение категорий операций") : ("Изменение операции", "Изменение операций"),
                name: { value in transaction(value, in: after.transactions.contains(where: { $0.id == value.id }) ? after : before) }, changes: { old, new in
            var fields: [String] = []
            if old.merchant != new.merchant { fields.append("\(clean(old.merchant)) → \(clean(new.merchant))") }
            if old.amount != new.amount || old.accountID != new.accountID {
                fields.append("\(money(old.amount, account: old.accountID, in: before)) → \(money(new.amount, account: new.accountID, in: after))")
            }
            if old.accountID != new.accountID { fields.append(L("Счет: \(clean(before.account(old.accountID)?.name ?? "—")) → \(clean(after.account(new.accountID)?.name ?? "—"))")) }
            if old.categoryID != new.categoryID { fields.append(L("Категория: \(category(old.categoryID, in: before)) → \(category(new.categoryID, in: after))")) }
            if old.date != new.date { fields.append(L("Дата: \(date(old.date)) → \(date(new.date))")) }
            if old.kind != new.kind { fields.append(L("Тип: \(L(old.kind.title)) → \(L(new.kind.title))")) }
            if old.note != new.note { fields.append(L("Заметка изменена")) }
            if old.tags != new.tags { fields.append(L("Теги: \(old.tags.map(clean).joined(separator: ", ")) → \(new.tags.map(clean).joined(separator: ", "))")) }
            if old.destinationAccountID != new.destinationAccountID || old.destinationAmount != new.destinationAmount {
                fields.append(L("Получатель перевода или сумма зачисления изменены"))
            }
            if old.conversion != new.conversion { fields.append(L("Валютная конвертация изменена")) }
            return ([transaction(new, in: after)] + fields).joined(separator: " · ")
        })
        records(before.accounts, after.accounts,
                added: ("Добавление счета", "Добавление счетов"), removed: ("Удаление счета", "Удаление счетов"),
                edited: ("Изменение счета", "Изменение счетов"), name: { clean($0.name) }, changes: { old, new in
            var fields = [clean(new.name)]
            if old.name != new.name { fields.append("\(clean(old.name)) → \(clean(new.name))") }
            if old.archived != new.archived { fields.append(new.archived ? L("Перемещен в архив") : L("Возвращен из архива")) }
            if old.openingBalance != new.openingBalance || old.currency != new.currency {
                fields.append(L("Начальный остаток: \(DisplayMoney.string(old.openingBalance, currency: old.currency)) → \(DisplayMoney.string(new.openingBalance, currency: new.currency))"))
            }
            if old.bankFeePercent != new.bankFeePercent { fields.append(L("Комиссия: \(Money.plain(old.bankFeePercent))% → \(Money.plain(new.bankFeePercent))%")) }
            if old.kind != new.kind { fields.append(L("Тип счета: \(L(old.kind.title)) → \(L(new.kind.title))")) }
            if old.color != new.color { fields.append(L("Цвет счета изменен")) }
            return fields.joined(separator: " · ")
        })
        records(before.categories, after.categories,
                added: ("Добавление категории", "Добавление категорий"), removed: ("Удаление категории", "Удаление категорий"),
                edited: ("Изменение категории", "Изменение категорий"), name: { clean($0.name) }, changes: { old, new in
            old.name != new.name ? "\(clean(old.name)) → \(clean(new.name))" : clean(new.name)
        })
        records(before.rules, after.rules,
                added: ("Добавление правила", "Добавление правил"), removed: ("Удаление правила", "Удаление правил"),
                edited: ("Изменение правила", "Изменение правил"), name: { "\(clean($0.keyword)) → \(category($0.categoryID, in: after))" }, changes: { old, new in
            "\(clean(old.keyword)) → \(category(old.categoryID, in: before)); \(clean(new.keyword)) → \(category(new.categoryID, in: after))"
        })
        records(before.budgets, after.budgets,
                added: ("Добавление бюджета", "Добавление бюджетов"), removed: ("Удаление бюджета", "Удаление бюджетов"),
                edited: ("Изменение бюджета", "Изменение бюджетов"), name: { "\(category($0.categoryID, in: after)) · \(DisplayMoney.string($0.limit, currency: after.preferences.baseCurrency))" })
        records(before.goals, after.goals,
                added: ("Добавление цели", "Добавление целей"), removed: ("Удаление цели", "Удаление целей"),
                edited: ("Изменение цели", "Изменение целей"), name: { clean($0.name) })
        records(before.recurring, after.recurring,
                added: ("Добавление регулярного платежа", "Добавление регулярных платежей"), removed: ("Удаление регулярного платежа", "Удаление регулярных платежей"),
                edited: ("Изменение регулярного платежа", "Изменение регулярных платежей"), name: { "\(clean($0.name)) · \(money($0.amount, account: $0.accountID, in: after))" })
        records(before.importHistory, after.importHistory,
                added: ("Импорт файла", "Импорт файлов"), removed: ("Удаление истории импорта", "Удаление истории импортов"),
                edited: ("Изменение импорта", "Изменение импортов"), name: { clean($0.filename) }, changes: { old, new in
            clean(new.filename) + (old.rolledBackAt != new.rolledBackAt ? " · " + (new.rolledBackAt == nil ? L("Импорт восстановлен") : L("Импорт отменен")) : "")
        })
        let a = before.preferences, b = after.preferences
        func setting(_ title: String, _ old: String, _ new: String) {
            if old != new { groups.append(ChangeDescription(title: L(title), detail: "\(old) → \(new)")) }
        }
        setting("Изменение базовой валюты", a.baseCurrency, b.baseCurrency)
        func appearance(_ value: String) -> String { value == "light" ? L("Светлое") : value == "dark" ? L("Темное") : L("Как в системе") }
        setting("Изменение оформления", appearance(a.appearance), appearance(b.appearance))
        func enabled(_ value: Bool) -> String { value ? L("Включено") : L("Выключено") }
        setting("Автоматическая загрузка курсов", enabled(a.automaticRates), enabled(b.automaticRates))
        setting("Раздел «Бюджеты»", enabled(a.showBudgets), enabled(b.showBudgets))
        setting("Раздел «Цели»", enabled(a.showGoals), enabled(b.showGoals))
        setting("Раздел «Регулярные платежи»", enabled(a.showRecurring), enabled(b.showRecurring))
        setting("Изменение AI-помощника", a.aiAgent, b.aiAgent)
        if !b.automaticRates && a.rates != b.rates && a.baseCurrency == b.baseCurrency {
            let currencies = Set(a.rates.keys).union(b.rates.keys).filter { a.rates[$0] != b.rates[$0] }.sorted()
            groups.append(ChangeDescription(title: L("Изменение курсов валют"), detail: currencies.map { code in
                "\(code): \(a.rates[code].map(Money.plain) ?? "—") → \(b.rates[code].map(Money.plain) ?? "—")"
            }.joined(separator: " · ")))
        }
        if let batch = after.importHistory.first(where: { value in !before.importHistory.contains(where: { $0.id == value.id }) }) {
            return ChangeDescription(title: L("Импорт: \(clean(batch.filename))"), detail: groups.filter { $0.title != L("Импорт файла") }.map { "\($0.title): \($0.detail)" }.joined(separator: "\n"))
        }
        if let batch = after.importHistory.first(where: { value in value.rolledBackAt != nil && before.importHistory.first(where: { $0.id == value.id })?.rolledBackAt == nil }) {
            return ChangeDescription(title: L("Отмена импорта: \(clean(batch.filename))"), detail: groups.map { "\($0.title): \($0.detail)" }.joined(separator: "\n"))
        }
        if groups.count == 1 { return groups[0] }
        if groups.isEmpty { return ChangeDescription(title: L("Изменение данных"), detail: L("Сохраненное состояние учета")) }
        return ChangeDescription(title: L("Несколько изменений"), detail: groups.map { "\($0.title): \($0.detail)" }.joined(separator: "\n"))
    }

    private static func clean(_ text: String) -> String {
        String(text.split(whereSeparator: { $0.isNewline }).joined(separator: " ").prefix(120))
    }
    private static func category(_ id: UUID?, in ledger: Ledger) -> String { ledger.category(id).map { clean($0.name) } ?? L("Без категории") }
    private static func date(_ value: Date) -> String { value.formatted(.dateTime.day().month(.abbreviated).year().locale(L10n.locale)) }
    private static func money(_ amount: Decimal, account: UUID, in ledger: Ledger) -> String {
        DisplayMoney.string(amount, currency: ledger.account(account)?.currency ?? ledger.preferences.baseCurrency)
    }
    private static func transaction(_ value: Transaction, in ledger: Ledger) -> String {
        let name = value.merchant.isEmpty ? L("Без описания") : clean(value.merchant)
        return "\(name) · \(money(value.amount, account: value.accountID, in: ledger)) · \(date(value.date))"
    }
}
