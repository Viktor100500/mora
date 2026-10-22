import SwiftUI
import FinanceCore

let currencyList = ["RUB", "USD", "EUR", "RSD", "GBP", "CHF", "CNY", "JPY", "AED", "GEL", "TRY", "KZT", "CAD", "AUD", "INR"]

struct AccountsView: View {
    @EnvironmentObject var store: FinanceStore
    @Binding var sheet: EditorSheet?
    @State private var deletingAccount: Account?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text(L("\(store.ledger.accounts.count) счетов · остатки на сегодня")).font(.callout).foregroundStyle(.secondary); Spacer(); Button { sheet = .account(nil) } label: { Label(L("Добавить счет"), systemImage: "plus") }.buttonStyle(.borderedProminent) }
            if store.ledger.accounts.isEmpty { Card { EmptyState(icon: "wallet.bifold", title: L("Нет счетов"), text: L("Банковская карта, наличные, накопления или кредит. Укажите начальный остаток и валюту."), button: L("Добавить счет")) { sheet = .account(nil) } } }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                ForEach(store.ledger.accounts) { account in
                    Card {
                        VStack(alignment: .leading, spacing: 22) {
                            HStack { IconTile(icon: account.kind.icon, color: account.color, size: 44); VStack(alignment: .leading, spacing: 4) { Text(account.name).font(.system(size: 16, weight: .semibold)); Text(L(account.kind.title) + (account.archived ? L(" · архив") : "")).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(account.currency).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(7).background(Color.primary.opacity(0.04)).clipShape(Capsule()) }
                            FinancialText(DisplayMoney.string(store.reportBalance(account), currency: account.currency)).font(.system(size: 30, weight: .semibold, design: .rounded))
                            HStack { FinancialText(L("Начальный остаток: \(DisplayMoney.string(account.openingBalance, currency: account.currency))")).font(.caption).foregroundStyle(.secondary); Spacer(); GlassEditButton(title: "Редактировать счет") { sheet = .account(account) } }
                        }
                    }.opacity(account.archived ? 0.65 : 1)
                    .contextMenu {
                        Button(L("Редактировать")) { sheet = .account(account) }
                        Button(account.archived ? L("Вернуть из архива") : L("Архивировать")) { Task { @MainActor in  await store.setAccountArchived(account.id, archived: !account.archived)  } }
                        if account.archived { Button(L("Удалить счет окончательно"), role: .destructive) { deletingAccount = account } }
                    }
                }
            }
            Text(L("Архивные счета и их доходы, расходы и расписания исключены из расчетов. История сохраняется до удаления; счет можно вернуть из архива.")).font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog(L("Удалить счет «\(deletingAccount?.name ?? "")» окончательно?"), isPresented: Binding(get: { deletingAccount != nil }, set: { if !$0 { deletingAccount = nil } }), titleVisibility: .visible) {
            if let account = deletingAccount {
                Button(L("Удалить счет окончательно"), role: .destructive) { Task { @MainActor in  await store.deleteArchivedAccount(account.id); deletingAccount = nil  } }
            }
            Button(L("Отмена"), role: .cancel) { deletingAccount = nil }
        } message: {
            Text(L("Счет, его операции и расписания будут удалены. Переводы на других счетах сохранятся без изменения их остатков. Удаление можно отменить в настройках: «Данные и резервные копии» → «Отменить последнее изменение»."))
        }
    }
}

