import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FinanceCore
import CryptoKit

typealias Transaction = FinanceCore.Transaction
typealias Category = FinanceCore.Category

@MainActor
final class FinanceStore: ObservableObject {
    @Published private(set) var ledger: Ledger {
        didSet {
            let sharedAccounts = Set(oldValue.accounts.map(\.id)).intersection(ledger.accounts.map(\.id))
            reports = ReportCache(previous: oldValue.preferences.baseCurrency == ledger.preferences.baseCurrency && !sharedAccounts.isEmpty ? reports : nil)
            let missing = ledger.missingCurrencies
            if !missing.isEmpty, missing != oldValue.missingCurrencies {
                notifications.record(L("В итогах не учтены валюты без курса: \(missing.joined(separator: ", "))"),
                                     kind: .warning, actions: [.settings])
            }
        }
    }
    @Published private(set) var isDemo: Bool
    @Published var error: String? {
        didSet { if let error, error != oldValue { notifications.record(error, kind: .error) } }
    }
    @Published private(set) var activeNotice: AppNotification?
    private var noticeDismissal: Task<Void, Never>?
    var notice: String? {
        get { activeNotice?.message }
        set { if let newValue { showNotice(newValue) } else { activeNotice = nil } }
    }
    let notifications: AppNotifications
    var undoCount: Int { ledger.undoCount }
    var redoCount: Int { ledger.redoCount }
    var undoDescription: ChangeDescription? { undoDescriptions.first }
    var redoDescription: ChangeDescription? { redoDescriptions.first }
    @Published private(set) var undoDescriptions: [ChangeDescription] = []
    @Published private(set) var redoDescriptions: [ChangeDescription] = []
    @Published private(set) var imports = ImportPresentation()
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var isLoading = true
    @Published private(set) var isTerminating = false
    private var pendingWrites = 0
    private struct PendingTransactionSave {
        let value: Transaction
        let original: Transaction?
        let prepare: @MainActor (Transaction) async throws -> Transaction
        let review: (@MainActor (Transaction) async throws -> Void)?
    }
    private var savingTransactions: Set<UUID> = []
    private var failedTransactionSaves: [UUID: PendingTransactionSave] = [:]
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    @Published private(set) var updatingRates = false
    @Published private(set) var rateUpdateError: String? {
        didSet {
            if let rateUpdateError, rateUpdateError != oldValue {
                notifications.record(rateUpdateError, kind: .warning, actions: [.settings])
            }
        }
    }
    private var lastRateAttempt: Date?
    private var writeBlocked = false
    private var notificationTokenCache = ""
    private var lastUpdateChanged = false
    private var loadingTask: Task<Void, Never>?
    private var presentationDepth = 0
    private var deferredSnapshot: LedgerSnapshot?
    var isDeferringUpdates: Bool { presentationDepth > 0 }
    var latestLedger: Ledger { deferredSnapshot?.ledger ?? ledger }
    var reports = ReportCache()
    let fileURL: URL
    private let repository: LedgerRepository

