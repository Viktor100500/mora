import SwiftUI
import FinanceCore

struct BudgetsScreen: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        let ledger = store.ledger, currency = store.baseCurrency
        let total = ledger.budgets.reduce(Decimal(0)) { $0 + $1.limit }
        let spent = ledger.budgets.reduce(Decimal(0)) { $0 + store.spent(category: $1.categoryID, in: router.month) }
        List {
            Section {
                MonthSwitcher(month: $router.month).frame(maxWidth: .infinity).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Месячный план")).font(.subheadline).foregroundStyle(.secondary)
                    FinancialText(DisplayMoney.string(total, currency: currency)).font(.system(size: 30, weight: .semibold, design: .rounded))
                    Meter(progress: total > 0 ? (spent / total).double : 0, color: spent > total ? .token("red") : .moraGreen)
                    FinancialText(L("Осталось: \(DisplayMoney.string(total - spent, currency: currency))"))
                        .font(.subheadline.weight(.medium)).foregroundStyle(spent > total ? Color.token("red") : Color.moraGreen)
                }.padding(.vertical, 4)
            } footer: { Text(L("Лимиты повторяются каждый месяц · \(currency)")) }
            if ledger.budgets.isEmpty {
                EmptyCard(icon: "chart.pie", title: "Нет бюджетов", text: "Добавьте месячный лимит для категории расходов.", button: "Создать бюджет") { router.open(.budget(nil)) }
                    .listRowBackground(Color.clear)
            }
            Section {
                ForEach(ledger.budgets) { budget in
                    let spent = store.spent(category: budget.categoryID, in: router.month)
                    Button { router.open(.budget(budget)) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            BudgetProgress(budget: budget, month: router.month)
                            FinancialText(spent > budget.limit ? L("Превышение: \(DisplayMoney.string(spent - budget.limit, currency: currency))") : L("Доступно: \(DisplayMoney.string(budget.limit - spent, currency: currency))"))
                                .font(.caption).foregroundStyle(spent > budget.limit ? Color.token("red") : .secondary)
                        }.padding(.vertical, 4)
                    }.buttonStyle(.plain)
                    .swipeActions { Button(role: .destructive) { Task { await store.update { $0.budgets.removeAll { $0.id == budget.id } } } } label: { Label(L("Удалить"), systemImage: "trash") } }
                }
            }
        }
        .navigationTitle(L("Бюджеты"))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { router.open(.budget(nil)) } label: { Image(systemName: "plus") }.accessibilityLabel(L("Создать бюджет")) } }
    }
}

struct BudgetEditor: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    let budget: Budget?
    @State private var categoryID: UUID?
    @State private var limit: String

    init(budget: Budget?) {
        self.budget = budget
        _categoryID = State(initialValue: budget?.categoryID)
        _limit = State(initialValue: budget.map { Money.plain($0.limit) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L("Категория"), selection: $categoryID) {
                        Text(L("Выберите категорию")).tag(UUID?.none)
                        ForEach(store.ledger.categories.filter { c in c.kind == .expense && (!store.ledger.budgets.contains { $0.categoryID == c.id } || budget?.categoryID == c.id) }) {
                            Text($0.name).tag(UUID?.some($0.id))
                        }
                    }.pickerStyle(.navigationLink)
                    LabeledContent(L("Месячный лимит")) {
                        TextField("0", text: $limit).keyboardType(.decimalPad).multilineTextAlignment(.trailing).financialField()
                    }
                } footer: { Text(L("Лимит в \(store.baseCurrency) повторяется каждый месяц")) }
                if let budget {
                    Section { Button(L("Удалить бюджет"), role: .destructive) { Task { if await store.update({ $0.budgets.removeAll { $0.id == budget.id } }) { dismiss() } } } }
                }
            }
            .navigationTitle(budget == nil ? L("Месячный бюджет") : L("Редактировать бюджет"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(L("Отмена"), systemImage: "xmark") } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Сохранить")) {
                        guard let categoryID, let value = Money.parse(limit), value > 0 else { return }
                        let result = Budget(id: budget?.id ?? UUID(), categoryID: categoryID, limit: value)
                        Task { if await store.update({ replaceOrAppend(result, in: &$0.budgets) }) { dismiss() } }
                    }.disabled(categoryID == nil || (Money.parse(limit) ?? 0) <= 0).fontWeight(.semibold)
                }
            }
        }
    }
}