struct AccountEditor: View {
    @State private var saving = false
    @EnvironmentObject var store: FinanceStore
    @Environment(\.dismiss) var dismiss
    var account: Account?
    @State private var name: String
    @State private var currency: String
    @State private var kind: AccountKind
    @State private var opening: String
    @State private var conversionFee: String
    @State private var color: String
    init(account: Account?) {
        _conversionFee = State(initialValue: Money.plain(account?.bankFeePercent ?? 0))
        self.account = account; _name = State(initialValue: account?.name ?? ""); _currency = State(initialValue: account?.currency ?? "RUB"); _kind = State(initialValue: account?.kind ?? .checking); _opening = State(initialValue: account.map { Money.plain($0.openingBalance) } ?? "0"); _color = State(initialValue: account?.color ?? "green")
    }
    private var validFee: Bool { guard let fee = Money.parse(conversionFee) else { return false }; return fee >= 0 && fee <= 100 }
    private var used: Bool { guard let account else { return false }; return store.ledger.transactions.contains { $0.accountID == account.id || $0.destinationAccountID == account.id } || store.ledger.recurring.contains { $0.accountID == account.id } }
    private var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameAlreadyUsed: Bool { hasNameConflict(in: store.ledger) }
    private func hasNameConflict(in ledger: Ledger) -> Bool {
        !normalizedName.isEmpty && ledger.accounts.contains {
            $0.id != account?.id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(normalizedName) == .orderedSame
        }
    }
    var body: some View {
        ModalFrame(title: account == nil ? L("Новый счет") : L("Редактировать счет"), canSave: !normalizedName.isEmpty && !nameAlreadyUsed && Money.parse(opening) != nil && validFee, save: save) {
            VStack(alignment: .leading, spacing: 16) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    accountField("Название") { TextField(L("Название"), text: $name) }
                    accountField("Тип") {
                        Picker(L("Тип"), selection: $kind) { ForEach(AccountKind.allCases) { Text(L($0.title)).tag($0) } }
                    }
                    accountField("Валюта") {
                        Picker(L("Валюта"), selection: $currency) { ForEach(Array(Set(currencyList + [currency])).sorted(), id: \.self) { Text($0).tag($0) } }.disabled(used)
                    }
                    accountField("Начальный остаток") { TextField(L("Начальный остаток"), text: $opening).financialField() }
                    accountField("Комиссия, %") { TextField(L("Комиссия за конвертацию, %"), text: $conversionFee) }
                }
                .textFieldStyle(.roundedBorder)
                if nameAlreadyUsed {
                    Label(L("Счет с таким названием уже существует."), systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Text(L("Добавляется к курсу Visa при расходах в другой валюте. 0 — без комиссии. Сохраненные операции не пересчитываются."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                ColorPickerRow(color: $color)
                Text(L("Укажите остаток перед самой ранней операцией, которую будете добавлять или импортировать. Для учета только новых операций — текущий остаток.")).font(.caption).foregroundStyle(.secondary)
                if used { Text(L("Валюта счета с операциями фиксирована. Для другой валюты создайте отдельный счет.")).font(.caption).foregroundStyle(.secondary) }
            }
        }.onAppear { if account == nil { currency = store.ledger.preferences.baseCurrency } }
    }
    private func accountField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(L(title)).font(.callout).frame(width: 140, alignment: .trailing)
            content().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func save() { guard !saving else { return }; saving = true
        Task { @MainActor in defer { saving = false };
        guard !normalizedName.isEmpty, !nameAlreadyUsed, validFee, let fee = Money.parse(conversionFee), let opening = Money.parse(opening) else { return }
        var a = account ?? Account(name: name)
        a.name = normalizedName; a.currency = currency; a.kind = kind; a.openingBalance = opening; a.color = color; a.conversionFeePercent = fee == 0 ? nil : fee
        let value = a, originalID = account?.id, expectedName = normalizedName
        if await store.update({ ledger in
            guard !ledger.accounts.contains(where: { $0.id != originalID && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(expectedName) == .orderedSame }) else { throw LedgerError.invalid(L("Счет с таким названием уже существует.")) }
            replaceOrAppend(value, in: &ledger.accounts)
        }) { dismiss() }
     } }
}

struct BudgetsView: View {
    @EnvironmentObject var store: FinanceStore
    var month: Date
    @Binding var sheet: EditorSheet?
    var body: some View {
        let ledger = store.ledger
        let total = ledger.budgets.reduce(Decimal(0)) { $0 + $1.limit }
        let spent = ledger.budgets.reduce(Decimal(0)) { $0 + store.reportSpending(category: $1.categoryID, in: month) }
        VStack(spacing: 22) {
            Card {
                HStack { VStack(alignment: .leading, spacing: 10) { SectionHeading(title: L("Месячный план"), subtitle: L("Лимиты повторяются каждый месяц · \(ledger.preferences.baseCurrency)")); FinancialText(DisplayMoney.string(total, currency: ledger.preferences.baseCurrency)).font(.system(size: 32, weight: .semibold, design: .rounded)) }; Spacer(); VStack(alignment: .trailing, spacing: 10) { Text(L("Осталось в категориях с бюджетом")).font(.caption).foregroundStyle(.secondary); FinancialText(DisplayMoney.string(total - spent, currency: ledger.preferences.baseCurrency)).font(.title2.weight(.semibold)).foregroundStyle(spent > total ? Color.token("red") : .moraGreen); Button(L("Добавить бюджет")) { sheet = .budget(nil) }.buttonStyle(.borderedProminent) } }
            }
            if ledger.budgets.isEmpty { Card { EmptyState(icon: "chart.pie", title: L("Нет бюджетов"), text: L("Добавьте месячный лимит для категории расходов."), button: L("Создать бюджет")) { sheet = .budget(nil) } } }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                ForEach(ledger.budgets) { budget in
                    let spent = store.reportSpending(category: budget.categoryID, in: month)
                    Card {
                        VStack(alignment: .leading, spacing: 20) {
                            BudgetMini(budget: budget, ledger: ledger, month: month)
                            HStack { FinancialText(spent > budget.limit ? L("Превышение: \(DisplayMoney.string(spent - budget.limit, currency: ledger.preferences.baseCurrency))") : L("Доступно: \(DisplayMoney.string(budget.limit - spent, currency: ledger.preferences.baseCurrency))")).font(.caption).foregroundStyle(spent > budget.limit ? Color.token("red") : .secondary); Spacer(); Button { sheet = .budget(budget) } label: { Image(systemName: "pencil") }.buttonStyle(.plain) }
                        }
                    }.contextMenu { Button(L("Редактировать")) { sheet = .budget(budget) }; Button(L("Удалить бюджет"), role: .destructive) { Task { @MainActor in  await store.update { $0.budgets.removeAll { $0.id == budget.id } }  } } }
                }
            }
        }
    }
}

struct BudgetEditor: View {
    @State private var saving = false
    @EnvironmentObject var store: FinanceStore
    @Environment(\.dismiss) var dismiss
    var budget: Budget?
    @State private var categoryID: UUID?
    @State private var limit: String
    init(budget: Budget?) { self.budget = budget; _categoryID = State(initialValue: budget?.categoryID); _limit = State(initialValue: budget.map { Money.plain($0.limit) } ?? "") }
    var body: some View {
        ModalFrame(title: budget == nil ? L("Месячный бюджет") : L("Редактировать бюджет"), subtitle: L("Лимит в \(store.ledger.preferences.baseCurrency) повторяется каждый месяц"), canSave: categoryID != nil && (Money.parse(limit) ?? 0) > 0, save: save) {
            Form { Picker(L("Категория"), selection: $categoryID) { Text(L("Выберите категорию")).tag(Optional<UUID>.none); ForEach(store.ledger.categories.filter { c in c.kind == .expense && (!store.ledger.budgets.contains { $0.categoryID == c.id } || budget?.categoryID == c.id) }) { Text($0.name).tag(Optional($0.id)) } }; TextField(L("Месячный лимит"), text: $limit).financialField() }
        }
    }
    private func save() { guard !saving else { return }; saving = true
        Task { @MainActor in defer { saving = false };  guard let categoryID, let limit = Money.parse(limit), limit > 0 else { return }; let value = Budget(id: budget?.id ?? UUID(), categoryID: categoryID, limit: limit); if await store.update({ replaceOrAppend(value, in: &$0.budgets) }) { dismiss() }  } }
}

struct GoalsView: View {
    @EnvironmentObject var store: FinanceStore
    @Binding var sheet: EditorSheet?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text(L("Прогресс накоплений обновляется вручную.")).foregroundStyle(.secondary).font(.callout); Spacer(); Button(L("Создать цель")) { sheet = .goal(nil) }.buttonStyle(.borderedProminent) }
            if store.ledger.goals.isEmpty { Card { EmptyState(icon: "flag", title: L("Нет целей"), text: L("Укажите название, сумму и срок накопления."), button: L("Создать цель")) { sheet = .goal(nil) } } }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                ForEach(store.ledger.goals) { goal in
                    Card {
                        VStack(alignment: .leading, spacing: 22) {
                            HStack { IconTile(icon: goal.icon, color: "purple", size: 48); VStack(alignment: .leading, spacing: 5) { Text(goal.name).font(.system(size: 17, weight: .semibold)); Text(L("До \(goal.deadline.formatted(.dateTime.day().month(.wide).year().locale(L10n.locale)))")).font(.caption).foregroundStyle(.secondary) }; Spacer() }
                            HStack(alignment: .firstTextBaseline) { FinancialText(DisplayMoney.string(goal.saved, currency: store.ledger.preferences.baseCurrency)).font(.system(size: 28, weight: .semibold, design: .rounded)); Spacer(); Text("\(Int((goal.saved / goal.target).double * 100))%").font(.title3.weight(.medium)).foregroundStyle(Color.moraGreen) }
                            Meter(progress: (goal.saved / goal.target).double, color: .token("purple"))
                            HStack { FinancialText(L("Цель: \(DisplayMoney.string(goal.target, currency: store.ledger.preferences.baseCurrency))")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(L("Обновить")) { sheet = .goal(goal) }.buttonStyle(.bordered) }
                            let months = max(Calendar.current.dateComponents([.month], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: goal.deadline)).month ?? 0, 1)
                            FinancialText(goal.saved >= goal.target ? L("Сумма накоплена") : L("Нужно откладывать: \(DisplayMoney.string((goal.target - goal.saved) / Decimal(months), currency: store.ledger.preferences.baseCurrency)) в месяц")).font(.caption).foregroundStyle(.secondary)
                        }
                    }.contextMenu { Button(L("Редактировать")) { sheet = .goal(goal) }; Button(L("Удалить цель"), role: .destructive) { Task { @MainActor in  await store.update { $0.goals.removeAll { $0.id == goal.id } }  } } }
                }
            }
            Text(L("Накопленную сумму обновляйте вручную. Она не влияет на остатки счетов.")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct GoalEditor: View {
    @State private var saving = false
    @EnvironmentObject var store: FinanceStore
    @Environment(\.dismiss) var dismiss
    var goal: Goal?
    @State private var name: String
    @State private var target: String
    @State private var saved: String
    @State private var deadline: Date
    @State private var icon: String
    init(goal: Goal?) { self.goal = goal; _name = State(initialValue: goal?.name ?? ""); _target = State(initialValue: goal.map { Money.plain($0.target) } ?? ""); _saved = State(initialValue: goal.map { Money.plain($0.saved) } ?? "0"); _deadline = State(initialValue: goal?.deadline ?? Calendar.current.date(byAdding: .year, value: 1, to: Date())!); _icon = State(initialValue: goal?.icon ?? "flag") }
    var body: some View {
        ModalFrame(title: goal == nil ? L("Новая цель") : L("Обновить цель"), subtitle: L("Все суммы в \(store.ledger.preferences.baseCurrency)"), canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty && (Money.parse(target) ?? 0) > 0 && (Money.parse(saved) ?? -1) >= 0, save: save) {
            Form { TextField(L("Название"), text: $name); TextField(L("Целевая сумма"), text: $target).financialField(); TextField(L("Уже накоплено"), text: $saved).financialField(); EuropeanDatePicker(title: L("Срок"), selection: $deadline); Picker(L("Значок"), selection: $icon) { ForEach(["flag", "airplane", "house", "car", "shield.lefthalf.filled", "graduationcap", "gift"], id: \.self) { Image(systemName: $0).tag($0) } } }
        }
    }
    private func save() { guard !saving else { return }; saving = true
        Task { @MainActor in defer { saving = false };
        guard let target = Money.parse(target), let saved = Money.parse(saved), target > 0, saved >= 0 else { return }
        let value = Goal(id: goal?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespaces), target: target, saved: saved, deadline: deadline, icon: icon)
        if await store.update({ replaceOrAppend(value, in: &$0.goals) }) { dismiss() }
     } }
}

