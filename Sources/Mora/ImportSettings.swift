import SwiftUI
import AppKit
import FinanceCore

struct ImportView: View {
    @EnvironmentObject var store: FinanceStore
    @Environment(\.dismiss) var dismiss
    let table: CSVTable
    let filename: String
    @State private var mapping: CSVMapping
    @State private var result: CSVImportResult?
    @State private var validationError: String?
    @State private var preparing = false
    @State private var previewLedger: Ledger?
    @State private var work: Task<CSVImportResult, Error>?
    init(table: CSVTable, filename: String) {
        self.table = table; self.filename = filename
        _mapping = State(initialValue: CSVMapping(headers: table.headers))
    }
    private var canImport: Bool { guard let result else { return false }; return result.imported > 0 && (result.invalid == 0 || mapping.skipInvalid) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                IconTile(icon: "square.and.arrow.down", size: 44)
                VStack(alignment: .leading, spacing: 5) { Text(L("Импорт CSV")).font(.title2.weight(.semibold)); Text(L("\(filename) · \(table.rows.count) строк · \(table.delimiter == ";" ? L("точка с запятой") : table.delimiter == "\t" ? L("табуляция") : L("запятая"))")).font(.caption).foregroundStyle(.secondary) }
                Spacer(); Text(L("1. Сопоставьте колонки   →   2. Проверьте   →   3. Импортируйте")).font(.caption).foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeading(title: L("Колонки файла"), subtitle: L("Дата, описание и сумма обязательны"))
                        ForEach(CSVField.allCases) { field in
                            HStack {
                                Text(L(field.title)).font(.system(size: 11)).frame(width: 138, alignment: .leading)
                                Picker(L(field.title), selection: Binding(get: { mapping.columns[field] ?? -1 }, set: { if $0 < 0 { mapping.columns.removeValue(forKey: field) } else { mapping.columns[field] = $0 } })) {
                                    Text(L("Не импортировать")).tag(-1)
                                    ForEach(table.headers.indices, id: \.self) { i in Text("\(i + 1). \(table.headers[i])").tag(i) }
                                }.labelsHidden()
                            }
                        }
                        Divider().padding(.vertical, 6)
                        SectionHeading(title: L("Как читать данные"), subtitle: L("Валюта покупки будет автоматически пересчитана в валюту выбранного счета по курсу Visa"))
                        Picker(L("Формат даты"), selection: $mapping.dateFormat) { Text(L("Авто: ISO / ДД.ММ.ГГГГ")).tag("auto"); Text(L("ДД/ММ/ГГГГ")).tag("dd/MM/yyyy"); Text(L("ММ/ДД/ГГГГ")).tag("MM/dd/yyyy"); Text(L("ГГГГ-ММ-ДД")).tag("yyyy-MM-dd") }.font(.caption)
                        Picker(L("Счет по умолчанию"), selection: $mapping.defaultAccountID) { Text(L("Не выбран")).tag(Optional<UUID>.none); ForEach(store.ledger.accounts.filter { !$0.archived }) { Text($0.name).tag(Optional($0.id)) } }.font(.caption)
                        Text(L("Используется, когда в строке не указан счет. Именованные новые счета будут созданы с начальным остатком 0.")).font(.system(size: 10)).foregroundStyle(.secondary)
                        Picker(L("Валюта новых счетов"), selection: $mapping.defaultCurrency) { ForEach(currencyList, id: \.self) { Text($0).tag($0) } }.font(.caption)
                        Toggle(L("Положительная сумма означает расход"), isOn: $mapping.positiveIsExpense).font(.caption)
                        Text(L("При указанном типе income / expense / transfer знак определяется типом.")).font(.system(size: 10)).foregroundStyle(.secondary)
                        Toggle(L("Пропускать повторные операции"), isOn: $mapping.skipDuplicates).font(.caption)
                        Text(L("По ID пропускаются повторные записи. Без ID сравниваем с уже сохраненными покупками с учетом их количества. Одинаковые новые покупки в одном файле сохраняются отдельно.")).font(.system(size: 10)).foregroundStyle(.secondary)
                        if let result, result.invalid > 0 { Toggle(L("Пропустить строки с ошибками (\(result.invalid))"), isOn: $mapping.skipInvalid).font(.caption).foregroundStyle(.orange) }
                    }.padding(22)
                }.frame(width: 355)
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    if let validationError { Label(validationError, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 10)) }
                    if let result {
                        HStack(spacing: 18) { importCount(L("Готово"), result.imported, .moraGreen); importCount(L("Повторы пропущены"), result.duplicates, .secondary); importCount(L("Ошибки"), result.invalid, result.invalid > 0 ? .orange : .secondary) }
                        HStack {
                            Toggle(L("Выбрать все строки"), isOn: Binding(get: { mapping.excludedRows.isEmpty }, set: { mapping.excludedRows = $0 ? [] : Set(table.rows.indices.map { $0 + 2 }) })).toggleStyle(.checkbox).font(.caption)
                            Spacer()
                            Text(L("Исключено: \(result.excluded)")).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(L("Снимите галочку у операций, которые не нужно добавлять.")).font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(result.rows) { row in
                                    HStack(alignment: .top, spacing: 10) {
                                        Toggle(L("Добавить строку \(row.id): \(row.merchant)"), isOn: Binding(get: { !mapping.excludedRows.contains(row.id) }, set: { if $0 { mapping.excludedRows.remove(row.id) } else { mapping.excludedRows.insert(row.id) } })).toggleStyle(.checkbox).labelsHidden().accessibilityLabel(L("Добавить строку \(row.id): \(row.merchant)"))
                                        Text("\(row.id)").font(.caption2.monospaced()).foregroundStyle(.tertiary).frame(width: 25)
                                        Image(systemName: row.error != nil ? "exclamationmark.circle" : row.duplicate ? "doc.on.doc" : "checkmark.circle").foregroundStyle(row.error != nil ? Color.orange : row.duplicate ? .secondary : .moraGreen)
                                        VStack(alignment: .leading, spacing: 4) { Text(row.merchant.isEmpty ? L("Без описания") : row.merchant).font(.system(size: 12, weight: .medium)).lineLimit(1); Text(row.error ?? "\(row.date.map(Dates.string) ?? "") · \(row.account) · \(row.category.isEmpty ? L("Без категории / правило") : row.category)").font(.system(size: 10)).foregroundStyle(row.error == nil ? Color.secondary : .orange); if let conversion = row.conversion { FinancialText(L("Исходно: \(DisplayMoney.string(abs(conversion.originalAmount), currency: conversion.originalCurrency)) · Visa \(Money.plain(conversion.rate))")).font(.system(size: 10)).foregroundStyle(.secondary) }; if row.excluded { Text(L("Исключено из импорта")).font(.system(size: 10)).foregroundStyle(.secondary) } else if row.duplicate { Text(mapping.skipDuplicates ? L("Повтор будет пропущен") : L("Совпадение: будет импортировано")).font(.system(size: 10)).foregroundStyle(.secondary) } }
                                        Spacer(minLength: 4)
                                        FinancialText(row.amount.map { DisplayMoney.string($0, currency: row.currency) } ?? "—").font(.system(size: 11, weight: .medium)).lineLimit(1)
                                    }.padding(.vertical, 12).opacity(row.excluded ? 0.55 : 1)
                                    Divider().opacity(0.5)
                                }
                            }
                        }
                        if result.invalid > 0 && !mapping.skipInvalid { Text(L("Исправьте сопоставление или явно разрешите пропустить строки с ошибками.")).font(.caption).foregroundStyle(.orange) }
                        if result.imported == 0 && result.invalid == 0 { Text(result.excluded == table.rows.count ? L("Все строки исключены. Выберите операции для импорта.") : L("Среди выбранных строк нет новых операций.")).font(.callout).foregroundStyle(.secondary) }
                    } else { Spacer(); if preparing { ProgressView(L("Проверяем операции…")).frame(maxWidth: .infinity) } else { Image(systemName: "tablecells").font(.system(size: 48)).foregroundStyle(.tertiary).frame(maxWidth: .infinity); Text(L("Сопоставьте колонки для предпросмотра")).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity) }; Spacer() }
                }.padding(22).frame(maxWidth: .infinity)
            }.frame(height: 570)
            Divider()
            HStack { Text(L("До импорта данные не изменяются")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(L("Отмена")) { dismiss() }.keyboardShortcut(.cancelAction); Button(L("Импортировать \(result?.imported ?? 0) операций"), action: commit).buttonStyle(.borderedProminent).disabled(!canImport).keyboardShortcut(.defaultAction) }.padding(20)
        }.frame(width: 1040)
        .onAppear { mapping.defaultCurrency = store.ledger.preferences.baseCurrency; rebuild() }
        .onChange(of: mapping) { _, _ in rebuild() }
        .onChange(of: store.ledger) { _, _ in rebuild() }
        .onDisappear { work?.cancel() }
    }
    private func importCount(_ label: String, _ value: Int, _ color: Color) -> some View { VStack(alignment: .leading, spacing: 5) { Text("\(value)").font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(color); Text(label).font(.system(size: 10)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) }
    @MainActor private func rebuild() {
        work?.cancel(); result = nil; validationError = nil; preparing = true
        let tableSnapshot = table, mappingSnapshot = mapping, ledgerSnapshot = store.ledger
        let job = Task.detached(priority: .userInitiated) { try await CSVImporter.prepareAsync(tableSnapshot, mapping: mappingSnapshot, ledger: ledgerSnapshot) }
        work = job
        Task { @MainActor in
            do {
                let prepared = try await job.value
                guard !job.isCancelled else { return }
                result = prepared; previewLedger = ledgerSnapshot; preparing = false
            } catch {
                guard !job.isCancelled else { return }
                validationError = error.localizedDescription; preparing = false
            }
        }
    }
    private func commit() { Task { @MainActor in
        guard let fresh = result, previewLedger == store.ledger, fresh.imported > 0 && (fresh.invalid == 0 || mapping.skipInvalid) else { rebuild(); return }
        if let expected = previewLedger, await store.importPreparedCSV(fresh, filename: filename, expected: expected) { dismiss() }
     } }
}