struct GoalsScreen: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        let currency = store.baseCurrency
        List {
            if store.ledger.goals.isEmpty {
                EmptyCard(icon: "flag", title: "Нет целей", text: "Укажите название, сумму и срок накопления.", button: "Создать цель") { router.open(.goal(nil)) }
                    .listRowBackground(Color.clear)
            }
            ForEach(store.ledger.goals) { goal in
                Section {
                    Button { router.open(.goal(goal)) } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                IconTile(icon: goal.icon, color: "purple", size: 44)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(goal.name).font(.headline).foregroundStyle(.primary)
                                    Text(L("До \(goal.deadline.formatted(.dateTime.day().month(.wide).year().locale(L10n.locale)))")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(percent(goal.saved, of: goal.target))%").font(.title3.weight(.semibold)).foregroundStyle(Color.moraGreen)
                            }
                            Meter(progress: (goal.saved / goal.target).double, color: .token("purple"))
                            HStack {
                                FinancialText(DisplayMoney.string(goal.saved, currency: currency)).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Spacer()
                                FinancialText(L("Цель: \(DisplayMoney.string(goal.target, currency: currency))")).font(.caption).foregroundStyle(.secondary)
                            }
                            let months = max(Calendar.current.dateComponents([.month], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: goal.deadline)).month ?? 0, 1)
                            FinancialText(goal.saved >= goal.target ? L("Сумма накоплена") : L("Нужно откладывать: \(DisplayMoney.string((goal.target - goal.saved) / Decimal(months), currency: currency)) в месяц"))
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }.buttonStyle(.plain)
                    .swipeActions { Button(role: .destructive) { Task { await store.update { $0.goals.removeAll { $0.id == goal.id } } } } label: { Label(L("Удалить"), systemImage: "trash") } }
                }
            }
            Section { Text(L("Накопленную сумму обновляйте вручную. Она не влияет на остатки счетов.")).font(.footnote).foregroundStyle(.secondary) }
                .listRowBackground(Color.clear)
        }
        .navigationTitle(L("Цели"))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { router.open(.goal(nil)) } label: { Image(systemName: "plus") }.accessibilityLabel(L("Создать цель")) } }
    }
}