    init(directory customDirectory: URL? = nil) {
        let args = CommandLine.arguments
        let directory: URL
        if let customDirectory { directory = customDirectory }
        else if let i = args.firstIndex(of: "--data-dir"), args.indices.contains(i + 1) { directory = URL(fileURLWithPath: args[i + 1]) }
        else { directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mora", isDirectory: true) }
        fileURL = directory.appendingPathComponent("ledger.json")
        repository = LedgerRepository(fileURL: fileURL, forcedDemo: args.contains("--demo"))
        notifications = AppNotifications(fileURL: args.contains("--demo") ? nil : directory.appendingPathComponent("notification-history.json"))
        ledger = .empty; isDemo = false
    }
    func load() async {
        if let loadingTask { await loadingTask.value; return }
        guard isLoading else { return }
        let directory = fileURL.deletingLastPathComponent(), launchTime = NSRunningApplication.current.launchDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        let task = Task { @MainActor in
            await notifications.load()
            do {
                try await BackgroundWork.shared.perform {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let marker = directory.appendingPathComponent("mcp-app-\(ProcessInfo.processInfo.processIdentifier).json")
                    try JSONSerialization.data(withJSONObject: ["protocol": 4, "launch_time": launchTime]).write(to: marker, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
                }
                publish(try await repository.load())
                await prepareInitialReports()
            } catch { self.error = error.localizedDescription; writeBlocked = true }
            isLoading = false
        }
        loadingTask = task
        await task.value
        loadingTask = nil
    }
    private func publish(_ snapshot: LedgerSnapshot) {
        guard snapshot.revision > revision else { return }
        if isDeferringUpdates {
            if snapshot.revision > (deferredSnapshot?.revision ?? revision) { deferredSnapshot = snapshot }
            return
        }
        AppMotion.update {
            notificationTokenCache = snapshot.token
            undoDescriptions = snapshot.undoDescriptions; redoDescriptions = snapshot.redoDescriptions
            imports = snapshot.imports
            isDemo = snapshot.isDemo; writeBlocked = snapshot.writeBlocked
            revision = snapshot.revision
            ledger = snapshot.ledger
        }
        if let warning = snapshot.warning { error = L(warning) }
    }
    func beginDeferredUpdates() { presentationDepth += 1 }
    func endDeferredUpdates() async {
        guard presentationDepth > 0 else { return }
        // Include writes from the disk watcher, MCP and editors during the sync.
        await reloadFromDisk()
        presentationDepth -= 1
        if presentationDepth == 0, let snapshot = deferredSnapshot {
            deferredSnapshot = nil
            publish(snapshot)
        }
    }
    func showNotice(_ message: String, detail: String? = nil, kind: AppNotification.Kind = .success,
                    actions: [AppNotificationAction] = [], dismissAfter: Duration = .seconds(7)) {
        noticeDismissal?.cancel()
        activeNotice = notifications.record(message, detail: detail, kind: kind, actions: actions)
        if let id = activeNotice?.id { dismissNotice(id, after: dismissAfter) }
    }
    func showTransientNotice(_ message: String, detail: String? = nil, kind: AppNotification.Kind = .success,
                             actions: [AppNotificationAction] = [], dismissAfter: Duration = .seconds(7)) {
        noticeDismissal?.cancel()
        activeNotice = AppNotification(message: message, detail: detail, kind: kind, actions: actions)
        if let id = activeNotice?.id { dismissNotice(id, after: dismissAfter) }
    }
    func beginProgressNotice(_ message: String, detail: String? = nil, householdID: UUID? = nil) -> UUID {
        noticeDismissal?.cancel()
        let event = notifications.record(message, detail: detail, kind: .information, householdID: householdID, progress: true)
        activeNotice = event
        return event.id
    }
    func finishProgressNotice(_ id: UUID, message: String? = nil, detail: String? = nil,
                             kind: AppNotification.Kind = .success, actions: [AppNotificationAction] = [],
                             dismissAfter: Duration = .seconds(7)) {
        guard let message else {
            notifications.removeProgress(id)
            if activeNotice?.id == id { activeNotice = nil }
            return
        }
        let event = notifications.finishProgress(id, message: message, detail: detail, kind: kind, actions: actions)
        guard activeNotice?.id == id else { return }
        activeNotice = event
        noticeDismissal?.cancel()
        dismissNotice(id, after: dismissAfter)
    }
    private func dismissNotice(_ id: UUID, after delay: Duration) {
        noticeDismissal = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            if self?.activeNotice?.id == id { self?.activeNotice = nil }
        }
    }
    func reconcileWallet(_ captures: [CloudCapture], householdID: UUID) {
        notifications.reconcileWallet(captures, householdID: householdID)
        guard let current = activeNotice, !current.isInProgress, current.householdID == householdID,
              let event = notifications.events.first(where: { $0.id == current.id }) else { return }
        if event.isResolved { noticeDismissal?.cancel(); activeNotice = nil }
        else if event != current { activeNotice = event }
    }
    var notificationStateToken: String { notificationTokenCache }
    var undoNotificationActions: [AppNotificationAction] {
        undoCount > 0 && !notificationStateToken.isEmpty ? [.undo(notificationStateToken)] : []
    }
    private var updatedUndoActions: [AppNotificationAction] { lastUpdateChanged ? undoNotificationActions : [] }
    func canPerformNotificationAction(_ action: AppNotificationAction) -> Bool {
        switch action {
        case .undo(let token): return undoCount > 0 && !token.isEmpty && token == notificationStateToken
        case .redo(let token): return redoCount > 0 && !token.isEmpty && token == notificationStateToken
        case .rollbackImport(let id): return imports.previews[id] != nil
        case .retryTransaction(let id): return failedTransactionSaves[id] != nil && !isTerminating
        default: return true
        }
    }
    func performHistoryAction(_ action: AppNotificationAction) async {
        await reloadFromDisk()
        guard canPerformNotificationAction(action) else {
            error = L("Это действие больше недоступно: данные уже изменились.")
            return
        }
        switch action {
        case .undo(let token): await undo(expectedToken: token)
        case .redo(let token): await redo(expectedToken: token)
        default: break
        }
    }
    func reloadFromDisk() async {
        await load()
        guard !writeBlocked else { return }
        do { publish(try await repository.load()) }
        catch { self.error = error.localizedDescription }
    }
    func refreshExchangeRates(force: Bool = false) async {
        guard !isDemo, !writeBlocked, !isTerminating, ledger.preferences.automaticRates, !updatingRates else { return }
        let now = Date()
        guard ExchangeRateRefreshPolicy.shouldRefresh(snapshot: ledger.preferences.exchangeRateSnapshot, lastAttempt: lastRateAttempt, now: now, force: force) else { return }
        lastRateAttempt = now; updatingRates = true; rateUpdateError = nil
        pendingWrites += 1; defer { finishedWrite(); updatingRates = false }
        do {
            let snapshot = try await ExchangeRateClient().fetch(now: now)
            try Task.checkCancellation()
            guard !isDemo, !writeBlocked, ledger.preferences.automaticRates else { return }
            // Apply to the latest locked snapshot; edits made during the request win.
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
        if success { rateUpdateError = nil; lastRateAttempt = nil }
    }

    func beginTermination() { isTerminating = true }
    func finishPendingWrites() async {
        while pendingWrites > 0 { await withCheckedContinuation { writeWaiters.append($0) } }
        await notifications.flush()
    }
    private func finishedWrite() {
        pendingWrites -= 1
        if pendingWrites == 0 {
            let waiters = writeWaiters; writeWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }
    func change<Value: Sendable>(_ action: @escaping @Sendable (inout Ledger) throws -> Value) async -> Value? {
        guard !isTerminating else { return nil }
        pendingWrites += 1; defer { finishedWrite() }
        await load()
        do {
            let result = try await repository.mutate(action)
            publish(result.snapshot); lastUpdateChanged = result.changed
            return result.value
        } catch { self.error = error.localizedDescription; lastUpdateChanged = false; return nil }
    }
    @discardableResult
    func update(_ action: @escaping @Sendable (inout Ledger) throws -> Void) async -> Bool {
        await change { ledger in try action(&ledger); return true } ?? false
    }
    func undo(expectedToken: String? = nil) async {
        guard !isTerminating else { return }
        pendingWrites += 1; defer { finishedWrite() }
        await reloadFromDisk()
        guard let description = undoDescription else { return }
        let token = expectedToken ?? notificationStateToken
        do {
            publish(try await repository.moveHistory(undo: true, expectedToken: token))
            showNotice(L("Отменено: \(description.title)"), detail: description.detail, actions: [.redo(notificationStateToken)])
        } catch { self.error = error.localizedDescription }
    }
    func redo(expectedToken: String? = nil) async {
        guard !isTerminating else { return }
        pendingWrites += 1; defer { finishedWrite() }
        await reloadFromDisk()
        guard let description = redoDescription else { return }
        let token = expectedToken ?? notificationStateToken
        do {
            publish(try await repository.moveHistory(undo: false, expectedToken: token))
            showNotice(L("Возвращено: \(description.title)"), detail: description.detail, actions: undoNotificationActions)
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func startClean(baseCurrency: String = "RUB") async -> Bool {
        guard !isTerminating else { return false }
        pendingWrites += 1; defer { finishedWrite() }
        await load()
        do {
            let (snapshot, existing) = try await repository.initialize(baseCurrency: baseCurrency)
            publish(snapshot)
            notice = existing ? L("Открыта ваша существующая база вместо демо") : L("Добавьте счет для учета операций.")
            lastRateAttempt = nil; Task { await refreshExchangeRates() }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult
    func saveTransaction(_ value: Transaction, replacing originalID: UUID? = nil, original: Transaction? = nil) async -> Bool {
        guard !isTerminating else { return false }
        pendingWrites += 1; defer { finishedWrite() }
        do {
            try await persistTransaction(value, replacing: originalID, original: original)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    /// Own the submission before the sheet dismisses, including its rate lookup.
    @discardableResult
    func enqueueTransaction(_ value: Transaction, original: Transaction? = nil,
                            prepare: @escaping @MainActor (Transaction) async throws -> Transaction = { $0 },
                            review: (@MainActor (Transaction) async throws -> Void)? = nil) -> Bool {
        startTransactionSave(PendingTransactionSave(value: value, original: original, prepare: prepare, review: review))
    }

    func retryTransactionSave(_ id: UUID) {
        guard let submission = failedTransactionSaves[id] else { return }
        _ = startTransactionSave(submission)
    }

    private func startTransactionSave(_ submission: PendingTransactionSave) -> Bool {
        let id = submission.value.id
        guard !isTerminating, savingTransactions.insert(id).inserted else { return false }
        failedTransactionSaves[id] = nil
        pendingWrites += 1
        let progress = beginProgressNotice(L("Сохраняем операцию…"), detail: submission.value.merchant)
        Task { @MainActor in
            defer { savingTransactions.remove(id); finishedWrite() }
            do {
                let prepared = try await submission.prepare(submission.value)
                if let review = submission.review { try await review(prepared) }
                else { try await persistTransaction(prepared, replacing: submission.original?.id, original: submission.original) }
                finishProgressNotice(progress, message: L("Операция сохранена"), detail: prepared.merchant,
                                     actions: submission.review == nil ? undoNotificationActions : [])
            } catch {
                failedTransactionSaves[id] = submission
                finishProgressNotice(progress, message: L("Не удалось сохранить операцию"),
                                     detail: submission.value.merchant + "\n" + error.localizedDescription,
                                     kind: .error, actions: [.retryTransaction(id)])
            }
        }
        return true
    }

    private func persistTransaction(_ value: Transaction, replacing originalID: UUID?, original: Transaction?) async throws {
        await load()
        let result = try await repository.mutate { ledger in
            let existing = originalID.flatMap { id in ledger.transactions.first { $0.id == id } }
            guard originalID == nil || existing != nil else { throw LedgerError.invalid(L("Операция уже удалена.")) }
            guard originalID == nil || originalID == value.id else { throw LedgerError.invalid(L("Идентификатор операции изменился.")) }
            guard originalID != nil || !ledger.transactions.contains(where: { $0.id == value.id }) else { throw LedgerError.invalid(L("Такая операция уже существует.")) }
            guard ledger.account(value.accountID)?.archived == false || existing?.accountID == value.accountID else { throw LedgerError.invalid(L("Верните счет из архива перед добавлением операций.")) }
            if let destination = value.destinationAccountID {
                guard ledger.account(destination)?.archived == false || existing?.destinationAccountID == destination else { throw LedgerError.invalid(L("Верните счет из архива перед добавлением операций.")) }
            }
            var saved = value
            if let original, let existing { saved = try value.mergingEditorChanges(from: original, into: existing) }
            if saved.categoryID == nil && saved.kind != .transfer {
                saved.categoryID = ledger.suggestedCategory(merchant: saved.merchant, kind: saved.kind)
            }
            replaceOrAppend(saved, in: &ledger.transactions)
        }
        publish(result.snapshot); lastUpdateChanged = result.changed
    }
    func deleteTransaction(_ id: UUID) async {
        let result = await change { ledger -> (Bool, ChangeDescription) in
            let before = ledger
            ledger.transactions.removeAll { $0.id == id }
            guard ledger.transactions.count != before.transactions.count else { return (false, ChangeDescription(title: "", detail: "")) }
            return (true, ChangeDescriptions.between(before, ledger))
        }
        if let (deleted, description) = result, deleted {
            showNotice(description.title, detail: description.detail, actions: undoNotificationActions)
        }
    }
    func setAccountArchived(_ id: UUID, archived: Bool) async {
        if await update({ try $0.setAccountArchived(id, archived: archived) }) {
            showNotice(archived ? L("Счет архивирован и исключен из расчетов") : L("Счет возвращен из архива"),
                       actions: updatedUndoActions + [.settings])
        }
    }
    func deleteArchivedAccount(_ id: UUID) async {
        if await update({ try $0.deleteArchivedAccount(id) }) {
            showNotice(L("Счет удален. Удаление можно отменить в настройках."), actions: updatedUndoActions + [.settings])
        }
    }
    @discardableResult
    func importPreparedCSV(_ prepared: CSVImportResult, filename: String, expected: Ledger) async -> Bool {
        let batch: ImportBatch? = await change { current in
            guard try LedgerFile.equivalent(current, expected), prepared.imported > 0 else { throw LedgerError.invalid(L("Данные изменились после предпросмотра. Проверьте обновленный список и повторите импорт.")) }
            let existing = Set(current.transactions.map(\.id))
            current = prepared.ledger
            guard let batch = try current.recordImport(addedIDs: Set(current.transactions.map(\.id)).subtracting(existing), filename: filename,
                totalRows: prepared.rows.count, excluded: prepared.excluded, duplicates: prepared.duplicates, invalid: prepared.invalid) else { throw LedgerError.invalid("Нет операций для импорта.") }; return batch
        }
        guard let batch else { return false }
        showNotice(L("Добавлено: \(prepared.imported). Исключено: \(prepared.excluded). Повторы: \(prepared.duplicates). Ошибки: \(prepared.invalid)."), actions: [.rollbackImport(batch.id), .imports])
        return true
    }
    @discardableResult
    func importCSV(_ table: CSVTable, mapping: CSVMapping, filename: String, expected: Ledger) async -> Bool {
        do {
            let prepared = try await BackgroundWork.shared.perform { try CSVImporter.prepare(table, mapping: mapping, ledger: expected) }
            guard prepared.imported > 0, prepared.invalid == 0 || mapping.skipInvalid else { throw LedgerError.invalid(L("Выберите операции и исправьте ошибки перед импортом.")) }
            return await importPreparedCSV(prepared, filename: filename, expected: expected)
        } catch { self.error = error.localizedDescription; return false }
    }
    func rollbackImport(_ id: UUID, allowModified: Bool = false) async {
        let filename = ledger.importHistory.first { $0.id == id }?.filename ?? L("Импорт")
        let removed: Int? = await change { try $0.rollbackImport(id, allowModified: allowModified) }
        if let removed { showNotice(L("Импорт отменен: \(filename)"), detail: L("Удалено операций: \(removed)"), actions: updatedUndoActions + [.imports]) }
    }
    func deleteCategory(_ id: UUID) async {
        await update { ledger in
            for i in ledger.transactions.indices where ledger.transactions[i].categoryID == id { ledger.transactions[i].categoryID = nil }
            for i in ledger.recurring.indices where ledger.recurring[i].categoryID == id { ledger.recurring[i].categoryID = nil }
            ledger.budgets.removeAll { $0.categoryID == id }; ledger.rules.removeAll { $0.categoryID == id }; ledger.categories.removeAll { $0.id == id }
        }
    }
    func pay(_ payment: RecurringPayment) async {
        let success = await update { ledger in
            guard let index = ledger.recurring.firstIndex(where: { $0.id == payment.id }) else { return }
            guard ledger.account(payment.accountID)?.archived == false else { throw LedgerError.invalid(L("Верните счет из архива перед учетом платежа.")) }
            let id = "recurring:\(payment.id):\(Dates.string(payment.nextDate))"
            guard !ledger.transactions.contains(where: { $0.externalID == id }) else { throw LedgerError.invalid(L("Этот платеж уже учтен.")) }
            ledger.transactions.append(Transaction(date: payment.nextDate, merchant: payment.name, amount: -payment.amount, accountID: payment.accountID, categoryID: payment.categoryID, kind: .expense, externalID: id, recurrenceID: payment.id))
            ledger.recurring[index].nextDate = payment.followingDate()
        }
        if success { showNotice(L("Платеж добавлен в операции"), actions: updatedUndoActions) }
    }
    func applyRules() async {
        let count: Int? = await change { ledger in
            var count = 0
            for i in ledger.transactions.indices where ledger.transactions[i].categoryID == nil && ledger.transactions[i].kind != .transfer {
                if let id = ledger.matchingCategory(merchant: ledger.transactions[i].merchant, kind: ledger.transactions[i].kind) { ledger.transactions[i].categoryID = id; count += 1 }
            }
            return count
        }
        if let count { showNotice(L("Категоризировано операций: \(count)"), actions: updatedUndoActions) }
    }
    func exportCSV(_ transactions: [Transaction]? = nil) async {
        guard !isTerminating else { return }
        pendingWrites += 1; defer { finishedWrite() }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "Mora-\(Dates.string(Date())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = ledger
        do { try await BackgroundWork.shared.perform { try CSVImporter.export(snapshot, transactions: transactions).write(to: url, atomically: true, encoding: .utf8) }; notice = L("CSV сохранен") }
        catch { self.error = error.localizedDescription }
    }
    func backup() async {
        guard !isTerminating else { return }
        pendingWrites += 1; defer { finishedWrite() }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Mora-backup-\(Dates.string(Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = ledger
        do { try await BackgroundWork.shared.perform { try LedgerFile.encode(snapshot).write(to: url, options: .atomic) }; notice = L("Резервная копия сохранена") }
        catch { self.error = error.localizedDescription }
    }
    func readBackup() async -> Ledger? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { return try await BackgroundWork.shared.perform { try LedgerFile.decode(Data(contentsOf: url)) } }
        catch { self.error = error.localizedDescription; return nil }
    }
    func restore(_ ledger: Ledger) async {
        guard !isTerminating else { return }
        pendingWrites += 1; defer { finishedWrite() }
        await load()
        do {
            publish(try await repository.restore(ledger))
            notice = L("Данные восстановлены")
            lastRateAttempt = nil; rateUpdateError = nil; Task { await refreshExchangeRates() }
        } catch { self.error = error.localizedDescription }
    }

}

enum Page: String, CaseIterable, Identifiable {
    case overview, transactions, accounts, analytics, categories, imports, budgets, goals, recurring, settings
    var id: String { rawValue }
    var title: String { switch self { case .overview: L("Обзор"); case .transactions: L("Операции"); case .accounts: L("Счета"); case .budgets: L("Бюджеты"); case .goals: L("Цели"); case .recurring: L("Регулярные платежи"); case .analytics: L("Аналитика"); case .categories: L("Категории и правила"); case .imports: L("История импортов"); case .settings: L("Настройки") } }
    var subtitle: String { switch self { case .overview: L("Балансы счетов и итоги выбранного месяца."); case .transactions: L("Поиск, добавление и редактирование операций."); case .accounts: L("Остатки, валюты и настройки счетов."); case .budgets: L("Месячные лимиты расходов по категориям."); case .goals: L("Суммы, сроки и прогресс накоплений."); case .recurring: L("Расписание платежей и добавление их в учет."); case .analytics: L("Доходы и расходы по месяцам, категориям и дням."); case .categories: L("Категории операций и правила их назначения."); case .imports: L("Загрузки из CSV, Apple Shortcuts и AI-агента. Просмотр и отмена импортов."); case .settings: L("Валюты, разделы приложения, импорт и резервные копии.") } }
    func isVisible(in preferences: Preferences) -> Bool {
        switch self {
        case .budgets: preferences.showBudgets
        case .goals: preferences.showGoals
        case .recurring: preferences.showRecurring
        default: true
        }
    }
    var icon: String { switch self { case .overview: "square.grid.2x2"; case .transactions: "arrow.left.arrow.right"; case .accounts: "wallet.bifold"; case .budgets: "chart.pie"; case .goals: "flag"; case .recurring: "repeat"; case .analytics: "chart.xyaxis.line"; case .categories: "tag"; case .imports: "clock.arrow.circlepath"; case .settings: "slider.horizontal.3" } }
}

enum EditorSheet: Identifiable {
    case welcome, transaction(Transaction?), similar(Transaction), split(Transaction), account(Account?), budget(Budget?), goal(Goal?), recurring(RecurringPayment?), category(Category?), rule(CategoryRule?), csv(CSVTable, String), aiImport
    var id: String { switch self { case .welcome: "welcome"; case .transaction(let t): "transaction-\(t?.id.uuidString ?? "new")"; case .similar(let t): "similar-\(t.id)"; case .split(let t): "split-\(t.id)"; case .account(let t): "account-\(t?.id.uuidString ?? "new")"; case .budget(let t): "budget-\(t?.id.uuidString ?? "new")"; case .goal(let t): "goal-\(t?.id.uuidString ?? "new")"; case .recurring(let t): "recurring-\(t?.id.uuidString ?? "new")"; case .category(let t): "category-\(t?.id.uuidString ?? "new")"; case .rule(let t): "rule-\(t?.id.uuidString ?? "new")"; case .csv: "csv"; case .aiImport: "ai-import" } }
}

extension Color {
    static let moraGreen = Color(nsColor: NSColor(name: NSColor.Name("MoraGreen")) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua { return NSColor(srgbRed: 0.52, green: 0.73, blue: 0.60, alpha: 1) }
        return NSColor(srgbRed: 0.20, green: 0.43, blue: 0.34, alpha: 1)
    })
    static func token(_ value: String) -> Color {
        if let rgb = CategoryAppearance.rgb(value) { return Color(red: rgb.red, green: rgb.green, blue: rgb.blue) }
        return switch value { case "teal": Color(red: 0.20, green: 0.58, blue: 0.56); case "cyan": Color(red: 0.24, green: 0.64, blue: 0.76); case "indigo": Color(red: 0.36, green: 0.39, blue: 0.70); case "mint": Color(red: 0.38, green: 0.70, blue: 0.55); case "lime": Color(red: 0.58, green: 0.68, blue: 0.28); case "brown": Color(red: 0.57, green: 0.40, blue: 0.29); case "coral": Color(red: 0.91, green: 0.48, blue: 0.42); case "lavender": Color(red: 0.66, green: 0.57, blue: 0.81); case "green": .moraGreen; case "orange": Color(red: 0.80, green: 0.48, blue: 0.28); case "blue": Color(red: 0.35, green: 0.53, blue: 0.72); case "purple": Color(red: 0.57, green: 0.48, blue: 0.70); case "pink": Color(red: 0.76, green: 0.46, blue: 0.57); case "red": Color(red: 0.78, green: 0.35, blue: 0.35); case "yellow": Color(red: 0.74, green: 0.62, blue: 0.30); default: .gray }
    }
}

struct Card<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var padding: CGFloat = 22
    var fillsHeight = false
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
            .background(scheme == .dark ? Color(red: 0.15, green: 0.17, blue: 0.16) : .white)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.055), lineWidth: 1))
    }
}

struct IconTile: View {
    var icon: String; var color: String = "green"; var size: CGFloat = 38
    var body: some View {
        Group {
            if CategoryAppearance.isEmoji(icon) {
                Text(icon).font(.system(size: size * 0.55))
            } else {
                Image(systemName: icon).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(Color.token(color))
            }
        }.frame(width: size, height: size).background(Color.token(color).opacity(0.11)).clipShape(RoundedRectangle(cornerRadius: size * 0.29))
    }
}

struct EmptyState: View {
    var icon: String; var title: String; var text: String
    var button: String? = nil; var action: () -> Void = {}
    var body: some View {
        VStack(spacing: 14) {
            IconTile(icon: icon, size: 64)
            Text(L(title)).font(.title3.weight(.semibold))
            Text(L(text)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            if let button { Button(L(button), action: action).buttonStyle(.borderedProminent).tint(.moraGreen) }
        }.frame(maxWidth: .infinity).padding(.vertical, 44)
    }
}

struct SectionHeading: View {
    var title: String; var subtitle: String? = nil
    var body: some View { VStack(alignment: .leading, spacing: 4) { Text(L(title)).font(.system(size: 17, weight: .semibold)); if let subtitle { Text(L(subtitle)).font(.caption).foregroundStyle(.secondary) } } }
}

struct Meter: View {
    var progress: Double; var color: Color = .moraGreen
    var body: some View { GeometryReader { proxy in ZStack(alignment: .leading) { Capsule().fill(color.opacity(0.10)); Capsule().fill(color).frame(width: proxy.size.width * min(max(progress, 0), 1)) } }.frame(height: 7) }
}

struct FinanceErrorAlert: ViewModifier {
    @EnvironmentObject var store: FinanceStore
    var active = true

    func body(content: Content) -> some View {
        content.alert(L("Не удалось выполнить действие"), isPresented: Binding(
            get: { active && store.error != nil },
            set: { if active && !$0 { store.error = nil } }
        )) {
            Button(L("Понятно")) { store.error = nil }
        } message: {
            FinancialText(store.error ?? "")
        }
    }
}

struct ModalFrame<Content: View>: View {
    var title: String; var subtitle: String = ""; var saveTitle = L("Сохранить"); var canSave = true
    var isSaving = false
    var save: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) { Text(L(title)).font(.title2.weight(.semibold)); if !subtitle.isEmpty { FinancialText(L(subtitle)).foregroundStyle(.secondary).font(.callout) } }.padding(24)
            Divider()
            content.padding(24)
            Divider()
            HStack {
                Button(L("Отмена")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Spacer()
                if isSaving { ProgressView(L("Сохраняем…")).controlSize(.small) }
                Button(L(saveTitle), action: save).buttonStyle(.borderedProminent).tint(.moraGreen)
                    .disabled(!canSave || isSaving).keyboardShortcut(.defaultAction)
            }.padding(20)
        }.frame(width: 500)
    }
}

func replaceOrAppend<T: Identifiable>(_ value: T, in items: inout [T]) where T.ID == UUID {
    if let index = items.firstIndex(where: { $0.id == value.id }) { items[index] = value } else { items.append(value) }
}
