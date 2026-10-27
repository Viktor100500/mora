import SwiftUI
import FinanceCore

struct Toast: Identifiable, Equatable {
    enum Kind: Equatable { case success, warning, error }
    let id = UUID()
    var message: String
    var detail: String?
    var kind: Kind = .success
    var undoable = false
}

/// The iPhone counterpart of the Mac store. All writes go through the shared
/// `LedgerRepository`, so the file format, validation, demo mode and undo history match.
@MainActor
final class FinanceStore: ObservableObject {
    @Published private(set) var ledger: Ledger = .empty { didSet { reports.reset() } }
    @Published private(set) var isDemo = false
    @Published private(set) var isLoading = true
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var undoDescriptions: [ChangeDescription] = []
    @Published private(set) var redoDescriptions: [ChangeDescription] = []
    @Published private(set) var imports = ImportPresentation()
    @Published private(set) var updatingRates = false
    @Published private(set) var rateUpdateError: String?
    @Published var error: String?
    @Published private(set) var toast: Toast?
    private var toastDismissal: Task<Void, Never>?
    private var writeBlocked = false
    private var lastRateAttempt: Date?
    private var loadingTask: Task<Void, Never>?
    let fileURL: URL
    let reports = ReportCache()
    private let repository: LedgerRepository

    var undoDescription: ChangeDescription? { undoDescriptions.first }
    var redoDescription: ChangeDescription? { redoDescriptions.first }
    var baseCurrency: String { ledger.preferences.baseCurrency }

    init(directory customDirectory: URL? = nil, forcedDemo: Bool? = nil) {
        let args = ProcessInfo.processInfo.arguments
        let directory: URL
        if let customDirectory { directory = customDirectory }
        else if let i = args.firstIndex(of: "--data-dir"), args.indices.contains(i + 1) { directory = URL(fileURLWithPath: args[i + 1]) }
        else { directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mora", isDirectory: true) }
        fileURL = directory.appendingPathComponent("ledger.json")
        repository = LedgerRepository(fileURL: fileURL, forcedDemo: forcedDemo ?? args.contains("--demo"))
    }

    func load() async {
        if let loadingTask { await loadingTask.value; return }
        guard isLoading else { return }
        let task = Task { @MainActor in
            do {
                let directory = fileURL.deletingLastPathComponent()
                try await BackgroundWork.shared.perform {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    // Ledger files are excluded from iCloud device backups only by the user's choice;
                    // the protection class keeps them encrypted while the iPhone is locked.
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
                }
                publish(try await repository.load())
            } catch { self.error = error.localizedDescription; writeBlocked = true }
            isLoading = false
        }
        loadingTask = task
        await task.value
        loadingTask = nil
    }

    private func publish(_ snapshot: LedgerSnapshot) {
        guard snapshot.revision > revision else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            undoDescriptions = snapshot.undoDescriptions; redoDescriptions = snapshot.redoDescriptions
            imports = snapshot.imports
            isDemo = snapshot.isDemo; writeBlocked = snapshot.writeBlocked
            revision = snapshot.revision
            ledger = snapshot.ledger
        }
        if let warning = snapshot.warning { error = L(warning) }
    }

    func reloadFromDisk() async {
        await load()
        guard !writeBlocked else { return }
        do { publish(try await repository.load()) }
        catch { self.error = error.localizedDescription }
    }

    // MARK: Notices