struct RecurringView: View {
    @EnvironmentObject var store: FinanceStore
    @Binding var sheet: EditorSheet?
    @State private var paymentToConfirm: RecurringPayment?
    var body: some View {
        VStack(spacing: 22) {
            Card {
                HStack { VStack(alignment: .leading, spacing: 10) { SectionHeading(title: L("Платежи в месяц"), subtitle: L("Месячный эквивалент активных платежей")); FinancialText(DisplayMoney.string(store.reportMonthlyRecurring, currency: store.ledger.preferences.baseCurrency)).font(.system(size: 32, weight: .semibold, design: .rounded)) }; Spacer(); Button(L("Добавить платеж")) { sheet = .recurring(nil) }.buttonStyle(.borderedProminent) }
            }
            Card {
                VStack(alignment: .leading, spacing: 18) {
                    if store.ledger.recurring.isEmpty { EmptyState(icon: "repeat", title: L("Нет регулярных платежей"), text: L("Добавьте подписки, аренду и другие повторяющиеся расходы."), button: L("Добавить платеж")) { sheet = .recurring(nil) } }
                    ForEach(store.ledger.recurring.sorted { $0.nextDate < $1.nextDate }) { payment in
                        HStack(spacing: 14) {
                            IconTile(icon: store.ledger.category(payment.categoryID)?.icon ?? "repeat", color: store.ledger.category(payment.categoryID)?.color ?? "blue")
                            VStack(alignment: .leading, spacing: 5) { Text(payment.name).font(.callout.weight(.medium)); Text(L(payment.frequency.title) + " · " + (store.ledger.account(payment.accountID)?.name ?? "")).font(.caption).foregroundStyle(.secondary) }
                            Spacer(); VStack(alignment: .trailing, spacing: 5) { FinancialText(DisplayMoney.string(payment.amount, currency: store.ledger.account(payment.accountID)?.currency ?? "RUB")).font(.callout.weight(.semibold)); Text(payment.active ? payment.nextDate.formatted(.dateTime.day().month(.wide).locale(L10n.locale)) : L("Приостановлен")).font(.caption).foregroundStyle(payment.nextDate < Calendar.current.startOfDay(for: Date()) && payment.active ? Color.token("red") : .secondary) }
                            Button(L("Учесть платеж")) { paymentToConfirm = payment }.disabled(!payment.active || store.ledger.account(payment.accountID)?.archived != false)
                            Button { sheet = .recurring(payment) } label: { Image(systemName: "pencil") }.buttonStyle(.plain)
                        }.padding(.vertical, 9).opacity(payment.active ? 1 : 0.6)
                        .contextMenu { Button(L("Редактировать")) { sheet = .recurring(payment) }; Button(payment.active ? L("Приостановить") : L("Возобновить")) { Task { @MainActor in  await store.update { ledger in if let i = ledger.recurring.firstIndex(where: { $0.id == payment.id }) { ledger.recurring[i].active.toggle() } }  } }; Button(L("Удалить расписание"), role: .destructive) { Task { @MainActor in  await store.update { $0.recurring.removeAll { $0.id == payment.id } }  } } }
                        Divider().opacity(0.5)
                    }
                }
            }
            Text(L("Платежи добавляются в операции по кнопке «Учесть платеж». Затем дата сдвигается на следующий период. Приложение не списывает деньги в банке.")).font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog(L("Учесть \(paymentToConfirm?.name ?? L("платеж"))?"), isPresented: Binding(get: { paymentToConfirm != nil }, set: { if !$0 { paymentToConfirm = nil } }), titleVisibility: .visible) {
            if let payment = paymentToConfirm { Button(L("Добавить расход")) { Task { @MainActor in  await store.pay(payment); paymentToConfirm = nil  } } }
        } message: { Text(L("Будет создана операция на запланированную дату. Если она уже есть в выписке, не добавляйте ее повторно.")) }
    }
}

struct RecurringEditor: View {
    @State private var saving = false
    @EnvironmentObject var store: FinanceStore
    @Environment(\.dismiss) var dismiss
    var payment: RecurringPayment?
    @State private var name: String
    @State private var amount: String
    @State private var accountID: UUID?
    @State private var categoryID: UUID?
    @State private var date: Date
    @State private var frequency: Frequency
    init(payment: RecurringPayment?) { self.payment = payment; _name = State(initialValue: payment?.name ?? ""); _amount = State(initialValue: payment.map { Money.plain($0.amount) } ?? ""); _accountID = State(initialValue: payment?.accountID); _categoryID = State(initialValue: payment?.categoryID); _date = State(initialValue: payment?.nextDate ?? Date()); _frequency = State(initialValue: payment?.frequency ?? .monthly) }
    var body: some View {
        ModalFrame(title: payment == nil ? L("Регулярный платеж") : L("Редактировать платеж"), canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty && (Money.parse(amount) ?? 0) > 0 && accountID != nil, save: save) {
            Form {
                TextField(L("Название"), text: $name); TextField(L("Сумма в валюте счета"), text: $amount).financialField()
                Picker(L("Счет"), selection: $accountID) { Text(L("Выберите счет")).tag(Optional<UUID>.none); ForEach(store.ledger.accounts.filter { !$0.archived || $0.id == accountID }) { Text($0.name + " · " + $0.currency).tag(Optional($0.id)) } }
                Picker(L("Категория"), selection: $categoryID) { Text(L("Без категории")).tag(Optional<UUID>.none); ForEach(store.ledger.categories.filter { $0.kind == .expense }) { Text($0.name).tag(Optional($0.id)) } }
                Picker(L("Повтор"), selection: $frequency) { ForEach(Frequency.allCases) { Text(L($0.title)).tag($0) } }
                EuropeanDatePicker(title: L("Следующий платеж"), selection: $date)
            }
        }.onAppear { if accountID == nil { accountID = store.ledger.accounts.first(where: { !$0.archived })?.id } }
    }
    private func save() { guard !saving else { return }; saving = true
        Task { @MainActor in defer { saving = false };
        guard let amount = Money.parse(amount), amount > 0, let accountID else { return }
        var value = RecurringPayment(id: payment?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespaces), amount: amount, accountID: accountID, categoryID: categoryID, frequency: frequency, nextDate: Calendar.current.startOfDay(for: date), active: payment?.active ?? true)
        if let payment, Calendar.current.isDate(payment.nextDate, inSameDayAs: date), payment.frequency == frequency { value.anchorDay = payment.anchorDay }
        if await store.update({ [value] in replaceOrAppend(value, in: &$0.recurring) }) { dismiss() }
     } }
}

