import SwiftUI
import FinanceCore

struct AccountsScreen: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var router: AppRouter
    @State private var deleting: Account?
    private var active: [Account] { store.ledger.accounts.filter { !$0.archived } }
    private var archived: [Account] { store.ledger.accounts.filter(\.archived) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Общий капитал")).font(.subheadline).foregroundStyle(.secondary)
                        FinancialText(DisplayMoney.string(store.netWorth, currency: store.baseCurrency))
                            .font(.system(size: 32, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.5)
                        Text(L("\(active.count) счетов · остатки на сегодня")).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
                CurrencyWarning().listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                if store.ledger.accounts.isEmpty {
                    EmptyCard(icon: "wallet.bifold", title: "Нет счетов", text: "Банковская карта, наличные, накопления или кредит. Укажите начальный остаток и валюту.", button: "Добавить счет") { router.open(.account(nil)) }
                        .listRowBackground(Color.clear)
                }
                if !active.isEmpty {
                    Section(L("Счета")) { ForEach(active) { row($0) } }
                }
                if !archived.isEmpty {
                    Section {
                        ForEach(archived) { row($0) }
                    } header: { Text(L("Архив")) } footer: {
                        Text(L("Архивные счета и их доходы, расходы и расписания исключены из расчетов. История сохраняется до удаления; счет можно вернуть из архива."))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L("Счета"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { router.open(.account(nil)) } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                        .accessibilityLabel(L("Добавить счет"))
                }
            }
            .confirmationDialog(L("Удалить счет «\(deleting?.name ?? "")» окончательно?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                if let account = deleting {
                    Button(L("Удалить счет окончательно"), role: .destructive) { Task { await store.deleteArchivedAccount(account.id); deleting = nil } }
                }
            } message: {
                Text(L("Счет, его операции и расписания будут удалены. Переводы на других счетах сохранятся без изменения их остатков. Изменение можно отменить."))
            }
        }
    }

    private func row(_ account: Account) -> some View {
        NavigationLink {
            AccountDetailScreen(accountID: account.id)
        } label: {
            HStack(spacing: 12) {
                IconTile(icon: account.kind.icon, color: account.color, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    // The balance keeps its width; a long name wraps instead of truncating.
                    Text(account.name).font(.body.weight(.medium)).lineLimit(2)
                    // The balance already shows the currency.
                    Text(L(account.kind.title)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                FinancialText(DisplayMoney.string(store.balance(account), currency: account.currency))
                    .font(.body.weight(.semibold)).lineLimit(1).fixedSize()
            }
            .opacity(account.archived ? 0.6 : 1)
        }
        .swipeActions(edge: .trailing) {
            if account.archived {
                Button(role: .destructive) { deleting = account } label: { Label(L("Удалить"), systemImage: "trash") }
            }
            Button { Task { await store.setAccountArchived(account.id, archived: !account.archived) } } label: {
                Label(account.archived ? L("Вернуть") : L("В архив"), systemImage: account.archived ? "tray.and.arrow.up" : "archivebox")
            }.tint(.orange)
        }
        .swipeActions(edge: .leading) {
            Button { router.open(.account(account)) } label: { Label(L("Изменить"), systemImage: "pencil") }.tint(.blue)
        }
    }
}

struct AccountDetailScreen: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var router: AppRouter
    let accountID: UUID
    @State private var deleting = false

    var body: some View {
        if let account = store.ledger.account(accountID) {
            let rows = store.ledger.transactions.filter { $0.accountID == account.id || $0.destinationAccountID == account.id }.sorted { $0.date > $1.date }
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            IconTile(icon: account.kind.icon, color: account.color, size: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L(account.kind.title) + (account.archived ? L(" · архив") : "")).font(.subheadline).foregroundStyle(.secondary)
                                Text(account.currency).font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                            }
                        }
                        FinancialText(DisplayMoney.string(store.balance(account), currency: account.currency))
                            .font(.system(size: 34, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.5)
                        FinancialText(L("Начальный остаток: \(DisplayMoney.string(account.openingBalance, currency: account.currency))")).font(.caption).foregroundStyle(.secondary)
                        if account.bankFeePercent > 0 {
                            Text(L("Комиссия за конвертацию: \(Money.plain(account.bankFeePercent))%")).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
                Section {
                    Button { router.open(.account(account)) } label: { Label(L("Редактировать счет"), systemImage: "pencil") }
                    Button { Task { await store.setAccountArchived(account.id, archived: !account.archived) } } label: {
                        Label(account.archived ? L("Вернуть из архива") : L("Архивировать"), systemImage: account.archived ? "tray.and.arrow.up" : "archivebox")
                    }
                    if account.archived {
                        Button(role: .destructive) { deleting = true } label: { Label(L("Удалить счет окончательно"), systemImage: "trash") }
                    }
                }
                Section(L("Операции")) {
                    if rows.isEmpty { Text(L("Операций нет")).foregroundStyle(.secondary) }
                    ForEach(rows.prefix(200)) { row in
                        Button { router.open(.transaction(row)) } label: { TransactionRow(transaction: row, ledger: store.ledger) }.buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(account.name)
            .confirmationDialog(L("Удалить счет «\(account.name)» окончательно?"), isPresented: $deleting, titleVisibility: .visible) {
                Button(L("Удалить счет окончательно"), role: .destructive) { Task { await store.deleteArchivedAccount(account.id) } }
            } message: {
                Text(L("Счет, его операции и расписания будут удалены. Переводы на других счетах сохранятся без изменения их остатков. Изменение можно отменить."))
            }
        } else {
            ContentUnavailableView(L("Счет удален"), systemImage: "wallet.bifold")
        }
    }
}

struct AccountEditor: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    let account: Account?
    @State private var name: String
    @State private var currency: String
    @State private var kind: AccountKind
    @State private var opening: String
    @State private var fee: String
    @State private var color: String
    @State private var saving = false

    init(account: Account?) {
        self.account = account
        _name = State(initialValue: account?.name ?? "")
        _currency = State(initialValue: account?.currency ?? "")
        _kind = State(initialValue: account?.kind ?? .checking)
        _opening = State(initialValue: account.map { Money.plain($0.openingBalance) } ?? "0")
        _fee = State(initialValue: Money.plain(account?.bankFeePercent ?? 0))
        _color = State(initialValue: account?.color ?? "green")
    }

    private var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var used: Bool {
        guard let account else { return false }
        return store.ledger.transactions.contains { $0.accountID == account.id || $0.destinationAccountID == account.id } || store.ledger.recurring.contains { $0.accountID == account.id }
    }
    private var duplicateName: Bool {
        !normalizedName.isEmpty && store.ledger.accounts.contains { $0.id != account?.id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(normalizedName) == .orderedSame }
    }
    private var validFee: Bool { guard let value = Money.parse(fee) else { return false }; return value >= 0 && value <= 100 }
    private var canSave: Bool { !normalizedName.isEmpty && !duplicateName && Money.parse(opening) != nil && validFee && !currency.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        IconTile(icon: kind.icon, color: color, size: 44)
                        TextField(L("Название"), text: $name).font(.headline)
                    }
                    if duplicateName { Label(L("Счет с таким названием уже существует."), systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.red) }
                    Picker(L("Тип"), selection: $kind) { ForEach(AccountKind.allCases) { Label(L($0.title), systemImage: $0.icon).tag($0) } }
                    Picker(L("Валюта"), selection: $currency) {
                        ForEach(Array(Set(currencyList + Locale.commonISOCurrencyCodes + [currency])).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.navigationLink).disabled(used)
                } footer: {
                    if used { Text(L("Валюта счета с операциями фиксирована. Для другой валюты создайте отдельный счет.")) }
                }
                Section {
                    LabeledContent(L("Начальный остаток")) {
                        TextField("0", text: $opening).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).financialField()
                    }
                } footer: {
                    Text(L("Укажите остаток перед самой ранней операцией, которую будете добавлять или импортировать. Для учета только новых операций — текущий остаток."))
                }
                Section {
                    LabeledContent(L("Комиссия, %")) {
                        TextField("0", text: $fee).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text(L("Добавляется к курсу Visa при расходах в другой валюте. 0 — без комиссии. Сохраненные операции не пересчитываются."))
                }
                Section(L("Цвет")) { ColorPalettePicker(color: $color) }
            }
            .navigationTitle(account == nil ? L("Новый счет") : L("Редактировать счет"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(L("Отмена"), systemImage: "xmark") } }
                ToolbarItem(placement: .confirmationAction) { Button(L("Сохранить"), action: save).disabled(!canSave || saving).fontWeight(.semibold) }
            }
            .onAppear { if currency.isEmpty { currency = store.baseCurrency } }
        }
    }

    private func save() {
        guard canSave, let feeValue = Money.parse(fee), let openingValue = Money.parse(opening) else { return }
        saving = true
        var value = account ?? Account(name: normalizedName)
        value.name = normalizedName; value.currency = currency; value.kind = kind; value.openingBalance = openingValue
        value.color = color; value.conversionFeePercent = feeValue == 0 ? nil : feeValue
        let result = value, originalID = account?.id, expected = normalizedName
        Task {
            if await store.update({ ledger in
                guard !ledger.accounts.contains(where: { $0.id != originalID && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(expected) == .orderedSame }) else {
                    throw LedgerError.invalid("Счет с таким названием уже существует.")
                }
                replaceOrAppend(result, in: &ledger.accounts)
            }) { dismiss() }
            saving = false
        }
    }
}

struct ColorPalettePicker: View {
    @Binding var color: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                ForEach(Palette.tokens, id: \.self) { token in
                    Button { color = token } label: {
                        Circle().fill(Color.token(token)).frame(width: 28, height: 28)
                            .overlay { if color == token { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) } }
                            .padding(3)
                            .overlay(Circle().stroke(Color.primary.opacity(color == token ? 0.5 : 0), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L(Palette.names[token] ?? token))
                    .accessibilityAddTraits(color == token ? .isSelected : [])
                }
            }
            ColorPicker(L("Свой цвет"), selection: Binding(get: { Color.token(color) }, set: { value in
                let resolved = value.resolve(in: EnvironmentValues())
                color = CategoryAppearance.hex(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
            }), supportsOpacity: false)
        }.padding(.vertical, 4)
    }
}