struct GoalEditor: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    let goal: Goal?
    @State private var name: String
    @State private var target: String
    @State private var saved: String
    @State private var deadline: Date
    @State private var icon: String
    private let icons = ["flag", "airplane", "house", "car", "shield.lefthalf.filled", "graduationcap", "gift", "heart", "laptopcomputer", "beach.umbrella"]

    init(goal: Goal?) {
        self.goal = goal
        _name = State(initialValue: goal?.name ?? "")
        _target = State(initialValue: goal.map { Money.plain($0.target) } ?? "")
        _saved = State(initialValue: goal.map { Money.plain($0.saved) } ?? "0")
        _deadline = State(initialValue: goal?.deadline ?? Calendar.current.date(byAdding: .year, value: 1, to: Date())!)
        _icon = State(initialValue: goal?.icon ?? "flag")
    }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && (Money.parse(target) ?? 0) > 0 && (Money.parse(saved) ?? -1) >= 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Название"), text: $name)
                    LabeledContent(L("Целевая сумма")) { TextField("0", text: $target).keyboardType(.decimalPad).multilineTextAlignment(.trailing).financialField() }
                    LabeledContent(L("Уже накоплено")) { TextField("0", text: $saved).keyboardType(.decimalPad).multilineTextAlignment(.trailing).financialField() }
                    DatePicker(L("Срок"), selection: $deadline, displayedComponents: .date)
                } footer: { Text(L("Все суммы в \(store.baseCurrency)")) }
                Section(L("Значок")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(icons, id: \.self) { symbol in
                            Button { icon = symbol } label: {
                                Image(systemName: symbol).font(.title3).frame(width: 46, height: 46)
                                    .foregroundStyle(icon == symbol ? Color.white : Color.token("purple"))
                                    .background(icon == symbol ? Color.token("purple") : Color.token("purple").opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.vertical, 6)
                }
                if let goal {
                    Section { Button(L("Удалить цель"), role: .destructive) { Task { if await store.update({ $0.goals.removeAll { $0.id == goal.id } }) { dismiss() } } } }
                }
            }
            .navigationTitle(goal == nil ? L("Новая цель") : L("Обновить цель"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(L("Отмена"), systemImage: "xmark") } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Сохранить")) {
                        guard let targetValue = Money.parse(target), let savedValue = Money.parse(saved) else { return }
                        let value = Goal(id: goal?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespaces), target: targetValue, saved: savedValue, deadline: deadline, icon: icon)
                        Task { if await store.update({ replaceOrAppend(value, in: &$0.goals) }) { dismiss() } }
                    }.disabled(!canSave).fontWeight(.semibold)
                }
            }
        }
    }
}

struct RecurringScreen: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var router: AppRouter
    @State private var confirming: RecurringPayment?

    var body: some View {
        let ledger = store.ledger
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Платежи в месяц")).font(.subheadline).foregroundStyle(.secondary)
                    FinancialText(DisplayMoney.string(store.monthlyRecurring, currency: store.baseCurrency)).font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text(L("Месячный эквивалент активных платежей")).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            if ledger.recurring.isEmpty {
                EmptyCard(icon: "repeat", title: "Нет регулярных платежей", text: "Добавьте подписки, аренду и другие повторяющиеся расходы.", button: "Добавить платеж") { router.open(.recurring(nil)) }
                    .listRowBackground(Color.clear)
            }
            Section {
                ForEach(ledger.recurring.sorted { $0.nextDate < $1.nextDate }) { payment in
                    let overdue = payment.active && payment.nextDate < Calendar.current.startOfDay(for: Date())
                    Button { router.open(.recurring(payment)) } label: {
                        HStack(spacing: 12) {
                            IconTile(icon: ledger.category(payment.categoryID)?.icon ?? "repeat", color: ledger.category(payment.categoryID)?.color ?? "blue", size: 38)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(payment.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                                Text(L(payment.frequency.title) + " · " + (ledger.account(payment.accountID)?.name ?? "")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                FinancialText(DisplayMoney.string(payment.amount, currency: ledger.account(payment.accountID)?.currency ?? "RUB")).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Text(payment.active ? payment.nextDate.dayTitle : L("Приостановлен")).font(.caption).foregroundStyle(overdue ? Color.token("red") : .secondary)
                            }
                        }.opacity(payment.active ? 1 : 0.6)
                    }.buttonStyle(.plain)
                    .swipeActions(edge: .leading) {
                        if payment.active && ledger.account(payment.accountID)?.archived == false {
                            Button { confirming = payment } label: { Label(L("Учесть"), systemImage: "checkmark.circle") }.tint(.moraGreen)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { Task { await store.update { $0.recurring.removeAll { $0.id == payment.id } } } } label: { Label(L("Удалить"), systemImage: "trash") }
                        Button { Task { await store.update { ledger in if let i = ledger.recurring.firstIndex(where: { $0.id == payment.id }) { ledger.recurring[i].active.toggle() } } } } label: {
                            Label(payment.active ? L("Пауза") : L("Возобновить"), systemImage: payment.active ? "pause" : "play")
                        }.tint(.orange)
                    }
                }
            } footer: {
                Text(L("Смахните вправо, чтобы учесть платеж: он добавится в операции, а дата сдвинется на следующий период. Приложение не списывает деньги в банке."))
            }
        }
        .navigationTitle(L("Регулярные платежи"))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { router.open(.recurring(nil)) } label: { Image(systemName: "plus") }.accessibilityLabel(L("Добавить платеж")) } }
        .confirmationDialog(L("Учесть \(confirming?.name ?? L("платеж"))?"), isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if let payment = confirming { Button(L("Добавить расход")) { Task { await store.pay(payment); confirming = nil } } }
        } message: { Text(L("Будет создана операция на запланированную дату. Если она уже есть в выписке, не добавляйте ее повторно.")) }
    }
}