struct CategoriesView: View {
    @EnvironmentObject var store: FinanceStore
    @Binding var sheet: EditorSheet?
    @State private var deletingCategory: Category?
    var body: some View {
        VStack(spacing: 22) {
            Card {
                VStack(alignment: .leading, spacing: 20) {
                    HStack { SectionHeading(title: L("Категории"), subtitle: L("Отдельные категории для доходов и расходов")); Spacer(); Button(L("Добавить")) { sheet = .category(nil) }.buttonStyle(.borderedProminent) }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(store.ledger.categories) { c in
                            HStack(spacing: 10) {
                                IconTile(icon: c.icon, color: c.color, size: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(c.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    Text(L(c.kind.title)).font(.system(size: 10)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 44)
                                GlassEditButton(title: "Редактировать категорию") { sheet = .category(c) }
                            }.padding(12).background(Color.primary.opacity(0.025)).clipShape(RoundedRectangle(cornerRadius: 10)).help(c.name)
                                .contextMenu { Button(L("Редактировать")) { sheet = .category(c) }; Button(L("Удалить категорию"), role: .destructive) { deletingCategory = c } }
                        }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 20) {
                    HStack { SectionHeading(title: L("Правила категоризации"), subtitle: L("Если описание содержит слово, назначить категорию · применяется первое совпадение")); Spacer(); Button(L("Применить к существующим")) { Task { @MainActor in  await store.applyRules()  } }; Button(L("Добавить правило")) { sheet = .rule(nil) }.buttonStyle(.borderedProminent) }
                    if store.ledger.rules.isEmpty { Text(L("Создайте правило, например: «ВкусВилл» → «Продукты».")).font(.callout).foregroundStyle(.secondary).padding(.vertical, 20) }
                    ForEach(Array(store.ledger.rules.enumerated()), id: \.element.id) { index, rule in
                        HStack {
                            Text("\(index + 1)").font(.caption).foregroundStyle(.secondary).frame(width: 24)
                            Text(L("Описание содержит")).font(.caption).foregroundStyle(.secondary); Text(rule.keyword).font(.callout.weight(.medium)); Image(systemName: "arrow.right").foregroundStyle(.secondary); Text(store.ledger.category(rule.categoryID)?.name ?? "").font(.callout)
                            Spacer(); Button { Task { @MainActor in  await store.update { $0.rules.swapAt(index, index - 1) }  } } label: { Image(systemName: "arrow.up") }.disabled(index == 0).buttonStyle(.plain).help(L("Повысить приоритет"))
                            GlassEditButton(title: "Редактировать правило") { sheet = .rule(rule) }
                            Button(role: .destructive) { Task { @MainActor in  await store.update { $0.rules.removeAll { $0.id == rule.id } }  } } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                        }.padding(.vertical, 8)
                    }
                    Text(L("Правила применяются при импорте и ручном добавлении. Для существующих операций заполняются только пустые категории.")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog(L("Удалить категорию «\(deletingCategory?.name ?? "")»?"), isPresented: Binding(get: { deletingCategory != nil }, set: { if !$0 { deletingCategory = nil } }), titleVisibility: .visible) { if let c = deletingCategory { Button(L("Удалить категорию"), role: .destructive) { Task { @MainActor in  await store.deleteCategory(c.id); deletingCategory = nil  } } } } message: { Text(L("Операции сохранятся без категории. Связанные бюджеты и правила будут удалены. Изменение можно отменить.")) }
    }
}

struct CategoryEditor: View {
    @State private var saving = false
    @EnvironmentObject var store: FinanceStore
    @Environment(\.dismiss) var dismiss
    var category: Category?
    @State private var name: String
    @State private var kind: TransactionKind
    @State private var icon: String
    @State private var color: String
    @State private var useEmoji: Bool
    init(category: Category?) {
        self.category = category
        _name = State(initialValue: category?.name ?? "")
        _kind = State(initialValue: category?.kind ?? .expense)
        _icon = State(initialValue: category?.icon ?? "🏷️")
        _useEmoji = State(initialValue: CategoryAppearance.isEmoji(category?.icon ?? "🏷️"))
        _color = State(initialValue: category?.color ?? "green")
    }
    private var validIcon: Bool {
        useEmoji ? CategoryAppearance.isEmoji(icon) : (CategoryIconPicker.symbols.contains(icon) || icon == category?.icon)
    }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validIcon }
    var body: some View {
        ModalFrame(title: category == nil ? L("Новая категория") : L("Редактировать категорию"), canSave: canSave, save: save) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        IconTile(icon: validIcon ? icon : "tag", color: color, size: 48)
                        Text(name.isEmpty ? L("Новая категория") : name).font(.headline)
                    }
                    Form {
                        TextField(L("Название"), text: $name)
                        Picker(L("Тип"), selection: $kind) {
                            Text(L("Расход")).tag(TransactionKind.expense)
                            Text(L("Доход")).tag(TransactionKind.income)
                        }.disabled(category != nil)
                    }
                    CategoryIconPicker(icon: $icon, useEmoji: $useEmoji)
                    Divider()
                    ColorPickerRow(color: $color)
                }.padding(3)
            }.frame(maxHeight: 560)
        }
    }
    private func save() { guard !saving else { return }; saving = true
        Task { @MainActor in defer { saving = false };
        guard canSave else { return }
        let value = Category(id: category?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), icon: icon, color: color, kind: kind)
        if await store.update({ ledger in guard !ledger.categories.contains(where: { $0.id != value.id && $0.kind == value.kind && $0.name.localizedCaseInsensitiveCompare(value.name) == .orderedSame }) else { throw LedgerError.invalid(L("Такая категория уже существует.")) }; replaceOrAppend(value, in: &ledger.categories) }) { dismiss() }
     } }
}

