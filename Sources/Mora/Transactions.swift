import SwiftUI
import FinanceCore

struct TransactionsView: View {
    @EnvironmentObject var store: FinanceStore
    var month: Date
    @Binding var sheet: EditorSheet?
    @State private var search = ""
    @State private var accountID: UUID?
    @State private var categoryFilter = "all"
    @State private var kindFilter = "all"
    @State private var allTime = false
    @State private var selection: Set<UUID> = []
    @State private var confirmDelete = false
    @Environment(\.colorScheme) private var scheme
    private var filtered: [Transaction] {
        let source = allTime ? store.ledger.transactions : store.reportTransactions(in: month)
        return source.filter { t in
            (accountID == nil || t.accountID == accountID || t.destinationAccountID == accountID) &&
            (kindFilter == "all" || t.kind.rawValue == kindFilter) &&
            (categoryFilter == "all" || (categoryFilter == "none" ? t.categoryID == nil && t.kind != .transfer : t.categoryID?.uuidString == categoryFilter)) &&
            (search.isEmpty || (t.merchant + " " + t.note + " " + t.tags.joined(separator: " ")).localizedCaseInsensitiveContains(search))
        }.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            if $0.merchant != $1.merchant { return $0.merchant < $1.merchant }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    var body: some View {
        // One snapshot per update; scrolling the system List doesn't refilter the ledger.
        let rows = filtered
        VStack(spacing: 18) {
            Card(padding: 16) {
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField(L("Поиск по описанию, заметкам и тегам"), text: $search).textFieldStyle(.plain) }.padding(10).background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 9))
                        Button { sheet = .transaction(nil) } label: { Label(L("Добавить"), systemImage: "plus") }.buttonStyle(.borderedProminent).tint(.moraGreen)
                        Menu { Button(L("Экспортировать найденные операции")) { store.exportCSV(rows) }; Button(L("Экспортировать все операции")) { store.exportCSV() } } label: { Image(systemName: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize().help(L("Экспорт CSV"))
                    }
                    HStack(spacing: 16) {
                        Picker(L("Тип"), selection: $kindFilter) { Text(L("Все типы")).tag("all"); ForEach(TransactionKind.allCases) { Text(L($0.title)).tag($0.rawValue) } }.labelsHidden().frame(maxWidth: 160)
                        Picker(L("Счет"), selection: $accountID) { Text(L("Все счета")).tag(Optional<UUID>.none); ForEach(store.ledger.accounts) { Text($0.name).tag(Optional($0.id)) } }.labelsHidden().frame(maxWidth: 200)
                        Picker(L("Категория"), selection: $categoryFilter) { Text(L("Все категории")).tag("all"); Text(L("Без категории")).tag("none"); ForEach(store.ledger.categories) { Text($0.name + ($0.kind == .income ? L(" · доход") : "")).tag($0.id.uuidString) } }.labelsHidden().frame(maxWidth: 220)
                        Spacer(); Toggle(L("Все время"), isOn: $allTime).toggleStyle(.switch).controlSize(.small).font(.caption)
                    }
                }
            }
            if !selection.isEmpty {
                HStack {
                    Text(L("Выбрано: \(selection.count)")).font(.callout.weight(.medium))
                    Menu(L("Назначить категорию")) {
                        ForEach(store.ledger.categories) { c in Button(c.name + (c.kind == .income ? L(" · доход") : "")) {
                            store.update { ledger in for i in ledger.transactions.indices where selection.contains(ledger.transactions[i].id) && ledger.transactions[i].kind == c.kind { ledger.transactions[i].categoryID = c.id } }
                            selection = []
                        } }
                        Divider(); Button(L("Убрать категорию")) { store.update { ledger in for i in ledger.transactions.indices where selection.contains(ledger.transactions[i].id) { ledger.transactions[i].categoryID = nil } }; selection = [] }
                    }.fixedSize()
                    Button(L("Дублировать")) { duplicateTransactions(selection) }
                    Spacer(); Button(L("Удалить"), role: .destructive) { confirmDelete = true }; Button(L("Снять выбор")) { selection = [] }
                }.padding(14).background(Color.moraGreen.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Toggle(isOn: Binding(get: { !rows.isEmpty && Set(rows.map(\.id)).isSubset(of: selection) }, set: { selection = $0 ? Set(rows.map(\.id)) : [] })) { EmptyView() }.toggleStyle(.checkbox)
                    Text(L("\(rows.count) операций")).font(.callout.weight(.medium))
                    Spacer()
                    Text(L("Описание / категория / счет")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(L("Сумма")).font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 22).padding(.vertical, 16)
                Divider()
                if rows.isEmpty {
                    EmptyState(icon: "arrow.left.arrow.right", title: L("Операций не найдено"), text: search.isEmpty ? L("Добавьте операцию или импортируйте выписку. Также можно изменить фильтры и период.") : L("Попробуйте другой запрос или сбросьте фильтры."), button: L("Добавить операцию")) { sheet = .transaction(nil) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // List owns the only scroll view on this screen. Each ID has one
                    // row, with a stable minimum height and room for long descriptions.
                    List {
                        ForEach(rows) { t in
                            HStack(spacing: 12) {
                                Toggle(isOn: Binding(get: { selection.contains(t.id) }, set: { if $0 { selection.insert(t.id) } else { selection.remove(t.id) } })) { EmptyView() }.toggleStyle(.checkbox)
                                    .accessibilityLabel(L("Выбрать: \(t.merchant)"))
                                TransactionRow(transaction: t, ledger: store.ledger, merchantLines: nil)
                                    .contentShape(Rectangle()).onTapGesture { sheet = .transaction(t) }
                                Button { sheet = .transaction(t) } label: { Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary) }.buttonStyle(.plain).help(L("Редактировать"))
                            }
                            .frame(minHeight: 72)
                            .listRowInsets(EdgeInsets(top: 4, leading: 18, bottom: 4, trailing: 18))
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button(L("Редактировать")) { sheet = .transaction(t) }
                                Button(L("Дублировать")) { duplicateTransactions([t.id]) }
                                if t.kind != .transfer { Button(L("Разделить по категориям")) { sheet = .split(t) } }
                                Button(L("Создать похожую")) { sheet = .similar(t) }
                                Button(L("Удалить"), role: .destructive) { store.deleteTransaction(t.id) }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 80)
                }
                Divider()
                let income = rows.filter { $0.kind == .income && store.ledger.isActive($0) }.reduce(Decimal(0)) { $0 + (store.ledger.value($1) ?? 0) }
                let expense = rows.filter { $0.kind == .expense && store.ledger.isActive($0) }.reduce(Decimal(0)) { $0 - (store.ledger.value($1) ?? 0) }
                HStack {
                    Text(L("По текущему фильтру")).foregroundStyle(.secondary)
                    Spacer()
                    FinancialText(L("Доходы: \(DisplayMoney.string(income, currency: store.ledger.preferences.baseCurrency))"))
                    FinancialText(L("Расходы: \(DisplayMoney.string(expense, currency: store.ledger.preferences.baseCurrency))"))
                }.font(.caption).padding(.horizontal, 22).padding(.vertical, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(scheme == .dark ? Color(nsColor: .controlBackgroundColor) : .white)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.055), lineWidth: 1))
        }
        .onChange(of: rows.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .confirmationDialog(L("Удалить \(selection.count) операций?"), isPresented: $confirmDelete, titleVisibility: .visible) { Button(L("Удалить операции"), role: .destructive) { if store.update({ $0.transactions.removeAll { selection.contains($0.id) } }) { selection = [] } } } message: { Text(L("Это изменение можно отменить через меню «Финансы».")) }
    }

