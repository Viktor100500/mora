import SwiftUI
import FinanceCore

struct CSVImportView: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    let table: CSVTable
    let filename: String
    @State private var mapping: CSVMapping
    @State private var result: CSVImportResult?
    @State private var previewLedger: Ledger?
    @State private var validationError: String?
    @State private var preparing = false
    @State private var importing = false

    init(table: CSVTable, filename: String) {
        self.table = table; self.filename = filename
        _mapping = State(initialValue: CSVMapping(headers: table.headers))
    }
    private var canImport: Bool { guard let result else { return false }; return result.imported > 0 && (result.invalid == 0 || mapping.skipInvalid) }
    private var delimiterName: String { table.delimiter == ";" ? L("точка с запятой") : table.delimiter == "\t" ? L("табуляция") : L("запятая") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(L("Файл"), value: filename)
                    LabeledContent(L("Строк"), value: "\(table.rows.count) · \(delimiterName)")
                }
                Section {
                    ForEach(CSVField.allCases) { field in
                        Picker(L(field.title), selection: Binding(get: { mapping.columns[field] ?? -1 }, set: { if $0 < 0 { mapping.columns.removeValue(forKey: field) } else { mapping.columns[field] = $0 } })) {
                            Text(L("Не импортировать")).tag(-1)
                            ForEach(table.headers.indices, id: \.self) { i in Text("\(i + 1). \(table.headers[i])").tag(i) }
                        }
                    }
                } header: { Text(L("Колонки файла")) } footer: { Text(L("Дата, описание и сумма обязательны")) }
                Section {
                    Picker(L("Формат даты"), selection: $mapping.dateFormat) {
                        Text(L("Авто: ISO / ДД.ММ.ГГГГ")).tag("auto"); Text(L("ДД/ММ/ГГГГ")).tag("dd/MM/yyyy")
                        Text(L("ММ/ДД/ГГГГ")).tag("MM/dd/yyyy"); Text(L("ГГГГ-ММ-ДД")).tag("yyyy-MM-dd")
                    }
                    Picker(L("Счет по умолчанию"), selection: $mapping.defaultAccountID) {
                        Text(L("Не выбран")).tag(UUID?.none)
                        ForEach(store.ledger.accounts.filter { !$0.archived }) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    Picker(L("Валюта новых счетов"), selection: $mapping.defaultCurrency) { ForEach(currencyList, id: \.self) { Text($0).tag($0) } }
                    Toggle(L("Положительная сумма означает расход"), isOn: $mapping.positiveIsExpense)
                    Toggle(L("Пропускать повторные операции"), isOn: $mapping.skipDuplicates)
                    if let result, result.invalid > 0 {
                        Toggle(L("Пропустить строки с ошибками (\(result.invalid))"), isOn: $mapping.skipInvalid).tint(.orange)
                    }
                } header: { Text(L("Как читать данные")) } footer: {
                    Text(L("Счет по умолчанию используется, когда в строке не указан счет. Именованные новые счета будут созданы с начальным остатком 0. Валюта покупки будет пересчитана в валюту счета по курсу Visa."))
                }
                preview
            }
            .navigationTitle(L("Импорт CSV"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(L("Отмена"), systemImage: "xmark") } }
                ToolbarItem(placement: .confirmationAction) {
                    if importing { ProgressView() } else {
                        Button(L("Импортировать")) { commit() }.disabled(!canImport).fontWeight(.semibold)
                    }
                }
            }
            .task(id: TaskKey(mapping: mapping, revision: store.revision)) { await rebuild() }
            .onAppear {
                mapping.defaultCurrency = store.baseCurrency
                if mapping.defaultAccountID == nil { mapping.defaultAccountID = store.ledger.suggestedTransactionAccountID }
            }
        }
    }

    private struct TaskKey: Equatable { let mapping: CSVMapping; let revision: UInt64 }

    @ViewBuilder private var preview: some View {
        if let validationError {
            Section { Label(L(validationError), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        } else if let result {
            Section {
                HStack {
                    count(L("Готово"), result.imported, .moraGreen)
                    count(L("Повторы"), result.duplicates, .secondary)
                    count(L("Ошибки"), result.invalid, result.invalid > 0 ? .orange : .secondary)
                    count(L("Исключено"), result.excluded, .secondary)
                }
                Toggle(L("Выбрать все строки"), isOn: Binding(get: { mapping.excludedRows.isEmpty }, set: { mapping.excludedRows = $0 ? [] : Set(table.rows.indices.map { $0 + 2 }) }))
            } header: { Text(L("Предпросмотр")) } footer: {
                if result.invalid > 0 && !mapping.skipInvalid { Text(L("Исправьте сопоставление или явно разрешите пропустить строки с ошибками.")) }
                else if result.imported == 0 { Text(L("Среди выбранных строк нет новых операций.")) }
                else { Text(L("Снимите галочку у операций, которые не нужно добавлять. До импорта данные не изменяются.")) }
            }
            Section {
                ForEach(result.rows.prefix(500)) { row in
                    Button {
                        if mapping.excludedRows.contains(row.id) { mapping.excludedRows.remove(row.id) } else { mapping.excludedRows.insert(row.id) }
                    } label: { previewRow(row) }.buttonStyle(.plain)
                }
                if result.rows.count > 500 { Text(L("Показаны первые 500 строк")).font(.caption).foregroundStyle(.secondary) }
            }
        } else if preparing {
            Section { HStack { ProgressView(); Text(L("Проверяем операции…")).foregroundStyle(.secondary) } }
        }
    }

    private func previewRow(_ row: CSVPreviewRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: mapping.excludedRows.contains(row.id) ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(mapping.excludedRows.contains(row.id) ? Color.secondary : Color.moraGreen)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.merchant.isEmpty ? L("Без описания") : row.merchant).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(row.error.map(L) ?? "\(row.date.map(Dates.string) ?? "") · \(row.account) · \(row.category.isEmpty ? L("Без категории / правило") : row.category)")
                    .font(.caption).foregroundStyle(row.error == nil ? Color.secondary : .orange).lineLimit(2)
                if row.duplicate && !row.excluded {
                    Text(mapping.skipDuplicates ? L("Повтор будет пропущен") : L("Совпадение: будет импортировано")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            FinancialText(row.amount.map { DisplayMoney.string($0, currency: row.currency) } ?? "—").font(.subheadline.weight(.medium)).lineLimit(1)
        }
        .opacity(row.excluded ? 0.5 : 1)
    }

    private func count(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title3.weight(.semibold)).foregroundStyle(color)
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity)
    }

    private func rebuild() async {
        validationError = nil; preparing = true
        let table = table, mapping = mapping, ledger = store.ledger
        do {
            try await Task.sleep(for: .milliseconds(120))
            let prepared = try await Task.detached(priority: .userInitiated) {
                try await CSVImporter.prepareAsync(table, mapping: mapping, ledger: ledger)
            }.value
            guard !Task.isCancelled else { return }
            result = prepared; previewLedger = ledger; preparing = false
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            result = nil; validationError = error.localizedDescription; preparing = false
        }
    }

    private func commit() {
        guard let fresh = result, let expected = previewLedger, canImport else { return }
        importing = true
        Task {
            if await store.importPreparedCSV(fresh, filename: filename, expected: expected) { dismiss() }
            importing = false
        }
    }
}

