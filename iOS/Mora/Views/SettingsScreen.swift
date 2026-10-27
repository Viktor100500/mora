import SwiftUI
import FinanceCore

struct SettingsScreen: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var cloud: CloudSync
    @EnvironmentObject private var router: AppRouter
    @AppStorage("mora.hideAmounts") private var hideAmounts = false
    @State private var selectedBase = ""
    @State private var rateCurrency = "USD"
    @State private var rateAmount = ""
    @State private var exportFile: ExportFile?
    @State private var restoring = false
    @State private var restoreLedger: Ledger?
    @State private var confirmStart = false
    private var ledger: Ledger { store.ledger }
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "1.0") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }
    private var displayedCurrencies: [String] {
        Array(Set(ledger.accounts.map(\.currency) + [ledger.preferences.baseCurrency, "USD", "EUR"]))
            .filter { ledger.preferences.rates[$0] != nil }.sorted()
    }

    var body: some View {
        Form {
            Section {
                Button { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } label: {
                    LabeledContent(L("Язык интерфейса"), value: L10n.language == .russian ? "Русский" : "English")
                }.foregroundStyle(.primary)
                Picker(L("Оформление"), selection: Binding(get: { ledger.preferences.appearance }, set: { value in Task { await store.update { $0.preferences.appearance = value } } })) {
                    Text(L("Как в системе")).tag("system"); Text(L("Светлое")).tag("light"); Text(L("Темное")).tag("dark")
                }
                Toggle(L("Скрывать суммы"), isOn: $hideAmounts)
            } header: { Text(L("Интерфейс")) } footer: {
                Text(L("Язык совпадает с языком iPhone. Изменить его только для Mora можно в Настройках iPhone → Mora → Язык."))
            }
            Section {
                Picker(L("Базовая валюта"), selection: $selectedBase) {
                    ForEach(Array(Set(currencyList + Array(ledger.preferences.rates.keys))).sorted(), id: \.self) { Text($0).tag($0) }
                }
                if selectedBase != ledger.preferences.baseCurrency && !selectedBase.isEmpty {
                    Button(L("Применить: \(selectedBase)")) {
                        let base = selectedBase
                        Task { if !(await store.update { try $0.changeBaseCurrency(to: base) }) { selectedBase = ledger.preferences.baseCurrency } }
                    }
                }
            } header: { Text(L("Валюта отчетов")) } footer: {
                Text(L("При смене базовой валюты лимиты бюджетов и суммы целей пересчитываются по текущему курсу."))
            }
            ratesSection
            Section {
                Toggle(L("Бюджеты"), isOn: preference(\.showBudgets))
                Toggle(L("Цели"), isOn: preference(\.showGoals))
                Toggle(L("Регулярные платежи"), isOn: preference(\.showRecurring))
            } header: { Text(L("Дополнительные разделы")) } footer: {
                Text(L("Включите нужные разделы. Их данные сохраняются при скрытии."))
            }
            historySection
            dataSection
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "leaf.fill").font(.system(size: 30)).foregroundStyle(Color.moraGreen)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mora \(version)").font(.headline)
                        Text(L("Личный учет финансов на iPhone. Формат данных совпадает с Mora для Mac.")).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
            }
        }
        .navigationTitle(L("Настройки"))
        .onAppear { selectedBase = ledger.preferences.baseCurrency }
        .onChange(of: ledger.preferences.baseCurrency) { _, value in selectedBase = value }
        .fileExporter(isPresented: Binding(get: { exportFile != nil }, set: { if !$0 { exportFile = nil } }),
                      document: exportFile?.document, contentType: exportFile?.type ?? .json, defaultFilename: exportFile?.name) { result in
            if case .failure(let error) = result { store.error = error.localizedDescription }
            else if case .success = result { store.showToast(L("Файл сохранен")) }
        }
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): Task { restoreLedger = await store.readBackup(at: url) }
            case .failure(let error): store.error = error.localizedDescription
            }
        }
        .confirmationDialog(L("Восстановить резервную копию?"), isPresented: Binding(get: { restoreLedger != nil }, set: { if !$0 { restoreLedger = nil } }), titleVisibility: .visible) {
            if let ledger = restoreLedger {
                Button(L("Заменить данные"), role: .destructive) { Task { await store.restore(ledger); restoreLedger = nil } }
            }
        } message: {
            if let ledger = restoreLedger {
                Text(L("Счетов: \(ledger.accounts.count) · операций: \(ledger.transactions.count). Текущие данные будут заменены; это изменение можно отменить."))
            }
        }
        .confirmationDialog(L("Начать свой учет?"), isPresented: $confirmStart, titleVisibility: .visible) {
            Button(L("Начать с чистого листа")) { router.open(.welcome) }
        } message: { Text(L("Демонстрационные данные будут убраны. Затем можно добавить счета и импортировать свои операции.")) }
    }

    private func preference(_ path: WritableKeyPath<Preferences, Bool>) -> Binding<Bool> {
        Binding(get: { ledger.preferences[keyPath: path] }, set: { value in
            nonisolated(unsafe) let path = path
            Task { await store.update { $0.preferences[keyPath: path] = value } }
        })
    }

    @ViewBuilder private var ratesSection: some View {
        Section {
            if !store.isDemo {
                Toggle(L("Загружать из интернета раз в день"), isOn: Binding(get: { ledger.preferences.automaticRates }, set: { value in Task { await store.setAutomaticRates(value) } }))
                if ledger.preferences.automaticRates {
                    Button { Task { await store.refreshExchangeRates(force: true) } } label: {
                        HStack {
                            Text(store.updatingRates ? L("Обновляем…") : L("Обновить сейчас"))
                            Spacer()
                            if store.updatingRates { ProgressView() }
                        }
                    }.disabled(store.updatingRates)
                    if let error = store.rateUpdateError { Label(L(error), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                }
            }
            ForEach(displayedCurrencies, id: \.self) { code in
                LabeledContent("1 \(code)") {
                    FinancialText("\(rateText(ledger.preferences.rates[code] ?? 1)) \(ledger.preferences.baseCurrency)")
                }
                .swipeActions {
                    if !ledger.preferences.automaticRates && code != ledger.preferences.baseCurrency {
                        Button(role: .destructive) { Task { await store.update { $0.preferences.rates.removeValue(forKey: code) } } } label: { Label(L("Удалить"), systemImage: "trash") }
                    }
                }
            }
            if !ledger.preferences.automaticRates {
                HStack {
                    TextField(L("Код"), text: $rateCurrency).textInputAutocapitalization(.characters).frame(width: 70)
                    Text("=")
                    TextField(L("Курс"), text: $rateAmount).keyboardType(.decimalPad)
                    Text(ledger.preferences.baseCurrency).foregroundStyle(.secondary)
                    Button(L("Сохранить")) { saveRate() }.disabled(!validRate)
                }
            }
        } header: { Text(L("Курсы валют")) } footer: {
            if let snapshot = ledger.preferences.exchangeRateSnapshot, ledger.preferences.automaticRates {
                Text(L("Курсы: ExchangeRate-API · Получены \(snapshot.fetchedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(L10n.locale))). Без интернета используются последние сохраненные значения."))
            } else if store.isDemo {
                Text(L("В демо используются условные курсы, не рыночные котировки."))
            } else {
                Text(L("1 единица валюты = указанная сумма в \(ledger.preferences.baseCurrency)"))
            }
        }
    }

    private var validRate: Bool {
        let code = rateCurrency.trimmingCharacters(in: .whitespaces).uppercased()
        return (Money.parse(rateAmount) ?? 0) > 0 && Locale.commonISOCurrencyCodes.contains(code) && code != ledger.preferences.baseCurrency
    }
    private func saveRate() {
        guard validRate, let value = Money.parse(rateAmount) else { return }
        let code = rateCurrency.trimmingCharacters(in: .whitespaces).uppercased()
        Task { if await store.update({ $0.preferences.rates[code] = value }) { rateAmount = "" } }
    }
    private func rateText(_ value: Decimal) -> String {
        var input = value, result = Decimal()
        NSDecimalRound(&result, &input, value < 1 ? 6 : 4, .plain)
        return Money.plain(result)
    }

    @ViewBuilder private var historySection: some View {
        Section {
            Button { Task { await store.undo() } } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label(L("Отменить последнее изменение"), systemImage: "arrow.uturn.backward")
                    if let description = store.undoDescription {
                        FinancialText(description.title + (description.detail.isEmpty ? "" : " · " + description.detail.replacingOccurrences(of: "\n", with: " · ")))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }.disabled(store.undoDescription == nil)
            Button { Task { await store.redo() } } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label(L("Вернуть последнее изменение"), systemImage: "arrow.uturn.forward")
                    if let description = store.redoDescription {
                        FinancialText(description.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }.disabled(store.redoDescription == nil)
        } header: { Text(L("История изменений")) } footer: {
            Text(L("Хранятся последние 20 изменений. Автоматическая загрузка курсов не считается изменением."))
        }
    }

    @ViewBuilder private var dataSection: some View {
        Section {
            Button { Task { if let data = await store.csvExport() { exportFile = ExportFile(document: DataDocument(data: data), name: "Mora-\(Dates.string(Date())).csv", type: .commaSeparatedText) } } } label: {
                Label(L("Экспорт всех операций в CSV"), systemImage: "tablecells")
            }
            Button { Task { if let data = await store.backupData() { exportFile = ExportFile(document: DataDocument(data: data), name: "Mora-backup-\(Dates.string(Date())).json", type: .json) } } } label: {
                Label(L("Сохранить резервную копию JSON"), systemImage: "externaldrive")
            }.disabled(store.isDemo)
            Button { restoring = true } label: { Label(L("Восстановить из резервной копии…"), systemImage: "arrow.counterclockwise") }
            if store.isDemo {
                Button { confirmStart = true } label: { Label(L("Начать свой учет"), systemImage: "sparkles") }
            }
        } header: { Text(L("Данные и резервные копии")) } footer: {
            Text(cloud.householdID == nil
                 ? L("Счета и операции хранятся на этом iPhone. Резервная копия JSON совместима с Mora для Mac: так можно перенести данные между устройствами.")
                 : L("На iPhone хранится копия общей облачной базы."))
        }
    }
}
