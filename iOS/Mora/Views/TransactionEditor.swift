import SwiftUI
import FinanceCore

/// New, edited, similar and Wallet-reviewed operations share one form, as on the Mac.
struct TransactionEditor: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var cloud: CloudSync
    @Environment(\.dismiss) private var dismiss
    let transaction: Transaction?
    private let walletCapture: CloudCapture?
    private let amountSuggestion: WalletReviewDraft.AmountSuggestion?
    private let newWalletCard: String?
    private let dateReference: Date
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
    @State private var confirmDelete = false
    @State private var newTransactionID = UUID()
    @FocusState private var focus: Field?
    private enum Field: Hashable { case amount, merchant, destinationAmount, note, tags }
    private enum Required: Hashable { case merchant, amount, account, destination, destinationAmount }

    init(transaction: Transaction? = nil, template: Transaction? = nil, walletCapture: CloudCapture? = nil, ledger: Ledger) {
        self.transaction = transaction
        self.walletCapture = walletCapture
        let source = transaction ?? template.map { $0.similarTransaction() }
        let draft = walletCapture.map { WalletReviewDraft(capture: $0, ledger: ledger, locale: L10n.locale) }
        amountSuggestion = draft?.amount.isEmpty == true ? draft?.suggestion : nil
        newWalletCard = walletCapture.flatMap { $0.awaitsCardLink ? ($0.card ?? "") : nil }
        dateReference = source?.date ?? draft?.date ?? Date()
        _merchant = State(initialValue: source?.merchant ?? draft?.merchant ?? "")
        _amount = State(initialValue: source.map { Money.plain(abs($0.conversion?.originalAmount ?? $0.amount)) } ?? draft?.prefillAmount ?? "")
        _kind = State(initialValue: source?.kind ?? .expense)
        _date = State(initialValue: dateReference)
        _accountID = State(initialValue: source?.accountID ?? (walletCapture == nil ? ledger.suggestedTransactionAccountID : draft?.accountID))
        _categoryID = State(initialValue: source?.categoryID)
        _destinationID = State(initialValue: source?.destinationAccountID)
        _destinationAmount = State(initialValue: source?.destinationAmount.map(Money.plain) ?? "")
        _note = State(initialValue: source?.note ?? draft?.note ?? "")
        _tags = State(initialValue: source?.tags.joined(separator: ", ") ?? draft?.tags.joined(separator: ", ") ?? "")
        let initialCurrency = source?.conversion?.originalCurrency ?? draft?.prefillCurrency ?? ""
        _currency = State(initialValue: initialCurrency == WalletReviewDraft.unknownCurrency ? "" : initialCurrency)
    }

    private var ledger: Ledger { store.ledger }
    private var account: Account? { accountID.flatMap { ledger.account($0) } }
    private var destination: Account? { destinationID.flatMap { ledger.account($0) } }
    private var sameCurrency: Bool { account?.currency == destination?.currency }
    private var standaloneTransfer: Bool { transaction?.isStandaloneTransfer == true && kind == .transfer }
    private var purchaseCurrency: String { currency.isEmpty ? (account?.currency ?? "") : currency }
    private var needsConversion: Bool { kind != .transfer && account != nil && purchaseCurrency != account?.currency }
    private var quoteKey: String { "\(purchaseCurrency)|\(account?.currency ?? "")|\(Dates.string(date))|\(kind.rawValue)|\(accountID?.uuidString ?? "")|\(Money.plain(account?.bankFeePercent ?? 0))" }
    private var currencySelection: Binding<String> {
        Binding(get: { purchaseCurrency }, set: { currency = $0 == account?.currency ? "" : $0 })
    }
    private var suggestedCategory: UUID? {
        merchant.trimmingCharacters(in: .whitespaces).isEmpty ? nil : ledger.suggestedCategory(merchant: merchant, kind: kind)
    }
    private var title: String {
        walletCapture != nil ? L("Проверить покупку") : transaction == nil ? L("Новая операция") : L("Редактировать операцию")
    }

    private var errors: [Required: String] {
        var errors: [Required: String] = [:]
        if merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors[.merchant] = L("Обязательно к заполнению") }
        if amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors[.amount] = L("Обязательно к заполнению") }
        else if (AmountInput.parse(amount) ?? 0) <= 0 { errors[.amount] = L("Введите сумму больше нуля.") }
        if let error = conversionAmountError { errors[.amount] = error }
        if account == nil { errors[.account] = L("Обязательно к заполнению") }
        if kind == .transfer && !standaloneTransfer {
            if destination == nil { errors[.destination] = L("Обязательно к заполнению") }
            else if destinationID == accountID { errors[.destination] = L("Выберите другой счет для зачисления.") }
            if destination != nil && account != nil && !sameCurrency && (AmountInput.parse(destinationAmount) ?? 0) <= 0 {
                errors[.destinationAmount] = destinationAmount.isEmpty ? L("Обязательно к заполнению") : L("Введите сумму зачисления больше нуля.")
            }
        }
        return errors
    }

    var body: some View {
        NavigationStack {
            Form {
                notices
                Section {
                    Picker(L("Тип"), selection: $kind) {
                        ForEach(TransactionKind.allCases) { Text(L($0.title)).tag($0) }
                    }
                    .pickerStyle(.segmented).disabled(standaloneTransfer || walletCapture != nil)
                    .listRowSeparator(.hidden)
                    amountField
                    validation(.amount)
                }
                Section {
                    Picker(kind == .transfer && !standaloneTransfer ? L("Со счета") : L("Счет"), selection: $accountID) {
                        Text(L("Выберите счет")).tag(UUID?.none)
                        ForEach(ledger.accounts.filter { !$0.archived || $0.id == transaction?.accountID }) { Text($0.name + " · " + $0.currency).tag(UUID?.some($0.id)) }
                    }
                    validation(.account)
                    if kind == .transfer {
                        if standaloneTransfer {
                            LabeledContent(L("Удаленный счет"), value: transaction?.removedTransferAccountName ?? "")
                        } else {
                            Picker(L("На счет"), selection: $destinationID) {
                                Text(L("Выберите счет")).tag(UUID?.none)
                                ForEach(ledger.accounts.filter { $0.id != accountID && (!$0.archived || $0.id == destinationID) }) { Text($0.name + " · " + $0.currency).tag(UUID?.some($0.id)) }
                            }
                            validation(.destination)
                            if destination != nil && !sameCurrency {
                                HStack {
                                    TextField(L("Сумма зачисления"), text: $destinationAmount).keyboardType(.decimalPad).focused($focus, equals: .destinationAmount)
                                        .onChange(of: destinationAmount) { _, value in destinationAmount = AmountInput.filtered(value) }
                                        .financialField()
                                    Text(destination?.currency ?? "").foregroundStyle(.secondary)
                                }
                                validation(.destinationAmount)
                            }
                        }
                    } else if account != nil {
                        Picker(L("Валюта покупки"), selection: currencySelection) {
                            let preferred = Set(ledger.accounts.map(\.currency))
                            ForEach(Locale.commonISOCurrencyCodes.sorted().filter { preferred.contains($0) }, id: \.self) { Text($0).tag($0) }
                            ForEach(Locale.commonISOCurrencyCodes.sorted().filter { !preferred.contains($0) }, id: \.self) { Text($0).tag($0) }
                        }.pickerStyle(.navigationLink)
                    }
                }
                if needsConversion { Section(L("Пересчет Visa")) { conversionPreview } }
                Section {
                    TextField(L("Название"), text: $merchant).focused($focus, equals: .merchant).textInputAutocapitalization(.sentences)
                    if focus == .merchant && !merchantSuggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack { ForEach(merchantSuggestions, id: \.self) { name in chip(name) { merchant = name; focus = nil } } }
                        }
                    }
                    validation(.merchant)
                    DatePicker(L("Дата"), selection: $date, displayedComponents: .date)
                    if kind != .transfer {
                        Picker(L("Категория"), selection: $categoryID) {
                            Text(suggestedCategory.flatMap { ledger.category($0) }.map { L("Автоматически: \($0.name)") } ?? L("Автоматически / без категории")).tag(UUID?.none)
                            ForEach(ledger.categories.filter { $0.kind == kind }) { category in
                                Label { Text(category.name) } icon: { IconTile(icon: category.icon, color: category.color, size: 26) }.tag(UUID?.some(category.id))
                            }
                        }.pickerStyle(.navigationLink)
                    }
                }
                Section {
                    TextField(L("Заметка"), text: $note, axis: .vertical).lineLimit(1...4).focused($focus, equals: .note)
                    TextField(L("Теги через запятую"), text: $tags).focused($focus, equals: .tags).textInputAutocapitalization(.never)
                    let suggestions = Array(TransactionTags.suggestions(for: tags, available: ledger.availableTags).prefix(10))
                    if !suggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack { ForEach(suggestions, id: \.self) { tag in chip("#" + tag) { tags = TransactionTags.selecting(tag, in: tags, available: ledger.availableTags) } } }
                        }
                    }
                }
                balancePreview
                Section {
                    if kind == .transfer { Text(L("Переводы изменяют остатки счетов и не включаются в доходы и расходы.")) }
                    if date > Date() { Text(L("Будущая операция попадет в отчет за свой месяц. Остатки счетов изменятся в дату операции.")) }
                }.font(.footnote).foregroundStyle(.secondary).listRowBackground(Color.clear)
                if let transaction, walletCapture == nil {
                    Section {
                        Button(L("Удалить операцию"), role: .destructive) { confirmDelete = true }
                    }
                    .confirmationDialog(L("Удалить операцию «\(transaction.merchant)»?"), isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button(L("Удалить"), role: .destructive) {
                            Task { await store.deleteTransactions([transaction.id]); dismiss() }
                        }
                    }
                }
            }
            .disabled(saving)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(L("Отмена"), systemImage: "xmark") }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button(action: save) { Label(L("Сохранить"), systemImage: "checkmark") }
                            .fontWeight(.semibold).buttonStyle(.borderedProminent)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button(L("Готово")) { focus = nil } }
            }
            .interactiveDismissDisabled(saving)
            .task(id: quoteKey) {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                await refreshConversion()
            }
            .onChange(of: kind) { _, new in if ledger.category(categoryID)?.kind != new { categoryID = nil } }
            .onChange(of: accountID) { _, id in if destinationID == id { destinationID = nil } }
            .onAppear { if transaction == nil && walletCapture == nil && amount.isEmpty { focus = .amount } }
        }
    }

    @ViewBuilder private var notices: some View {
        if ledger.accounts.isEmpty {
            Section { Label(L("Сначала добавьте счет в разделе «Счета»."), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }
        if let card = newWalletCard {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Новая карта: \(card.isEmpty ? L("без названия") : card)")).font(.subheadline.weight(.semibold))
                        Text(L("Выбранный счет запомнится для этой карты. Следующие покупки ею будут записываться туда автоматически.")).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "creditcard").foregroundStyle(Color.moraGreen) }
            }
        }
        if let suggestion = amountSuggestion {
            Section {
                Label(L("Wallet не передал сумму. Подставлена сумма прошлой покупки «\(suggestion.merchant)» от \(suggestion.date.formatted(date: .abbreviated, time: .omitted)). Проверьте ее."),
                      systemImage: "clock.arrow.circlepath").font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private var amountField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(kind == .income ? "+" : kind == .expense ? "−" : "")
                .font(.system(size: 30, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            TextField("0", text: $amount)
                .keyboardType(.decimalPad)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .focused($focus, equals: .amount)
                .onChange(of: amount) { _, value in
                    let filtered = AmountInput.filtered(value)
                    if filtered != value { amount = filtered }
                }
                .financialField()
                .accessibilityLabel(L("Сумма"))
            Text(kind == .transfer ? (account?.currency ?? "") : purchaseCurrency).font(.title3.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func validation(_ field: Required) -> some View {
        if attemptedSave, let error = errors[field] {
            Label(error, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.red)
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.medium)).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.moraGreen.opacity(0.12), in: Capsule())
                .foregroundStyle(Color.moraGreen)
        }.buttonStyle(.plain)
    }

    private var merchantSuggestions: [String] {
        let query = merchant.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { return [] }
        var seen = Set<String>(), result: [String] = []
        for transaction in ledger.transactions.reversed() where transaction.kind == kind {
            let name = transaction.merchant
            guard name.localizedCaseInsensitiveContains(query), name.localizedCaseInsensitiveCompare(query) != .orderedSame,
                  seen.insert(name.lowercased()).inserted else { continue }
            result.append(name)
            if result.count == 5 { break }
        }
        return result
    }

    // MARK: Conversion

    @MainActor private func refreshConversion() async {
        conversion = nil; conversionError = nil; conversionKey = quoteKey
        guard needsConversion, let account else { return }
        let key = quoteKey
        let value = AmountInput.parse(amount) ?? 1
        let signed = kind == .income ? value : -value
        do {
            let quote: CardConversion
            if transaction?.accountID == accountID, let saved = transaction?.conversion, saved.originalAmount == signed,
               saved.originalCurrency == purchaseCurrency, saved.accountCurrency == account.currency,
               Dates.string(saved.date) == Dates.string(date) { quote = saved }
            else {
                let rate = try await VisaRateClient.shared.rate(from: purchaseCurrency, to: account.currency, date: date)
                quote = CardConversion(originalAmount: signed, originalCurrency: purchaseCurrency, accountCurrency: account.currency,
                                       rate: rate, date: Calendar.current.startOfDay(for: date)).applyingFee(of: account)
            }
            try Task.checkCancellation()
            guard key == quoteKey else { return }
            conversion = quote; conversionKey = key
        } catch is CancellationError {
        } catch {
            guard key == quoteKey else { return }
            conversionError = (error as? URLError) != nil ? L("Не удалось подключиться к Visa. Проверьте интернет-соединение.") : error.localizedDescription
        }
    }
    private var currentConversion: CardConversion? {
        guard conversionKey == quoteKey, var quote = conversion, let value = AmountInput.parse(amount), value > 0 else { return nil }
        let signed = kind == .income ? value : -value
        if quote.originalAmount != signed, let account {
            quote.originalAmount = signed
            quote = quote.applyingFee(of: account)
        }
        return quote
    }
    private var conversionAmountError: String? {
        guard let quote = currentConversion else { return nil }
        do { _ = try quote.convertedAmount(); return nil } catch { return L(error.localizedDescription) }
    }

    @ViewBuilder private var conversionPreview: some View {
        let quote = currentConversion
        if let quote, let converted = try? quote.convertedAmount() {
            VStack(alignment: .leading, spacing: 4) {
                FinancialText("\(kind == .income ? L("Будет зачислено") : L("Будет списано")): \(DisplayMoney.string(abs(converted), currency: quote.accountCurrency))")
                    .font(.subheadline.weight(.semibold))
                FinancialText(L("Visa · 1 \(quote.originalCurrency) = \(Money.plain(quote.rate)) \(quote.accountCurrency) · \(Dates.string(quote.date))"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(quote.feePercent == 0 ? L("Без банковской комиссии") : L("Банковская комиссия: \(Money.plain(quote.feePercent))% · включена в сумму"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if let error = conversionAmountError {
            Text(error).font(.caption).foregroundStyle(.red)
        } else if let conversionError, conversionKey == quoteKey {
            VStack(alignment: .leading, spacing: 8) {
                Text(L(conversionError)).font(.caption).foregroundStyle(.red)
                Button(L("Повторить получение курса")) { Task { await refreshConversion() } }.font(.subheadline)
            }
        } else if (AmountInput.parse(amount) ?? 0) > 0 {
            HStack(spacing: 8) { ProgressView(); Text(L("Получаем курс Visa…")).font(.subheadline).foregroundStyle(.secondary) }
        } else {
            Text(L("Введите сумму покупки в валюте \(purchaseCurrency).")).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Balance

    private var balanceDraft: Transaction? {
        guard let value = AmountInput.parse(amount), value > 0, let accountID else { return nil }
        let converted = currentConversion.flatMap { try? $0.convertedAmount() }
        guard !needsConversion || converted != nil else { return nil }
        var signed = kind == .income ? value : -value
        if standaloneTransfer { signed = (transaction?.amount ?? 0) > 0 ? value : -value }
        return Transaction(id: transaction?.id ?? newTransactionID, date: TransactionDateEditing.changingDay(of: dateReference, to: date),
                           merchant: "", amount: converted ?? signed, accountID: accountID, kind: kind,
                           destinationAccountID: kind == .transfer && !standaloneTransfer ? destinationID : nil,
                           destinationAmount: kind == .transfer && !standaloneTransfer ? (sameCurrency ? value : AmountInput.parse(destinationAmount)) : nil)
    }

    @ViewBuilder private var balancePreview: some View {
        if let draft = balanceDraft {
            let through = max(Date(), draft.date)
            let accounts = [account, kind == .transfer && !standaloneTransfer ? destination : nil].compactMap { $0 }
            Section(L("Баланс после операции")) {
                ForEach(accounts) { account in
                    LabeledContent(account.name) {
                        FinancialText(DisplayMoney.string(ledger.projectedBalance(account, replacing: transaction?.id, with: draft, through: through), currency: account.currency))
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    // MARK: Save

    private func makeDraft() -> Transaction? {
        guard let value = AmountInput.parse(amount), value > 0, let accountID else { return nil }
        var result = transaction ?? Transaction(id: newTransactionID, date: date, merchant: merchant, amount: -value, accountID: accountID)
        result.date = TransactionDateEditing.changingDay(of: dateReference, to: date)
        result.merchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        result.amount = kind == .income ? value : -value
        result.kind = kind; result.accountID = accountID
        if standaloneTransfer { result.amount = (transaction?.amount ?? 0) > 0 ? value : -value }
        result.categoryID = kind == .transfer ? nil : categoryID
        result.destinationAccountID = kind == .transfer && !standaloneTransfer ? destinationID : nil
        result.destinationAmount = kind == .transfer && !standaloneTransfer ? (sameCurrency ? value : AmountInput.parse(destinationAmount)) : nil
        result.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        result.tags = TransactionTags.parse(tags).sorted()
        result.conversion = nil
        if needsConversion {
            guard let quote = currentConversion, let converted = try? quote.convertedAmount() else { return nil }
            result.amount = converted; result.conversion = quote
        }
        return result
    }

    private func save() {
        guard !saving else { return }
        attemptedSave = true
        focus = nil
        guard errors.isEmpty else { return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            if needsConversion && currentConversion == nil { await refreshConversion() }
            guard let value = makeDraft() else {
                if needsConversion && conversionError == nil { conversionError = L("Курс Visa еще не получен. Повторите сохранение.") }
                return
            }
            let saved: Bool
            if let capture = walletCapture { saved = await cloud.review(capture, transaction: value) }
            else { saved = await store.saveTransaction(value, original: transaction) }
            if saved { dismiss() }
        }
    }
}

struct SplitEditor: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    let transaction: Transaction
    @State private var firstAmount = ""
    @State private var firstCategory: UUID?
    @State private var secondCategory: UUID?
    @State private var saving = false
    private var currency: String { store.ledger.account(transaction.accountID)?.currency ?? "RUB" }
    private var remainder: Decimal { abs(transaction.amount) - (AmountInput.parse(firstAmount) ?? 0) }
    private var canSave: Bool { (AmountInput.parse(firstAmount) ?? 0) > 0 && remainder > 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(transaction.merchant) { FinancialText(DisplayMoney.string(abs(transaction.amount), currency: currency)) }
                }
                Section(L("Первая часть")) {
                    TextField(L("Сумма первой части"), text: $firstAmount).keyboardType(.decimalPad).financialField()
                        .onChange(of: firstAmount) { _, value in firstAmount = AmountInput.filtered(value) }
                    categoryPicker(L("Первая категория"), selection: $firstCategory)
                }
                Section(L("Вторая часть")) {
                    LabeledContent(L("Сумма")) { FinancialText(DisplayMoney.string(max(remainder, 0), currency: currency)) }
                    categoryPicker(L("Вторая категория"), selection: $secondCategory)
                }
                Section { Text(L("Исходная операция будет заменена двумя частями. Общая сумма и остаток счета сохранятся.")).font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle(L("Разделить операцию"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(L("Отмена"), systemImage: "xmark") } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Разделить")) {
                        guard let value = AmountInput.parse(firstAmount) else { return }
                        saving = true
                        Task { if await store.split(transaction, firstAmount: value, firstCategory: firstCategory, secondCategory: secondCategory) { dismiss() }; saving = false }
                    }.disabled(!canSave || saving).fontWeight(.semibold)
                }
            }
            .onAppear { firstCategory = transaction.categoryID }
        }
    }

    private func categoryPicker(_ title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            Text(L("Без категории")).tag(UUID?.none)
            ForEach(store.ledger.categories.filter { $0.kind == transaction.kind }) { Text($0.name).tag(UUID?.some($0.id)) }
        }
    }
}
