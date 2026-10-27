import SwiftUI
import FinanceCore

/// Each incoming purchase owns fresh editor state, even when the sheet is reused.
struct WalletReviewForm: View {
    @EnvironmentObject private var store: FinanceStore
    let capture: CloudCapture

    var body: some View {
        TransactionEditor(walletCapture: capture, ledger: store.ledger)
            .id(capture.id)
    }
}

struct TransactionsView: View {
    @EnvironmentObject var store: FinanceStore
    @Binding var sheet: EditorSheet?
    @Binding var filters: TransactionSearch
    @State private var presentation = TransactionListPresentation()
    private var selection: Set<UUID> {
        get { presentation.selection }
        nonmutating set { presentation.selection = newValue }
    }
    @State private var confirmDelete = false
    @State private var detailsTransaction: Transaction?
    @Environment(\.colorScheme) private var scheme
    private var rows: [Transaction] { presentation.rows }
    private var hasLoadedRows: Bool { presentation.hasLoadedRows }
    private var visibleIDs: Set<UUID> { presentation.visibleIDs }
    private var income: Decimal { presentation.income }
    private var expense: Decimal { presentation.expense }
    private struct SearchRequest: Equatable, Sendable {
        let query: TransactionSearch
        let revision: UInt64
    }
    private var searchRequest: SearchRequest {
        SearchRequest(query: filters, revision: store.revision)
    }
    var body: some View {
        VStack(spacing: CardLayout.spacing) {
            filterBar
            VStack(alignment: .leading, spacing: 0) {
                TransactionListHeader(rowCount: rows.count, selectionCount: selection.count,
                    allSelected: Binding(get: { !rows.isEmpty && visibleIDs.count <= selection.count && visibleIDs.isSubset(of: selection) },
                        set: { selection = $0 ? visibleIDs : [] })) {
                    bulkActions
                }.opacity(hasLoadedRows ? 1 : 0)
                Divider()
                if !hasLoadedRows {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty {
                    EmptyState(icon: "arrow.left.arrow.right", title: L("Операций не найдено"), text: filters.text.isEmpty ? L("Добавьте операцию или импортируйте выписку. Также можно изменить фильтры и период.") : L("Попробуйте другой запрос или сбросьте фильтры."), button: L("Добавить операцию")) { sheet = .transaction(nil) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TransactionRowsList(rows: rows, selection: Binding(get: { selection }, set: { selection = $0 }),
                                        sheet: $sheet, detailsTransaction: $detailsTransaction,
                                        duplicating: presentation.duplicating, duplicate: duplicateTransactions)
                }
                Divider()
                HStack {
                    Text(L("По текущему фильтру")).foregroundStyle(.secondary)
                    Spacer()
                    FinancialText(L("Доходы: \(DisplayMoney.string(income, currency: store.ledger.preferences.baseCurrency))"))
                    FinancialText(L("Расходы: \(DisplayMoney.string(expense, currency: store.ledger.preferences.baseCurrency))"))
                }.font(.caption).padding(.horizontal, 22).padding(.vertical, 16).opacity(hasLoadedRows ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(scheme == .dark ? Color(nsColor: .controlBackgroundColor) : .white)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.055), lineWidth: 1))
        }
        .sheet(item: $detailsTransaction) { transaction in
            TransactionDetailsView(transaction: store.ledger.transactions.first { $0.id == transaction.id } ?? transaction, ledger: store.ledger)
        }
        .focusedSceneValue(\.exportFilteredTransactions, {
            let visibleRows = rows
            Task { @MainActor in await store.exportCSV(visibleRows) }
        })
        .task(id: searchRequest) {
            let request = searchRequest, snapshot = store.ledger.withoutChangeHistory()
            do {
                if !request.query.text.isEmpty { try await Task.sleep(for: .milliseconds(150)) }
                let result = try await BackgroundWork.shared.perform { try request.query.prepare(in: snapshot) }
                guard !Task.isCancelled, request == searchRequest else { return }
                AppMotion.update(using: AppMotion.list) { presentation.apply(result) }
            } catch is CancellationError { }
            catch { presentation.failedRefresh(); store.error = error.localizedDescription }
        }
        .confirmationDialog(L("Удалить \(selection.count) операций?"), isPresented: $confirmDelete, titleVisibility: .visible) { Button(L("Удалить операции"), role: .destructive) { Task { @MainActor in
            let result = await store.change { [selection] ledger -> (Bool, ChangeDescription) in
                let before = ledger
                ledger.transactions.removeAll { selection.contains($0.id) }
                guard ledger.transactions.count != before.transactions.count else { return (false, ChangeDescription(title: "", detail: "")) }
                return (true, ChangeDescriptions.between(before, ledger))
            }
            if let (deleted, description) = result, deleted {
                store.showNotice(description.title, detail: description.detail, actions: store.undoNotificationActions)
                selection = []
            }
        } } } message: { Text(L("Это изменение можно отменить через меню «Финансы».")) }
    }

    @ViewBuilder private var bulkActions: some View {
        Menu(L("Назначить категорию")) {
            ForEach(store.ledger.categories) { category in
                Button(category.name + (category.kind == .income ? L(" · доход") : "")) {
                    Task { @MainActor in
                        await store.update { [selection] ledger in
                            for index in ledger.transactions.indices where selection.contains(ledger.transactions[index].id) && ledger.transactions[index].kind == category.kind {
                                ledger.transactions[index].categoryID = category.id
                            }
                        }
                        selection = []
                    }
                }
            }
            Divider()
            Button(L("Убрать категорию")) {
                Task { @MainActor in
                    await store.update { [selection] ledger in
                        for index in ledger.transactions.indices where selection.contains(ledger.transactions[index].id) {
                            ledger.transactions[index].categoryID = nil
                        }
                    }
                    selection = []
                }
            }
        }.fixedSize()
        Button(L("Дублировать")) { duplicateTransactions(selection) }.disabled(presentation.duplicating)
        Button(L("Удалить"), role: .destructive) { confirmDelete = true }
        Button(L("Снять выбор")) { selection = [] }
    }

    private var filterBar: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(L("Поиск по описанию, заметкам и тегам"), text: $filters.text).textFieldStyle(.plain)
                    }.font(.body).padding(.horizontal, 12).frame(height: 40).modifier(TransactionFilterSurface())
                    Button { sheet = .transaction(nil) } label: { Label(L("Добавить"), systemImage: "plus") }
                        .buttonStyle(TransactionToolbarButtonStyle(prominent: true))
                    Button { let visibleRows = rows; Task { @MainActor in await store.exportCSV(visibleRows) } } label: {
                        Label(L("Экспорт CSV"), systemImage: "square.and.arrow.up")
                    }.buttonStyle(TransactionToolbarButtonStyle()).help(L("Экспортировать операции по текущему фильтру"))
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { filterMenus; dateFilters }.fixedSize()
                    VStack(alignment: .leading, spacing: 10) { filterMenus; dateFilters }
                }
            }
        }
    }

    private var categorySelection: Binding<Set<String>?> {
        Binding(get: {
            filters.categoryIDs.map { ids in
                Set(ids.map(\.uuidString)).union(filters.includesUncategorized ? ["none"] : [])
            }
        }, set: { selected in
            filters.categoryIDs = selected.map { Set($0.compactMap(UUID.init(uuidString:))) }
            filters.includesUncategorized = selected?.contains("none") == true
        })
    }

    private var filterMenus: some View {
        HStack(spacing: 10) {
            TransactionFilterChecklist(title: L("Типы"), allTitle: L("Все типы"), width: 132,
                selection: $filters.kinds, options: TransactionKind.allCases.map { FilterChoice(id: $0, title: L($0.title)) })
            TransactionFilterChecklist(title: L("Счета"), allTitle: L("Все счета"), width: 180,
                selection: $filters.accountIDs, options: store.ledger.accounts.map { FilterChoice(id: $0.id, title: $0.name + " · " + $0.currency) })
            TransactionFilterChecklist(title: L("Категории"), allTitle: L("Все категории"), width: 180,
                selection: categorySelection, options: [FilterChoice(id: "none", title: L("Без категории"))] + store.ledger.categories.map {
                    FilterChoice(id: $0.id.uuidString, title: $0.name + ($0.kind == .income ? L(" · доход") : ""))
                })
        }
    }

    private var dateFilters: some View {
        TransactionPeriodPicker(startDate: $filters.startDate, endDate: $filters.endDate)
    }

    private func duplicateTransactions(_ ids: Set<UUID>) {
        guard presentation.beginDuplication() else { return }
        Task { @MainActor in
            let copyIDs: Set<UUID>? = await store.change({ ledger in
                let copies = ledger.transactions.filter { ids.contains($0.id) }.map { original in
                    var copy = original
                    copy.id = UUID(); copy.externalID = nil; copy.recurrenceID = nil; copy.importBatchID = nil
                    return copy
                }
                ledger.transactions.append(contentsOf: copies)
                return Set(copies.map(\.id))
            })
            presentation.completedDuplication(copyIDs)
        }
    }
}