    func showToast(_ message: String, detail: String? = nil, kind: Toast.Kind = .success, undoable: Bool = false) {
        toastDismissal?.cancel()
        let value = Toast(message: message, detail: detail, kind: kind, undoable: undoable && !undoDescriptions.isEmpty)
        withAnimation(.spring(duration: 0.35)) { toast = value }
        toastDismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(value.undoable ? 6 : 4)) } catch { return }
            if self?.toast?.id == value.id { withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil } }
        }
    }
    func dismissToast() { withAnimation(.easeOut(duration: 0.2)) { toast = nil } }

    // MARK: Writes

    func change<Value: Sendable>(_ action: @escaping @Sendable (inout Ledger) throws -> Value) async -> Value? {
        await load()
        do {
            let result = try await repository.mutate(action)
            // Publish the persisted form: JSON keeps whole seconds, and later
            // edits compare against the file, not against this in-memory value.
            publish((try? await repository.load()) ?? result.snapshot)
            return result.value
        } catch { self.error = error.localizedDescription; return nil }
    }
    @discardableResult
    func update(_ action: @escaping @Sendable (inout Ledger) throws -> Void) async -> Bool {
        await change { ledger in try action(&ledger); return true } ?? false
    }
    func undo() async {
        await reloadFromDisk()
        guard let description = undoDescription else { return }
        do {
            publish(try await repository.moveHistory(undo: true))
            showToast(L("Отменено: \(description.title)"), detail: description.detail)
        } catch { self.error = error.localizedDescription }
    }
    func redo() async {
        await reloadFromDisk()
        guard let description = redoDescription else { return }
        do {
            publish(try await repository.moveHistory(undo: false))
            showToast(L("Возвращено: \(description.title)"), detail: description.detail, undoable: true)
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult
    func startClean(baseCurrency: String, announce: Bool = true) async -> Bool {
        await load()
        do {
            let (snapshot, existing) = try await repository.initialize(baseCurrency: baseCurrency)
            publish(snapshot)
            if announce { showToast(existing ? L("Открыта ваша существующая база вместо демо") : L("Добавьте счет для учета операций.")) }
            lastRateAttempt = nil
            Task { await refreshExchangeRates() }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult
    func saveTransaction(_ value: Transaction, original: Transaction? = nil) async -> Bool {
        let saved = await update { ledger in
            let originalID = original?.id
            let existing = originalID.flatMap { id in ledger.transactions.first { $0.id == id } }
            guard originalID == nil || existing != nil else { throw LedgerError.invalid("Операция уже удалена.") }
            guard originalID != nil || !ledger.transactions.contains(where: { $0.id == value.id }) else { throw LedgerError.invalid("Такая операция уже существует.") }
            guard ledger.account(value.accountID)?.archived == false || existing?.accountID == value.accountID else { throw LedgerError.invalid("Верните счет из архива перед добавлением операций.") }
            if let destination = value.destinationAccountID {
                guard ledger.account(destination)?.archived == false || existing?.destinationAccountID == destination else { throw LedgerError.invalid("Верните счет из архива перед добавлением операций.") }
            }
            var result = value
            if let original, let existing { result = try value.mergingEditorChanges(from: original, into: existing) }
            if result.categoryID == nil && result.kind != .transfer {
                result.categoryID = ledger.suggestedCategory(merchant: result.merchant, kind: result.kind)
            }
            replaceOrAppend(result, in: &ledger.transactions)
        }
        if saved { showToast(L("Операция сохранена"), detail: value.merchant, undoable: true) }
        return saved
    }

    func deleteTransactions(_ ids: Set<UUID>) async {
        let result = await change { ledger -> ChangeDescription? in
            let before = ledger
            ledger.transactions.removeAll { ids.contains($0.id) }
            guard ledger.transactions.count != before.transactions.count else { return nil }
            return ChangeDescriptions.between(before, ledger)
        }
        if let description = result ?? nil { showToast(description.title, detail: description.detail, undoable: true) }
    }

    func duplicateTransactions(_ ids: Set<UUID>) async {
        let count: Int? = await change { ledger in
            let copies = ledger.transactions.filter { ids.contains($0.id) }.map { original in
                var copy = original
                copy.id = UUID(); copy.externalID = nil; copy.recurrenceID = nil; copy.importBatchID = nil
                return copy
            }
            ledger.transactions.append(contentsOf: copies)
            return copies.count
        }
        if let count, count > 0 { showToast(L("Дублировано операций: \(count)"), undoable: true) }
    }

    func assignCategory(_ categoryID: UUID?, to ids: Set<UUID>) async {
        await update { ledger in
            let kind = ledger.category(categoryID)?.kind
            for index in ledger.transactions.indices where ids.contains(ledger.transactions[index].id) {
                guard ledger.transactions[index].kind != .transfer else { continue }
                if let kind, ledger.transactions[index].kind != kind { continue }
                ledger.transactions[index].categoryID = categoryID
            }
        }
    }

    func split(_ transaction: Transaction, firstAmount: Decimal, firstCategory: UUID?, secondCategory: UUID?) async -> Bool {
        let remainder = abs(transaction.amount) - firstAmount
        guard firstAmount > 0, remainder > 0 else { return false }
        var first = transaction, second = transaction
        let sign: Decimal = transaction.kind == .income ? 1 : -1
        first.amount = sign * firstAmount; first.categoryID = firstCategory
        second.id = UUID(); second.amount = sign * remainder; second.categoryID = secondCategory
        second.externalID = transaction.externalID.map { $0 + ":split:" + second.id.uuidString }; second.recurrenceID = nil
        if let conversion = transaction.conversion {
            let context = L("Исходная покупка: \(Money.plain(conversion.originalAmount)) \(conversion.originalCurrency); Visa \(Money.plain(conversion.rate)) на \(Dates.string(conversion.date)).")
            first.note += (first.note.isEmpty ? "" : "\n") + context; second.note += (second.note.isEmpty ? "" : "\n") + context
            first.conversion = nil; second.conversion = nil
        }
        let parts = [first, second]
        return await update { ledger in
            guard ledger.transactions.first(where: { $0.id == transaction.id }) == transaction else {
                throw LedgerError.invalid("Данные изменились в другом окне или через MCP. Повторите действие с обновленными данными.")
            }
            ledger.transactions.removeAll { $0.id == transaction.id }
            ledger.transactions.append(contentsOf: parts)
        }
    }

    func setAccountArchived(_ id: UUID, archived: Bool) async {
        if await update({ try $0.setAccountArchived(id, archived: archived) }) {
            showToast(archived ? L("Счет архивирован и исключен из расчетов") : L("Счет возвращен из архива"), undoable: true)
        }
    }
    func deleteArchivedAccount(_ id: UUID) async {
        if await update({ try $0.deleteArchivedAccount(id) }) {
            showToast(L("Счет удален"), undoable: true)
        }
    }
    func deleteCategory(_ id: UUID) async {
        if await update({ ledger in
            for i in ledger.transactions.indices where ledger.transactions[i].categoryID == id { ledger.transactions[i].categoryID = nil }
            for i in ledger.recurring.indices where ledger.recurring[i].categoryID == id { ledger.recurring[i].categoryID = nil }
            ledger.budgets.removeAll { $0.categoryID == id }; ledger.rules.removeAll { $0.categoryID == id }
            ledger.categories.removeAll { $0.id == id }
        }) { showToast(L("Категория удалена"), undoable: true) }
    }
    func pay(_ payment: RecurringPayment) async {
        let success = await update { ledger in
            guard let index = ledger.recurring.firstIndex(where: { $0.id == payment.id }) else { return }
            guard ledger.account(payment.accountID)?.archived == false else { throw LedgerError.invalid("Верните счет из архива перед учетом платежа.") }
            let id = "recurring:\(payment.id):\(Dates.string(payment.nextDate))"
            guard !ledger.transactions.contains(where: { $0.externalID == id }) else { throw LedgerError.invalid("Этот платеж уже учтен.") }
            ledger.transactions.append(Transaction(date: payment.nextDate, merchant: payment.name, amount: -payment.amount, accountID: payment.accountID, categoryID: payment.categoryID, kind: .expense, externalID: id, recurrenceID: payment.id))
            ledger.recurring[index].nextDate = payment.followingDate()
        }
        if success { showToast(L("Платеж добавлен в операции"), undoable: true) }
    }
    func applyRules() async {
        let count: Int? = await change { ledger in
            var count = 0
            for i in ledger.transactions.indices where ledger.transactions[i].categoryID == nil && ledger.transactions[i].kind != .transfer {
                if let id = ledger.matchingCategory(merchant: ledger.transactions[i].merchant, kind: ledger.transactions[i].kind) {
                    ledger.transactions[i].categoryID = id; count += 1
                }
            }
            return count
        }
        if let count { showToast(L("Категоризировано операций: \(count)"), undoable: count > 0) }
    }

    // MARK: Import, export and backups

    @discardableResult
    func importPreparedCSV(_ prepared: CSVImportResult, filename: String, expected: Ledger) async -> Bool {
        let batch: ImportBatch? = await change { current in
            guard try LedgerFile.equivalent(current, expected), prepared.imported > 0 else {
                throw LedgerError.invalid("Данные изменились после предпросмотра. Проверьте обновленный список и повторите импорт.")
            }
            let existing = Set(current.transactions.map(\.id))
            current = prepared.ledger
            guard let batch = try current.recordImport(addedIDs: Set(current.transactions.map(\.id)).subtracting(existing), filename: filename,
                totalRows: prepared.rows.count, excluded: prepared.excluded, duplicates: prepared.duplicates, invalid: prepared.invalid) else {
                throw LedgerError.invalid("Нет операций для импорта.")
            }
            return batch
        }
        guard batch != nil else { return false }
        showToast(L("Добавлено: \(prepared.imported). Исключено: \(prepared.excluded). Повторы: \(prepared.duplicates). Ошибки: \(prepared.invalid)."), undoable: true)
        return true
    }
    func rollbackImport(_ id: UUID, allowModified: Bool = false) async {
        let filename = ledger.importHistory.first { $0.id == id }?.filename ?? L("Импорт")
        let removed: Int? = await change { try $0.rollbackImport(id, allowModified: allowModified) }
        if let removed { showToast(L("Импорт отменен: \(filename)"), detail: L("Удалено операций: \(removed)"), undoable: true) }
    }
    func csvExport(_ transactions: [Transaction]? = nil) async -> Data? {
        let snapshot = ledger
        return await BackgroundWork.shared.perform { Data(CSVImporter.export(snapshot, transactions: transactions).utf8) }
    }
    func backupData() async -> Data? {
        let snapshot = ledger
        do { return try await BackgroundWork.shared.perform { try LedgerFile.encode(snapshot) } }
        catch { self.error = error.localizedDescription; return nil }
    }
    func readBackup(at url: URL) async -> Ledger? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { return try await BackgroundWork.shared.perform { try LedgerFile.decode(Data(contentsOf: url)) } }
        catch { self.error = error.localizedDescription; return nil }
    }
    func readCSV(at url: URL) async -> (CSVTable, String)? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            return try await BackgroundWork.shared.perform {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 20_000_000 else { throw LedgerError.invalid("Файл больше 20 МБ. Разделите его на части.") }
                return (try CSVTable.read(Data(contentsOf: url)), url.lastPathComponent)
            }
        } catch { self.error = error.localizedDescription; return nil }
    }
    func restore(_ ledger: Ledger) async {
        await load()
        do {
            publish(try await repository.restore(ledger))
            showToast(L("Данные восстановлены"))
            lastRateAttempt = nil; rateUpdateError = nil
            Task { await refreshExchangeRates() }
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Exchange rates

    func refreshExchangeRates(force: Bool = false) async {
        guard !isDemo, !writeBlocked, ledger.preferences.automaticRates, !updatingRates else { return }
        let now = Date()
        guard ExchangeRateRefreshPolicy.shouldRefresh(snapshot: ledger.preferences.exchangeRateSnapshot, lastAttempt: lastRateAttempt, now: now, force: force) else { return }
        lastRateAttempt = now; updatingRates = true; rateUpdateError = nil
        defer { updatingRates = false }
        do {
            let snapshot = try await ExchangeRateClient().fetch(now: now)
            try Task.checkCancellation()
            guard !isDemo, !writeBlocked, ledger.preferences.automaticRates else { return }
            let result = try await repository.mutate(recordHistory: false) { ledger in
                guard ledger.preferences.automaticRates else { return }
                try ledger.applyExchangeRates(snapshot)
            }
            publish(result.snapshot)
        } catch is CancellationError {
            lastRateAttempt = nil
        } catch {
            guard ledger.preferences.automaticRates else { return }
            rateUpdateError = (error as? URLError) != nil ? L("Не удалось подключиться к сервису курсов. Проверьте интернет-соединение.") : error.localizedDescription
        }
    }
    func setAutomaticRates(_ enabled: Bool) async {
        let success = await update { next in
            next.preferences.automaticRates = enabled
            if enabled, let snapshot = next.preferences.exchangeRateSnapshot {
                next.preferences.rates = try snapshot.rates(in: next.preferences.baseCurrency)
            }
        }
        if success {
            rateUpdateError = nil; lastRateAttempt = nil
            if enabled { await refreshExchangeRates(force: true) }
        }
    }
}