struct SettingsView: View {
    @EnvironmentObject private var cloud: CloudSync
    @EnvironmentObject var store: FinanceStore
    @State private var rateCurrency = "USD"
    @State private var rateAmount = ""
    @State private var restoreLedger: Ledger?
    @State private var selectedBase = "RUB"
    private var ledger: Ledger { store.ledger }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1" }
    private var displayedCurrencies: [String] {
        let extra = ledger.preferences.automaticRates ? [] : [rateCurrency.trimmingCharacters(in: .whitespaces).uppercased()]
        return Array(Set(ledger.accounts.map(\.currency) + [ledger.preferences.baseCurrency, "USD", "EUR"] + extra))
            .filter { ledger.preferences.rates[$0] != nil }.sorted()
    }
    var body: some View {
        VStack(spacing: 22) {
            LanguageSettingsCard()
            Card {
                VStack(alignment: .leading, spacing: 22) {
                    SectionHeading(title: L("Валюты и отображение"), subtitle: L("Все отчеты и бюджеты используют базовую валюту"))
                    HStack(spacing: 12) {
                        Text(L("Базовая валюта")).font(.callout); Spacer()
                        HStack(spacing: 8) {
                            Picker(L("Базовая валюта"), selection: $selectedBase) {
                                ForEach(Array(Set(currencyList + Array(ledger.preferences.rates.keys))).sorted(), id: \.self) { Text($0).tag($0) }
                            }.pickerStyle(.menu).labelsHidden().fixedSize()
                            Button(L("Применить")) { Task { @MainActor in
                                if !(await store.update({ [selectedBase] in try $0.changeBaseCurrency(to: selectedBase) })) { selectedBase = ledger.preferences.baseCurrency }
                             } }.buttonStyle(.bordered).disabled(selectedBase == ledger.preferences.baseCurrency)
                        }.controlSize(.regular).fixedSize()
                    }
                    Text(L("При смене базовой валюты лимиты бюджетов и суммы целей пересчитываются по текущему курсу.")).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack { Text(L("Оформление")).font(.callout); Spacer(); Picker(L("Оформление"), selection: Binding(get: { ledger.preferences.appearance }, set: { value in Task { @MainActor in  await store.update { $0.preferences.appearance = value }  } })) { Text(L("Как в системе")).tag("system"); Text(L("Светлое")).tag("light"); Text(L("Темное")).tag("dark") }.pickerStyle(.menu).labelsHidden().fixedSize() }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 18) {
                    SectionHeading(title: L("Дополнительные разделы"), subtitle: L("Включите нужные разделы. Их данные сохраняются при скрытии."))
                    Toggle(L("Бюджеты"), isOn: Binding(get: { ledger.preferences.showBudgets }, set: { value in Task { @MainActor in  await store.update { $0.preferences.showBudgets = value }  } }))
                    Toggle(L("Цели"), isOn: Binding(get: { ledger.preferences.showGoals }, set: { value in Task { @MainActor in  await store.update { $0.preferences.showGoals = value }  } }))
                    Toggle(L("Регулярные платежи"), isOn: Binding(get: { ledger.preferences.showRecurring }, set: { value in Task { @MainActor in  await store.update { $0.preferences.showRecurring = value }  } }))
                }.font(.callout)
            }
            Card {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        SectionHeading(title: L("Курсы валют"), subtitle: L("1 единица валюты = указанная сумма в \(ledger.preferences.baseCurrency)"))
                        Spacer()
                        if !store.isDemo, ledger.preferences.automaticRates {
                            if store.updatingRates { ProgressView().controlSize(.small) }
                            Button(store.updatingRates ? L("Обновляем…") : L("Обновить сейчас")) { Task { await store.refreshExchangeRates(force: true) } }.disabled(store.updatingRates)
                        }
                    }
                    if !store.isDemo {
                        Toggle(L("Загружать из интернета раз в день"), isOn: Binding(get: { ledger.preferences.automaticRates }, set: { value in Task { @MainActor in await store.setAutomaticRates(value) } })).font(.callout)
                        if ledger.preferences.automaticRates {
                            HStack(spacing: 8) {
                                Link(L("Курсы: ExchangeRate-API"), destination: ExchangeRateSnapshot.providerURL)
                                if let snapshot = ledger.preferences.exchangeRateSnapshot {
                                    Text(L("· Получены \(snapshot.fetchedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(L10n.locale)))"))
                                }
                            }.font(.caption).foregroundStyle(.secondary)
                            if let snapshot = ledger.preferences.exchangeRateSnapshot {
                                Text(L("Дата курсов: \(quoteDate(snapshot.quotedAt)). Без интернета используются последние сохраненные значения.")).font(.caption).foregroundStyle(.secondary)
                            } else if !store.updatingRates {
                                Text(L("Курсы еще не загружены. При подключении к интернету загрузка начнется автоматически.")).font(.caption).foregroundStyle(.secondary)
                            }
                            if let error = store.rateUpdateError {
                                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    ForEach(displayedCurrencies, id: \.self) { code in
                        HStack {
                            IconTile(icon: "banknote", color: "blue", size: 30)
                            Text("1 \(code)").font(.callout.weight(.medium)); Image(systemName: "equal").foregroundStyle(.secondary)
                            FinancialText("\(rateText(ledger.preferences.rates[code] ?? 1)) \(ledger.preferences.baseCurrency)").font(.callout).monospacedDigit()
                            Spacer()
                            if !ledger.preferences.automaticRates, code != ledger.preferences.baseCurrency {
                                Button(L("Изменить")) { rateCurrency = code; rateAmount = Money.plain(ledger.preferences.rates[code] ?? 1) }
                                Button(role: .destructive) { Task { @MainActor in  await store.update { $0.preferences.rates.removeValue(forKey: code) }  } } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                            }
                        }
                    }
                    if !ledger.preferences.automaticRates {
                        if ledger.preferences.exchangeRateSnapshot != nil {
                            Link(L("Курсы: ExchangeRate-API"), destination: ExchangeRateSnapshot.providerURL).font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        HStack { TextField(L("Код, например USD"), text: $rateCurrency).frame(width: 150).textFieldStyle(.roundedBorder); Text("="); TextField(L("Курс"), text: $rateAmount).financialField().frame(width: 160).textFieldStyle(.roundedBorder); Text(ledger.preferences.baseCurrency).foregroundStyle(.secondary); Spacer(); Button(L("Сохранить курс")) { saveRate() }.buttonStyle(.borderedProminent).disabled((Money.parse(rateAmount) ?? 0) <= 0 || !Locale.commonISOCurrencyCodes.contains(rateCurrency.trimmingCharacters(in: .whitespaces).uppercased()) || rateCurrency.trimmingCharacters(in: .whitespaces).uppercased() == ledger.preferences.baseCurrency) }
                    }
                    Text(L("Курсы применяются ко всем операциям, включая историю. Для налогового учета и исторических курсов эта версия не предназначена.")).font(.caption).foregroundStyle(.secondary)
                    if store.isDemo { Text(L("В демо используются условные курсы, не рыночные котировки.")).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 20) {
                    SectionHeading(title: L("AI-помощник"), subtitle: L("Импорт выписок и скриншотов без обязательной настройки MCP"))
                    HStack { Text(L("AI-агент для импорта")); Spacer(); Picker(L("AI-агент"), selection: Binding(get: { ledger.preferences.aiAgent }, set: { value in Task { @MainActor in  await store.update { $0.preferences.aiAgent = value }  } })) { ForEach(AIAgent.allCases) { Text(L($0.title)).tag($0.rawValue) } }.labelsHidden().frame(width: 180) }
                    HStack { Label(L("Промпт для CSV"), systemImage: "text.bubble"); Spacer(); Button(L("Скопировать")) { copyAIPrompt("mora-csv", includeContext: true) } }
                    HStack { Label(L("Инструкция для MCP"), systemImage: "point.3.connected.trianglepath.dotted"); Spacer(); Button(L("Скопировать")) { copyAIPrompt("mora-mcp", includeContext: true) } }
                    Text(L("Агент использует доступное подключение или встроенный компонент Mora. Без доступа к Mac подготовит CSV. Промпт включает названия счетов, их валюты и категории.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 20) {
                    SectionHeading(title: L("Данные и резервные копии"), subtitle: cloud.householdID == nil ? L("Счета и операции хранятся на вашем Mac") : L("На Mac хранится копия общей облачной базы"))
                    HStack { Label(L("Экспорт всех операций в CSV"), systemImage: "tablecells"); Spacer(); Button(L("Экспортировать")) { Task { @MainActor in  await store.exportCSV()  } } }
                    HStack { Label(L("Полная резервная копия"), systemImage: "externaldrive"); Spacer(); Button(L("Сохранить JSON")) { Task { @MainActor in  await store.backup()  } }; Button(L("Восстановить…")) { Task { @MainActor in  restoreLedger = await store.readBackup()  } } }
                    HStack { Label(L("Образец CSV"), systemImage: "doc.text"); Spacer(); Button(L("Сохранить образец")) { saveTemplate() } }
                    Divider()
                    Text(L("Резервная копия JSON включает данные, настройки и историю изменений.")).font(.caption).foregroundStyle(.secondary)
                    if !store.isDemo { HStack { Text(store.fileURL.path).font(.system(size: 10)).foregroundStyle(.tertiary).textSelection(.enabled); Spacer(); Button(L("Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL]) } } }
                }
            }
            ChangeHistoryCard()
            MerchantSettingsCard()
            CloudSettingsCard()
            SupportSettingsCard()
            Card {
                HStack { Image(systemName: "leaf.fill").font(.system(size: 32)).foregroundStyle(Color.moraGreen); VStack(alignment: .leading, spacing: 6) { Text("Mora \(version)").font(.headline); Text(L("Личный учет финансов на Mac.")).font(.caption).foregroundStyle(.secondary) }; Spacer() }
            }
        }
        .onAppear { selectedBase = ledger.preferences.baseCurrency }
        .confirmationDialog(L("Заменить текущие данные резервной копией?"), isPresented: Binding(get: { restoreLedger != nil }, set: { if !$0 { restoreLedger = nil } }), titleVisibility: .visible) { if let backup = restoreLedger { Button(L("Восстановить \(backup.transactions.count) операций")) { Task { @MainActor in  await store.restore(backup); selectedBase = store.ledger.preferences.baseCurrency; restoreLedger = nil  } } } } message: { Text(L("Копия проверена. Текущие данные будут заменены; предыдущая версия сохранится в автоматической резервной копии. При необходимости сначала экспортируйте текущую копию.")) }
    }
    private func rateText(_ rate: Decimal) -> String {
        let formatter = NumberFormatter(); formatter.locale = L10n.locale
        formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 6
        return formatter.string(from: rate as NSDecimalNumber) ?? Money.plain(rate)
    }
    private func quoteDate(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = L10n.locale
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }
    private func saveRate() { Task { @MainActor in  guard let rate = Money.parse(rateAmount), rate > 0 else { return }; let code = rateCurrency.trimmingCharacters(in: .whitespaces).uppercased(); if await store.update({ $0.preferences.rates[code] = rate }) { rateAmount = ""; store.notice = L("Курс \(code) обновлен") }  } }
    private func copyAIPrompt(_ name: String, includeContext: Bool) { Task { @MainActor in
        do {
            let context = store.isDemo ? Ledger.empty : ledger
            let directory = store.fileURL.deletingLastPathComponent()
            let text = try await BackgroundWork.shared.perform { try AIPrompt.text(name, ledger: context, includeContext: includeContext, dataDirectory: directory) }
            AIPrompt.copy(text)
            store.notice = L("Промпт скопирован")
        } catch { store.error = error.localizedDescription }
    } }
    private func saveTemplate() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "Mora-example.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = L("date,merchant,amount,currency,account,category,type,note,tags,id,to_account,to_amount\r\n\(Dates.string(Date())),Продукты,-1250.50,RUB,Основной счет,Продукты,expense,Покупки на неделю,личное,example-001,,\r\n")
        Task { @MainActor in
            do { try await BackgroundWork.shared.perform { try text.write(to: url, atomically: true, encoding: .utf8) } }
            catch { store.error = error.localizedDescription }
        }
    }
}