/// Scroll position belongs to the list, so scrolling does not invalidate the
/// filters, totals, and selection controls surrounding it.
private struct TransactionRowsList: View {
    @EnvironmentObject private var store: FinanceStore
    let rows: [Transaction]
    @Binding var selection: Set<UUID>
    @Binding var sheet: EditorSheet?
    @Binding var detailsTransaction: Transaction?
    let duplicating: Bool
    let duplicate: (Set<UUID>) -> Void
    @State private var scrollAnchor: UUID?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { t in
                    HStack(spacing: 12) {
                        Toggle(isOn: Binding(get: { selection.contains(t.id) }, set: { if $0 { selection.insert(t.id) } else { selection.remove(t.id) } })) { EmptyView() }.toggleStyle(.checkbox)
                            .labelsHidden().frame(width: 20, height: 36)
                            .accessibilityLabel(L("Выбрать: \(t.merchant)"))
                        TransactionRow(transaction: t, ledger: store.ledger, showsNote: true)
                            .contentShape(Rectangle()).onTapGesture { sheet = .transaction(t) }
                        GlassEditButton { sheet = .transaction(t) }
                    }
                    .frame(minHeight: 64)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(selection.contains(t.id) ? Color.moraGreen.opacity(0.06) : Color.clear)
                    .smoothUpdates(value: selection.contains(t.id))
                    .overlay(alignment: .bottom) {
                        if t.id != rows.last?.id { Divider().padding(.leading, 18).opacity(0.55) }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    .contextMenu {
                        Button(L("Подробности операции")) { detailsTransaction = t }
                        Divider()
                        Button(L("Редактировать")) { sheet = .transaction(t) }
                        Button(L("Дублировать")) { duplicate([t.id]) }.disabled(duplicating)
                        if t.kind != .transfer { Button(L("Разделить по категориям")) { sheet = .split(t) } }
                        Button(L("Создать похожую")) { sheet = .similar(t) }
                        Button(L("Удалить"), role: .destructive) { Task { @MainActor in await store.deleteTransaction(t.id) } }
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $scrollAnchor, anchor: .top)
        .modifier(ConsistentScrollEdges())
    }
}

/// Selection actions replace the ordinary table header in the same footprint.
struct TransactionListHeader<Actions: View>: View {
    let rowCount: Int
    let selectionCount: Int
    @Binding var allSelected: Bool
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $allSelected) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden().frame(width: 20)
            Text(selectionCount == 0 ? L("\(rowCount) операций") : L("Выбрано: \(selectionCount)"))
                .font(.callout.weight(.medium)).lineLimit(1)
            Spacer(minLength: 8)
            if selectionCount == 0 {
                Text(L("Сумма")).font(.caption).foregroundStyle(.secondary).padding(.trailing, 48)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actions }.fixedSize()
                    Menu(L("Действия")) { actions }.fixedSize()
                }.font(.callout)
            }
        }
        .frame(height: 28)
        .padding(.horizontal, 26).padding(.vertical, 12)
        .background(selectionCount == 0 ? Color.clear : Color.moraGreen.opacity(0.08))
        .smoothUpdates(value: selectionCount)
    }
}

