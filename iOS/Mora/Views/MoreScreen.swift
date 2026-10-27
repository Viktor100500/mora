import SwiftUI
import FinanceCore

struct MoreScreen: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var cloud: CloudSync
    @EnvironmentObject private var router: AppRouter
    @State private var importingCSV = false
    @State private var directScreen: String?
    private var preferences: Preferences { store.ledger.preferences }

    var body: some View {
        NavigationStack {
            List {
                if store.isDemo {
                    Section { DemoBanner().listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                }
                Section(L("Учет")) {
                    NavigationLink { CategoriesScreen() } label: { Label(L("Категории и правила"), systemImage: "tag") }
                    if preferences.showBudgets { NavigationLink { BudgetsScreen() } label: { Label(L("Бюджеты"), systemImage: "chart.pie") } }
                    if preferences.showGoals { NavigationLink { GoalsScreen() } label: { Label(L("Цели"), systemImage: "flag") } }
                    if preferences.showRecurring { NavigationLink { RecurringScreen() } label: { Label(L("Регулярные платежи"), systemImage: "repeat") } }
                }
                Section(L("Импорт")) {
                    Button { importingCSV = true } label: { Label(L("Импортировать CSV…"), systemImage: "tablecells") }
                    NavigationLink { ImportHistoryScreen() } label: { Label(L("История импортов"), systemImage: "clock.arrow.circlepath") }
                }
                Section {
                    NavigationLink { CloudScreen() } label: {
                        HStack {
                            Label(L("Общая база и Apple Pay"), systemImage: "icloud")
                            Spacer()
                            if !cloud.pending.isEmpty {
                                Text("\(cloud.pending.count)").font(.caption.weight(.bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 7).padding(.vertical, 2).background(Color.red, in: Capsule())
                            } else if cloud.householdID != nil {
                                Text(cloud.enabled ? L("Включена") : L("Пауза")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    NavigationLink { SettingsScreen() } label: { Label(L("Настройки"), systemImage: "slider.horizontal.3") }
                }
                SupportSection()
                Section {
                    StorageFooter().listRowBackground(Color.clear)
                }
            }
            .navigationTitle(L("Ещё"))
            .navigationDestination(item: $directScreen) { name in
                switch name {
                case "settings": SettingsScreen()
                case "categories": CategoriesScreen()
                case "cloud": CloudScreen()
                case "imports": ImportHistoryScreen()
                case "budgets": BudgetsScreen()
                case "goals": GoalsScreen()
                default: RecurringScreen()
                }
            }
            .onAppear { if let name = router.debugMoreDestination { router.debugMoreDestination = nil; directScreen = name } }
            .fileImporter(isPresented: $importingCSV, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
                switch result {
                case .success(let url):
                    Task { if let file = await store.readCSV(at: url) { router.open(.csv(file.0, file.1)) } }
                case .failure(let error): store.error = error.localizedDescription
                }
            }
        }
    }
}

// MARK: Categories and rules

struct CategoriesScreen: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var router: AppRouter
    @State private var deleting: Category?

    var body: some View {
        List {
            categorySection(.expense, title: L("Расходы"))
            categorySection(.income, title: L("Доходы"))
            Section {
                if store.ledger.rules.isEmpty {
                    Text(L("Создайте правило, например: «ВкусВилл» → «Продукты».")).font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(Array(store.ledger.rules.enumerated()), id: \.element.id) { index, rule in
                    Button { router.open(.rule(rule)) } label: {
                        HStack(spacing: 10) {
                            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("Описание содержит")).font(.caption2).foregroundStyle(.secondary)
                                Text(rule.keyword).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            }
                            Spacer()
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                            Text(store.ledger.category(rule.categoryID)?.name ?? "").font(.subheadline).foregroundStyle(.primary)
                        }
                    }
                }
                .onMove { source, destination in
                    Task { await store.update { $0.rules.move(fromOffsets: source, toOffset: destination) } }
                }
                .onDelete { offsets in
                    let ids = offsets.map { store.ledger.rules[$0].id }
                    Task { await store.update { ledger in ledger.rules.removeAll { ids.contains($0.id) } } }
                }
                Button { router.open(.rule(nil)) } label: { Label(L("Добавить правило"), systemImage: "plus") }
                Button { Task { await store.applyRules() } } label: { Label(L("Применить к существующим"), systemImage: "wand.and.stars") }
                    .disabled(store.ledger.rules.isEmpty)
            } header: { Text(L("Правила категоризации")) } footer: {
                Text(L("Если описание содержит слово, назначить категорию · применяется первое совпадение. Для существующих операций заполняются только пустые категории."))
            }
        }
        .navigationTitle(L("Категории и правила"))
        .toolbar { EditButton() }
        .confirmationDialog(L("Удалить категорию «\(deleting?.name ?? "")»?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let category = deleting { Button(L("Удалить категорию"), role: .destructive) { Task { await store.deleteCategory(category.id); deleting = nil } } }
        } message: { Text(L("Операции сохранятся без категории. Связанные бюджеты и правила будут удалены. Изменение можно отменить.")) }
    }

    private func categorySection(_ kind: TransactionKind, title: String) -> some View {
        Section(title) {
            ForEach(store.ledger.categories.filter { $0.kind == kind }) { category in
                Button { router.open(.category(category, kind)) } label: {
                    HStack(spacing: 12) {
                        IconTile(icon: category.icon, color: category.color, size: 34)
                        Text(category.name).foregroundStyle(.primary)
                    }
                }
                .swipeActions { Button(role: .destructive) { deleting = category } label: { Label(L("Удалить"), systemImage: "trash") } }
            }
            Button { router.open(.category(nil, kind)) } label: { Label(L("Добавить категорию"), systemImage: "plus") }
        }
    }
}

struct CategoryEditor: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    let category: Category?
    @State private var name: String
    @State private var kind: TransactionKind
    @State private var icon: String
    @State private var color: String
    @State private var useEmoji: Bool
    @State private var emoji: String

    static let symbols = [
        "tag", "basket", "cart", "cup.and.saucer", "fork.knife", "carrot", "wineglass", "birthday.cake",
        "tram", "car", "bus", "bicycle", "fuelpump", "airplane", "ferry", "parkingsign.circle",
        "house", "building.2", "key", "bolt", "drop", "flame", "lightbulb", "sofa",
        "bag", "tshirt", "gift", "heart", "cross.case", "pills", "stethoscope", "pawprint",
        "sparkles", "gamecontroller", "film", "music.note", "book", "graduationcap", "figure.run", "dumbbell",
        "repeat", "phone", "iphone", "wifi", "antenna.radiowaves.left.and.right", "network", "desktopcomputer", "envelope",
        "building.columns", "doc.text", "percent", "banknote", "creditcard", "receipt", "chart.line.uptrend.xyaxis", "shield",
        "briefcase", "hammer", "wrench.and.screwdriver", "paintbrush", "leaf", "globe", "arrow.down.left", "ellipsis"
    ]

    init(category: Category?, kind: TransactionKind) {
        self.category = category
        _name = State(initialValue: category?.name ?? "")
        _kind = State(initialValue: category?.kind ?? kind)
        let icon = category?.icon ?? "tag"
        _icon = State(initialValue: icon)
        _useEmoji = State(initialValue: CategoryAppearance.isEmoji(icon))
        _emoji = State(initialValue: CategoryAppearance.isEmoji(icon) ? icon : "🏷️")
        _color = State(initialValue: category?.color ?? "green")
    }

    private var resolvedIcon: String { useEmoji ? emoji : icon }
    private var validIcon: Bool { useEmoji ? CategoryAppearance.isEmoji(emoji) : (Self.symbols.contains(icon) || icon == category?.icon) }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validIcon }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        IconTile(icon: validIcon ? resolvedIcon : "tag", color: color, size: 48)
                        TextField(L("Название"), text: $name).font(.headline)
                    }
                    Picker(L("Тип"), selection: $kind) {
                        Text(L("Расход")).tag(TransactionKind.expense)
                        Text(L("Доход")).tag(TransactionKind.income)
                    }.pickerStyle(.segmented).disabled(category != nil)
                }
                Section(L("Значок")) {
                    Picker(L("Значок"), selection: $useEmoji) {
                        Text(L("Символ")).tag(false)
                        Text(L("Эмодзи")).tag(true)
                    }.pickerStyle(.segmented)
                    if useEmoji {
                        TextField(L("Эмодзи"), text: $emoji)
                            .font(.largeTitle)
                            .onChange(of: emoji) { _, value in if let last = value.last, value.count > 1 { emoji = String(last) } }
                        if !CategoryAppearance.isEmoji(emoji) { Text(L("Введите один эмодзи.")).font(.caption).foregroundStyle(.red) }
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                            ForEach(Self.symbols, id: \.self) { symbol in
                                Button { icon = symbol } label: {
                                    Image(systemName: symbol).font(.title3).frame(width: 42, height: 42)
                                        .foregroundStyle(icon == symbol ? Color.white : Color.token(color))
                                        .background(icon == symbol ? Color.token(color) : Color.token(color).opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }.buttonStyle(.plain)
                            }
                        }.padding(.vertical, 6)
                    }
                }
                Section(L("Цвет")) { ColorPalettePicker(color: $color) }
            }
            .navigationTitle(category == nil ? L("Новая категория") : L("Редактировать категорию"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(L("Отмена"), systemImage: "xmark") } }
                ToolbarItem(placement: .confirmationAction) { Button(L("Сохранить"), action: save).disabled(!canSave).fontWeight(.semibold) }
            }
        }
    }

    private func save() {
        let value = Category(id: category?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), icon: resolvedIcon, color: color, kind: kind)
        Task {
            if await store.update({ ledger in
                guard !ledger.categories.contains(where: { $0.id != value.id && $0.kind == value.kind && $0.name.localizedCaseInsensitiveCompare(value.name) == .orderedSame }) else {
                    throw LedgerError.invalid("Такая категория уже существует.")
                }
                replaceOrAppend(value, in: &ledger.categories)
            }) { dismiss() }
        }
    }
}

