import SwiftUI
import FinanceCore

struct TransactionsScreen: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var router: AppRouter
    @State private var filters = TransactionSearch()
    @State private var result: TransactionSearch.Result?
    @State private var selection: Set<UUID> = []
    @State private var editMode: EditMode = .inactive
    @State private var showFilters = false
    @State private var confirmDelete = false
    @State private var exportFile: ExportFile?

    private struct SearchRequest: Equatable { let query: TransactionSearch; let revision: UInt64 }
    private var request: SearchRequest { SearchRequest(query: filters, revision: store.revision) }
    private var rows: [Transaction] { result?.rows ?? [] }
    private var days: [(day: Date, rows: [Transaction])] {
        var groups: [(day: Date, rows: [Transaction])] = []
        for row in rows {
            let day = Calendar.current.startOfDay(for: row.date)
            if groups.last?.day == day { groups[groups.count - 1].rows.append(row) } else { groups.append((day, [row])) }
        }
        return groups
    }
    private var isFiltered: Bool { filters.accountIDs != nil || filters.kinds != nil || filters.categoryIDs != nil }
    private var monthPeriod: Date? {
        let start = Dates.month(filters.startDate)
        let end = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.date(byAdding: .month, value: 1, to: start)!)!
        return Calendar.current.isDate(filters.startDate, inSameDayAs: start) && Calendar.current.isDate(filters.endDate, inSameDayAs: end) ? start : nil
    }

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                Section {
                    // The separator otherwise starts at the centered title.
                    periodHeader.alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    if let result { totals(result) }
                }
                if result == nil {
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                } else if rows.isEmpty {
                    EmptyCard(icon: "arrow.left.arrow.right", title: "Операций не найдено",
                              text: filters.text.isEmpty ? "Добавьте операцию или импортируйте выписку. Также можно изменить фильтры и период." : "Попробуйте другой запрос или сбросьте фильтры.",
                              button: "Добавить операцию") { router.open(.transaction(nil)) }
                        .listRowBackground(Color.clear)
                }
                ForEach(days, id: \.day) { group in
                    Section {
                        ForEach(group.rows) { transaction in
                            row(transaction)
                        }
                    } header: {
                        HStack {
                            Text(group.day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(L10n.locale)).capitalized(with: L10n.locale))
                            Spacer()
                            let total = dayExpense(group.rows)
                            if total > 0 { FinancialText("−" + DisplayMoney.string(total, currency: store.baseCurrency)) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, $editMode)
            .searchable(text: $filters.text, prompt: L("Поиск по описанию, заметкам и тегам"))
            .navigationTitle(L("Операции"))
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { if editMode.isEditing { bulkBar } }
            .sheet(isPresented: $showFilters) {
                TransactionFiltersView(filters: $filters).environmentObject(store).environment(\.locale, L10n.locale)
            }
            .fileExporter(isPresented: Binding(get: { exportFile != nil }, set: { if !$0 { exportFile = nil } }),
                          document: exportFile?.document, contentType: .commaSeparatedText, defaultFilename: exportFile?.name) { result in
                if case .failure(let error) = result { store.error = error.localizedDescription }
            }
            .confirmationDialog(L("Удалить \(selection.count) операций?"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(L("Удалить операции"), role: .destructive) {
                    let ids = selection
                    Task { await store.deleteTransactions(ids); selection = []; editMode = .inactive }
                }
            } message: { Text(L("Изменение можно отменить.")) }
            .task(id: request) {
                let request = request, snapshot = store.ledger.withoutChangeHistory()
                do {
                    if !request.query.text.isEmpty { try await Task.sleep(for: .milliseconds(150)) }
                    let value = try await BackgroundWork.shared.perform { try request.query.prepare(in: snapshot) }
                    guard !Task.isCancelled, request == self.request else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { result = value; selection.formIntersection(value.ids) }
                } catch is CancellationError {
                } catch { store.error = error.localizedDescription }
            }
            .onAppear(perform: applyRequestedFilter)
            .onChange(of: router.transactionFilter) { _, _ in applyRequestedFilter() }
        }
    }

    private func row(_ transaction: Transaction) -> some View {
        TransactionRow(transaction: transaction, ledger: store.ledger, showsDate: false)
            .tag(transaction.id)
            .onTapGesture { if !editMode.isEditing { router.open(.transaction(transaction)) } }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { Task { await store.deleteTransactions([transaction.id]) } } label: { Label(L("Удалить"), systemImage: "trash") }
            }
            .swipeActions(edge: .leading) {
                Button { Task { await store.duplicateTransactions([transaction.id]) } } label: { Label(L("Дублировать"), systemImage: "plus.square.on.square") }
                    .tint(.blue)
            }
            .contextMenu {
                Button { router.open(.transaction(transaction)) } label: { Label(L("Редактировать"), systemImage: "pencil") }
                Button { router.open(.similar(transaction)) } label: { Label(L("Создать похожую"), systemImage: "plus.rectangle.on.rectangle") }
                Button { Task { await store.duplicateTransactions([transaction.id]) } } label: { Label(L("Дублировать"), systemImage: "plus.square.on.square") }
                if transaction.kind != .transfer {
                    Button { router.open(.split(transaction)) } label: { Label(L("Разделить по категориям"), systemImage: "square.split.2x1") }
                }
                Divider()
                Button(role: .destructive) { Task { await store.deleteTransactions([transaction.id]) } } label: { Label(L("Удалить"), systemImage: "trash") }
            }
    }

    private var periodHeader: some View {
        HStack {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                .accessibilityLabel(L("Предыдущий месяц"))
            Spacer()
            Button { showFilters = true } label: {
                VStack(spacing: 2) {
                    Text(monthPeriod?.monthTitle ?? "\(filters.startDate.shortDay) – \(filters.endDate.shortDay)").font(.headline).foregroundStyle(.primary)
                    if isFiltered { Text(L("Фильтры включены")).font(.caption2).foregroundStyle(Color.moraGreen) }
                }
            }.buttonStyle(.borderless)
            Spacer()
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                .accessibilityLabel(L("Следующий месяц"))
        }
    }

    private func totals(_ result: TransactionSearch.Result) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Доходы")).font(.caption).foregroundStyle(.secondary)
                FinancialText("+" + DisplayMoney.string(result.income, currency: store.baseCurrency)).font(.subheadline.weight(.semibold)).foregroundStyle(Color.moraGreen)
            }
            Spacer()
            VStack(alignment: .center, spacing: 2) {
                Text(L("Операций")).font(.caption).foregroundStyle(.secondary)
                Text("\(result.rows.count)").font(.subheadline.weight(.semibold))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(L("Расходы")).font(.caption).foregroundStyle(.secondary)
                FinancialText("−" + DisplayMoney.string(result.expense, currency: store.baseCurrency)).font(.subheadline.weight(.semibold))
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(editMode.isEditing ? L("Готово") : L("Выбрать")) {
                withAnimation { editMode = editMode.isEditing ? .inactive : .active; if !editMode.isEditing { selection = [] } }
            }.disabled(rows.isEmpty && !editMode.isEditing)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button { showFilters = true } label: { Label(L("Фильтры и период"), systemImage: "line.3.horizontal.decrease.circle") }
                if isFiltered || monthPeriod == nil {
                    Button { withAnimation { filters = TransactionSearch(startDate: Dates.month(filters.startDate), text: filters.text) } } label: { Label(L("Сбросить фильтры"), systemImage: "xmark.circle") }
                }
                Divider()
                Button { Task { await export() } } label: { Label(L("Экспорт CSV"), systemImage: "square.and.arrow.up") }
                    .disabled(rows.isEmpty)
            } label: {
                Image(systemName: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            Button { router.open(.transaction(nil)) } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                .accessibilityLabel(L("Новая операция"))
        }
    }

    private var bulkBar: some View {
        HStack(spacing: 12) {
            Text(L("Выбрано: \(selection.count)")).font(.subheadline.weight(.medium))
            Spacer()
            Menu {
                ForEach(store.ledger.categories) { category in
                    Button(category.name + (category.kind == .income ? L(" · доход") : "")) {
                        let ids = selection
                        Task { await store.assignCategory(category.id, to: ids); selection = [] }
                    }
                }
                Divider()
                Button(L("Убрать категорию")) {
                    let ids = selection
                    Task { await store.assignCategory(nil, to: ids); selection = [] }
                }
            } label: { Label(L("Категория"), systemImage: "tag") }
            Button { let ids = selection; Task { await store.duplicateTransactions(ids); selection = [] } } label: { Image(systemName: "plus.square.on.square") }
                .accessibilityLabel(L("Дублировать"))
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .accessibilityLabel(L("Удалить"))
        }
        .disabled(selection.isEmpty)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.bar)
    }

    private func dayExpense(_ rows: [Transaction]) -> Decimal {
        rows.filter { $0.kind == .expense && store.ledger.isActive($0) }.reduce(0) { $0 - (store.ledger.value($1) ?? 0) }
    }

    private func shiftMonth(_ offset: Int) {
        let start = Calendar.current.date(byAdding: .month, value: offset, to: Dates.month(filters.startDate))!
        withAnimation {
            filters.startDate = start
            filters.endDate = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.date(byAdding: .month, value: 1, to: start)!)!
        }
    }

    private func applyRequestedFilter() {
        guard let request = router.transactionFilter else { return }
        router.transactionFilter = nil
        var next = TransactionSearch(startDate: Dates.month(request.month))
        if let category = request.categoryID { next.categoryIDs = [category] }
        if let account = request.accountID { next.accountIDs = [account] }
        filters = next
    }

    private func export() async {
        guard let data = await store.csvExport(rows) else { return }
        exportFile = ExportFile(document: DataDocument(data: data), name: "Mora-\(Dates.string(Date())).csv")
    }
}