struct TransactionEditor: View {
    @EnvironmentObject var store: FinanceStore
    @EnvironmentObject private var cloud: CloudSync
    @Environment(\.dismiss) var dismiss
    var transaction: Transaction?
    private let walletCapture: CloudCapture?
    private let amountSuggestion: WalletReviewDraft.AmountSuggestion?
    private let newWalletCard: String?
    private let dateReference: Date
    private let rateClient: VisaRateClient
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
    @State private var saving = false
    @State private var attemptedSave = false
    @State private var newTransactionID = UUID()
    private enum RequiredField: Hashable { case merchant, amount, account, destination, destinationAmount }
    @State private var focusedAmount: RequiredField?
    private var balanceDraft: Transaction? {
        guard let amount = AmountInput.parse(amount), amount > 0, let accountID else { return nil }
        let converted = currentConversion.flatMap { try? $0.convertedAmount() }
        guard !needsConversion || converted != nil else { return nil }
        var signedAmount = kind == .income ? amount : -amount
        if standaloneTransfer { signedAmount = (transaction?.amount ?? 0) > 0 ? amount : -amount }
        return Transaction(id: newTransactionID, date: TransactionDateEditing.changingDay(of: dateReference, to: date),
                           merchant: "", amount: converted ?? signedAmount, accountID: accountID, kind: kind,
                           destinationAccountID: kind == .transfer && !standaloneTransfer ? destinationID : nil,
                           destinationAmount: kind == .transfer && !standaloneTransfer ? (sameCurrency ? amount : AmountInput.parse(destinationAmount)) : nil)
    }
    init(transaction: Transaction? = nil, template: Transaction? = nil, walletCapture: CloudCapture? = nil, ledger: Ledger? = nil,
         rateClient: VisaRateClient = .shared) {
        self.transaction = transaction
        self.rateClient = rateClient
        let transaction = transaction ?? template.map { $0.similarTransaction() }
        self.walletCapture = walletCapture
        let draft = walletCapture.map { WalletReviewDraft(capture: $0, ledger: ledger ?? .empty, locale: L10n.locale) }
        amountSuggestion = draft?.amount.isEmpty == true ? draft?.suggestion : nil
        newWalletCard = walletCapture.flatMap { $0.awaitsCardLink ? ($0.card ?? "") : nil }
        dateReference = transaction?.date ?? draft?.date ?? Date()
        _merchant = State(initialValue: transaction?.merchant ?? draft?.merchant ?? ""); _amount = State(initialValue: transaction.map { Money.plain(abs($0.conversion?.originalAmount ?? $0.amount)) } ?? draft?.prefillAmount ?? "")
        _kind = State(initialValue: transaction?.kind ?? .expense); _date = State(initialValue: dateReference)
        _accountID = State(initialValue: transaction?.accountID ?? (walletCapture == nil ? ledger?.suggestedTransactionAccountID : draft?.accountID)); _categoryID = State(initialValue: transaction?.categoryID)
        _destinationID = State(initialValue: transaction?.destinationAccountID); _destinationAmount = State(initialValue: transaction?.destinationAmount.map(Money.plain) ?? "")
        _note = State(initialValue: transaction?.note ?? draft?.note ?? ""); _tags = State(initialValue: transaction?.tags.joined(separator: ", ") ?? draft?.tags.joined(separator: ", ") ?? "")
        let initialCurrency = transaction?.conversion?.originalCurrency ?? draft?.prefillCurrency ?? ""
        _currency = State(initialValue: initialCurrency == WalletReviewDraft.unknownCurrency ? "" : initialCurrency)
    }
    private var account: Account? { accountID.flatMap { store.ledger.account($0) } }
    private var destination: Account? { destinationID.flatMap { store.ledger.account($0) } }
    private var sameCurrency: Bool { account?.currency == destination?.currency }
    @State private var suggestedCategory: UUID?
    @State private var availableTags: [String] = []
    private struct CategoryQuery: Equatable, Sendable {
        let merchant: String
        let kind: TransactionKind
        let revision: UInt64
    }
    private var categoryQuery: CategoryQuery { CategoryQuery(merchant: merchant, kind: kind, revision: store.revision) }
    private var automaticCategoryLabel: String {
        suggestedCategory.flatMap { store.ledger.category($0) }.map { L("Автоматически: \($0.name)") } ?? L("Автоматически / без категории")
    }
    private var standaloneTransfer: Bool { transaction?.isStandaloneTransfer == true && kind == .transfer }
    private var purchaseCurrency: String { currency.isEmpty ? (account?.currency ?? "") : currency }
    private var currencySelection: Binding<String> {
        Binding(get: { purchaseCurrency }, set: { currency = $0 == account?.currency ? "" : $0 })
    }
    private var needsConversion: Bool { kind != .transfer && account != nil && purchaseCurrency != account?.currency }
    private var quoteKey: String { "\(purchaseCurrency)|\(account?.currency ?? "")|\(Dates.string(date))|\(kind.rawValue)|\(accountID?.uuidString ?? "")|\(Money.plain(account?.bankFeePercent ?? 0))" }
    private var validationErrors: [RequiredField: String] {
        var errors: [RequiredField: String] = [:]
        if merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors[.merchant] = L("Обязательно к заполнению") }
        if amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors[.amount] = L("Обязательно к заполнению") }
        else if (AmountInput.parse(amount) ?? 0) <= 0 { errors[.amount] = L("Введите сумму больше нуля.") }
        if let error = conversionAmountError { errors[.amount] = error }
        if account == nil { errors[.account] = L("Обязательно к заполнению") }
        if kind == .transfer && !standaloneTransfer {
            if destination == nil { errors[.destination] = L("Обязательно к заполнению") }
            else if destinationID == accountID { errors[.destination] = L("Выберите другой счет для зачисления.") }
            if destination != nil && account != nil && !sameCurrency && (AmountInput.parse(destinationAmount) ?? 0) <= 0 {
                errors[.destinationAmount] = destinationAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L("Обязательно к заполнению") : L("Введите сумму зачисления больше нуля.")
            }
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
        ModalFrame(title: walletCapture != nil ? L("Проверить покупку") : transaction == nil ? L("Новая операция") : L("Редактировать операцию"), canSave: !saving && (walletCapture == nil || !cloud.busy), save: save) {
            VStack(alignment: .leading, spacing: 18) {
                if store.ledger.accounts.isEmpty { Text(L("Сначала добавьте счет в разделе «Счета».")).foregroundStyle(.orange) }
                if let card = newWalletCard {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Новая карта: \(card.isEmpty ? L("без названия") : card)")).font(.callout.weight(.semibold))
                            Text(L("Выбранный счет запомнится для этой карты. Следующие покупки ею будут записываться туда автоматически.")).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "creditcard").foregroundStyle(Color.moraGreen) }
                }
                if let suggestion = amountSuggestion {
                    Label(L("Wallet не передал сумму. Подставлена сумма прошлой покупки «\(suggestion.merchant)» от \(suggestion.date.formatted(date: .abbreviated, time: .omitted)). Проверьте ее."),
                          systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.orange)
                }
                Form {
                    LabeledContent(kind == .transfer && !standaloneTransfer ? L("Со счета") : L("Счет")) {
                        Picker(L("Счет"), selection: $accountID) { Text(L("Выберите счет")).tag(Optional<UUID>.none); ForEach(store.ledger.accounts.filter { !$0.archived || $0.id == transaction?.accountID }) { Text($0.name + " · " + $0.currency).tag(Optional($0.id)) } }
                            .labelsHidden().modifier(TransactionFieldValidation(invalid: showsError(.account)))
                    }.foregroundStyle(showsError(.account) ? Color.red : Color.primary)
                    validationMessage(.account)
                    Picker(L("Тип"), selection: $kind) { ForEach(TransactionKind.allCases) { Text(L($0.title)).tag($0) } }.pickerStyle(.segmented).disabled(standaloneTransfer)
                    LabeledContent(L("Сумма")) {
                        if kind == .transfer {
                            transferAmountField(L("Сумма"), text: $amount, currency: account?.currency, field: .amount)
                        } else {
                            DecimalAmountField(title: L("Сумма"), text: $amount, onSubmit: save).financialField()
                                .modifier(TransactionFieldValidation(invalid: showsError(.amount)))
                        }
                    }.foregroundStyle(showsError(.amount) ? Color.red : Color.primary)
                    validationMessage(.amount)
                    if account != nil && kind != .transfer {
                        PurchaseCurrencyPicker(selection: currencySelection, accounts: store.ledger.accounts)
                    }
                    LabeledContent(L("Название")) {
                        TextField(L("Название"), text: $merchant).labelsHidden()
                            .modifier(TransactionFieldValidation(invalid: showsError(.merchant)))
                    }.foregroundStyle(showsError(.merchant) ? Color.red : Color.primary)
                    validationMessage(.merchant)
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
                                transferAmountField(L("Сумма зачисления"), text: $destinationAmount, currency: destination?.currency, field: .destinationAmount)
                            }.foregroundStyle(showsError(.destinationAmount) ? Color.red : Color.primary)
                            validationMessage(.destinationAmount)
                        }
                    } else {
                        Picker(L("Категория"), selection: $categoryID) { Text(automaticCategoryLabel).tag(Optional<UUID>.none); ForEach(store.ledger.categories.filter { $0.kind == kind }) { Text($0.name).tag(Optional($0.id)) } }
                    }
                    TextField(L("Заметка"), text: $note, axis: .vertical).lineLimit(2...4)
                    TransactionTagsField(text: $tags, available: availableTags)
                }.disabled(saving)
                transactionPreview
                if kind == .transfer { Text(L("Переводы изменяют остатки счетов и не включаются в доходы и расходы.")).font(.caption).foregroundStyle(.secondary) }
                if date > Date() { Text(L("Будущая операция попадет в отчет за свой месяц. Остатки счетов изменятся в дату операции.")).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .interactiveDismissDisabled(saving)
        .task(id: quoteKey) {
            await refreshConversion()
        }
        .task(id: categoryQuery) {
            let query = categoryQuery, snapshot = store.ledger.withoutChangeHistory()
            do {
                try await Task.sleep(for: .milliseconds(150)); try Task.checkCancellation()
                let result = await BackgroundWork.shared.perform { snapshot.suggestedCategory(merchant: query.merchant, kind: query.kind) }
                guard !Task.isCancelled, query == categoryQuery else { return }
                suggestedCategory = result
            } catch { }
        }
        .task(id: store.revision) {
            let revision = store.revision, snapshot = store.ledger.withoutChangeHistory()
            let tags = await BackgroundWork.shared.perform { snapshot.availableTags }
            guard !Task.isCancelled, revision == store.revision else { return }
            availableTags = tags
        }
        .onChange(of: kind) { _, new in if store.ledger.category(categoryID)?.kind != new { categoryID = nil } }
        .onChange(of: accountID) { _, id in if destinationID == id { destinationID = nil } }
    }
    private func transferAmountField(_ title: String, text: Binding<String>, currency: String?, field: RequiredField) -> some View {
        HStack(spacing: 8) {
            DecimalAmountField(title: title, text: text, plain: true, currency: currency,
                onEditingChanged: { focusedAmount = $0 ? field : nil }, onSubmit: save).financialField()
            if let currency {
                Text(currency).font(.callout.weight(.medium)).foregroundStyle(.secondary).fixedSize()
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
            focusedAmount == field ? Color.moraGreen : Color.primary.opacity(0.12), lineWidth: focusedAmount == field ? 2 : 1))
        .modifier(TransactionFieldValidation(invalid: showsError(field)))
    }
    @MainActor private func refreshConversion() async {
        conversion = nil; conversionError = nil; conversionKey = quoteKey
        guard needsConversion, let account else { return }
        let key = quoteKey
        let amount = AmountInput.parse(amount) ?? 1
        let signed = kind == .income ? amount : -amount
        do {
            let quote: CardConversion
            if transaction?.accountID == accountID, let saved = transaction?.conversion, saved.originalAmount == signed,
               saved.originalCurrency == purchaseCurrency, saved.accountCurrency == account.currency,
               Dates.string(saved.date) == Dates.string(date) { quote = saved }
            else {
                let rate = try await rateClient.rate(from: purchaseCurrency, to: account.currency, date: date)
                quote = CardConversion(originalAmount: signed, originalCurrency: purchaseCurrency, accountCurrency: account.currency,
                                       rate: rate, date: Calendar.current.startOfDay(for: date)).applyingFee(of: account)
            }
            try Task.checkCancellation()
            guard key == quoteKey else { return }
            conversion = quote; conversionKey = key
        } catch is CancellationError { }
        catch { guard key == quoteKey else { return }; conversionError = error.localizedDescription }
    }
    private var currentConversion: CardConversion? {
        guard conversionKey == quoteKey, var quote = conversion, let amount = AmountInput.parse(amount), amount > 0 else { return nil }
        let signed = kind == .income ? amount : -amount
        if quote.originalAmount != signed, let account {
            quote.originalAmount = signed
            quote = quote.applyingFee(of: account)
        }
        return quote
    }

    private var conversionAmountError: String? {
        guard let quote = currentConversion else { return nil }
        do { _ = try quote.convertedAmount(); return nil } catch { return error.localizedDescription }
    }

    private var transactionPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            TransactionBalancePreview(draft: balanceDraft, originalID: transaction?.id,
                                      account: account, destination: kind == .transfer && !standaloneTransfer ? destination : nil,
                                      kind: kind)
            if needsConversion { conversionPreview }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Measure only the three lines that the quote actually needs. Loading and
    // error states overlay those lines, so neither adds blank space or moves buttons.
    private var conversionPreview: some View {
        let quote = currentConversion
        let converted = quote.flatMap { try? $0.convertedAmount() }
        let ready = converted != nil
        return VStack(alignment: .leading, spacing: 5) {
            FinancialText("\(kind == .income ? L("Будет зачислено") : L("Будет списано")): \(converted.map { DisplayMoney.string(abs($0), currency: quote?.accountCurrency ?? "") } ?? "—")")
                .font(.callout.weight(.semibold))
            FinancialText(L("Visa · 1 \(quote?.originalCurrency ?? purchaseCurrency) = \(quote.map { Money.plain($0.rate) } ?? "—") \(quote?.accountCurrency ?? account?.currency ?? "") · \(Dates.string(quote?.date ?? date))"))
                .font(.caption).foregroundStyle(.secondary)
            Text((quote?.feePercent ?? 0) == 0 ? L("Без банковской комиссии") : L("Банковская комиссия: \(Money.plain(quote?.feePercent ?? 0))% · включена в сумму"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(ready ? 1 : 0).accessibilityHidden(!ready)
        .overlay(alignment: .topLeading) {
            if !ready {
                VStack(alignment: .leading, spacing: 5) {
                    if let error = conversionAmountError {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                    } else if let conversionError, conversionKey == quoteKey {
                        Text(conversionError).font(.caption).foregroundStyle(.red).lineLimit(2)
                        Button(L("Повторить получение курса")) { Task { await refreshConversion() } }.controlSize(.small)
                    } else if (AmountInput.parse(amount) ?? 0) > 0 {
                        ProgressView(L("Получаем курс Visa…")).controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .smoothUpdates(value: conversionKey)
        .smoothUpdates(value: ready)
        .smoothUpdates(value: conversionError)
    }

    private func makeDraft() -> Transaction? {
        guard let amount = AmountInput.parse(amount), amount > 0, let accountID else { return nil }
        var value = transaction ?? Transaction(id: newTransactionID, date: date, merchant: merchant, amount: -amount, accountID: accountID)
        value.date = TransactionDateEditing.changingDay(of: dateReference, to: date); value.merchant = merchant.trimmingCharacters(in: .whitespaces); value.amount = kind == .income ? amount : -amount; value.kind = kind; value.accountID = accountID
        if standaloneTransfer { value.amount = (transaction?.amount ?? 0) > 0 ? amount : -amount }
        value.categoryID = kind == .transfer ? nil : categoryID
        value.destinationAccountID = kind == .transfer && !standaloneTransfer ? destinationID : nil; value.destinationAmount = kind == .transfer && !standaloneTransfer ? (sameCurrency ? amount : AmountInput.parse(destinationAmount)) : nil
        value.note = note; value.tags = TransactionTags.parse(tags).sorted()
        value.conversion = nil
        if needsConversion, let conversion = currentConversion, let converted = try? conversion.convertedAmount() {
            value.amount = converted; value.conversion = conversion
        }
        return value
    }

    private func save() {
        guard !saving else { return }
        // Commit AppKit's native field editor before dismissing the sheet.
        NSApp.keyWindow?.makeFirstResponder(nil)
        attemptedSave = true
        guard canSave, let value = makeDraft() else { return }
        // Capture immutable inputs; this work outlives the SwiftUI sheet task.
        let conversionAccount = needsConversion && value.conversion == nil ? account : nil
        let purchaseCurrency = purchaseCurrency, quoteDate = date
        let cloud = cloud, rateClient = rateClient
        let review: (@MainActor (Transaction) async throws -> Void)?
        if let capture = walletCapture {
            review = { value in
                guard await cloud.review(capture, transaction: value, reportError: false) else {
                    throw LedgerError.invalid(cloud.error ?? L("Не удалось сохранить операцию"))
                }
            }
        } else { review = nil }
        saving = store.enqueueTransaction(value, original: transaction, prepare: { value in
            guard let account = conversionAccount else { return value }
            var prepared = value
            let quote = try await rateClient.conversion(amount: value.amount, from: purchaseCurrency,
                to: account.currency, date: quoteDate).applyingFee(of: account)
            prepared.amount = try quote.convertedAmount(); prepared.conversion = quote
            return prepared
        }, review: review)
        if saving { dismiss() }
    }

}

// Keep asynchronous balance updates local to the preview, away from the form's input state.
private struct TransactionBalancePreview: View {
    @EnvironmentObject private var store: FinanceStore
    let draft: Transaction?
    let originalID: UUID?
    let account: Account?
    let destination: Account?
    let kind: TransactionKind
    @State private var balances: [UUID: Decimal] = [:]
    @State private var completedQuery: Query?

    private struct Query: Equatable {
        let draft: Transaction?
        let revision: UInt64
    }
    private var query: Query { Query(draft: draft, revision: store.revision) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let account { balanceLine(account) }
            if let destination { balanceLine(destination) }
        }
        .smoothUpdates(value: balances)
        .task(id: query) {
            let requested = query, originalID = originalID
            guard let draft = requested.draft else { balances = [:]; completedQuery = requested; return }
            let snapshot = store.ledger.withoutChangeHistory()
            let through = max(Date(), draft.date)
            let result = await BackgroundWork.shared.perform {
                guard !Task.isCancelled else { return [UUID: Decimal]() }
                var values: [UUID: Decimal] = [:]
                for id in [draft.accountID, draft.destinationAccountID].compactMap({ $0 }) {
                    if let account = snapshot.account(id) {
                        values[id] = snapshot.projectedBalance(account, replacing: originalID, with: draft, through: through)
                    }
                }
                return values
            }
            guard !Task.isCancelled, requested == query else { return }
            balances = result; completedQuery = requested
        }
    }

    private func balanceLine(_ account: Account) -> some View {
        HStack {
            Text(kind == .transfer ? account.name : L("Баланс после операции")).lineLimit(1)
            Spacer()
            if completedQuery == query, let value = balances[account.id] {
                FinancialText(DisplayMoney.string(value, currency: account.currency)).fontWeight(.semibold)
            } else { FinancialText("— \(account.currency)").foregroundStyle(.secondary) }
        }.font(.callout)
    }
}

private struct PurchaseCurrencyPicker: View {
    @Binding var selection: String
    let accounts: [Account]
    private static let codes = Locale.commonISOCurrencyCodes.sorted()
    var body: some View {
        let preferred = Set(accounts.map(\.currency))
        Picker(L("Валюта покупки"), selection: $selection) {
            ForEach(Self.codes.filter { preferred.contains($0) }, id: \.self) { Text($0).tag($0) }
            if !preferred.isEmpty { Divider() }
            ForEach(Self.codes.filter { !preferred.contains($0) }, id: \.self) { Text($0).tag($0) }
        }
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
    @State private var saving = false
    @EnvironmentObject var store: FinanceStore
    @Environment(\.dismiss) var dismiss
    var transaction: Transaction
    @State private var firstAmount = ""
    @State private var firstCategory: UUID?
    @State private var secondCategory: UUID?
    private var remainder: Decimal { abs(transaction.amount) - (AmountInput.parse(firstAmount) ?? 0) }
    var body: some View {
        ModalFrame(title: L("Разделить операцию"), subtitle: transaction.merchant + " · " + DisplayMoney.string(abs(transaction.amount), currency: store.ledger.account(transaction.accountID)?.currency ?? "RUB"), canSave: (AmountInput.parse(firstAmount) ?? 0) > 0 && remainder > 0, save: save) {
            Form {
                DecimalAmountField(title: L("Сумма первой части"), text: $firstAmount, onSubmit: save).financialField()
                Picker(L("Первая категория"), selection: $firstCategory) { Text(L("Без категории")).tag(Optional<UUID>.none); ForEach(store.ledger.categories.filter { $0.kind == transaction.kind }) { Text($0.name).tag(Optional($0.id)) } }
                LabeledContent(L("Вторая часть")) { FinancialText(DisplayMoney.string(remainder, currency: store.ledger.account(transaction.accountID)?.currency ?? "RUB")) }
                Picker(L("Вторая категория"), selection: $secondCategory) { Text(L("Без категории")).tag(Optional<UUID>.none); ForEach(store.ledger.categories.filter { $0.kind == transaction.kind }) { Text($0.name).tag(Optional($0.id)) } }
                Text(L("Исходная операция будет заменена двумя частями. Общая сумма и остаток счета сохранятся.")).font(.caption).foregroundStyle(.secondary)
            }
        }.onAppear { firstCategory = transaction.categoryID }
    }
    private func save() { guard !saving else { return }; saving = true
        Task { @MainActor in defer { saving = false }
        guard let amount = AmountInput.parse(firstAmount), amount > 0, remainder > 0 else { return }
        var first = transaction, second = transaction
        let sign: Decimal = transaction.kind == .income ? 1 : -1
        first.amount = sign * amount; first.categoryID = firstCategory
        second.id = UUID(); second.amount = sign * remainder; second.categoryID = secondCategory; second.externalID = transaction.externalID.map { $0 + ":split:" + second.id.uuidString }; second.recurrenceID = nil
        if let conversion = transaction.conversion {
            let context = L("Исходная покупка: \(Money.plain(conversion.originalAmount)) \(conversion.originalCurrency); Visa \(Money.plain(conversion.rate)) на \(Dates.string(conversion.date)).")
            first.note += "\n" + context; second.note += "\n" + context
            first.conversion = nil; second.conversion = nil
        }
        if await store.update({ [first, second, transaction] ledger in
            guard ledger.transactions.first(where: { $0.id == transaction.id }) == transaction else { throw LedgerError.invalid(L("Данные изменились в другом окне или через MCP. Повторите действие с обновленными данными.")) }
            ledger.transactions.removeAll { $0.id == transaction.id }; ledger.transactions.append(contentsOf: [first, second]) }) { dismiss() }
     } }
}