struct RuleEditor: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    let rule: CategoryRule?
    @State private var keyword: String
    @State private var categoryID: UUID?

    init(rule: CategoryRule?) {
        self.rule = rule
        _keyword = State(initialValue: rule?.keyword ?? "")
        _categoryID = State(initialValue: rule?.categoryID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Описание содержит"), text: $keyword).textInputAutocapitalization(.never)
                    Picker(L("Назначить категорию"), selection: $categoryID) {
                        Text(L("Выберите категорию")).tag(UUID?.none)
                        ForEach(store.ledger.categories) { Text($0.name + ($0.kind == .income ? L(" · доход") : "")).tag(UUID?.some($0.id)) }
                    }.pickerStyle(.navigationLink)
                } footer: { Text(L("Поиск в описании без учета регистра")) }
                if let rule {
                    Section {
                        Button(L("Удалить правило"), role: .destructive) {
                            Task { if await store.update({ $0.rules.removeAll { $0.id == rule.id } }) { dismiss() } }
                        }
                    }
                }
            }
            .navigationTitle(L("Правило категоризации"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(L("Отмена"), systemImage: "xmark") } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Сохранить")) {
                        guard let categoryID else { return }
                        let value = CategoryRule(id: rule?.id ?? UUID(), keyword: keyword.trimmingCharacters(in: .whitespaces), categoryID: categoryID)
                        Task { if await store.update({ replaceOrAppend(value, in: &$0.rules) }) { dismiss() } }
                    }
                    .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty || categoryID == nil).fontWeight(.semibold)
                }
            }
        }
    }
}