struct TransactionFiltersView: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    @Binding var filters: TransactionSearch

    var body: some View {
        NavigationStack {
            Form {
                Section(L("Период")) {
                    DatePicker(L("С"), selection: $filters.startDate, displayedComponents: .date)
                    DatePicker(L("По"), selection: $filters.endDate, in: filters.startDate..., displayedComponents: .date)
                    HStack {
                        quickPeriod(L("Этот месяц"), months: 0)
                        quickPeriod(L("3 месяца"), months: 2)
                        quickPeriod(L("Год"), months: 11)
                    }.buttonStyle(.bordered).controlSize(.small)
                }
                Section(L("Типы")) {
                    ForEach(TransactionKind.allCases) { kind in
                        check(L(kind.title), isOn: filters.kinds?.contains(kind) ?? true) { toggle(kind, in: &filters.kinds, all: Set(TransactionKind.allCases)) }
                    }
                }
                Section(L("Счета")) {
                    ForEach(store.ledger.accounts) { account in
                        check(account.name + " · " + account.currency, isOn: filters.accountIDs?.contains(account.id) ?? true) {
                            toggle(account.id, in: &filters.accountIDs, all: Set(store.ledger.accounts.map(\.id)))
                        }
                    }
                }
                Section(L("Категории")) {
                    check(L("Без категории"), isOn: filters.categoryIDs == nil || filters.includesUncategorized) {
                        if filters.categoryIDs == nil { filters.categoryIDs = Set(store.ledger.categories.map(\.id)); filters.includesUncategorized = false }
                        else { filters.includesUncategorized.toggle(); normalizeCategories() }
                    }
                    ForEach(store.ledger.categories) { category in
                        check(category.name + (category.kind == .income ? L(" · доход") : ""), isOn: filters.categoryIDs?.contains(category.id) ?? true) {
                            if filters.categoryIDs == nil { filters.includesUncategorized = true }
                            toggle(category.id, in: &filters.categoryIDs, all: Set(store.ledger.categories.map(\.id)))
                            if filters.categoryIDs == nil { filters.includesUncategorized = false }
                            normalizeCategories()
                        }
                    }
                }
            }
            .navigationTitle(L("Фильтры"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("Сбросить")) { filters = TransactionSearch(startDate: Dates.month(filters.startDate), text: filters.text) }
                }
                ToolbarItem(placement: .confirmationAction) { Button(L("Готово")) { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func check(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if isOn { Image(systemName: "checkmark").foregroundStyle(Color.moraGreen).fontWeight(.semibold) }
            }
        }
    }

    private func toggle<T: Hashable>(_ value: T, in set: inout Set<T>?, all: Set<T>) {
        var current = set ?? all
        if current.contains(value) { current.remove(value) } else { current.insert(value) }
        set = current == all ? nil : current
    }

    private func normalizeCategories() {
        if filters.categoryIDs == Set(store.ledger.categories.map(\.id)) && filters.includesUncategorized {
            filters.categoryIDs = nil; filters.includesUncategorized = false
        }
    }

    private func quickPeriod(_ title: String, months: Int) -> some View {
        Button(title) {
            let end = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.date(byAdding: .month, value: 1, to: Dates.month(Date()))!)!
            filters.startDate = Calendar.current.date(byAdding: .month, value: -months, to: Dates.month(Date()))!
            filters.endDate = end
        }
    }
}