struct RuleEditor: View {
    @State private var saving = false
    @EnvironmentObject var store: FinanceStore
    @Environment(\.dismiss) var dismiss
    var rule: CategoryRule?
    @State private var keyword: String
    @State private var categoryID: UUID?
    init(rule: CategoryRule?) { self.rule = rule; _keyword = State(initialValue: rule?.keyword ?? ""); _categoryID = State(initialValue: rule?.categoryID) }
    var body: some View {
        ModalFrame(title: L("Правило категоризации"), subtitle: L("Поиск в описании без учета регистра"), canSave: !keyword.trimmingCharacters(in: .whitespaces).isEmpty && categoryID != nil, save: save) {
            Form { TextField(L("Описание содержит"), text: $keyword); Picker(L("Назначить категорию"), selection: $categoryID) { Text(L("Выберите категорию")).tag(Optional<UUID>.none); ForEach(store.ledger.categories) { Text($0.name + ($0.kind == .income ? L(" · доход") : "")).tag(Optional($0.id)) } } }
        }
    }
    private func save() { guard !saving else { return }; saving = true
        Task { @MainActor in defer { saving = false };  guard let categoryID else { return }; let value = CategoryRule(id: rule?.id ?? UUID(), keyword: keyword.trimmingCharacters(in: .whitespaces), categoryID: categoryID); if await store.update({ replaceOrAppend(value, in: &$0.rules) }) { dismiss() }  } }
}