    private func duplicateTransactions(_ ids: Set<UUID>) {
        var copyIDs = Set<UUID>()
        if store.update({ ledger in
            let copies = ledger.transactions.filter { ids.contains($0.id) }.map { original in
                var copy = original
                copy.id = UUID()
                copy.externalID = nil
                copy.recurrenceID = nil
                copy.importBatchID = nil
                copyIDs.insert(copy.id)
                return copy
            }
            ledger.transactions.append(contentsOf: copies)
        }) {
            selection = copyIDs
        }
    }
}

struct TransactionEditor: View {
    @EnvironmentObject var store: FinanceStore
    @EnvironmentObject private var cloud: CloudSync
    @Environment(\.dismiss) var dismiss
    var transaction: Transaction?
    private let walletCapture: CloudCapture?
    @State private var merchant: String
    @State private var amount: String
    @State private var kind: TransactionKind
    @State private var date: Date
    @State private var accountID: UUID?
    @State private var categoryID: UUID?
    @State private var destinationID: UUID?
    @State private var destinationAmount: String
    @State private var note: String
    @State private var tags: String
    @State private var currency: String
    @State private var conversion: CardConversion?
    @State private var conversionKey = ""
    @State private var conversionError: String?
    @State private var fetchingConversion = false
    @State private var saving = false
    @State private var attemptedSave = false
    @State private var saveBlocked = false
    private enum RequiredField { case merchant, amount, account, destination, destinationAmount, conversion }
    private struct EditorInput: Equatable {
        let merchant, amount, destinationAmount, note, tags, currency: String
        let kind: TransactionKind
        let date: Date
        let accountID, categoryID, destinationID: UUID?
    }
    private var editorInput: EditorInput {
        EditorInput(merchant: merchant, amount: amount, destinationAmount: destinationAmount, note: note, tags: tags,
                    currency: currency, kind: kind, date: date, accountID: accountID, categoryID: categoryID, destinationID: destinationID)
    }
    init(transaction: Transaction? = nil, template: Transaction? = nil, walletCapture: CloudCapture? = nil, ledger: Ledger? = nil) {
        self.transaction = transaction
        let transaction = transaction ?? template.map { $0.similarTransaction() }
        self.walletCapture = walletCapture
        let draft = walletCapture.map { WalletReviewDraft(capture: $0, ledger: ledger ?? .empty, locale: L10n.locale) }
        _merchant = State(initialValue: transaction?.merchant ?? draft?.merchant ?? ""); _amount = State(initialValue: transaction.map { Money.plain(abs($0.conversion?.originalAmount ?? $0.amount)) } ?? draft?.amount ?? "")
        _kind = State(initialValue: transaction?.kind ?? .expense); _date = State(initialValue: transaction?.date ?? draft?.date ?? Calendar.current.startOfDay(for: Date()))
        _accountID = State(initialValue: transaction?.accountID ?? (walletCapture == nil ? ledger?.suggestedTransactionAccountID : draft?.accountID)); _categoryID = State(initialValue: transaction?.categoryID)
        _destinationID = State(initialValue: transaction?.destinationAccountID); _destinationAmount = State(initialValue: transaction?.destinationAmount.map(Money.plain) ?? "")
        _note = State(initialValue: transaction?.note ?? draft?.note ?? ""); _tags = State(initialValue: transaction?.tags.joined(separator: ", ") ?? draft?.tags.joined(separator: ", ") ?? "")
        let initialCurrency = transaction?.conversion?.originalCurrency ?? draft?.currency ?? ""
        _currency = State(initialValue: initialCurrency == WalletReviewDraft.unknownCurrency ? "" : initialCurrency)
    }
    private var account: Account? { accountID.flatMap { store.ledger.account($0) } }
    private var destination: Account? { destinationID.flatMap { store.ledger.account($0) } }
    private var sameCurrency: Bool { account?.currency == destination?.currency }
    private var suggestedCategory: UUID? { store.ledger.suggestedCategory(merchant: merchant, kind: kind) }
    private var automaticCategoryLabel: String {
        suggestedCategory.flatMap { store.ledger.category($0) }.map { L("Автоматически: \($0.name)") } ?? L("Автоматически / без категории")
    }
    private var standaloneTransfer: Bool { transaction?.isStandaloneTransfer == true && kind == .transfer }
    private var purchaseCurrency: String { currency.isEmpty ? (account?.currency ?? "") : currency }
    private var currencySelection: Binding<String> {
        Binding(get: { purchaseCurrency }, set: { currency = $0 == account?.currency ? "" : $0 })
    }
    private var needsConversion: Bool { kind != .transfer && account != nil && purchaseCurrency != account?.currency }
    private var quoteKey: String { "\(amount)|\(purchaseCurrency)|\(account?.currency ?? "")|\(Dates.string(date))|\(kind.rawValue)|\(accountID?.uuidString ?? "")|\(Money.plain(account?.bankFeePercent ?? 0))" }
    private var validationErrors: [RequiredField: String] {
        var errors: [RequiredField: String] = [:]
        if merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors[.merchant] = L("Обязательно к заполнению") }
        if amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors[.amount] = L("Обязательно к заполнению") }
        else if (Money.parse(amount) ?? 0) <= 0 { errors[.amount] = L("Введите сумму больше нуля.") }
        if account == nil { errors[.account] = L("Обязательно к заполнению") }
        if kind == .transfer && !standaloneTransfer {
            if destination == nil { errors[.destination] = L("Обязательно к заполнению") }
            else if destinationID == accountID { errors[.destination] = L("Выберите другой счет для зачисления.") }
            if destination != nil && account != nil && !sameCurrency && (Money.parse(destinationAmount) ?? 0) <= 0 {
                errors[.destinationAmount] = destinationAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L("Обязательно к заполнению") : L("Введите сумму зачисления больше нуля.")
            }
        }
        if needsConversion && (conversion == nil || conversionKey != quoteKey || fetchingConversion) {
            errors[.conversion] = fetchingConversion ? L("Дождитесь получения курса.") : L("Для сохранения нужен курс конвертации.")
        }
        return errors
    }
    private var canSave: Bool {
        !saving && (walletCapture == nil || !cloud.busy) && validationErrors.isEmpty
    }
    private func showsError(_ field: RequiredField) -> Bool { attemptedSave && validationErrors[field] != nil }
    @ViewBuilder private func validationMessage(_ field: RequiredField) -> some View {
        if attemptedSave, let error = validationErrors[field] {
            Label(error, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.red)
        }
    }
    var body: some View {
        ModalFrame(title: walletCapture != nil ? L("Проверить покупку") : transaction == nil ? L("Новая операция") : L("Редактировать операцию"), canSave: !saveBlocked && !saving && (walletCapture == nil || !cloud.busy), save: save) {
            VStack(alignment: .leading, spacing: 18) {
                if store.ledger.accounts.isEmpty { Text(L("Сначала добавьте счет в разделе «Счета».")).foregroundStyle(.orange) }
                Form {
                    LabeledContent(kind == .transfer && !standaloneTransfer ? L("Со счета") : L("Счет")) {
                        Picker(L("Счет"), selection: $accountID) { Text(L("Выберите счет")).tag(Optional<UUID>.none); ForEach(store.ledger.accounts.filter { !$0.archived || $0.id == transaction?.accountID }) { Text($0.name + " · " + $0.currency).tag(Optional($0.id)) } }
                            .labelsHidden().modifier(TransactionFieldValidation(invalid: showsError(.account)))
                    }.foregroundStyle(showsError(.account) ? Color.red : Color.primary)
                    validationMessage(.account)
                    Picker(L("Тип"), selection: $kind) { ForEach(TransactionKind.allCases) { Text(L($0.title)).tag($0) } }.pickerStyle(.segmented).disabled(standaloneTransfer)
                    LabeledContent(L("Название")) {
                        TextField(L("Название"), text: $merchant).labelsHidden()
                            .modifier(TransactionFieldValidation(invalid: showsError(.merchant)))
                    }.foregroundStyle(showsError(.merchant) ? Color.red : Color.primary)
                    validationMessage(.merchant)
                    LabeledContent(L("Сумма")) {
                        TextField(L("Сумма"), text: $amount).labelsHidden().financialField()
                            .modifier(TransactionFieldValidation(invalid: showsError(.amount)))
                    }.foregroundStyle(showsError(.amount) ? Color.red : Color.primary)
                    validationMessage(.amount)
                    if let account {
                        if kind != .transfer {
                            Picker(L("Валюта покупки"), selection: currencySelection) {
                                ForEach(Locale.commonISOCurrencyCodes.sorted(), id: \.self) { code in Text(code).tag(code) }
                            }
                        } else {
                            LabeledContent(L("Валюта списания"), value: account.currency)
                        }
                    }
                    EuropeanDatePicker(title: L("Дата"), selection: $date)
                    if standaloneTransfer {
                        LabeledContent(L("Удаленный счет"), value: transaction?.removedTransferAccountName ?? "")
                    } else if kind == .transfer {
                        LabeledContent(L("На счет")) {
                            Picker(L("На счет"), selection: $destinationID) { Text(L("Выберите счет")).tag(Optional<UUID>.none); ForEach(store.ledger.accounts.filter { $0.id != accountID && (!$0.archived || $0.id == destinationID) }) { Text($0.name + " · " + $0.currency).tag(Optional($0.id)) } }
                                .labelsHidden().modifier(TransactionFieldValidation(invalid: showsError(.destination)))
                        }.foregroundStyle(showsError(.destination) ? Color.red : Color.primary)
                        validationMessage(.destination)
                        if !sameCurrency {
                            LabeledContent(L("Сумма зачисления")) {
                                HStack { TextField(L("Сумма зачисления"), text: $destinationAmount).labelsHidden().financialField().modifier(TransactionFieldValidation(invalid: showsError(.destinationAmount))); Text(destination?.currency ?? "").foregroundStyle(.secondary) }
                            }.foregroundStyle(showsError(.destinationAmount) ? Color.red : Color.primary)
                            validationMessage(.destinationAmount)
                        }
                    } else {
                        Picker(L("Категория"), selection: $categoryID) { Text(automaticCategoryLabel).tag(Optional<UUID>.none); ForEach(store.ledger.categories.filter { $0.kind == kind }) { Text($0.name).tag(Optional($0.id)) } }
                    }
                    TextField(L("Заметка"), text: $note, axis: .vertical).lineLimit(2...4)
                    TransactionTagsField(text: $tags, available: store.ledger.availableTags)
                }.disabled(saving)
                validationMessage(.conversion)
                if needsConversion {
                    if fetchingConversion { ProgressView(L("Получаем курс Visa…")).controlSize(.small) }
                    else if let conversion, conversionKey == quoteKey, let converted = try? conversion.convertedAmount() {
                        VStack(alignment: .leading, spacing: 5) {
                            FinancialText("\(kind == .income ? L("Будет зачислено") : L("Будет списано")): \(DisplayMoney.string(abs(converted), currency: conversion.accountCurrency))").font(.callout.weight(.semibold))
                            FinancialText(L("Visa · 1 \(conversion.originalCurrency) = \(Money.plain(conversion.rate)) \(conversion.accountCurrency) · \(Dates.string(conversion.date))")).font(.caption).foregroundStyle(.secondary)
                            Text(conversion.feePercent == 0 ? L("Без банковской комиссии") : L("Банковская комиссия: \(Money.plain(conversion.feePercent))% · включена в сумму")).font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let conversionError {
                        Text(conversionError).font(.callout).foregroundStyle(.red)
                        Button(L("Повторить получение курса")) { Task { await refreshConversion() } }
                    }
                }
                if kind == .transfer { Text(L("Переводы изменяют остатки счетов и не включаются в доходы и расходы.")).font(.caption).foregroundStyle(.secondary) }
                if date > Date() { Text(L("Будущая операция попадет в отчет за свой месяц. Остатки счетов изменятся в дату операции.")).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .task(id: quoteKey) { await refreshConversion() }
        .onChange(of: editorInput) { _, _ in saveBlocked = false }
        .onChange(of: kind) { _, new in if store.ledger.category(categoryID)?.kind != new { categoryID = nil } }
        .onChange(of: accountID) { _, id in if destinationID == id { destinationID = nil } }
    }
    @MainActor private func refreshConversion() async {
        conversion = nil; conversionError = nil; fetchingConversion = false
        guard needsConversion, let amount = Money.parse(amount), amount > 0, let account else { return }
        let key = quoteKey
        let signed = kind == .income ? amount : -amount
        fetchingConversion = true
        do {
            let quote: CardConversion
            if transaction?.accountID == accountID, let saved = transaction?.conversion, saved.originalAmount == signed,
               saved.originalCurrency == purchaseCurrency, saved.accountCurrency == account.currency,
               Dates.string(saved.date) == Dates.string(date) { quote = saved }
            else { quote = try await VisaRateClient.shared.conversion(amount: signed, from: purchaseCurrency, to: account.currency, date: date).applyingFee(of: account) }
            try Task.checkCancellation()
            guard key == quoteKey else { return }
            conversion = quote; conversionKey = key; fetchingConversion = false
        } catch is CancellationError { }
        catch { guard key == quoteKey else { return }; conversionError = error.localizedDescription; fetchingConversion = false }
    }
    private func save() {
        attemptedSave = true
        guard canSave, let amount = Money.parse(amount), amount > 0, let accountID else {
            saveBlocked = !validationErrors.isEmpty
            return
        }
        var value = transaction ?? Transaction(date: date, merchant: merchant, amount: -amount, accountID: accountID)
        value.date = walletCapture == nil ? Calendar.current.startOfDay(for: date) : date; value.merchant = merchant.trimmingCharacters(in: .whitespaces); value.amount = kind == .income ? amount : -amount; value.kind = kind; value.accountID = accountID
        if standaloneTransfer { value.amount = (transaction?.amount ?? 0) > 0 ? amount : -amount }
        value.categoryID = kind == .transfer ? nil : categoryID ?? suggestedCategory
        value.destinationAccountID = kind == .transfer && !standaloneTransfer ? destinationID : nil; value.destinationAmount = kind == .transfer && !standaloneTransfer ? (sameCurrency ? amount : Money.parse(destinationAmount)) : nil
        value.note = note; value.tags = TransactionTags.parse(tags).sorted()
        value.conversion = nil
        if needsConversion {
            guard conversionKey == quoteKey, let conversion, let converted = try? conversion.convertedAmount() else { return }
            value.amount = converted; value.conversion = conversion
        }
        if let walletCapture {
            saving = true
            Task { @MainActor in
                let success = await cloud.review(walletCapture, transaction: value)
                saving = false
                if success { dismiss() }
            }
            return
        }
        if store.saveTransaction(value, replacing: transaction?.id) { dismiss() }
    }
}

private struct TransactionFieldValidation: ViewModifier {
    let invalid: Bool
    func body(content: Content) -> some View {
        content
            .foregroundStyle(invalid ? Color.red : Color.primary)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(invalid ? Color.red.opacity(0.8) : .clear, lineWidth: 1))
    }
}

struct SplitEditor: View {
    @EnvironmentObject var store: FinanceStore
    @Environment(\.dismiss) var dismiss
    var transaction: Transaction
    @State private var firstAmount = ""
    @State private var firstCategory: UUID?
    @State private var secondCategory: UUID?
    private var remainder: Decimal { abs(transaction.amount) - (Money.parse(firstAmount) ?? 0) }
    var body: some View {
        ModalFrame(title: L("Разделить операцию"), subtitle: transaction.merchant + " · " + DisplayMoney.string(abs(transaction.amount), currency: store.ledger.account(transaction.accountID)?.currency ?? "RUB"), canSave: (Money.parse(firstAmount) ?? 0) > 0 && remainder > 0, save: save) {
            Form {
                TextField(L("Сумма первой части"), text: $firstAmount).financialField()
                Picker(L("Первая категория"), selection: $firstCategory) { Text(L("Без категории")).tag(Optional<UUID>.none); ForEach(store.ledger.categories.filter { $0.kind == transaction.kind }) { Text($0.name).tag(Optional($0.id)) } }
                LabeledContent(L("Вторая часть")) { FinancialText(DisplayMoney.string(remainder, currency: store.ledger.account(transaction.accountID)?.currency ?? "RUB")) }
                Picker(L("Вторая категория"), selection: $secondCategory) { Text(L("Без категории")).tag(Optional<UUID>.none); ForEach(store.ledger.categories.filter { $0.kind == transaction.kind }) { Text($0.name).tag(Optional($0.id)) } }
                Text(L("Исходная операция будет заменена двумя частями. Общая сумма и остаток счета сохранятся.")).font(.caption).foregroundStyle(.secondary)
            }
        }.onAppear { firstCategory = transaction.categoryID }
    }
    private func save() {
        guard let amount = Money.parse(firstAmount), amount > 0, remainder > 0 else { return }
        var first = transaction, second = transaction
        let sign: Decimal = transaction.kind == .income ? 1 : -1
        first.amount = sign * amount; first.categoryID = firstCategory
        second.id = UUID(); second.amount = sign * remainder; second.categoryID = secondCategory; second.externalID = transaction.externalID.map { $0 + ":split:" + second.id.uuidString }; second.recurrenceID = nil
        if let conversion = transaction.conversion {
            let context = L("Исходная покупка: \(Money.plain(conversion.originalAmount)) \(conversion.originalCurrency); Visa \(Money.plain(conversion.rate)) на \(Dates.string(conversion.date)).")
            first.note += "\n" + context; second.note += "\n" + context
            first.conversion = nil; second.conversion = nil
        }
        if store.update({ ledger in ledger.transactions.removeAll { $0.id == transaction.id }; ledger.transactions.append(contentsOf: [first, second]) }) { dismiss() }
    }
}