struct RecurringEditor: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    let payment: RecurringPayment?
    @State private var name: String
    @State private var amount: String
    @State private var accountID: UUID?
    @State private var categoryID: UUID?
    @State private var date: Date
    @State private var frequency: Frequency

    init(payment: RecurringPayment?) {
        self.payment = payment
        _name = State(initialValue: payment?.name ?? "")
        _amount = State(initialValue: payment.map { Money.plain($0.amount) } ?? "")
        _accountID = State(initialValue: payment?.accountID)
        _categoryID = State(initialValue: payment?.categoryID)
        _date = State(initialValue: payment?.nextDate ?? Date())
        _frequency = State(initialValue: payment?.frequency ?? .monthly)
    }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && (Money.parse(amount) ?? 0) > 0 && accountID != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Название"), text: $name)
                    LabeledContent(L("Сумма в валюте счета")) { TextField("0", text: $amount).keyboardType(.decimalPad).multilineTextAlignment(.trailing).financialField() }
                    Picker(L("Счет"), selection: $accountID) {
                        Text(L("Выберите счет")).tag(UUID?.none)
                        ForEach(store.ledger.accounts.filter { !$0.archived || $0.id == accountID }) { Text($0.name + " · " + $0.currency).tag(UUID?.some($0.id)) }
                    }
                    Picker(L("Категория"), selection: $categoryID) {
                        Text(L("Без категории")).tag(UUID?.none)
                        ForEach(store.ledger.categories.filter { $0.kind == .expense }) { Text($0.name).tag(UUID?.some($0.id)) }
                    }.pickerStyle(.navigationLink)
                    Picker(L("Повтор"), selection: $frequency) { ForEach(Frequency.allCases) { Text(L($0.title)).tag($0) } }
                    DatePicker(L("Следующий платеж"), selection: $date, displayedComponents: .date)
                }
                if let payment {
                    Section { Button(L("Удалить расписание"), role: .destructive) { Task { if await store.update({ $0.recurring.removeAll { $0.id == payment.id } }) { dismiss() } } } }
                }
            }
            .navigationTitle(payment == nil ? L("Регулярный платеж") : L("Редактировать платеж"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(L("Отмена"), systemImage: "xmark") } }
                ToolbarItem(placement: .confirmationAction) { Button(L("Сохранить"), action: save).disabled(!canSave).fontWeight(.semibold) }
            }
            .onAppear { if accountID == nil { accountID = store.ledger.accounts.first(where: { !$0.archived })?.id } }
        }
    }

    private func save() {
        guard let value = Money.parse(amount), value > 0, let accountID else { return }
        var result = RecurringPayment(id: payment?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespaces), amount: value, accountID: accountID,
                                      categoryID: categoryID, frequency: frequency, nextDate: Calendar.current.startOfDay(for: date), active: payment?.active ?? true)
        if let payment, Calendar.current.isDate(payment.nextDate, inSameDayAs: date), payment.frequency == frequency { result.anchorDay = payment.anchorDay }
        let saved = result
        Task { if await store.update({ replaceOrAppend(saved, in: &$0.recurring) }) { dismiss() } }
    }
}
