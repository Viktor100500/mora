import SwiftUI
import FinanceCore

struct ImportHistoryView: View {
    @EnvironmentObject var store: FinanceStore
    var onRollback: (UUID) -> Void
    private var batches: [ImportBatch] { store.imports.batches }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if batches.isEmpty {
                Card {
                    EmptyState(icon: "clock.arrow.circlepath", title: L("Импортов в истории пока нет"), text: L("Импорты CSV, покупки из Apple Shortcuts и пакеты операций из чата появятся здесь. История сохраняется после закрытия Mora."))
                }
            } else {
                Text(L("Отмена убирает только операции выбранного импорта. Другие операции, счета и категории сохраняются.")).font(.callout).foregroundStyle(.secondary)
                ForEach(batches) { batch in
                    batchCard(batch)
                }
            }
        }
    }

    private func batchCard(_ batch: ImportBatch) -> some View {
        let currentByID = store.imports.transactions
        let preview = store.imports.previews[batch.id]
        return Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    IconTile(icon: batch.rolledBackAt == nil ? (batch.source == "Apple Shortcuts" ? "iphone" : "doc.text") : "arrow.uturn.backward", color: batch.rolledBackAt == nil ? "green" : "gray", size: 42)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(batch.source == "Apple Shortcuts" ? L("Покупки из Apple Shortcuts") : batch.filename).font(.headline)
                        Text(batch.createdAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(L10n.locale)) + " · " + batch.source).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let rolledBack = batch.rolledBackAt {
                        VStack(alignment: .trailing, spacing: 4) {
                            Label(L("Отменен"), systemImage: "arrow.uturn.backward").foregroundStyle(.secondary)
                            Text(rolledBack.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(L10n.locale))).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Button(L("Отменить импорт")) { onRollback(batch.id) }
                    }
                }
                if batch.source == "Apple Shortcuts" {
                    Text(L("Покупок в загрузке: \(batch.transactions.count)")).font(.caption).foregroundStyle(.secondary)
                    Text(L("Все доступные покупки собраны при загрузке, независимо от даты и телефона. Покупки с неполными данными появятся здесь после проверки.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L("Добавлено: \(batch.transactions.count) из \(batch.totalRows) · Исключено: \(batch.excluded) · Повторы: \(batch.duplicates) · Ошибки: \(batch.invalid)")).font(.caption).foregroundStyle(.secondary)
                }
                if let preview {
                    Text(L("В учете: \(preview.remaining) · Изменено или разделено: \(preview.modified) · Удалено ранее: \(preview.missing)")).font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup(L("Операции импорта (\(batch.transactions.count))")) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(batch.transactions) { transaction in
                            historyRow(transaction, batch: batch, current: currentByID[transaction.id])
                            Divider().opacity(0.5)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func historyRow(_ transaction: Transaction, batch: ImportBatch, current: Transaction?) -> some View {
        let account = batch.accountNames[transaction.accountID.uuidString] ?? L("Счет")
        let category = transaction.kind == .transfer ? L("Перевод") : (transaction.categoryID.flatMap { batch.categoryNames[$0.uuidString] } ?? L("Без категории"))
        let subtitle = [Dates.string(transaction.date), account, category].joined(separator: " · ")
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.merchant).font(.callout.weight(.medium)).lineLimit(nil).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let conversion = transaction.conversion {
                    FinancialText("\(DisplayMoney.string(abs(conversion.originalAmount), currency: conversion.originalCurrency)) · Visa \(Money.plain(conversion.rate)) · \(Dates.string(conversion.date))").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            VStack(alignment: .trailing, spacing: 4) {
                FinancialText(DisplayMoney.string(transaction.amount, currency: batch.currencies[transaction.accountID.uuidString] ?? "")).font(.callout).monospacedDigit()
                if batch.rolledBackAt != nil { Text(L("Импорт отменен")).font(.caption).foregroundStyle(.secondary) }
                else if let current, current != transaction { Text(L("Изменена после импорта")).font(.caption).foregroundStyle(.orange) }
                else if current == nil { Text(L("Удалена из учета")).font(.caption).foregroundStyle(.secondary) }
            }.fixedSize(horizontal: true, vertical: false)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
    }
}