struct ImportHistoryScreen: View {
    @EnvironmentObject private var store: FinanceStore
    @State private var rollback: ImportBatch?

    var body: some View {
        List {
            if store.imports.batches.isEmpty {
                ContentUnavailableView(L("Импортов пока нет"), systemImage: "clock.arrow.circlepath", description: Text(L("Здесь появятся загрузки из CSV, Apple Shortcuts и AI-агента.")))
                    .listRowBackground(Color.clear)
            }
            ForEach(store.imports.batches) { batch in
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: batch.source == "CSV" ? "tablecells" : batch.source == "Apple Shortcuts" ? "wallet.pass" : "text.bubble")
                                .foregroundStyle(Color.moraGreen)
                            Text(batch.filename).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer()
                            if batch.rolledBackAt != nil { Text(L("Отменен")).font(.caption.weight(.medium)).foregroundStyle(.orange) }
                        }
                        Text(batch.createdAt.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(L10n.locale)) + " · " + L(batch.source))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(L("Добавлено: \(batch.transactions.count) из \(batch.totalRows) · Исключено: \(batch.excluded) · Повторы: \(batch.duplicates) · Ошибки: \(batch.invalid)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let preview = store.imports.previews[batch.id], batch.rolledBackAt == nil {
                        Button(role: .destructive) { rollback = batch } label: {
                            Label(L("Отменить импорт (\(preview.remaining))"), systemImage: "arrow.uturn.backward")
                        }.disabled(preview.remaining == 0)
                    }
                }
            }
        }
        .navigationTitle(L("История импортов"))
        .confirmationDialog(L("Отменить импорт «\(rollback?.filename ?? "")»?"), isPresented: Binding(get: { rollback != nil }, set: { if !$0 { rollback = nil } }), titleVisibility: .visible) {
            if let batch = rollback {
                Button(L("Отменить импорт"), role: .destructive) {
                    let modified = (store.imports.previews[batch.id]?.modified ?? 0) > 0
                    Task { await store.rollbackImport(batch.id, allowModified: modified); rollback = nil }
                }
            }
        } message: {
            if let batch = rollback, let preview = store.imports.previews[batch.id] {
                Text(L("Будет удалено операций: \(preview.remaining). Из них изменено или создано разделением: \(preview.modified). Остальные операции, счета и категории сохранятся."))
            }
        }
    }
}
