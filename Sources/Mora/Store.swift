import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FinanceCore

typealias Transaction = FinanceCore.Transaction
typealias Category = FinanceCore.Category

@MainActor
final class FinanceStore: ObservableObject {
    @Published private(set) var ledger: Ledger { didSet { reports = ReportCache() } }
    @Published private(set) var isDemo: Bool
    @Published var error: String?
    @Published var notice: String? { didSet { noticeImportID = nil; noticeAccountChange = false } }
    @Published private(set) var noticeAccountChange = false
    @Published private(set) var noticeImportID: UUID?
    var undoCount: Int { ledger.undoCount }
    var redoCount: Int { ledger.redoCount }
    @Published private(set) var updatingRates = false
    @Published private(set) var rateUpdateError: String?
    private var lastRateAttempt: Date?
    private var lastDiskVersion: DiskVersion?
    private struct DiskVersion: Equatable { let modified: Date; let size: UInt64; let inode: UInt64 }
    private var writeBlocked = false
    var reports = ReportCache()
    let fileURL: URL

    init() {
        let args = CommandLine.arguments
        let directory: URL
        if let i = args.firstIndex(of: "--data-dir"), args.indices.contains(i + 1) { directory = URL(fileURLWithPath: args[i + 1]) }
        else { directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mora", isDirectory: true) }
        fileURL = directory.appendingPathComponent("ledger.json")
        // Let MCP reject writes while an older GUI without coordinated saves is open.
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let marker = directory.appendingPathComponent("mcp-app-\(ProcessInfo.processInfo.processIdentifier).json")
            let data = try JSONSerialization.data(withJSONObject: ["protocol": 4, "launch_time": NSRunningApplication.current.launchDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970])
            try data.write(to: marker, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        } catch { /* A missing marker makes MCP request a restart rather than risk overwriting data. */ }
        if args.contains("--demo") { ledger = .demo(); isDemo = true; return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do { ledger = try LedgerFile.decode(Data(contentsOf: fileURL)); isDemo = false }
            catch {
                if let backup = try? LedgerFile.decode(Data(contentsOf: fileURL.appendingPathExtension("backup"))) {
                    ledger = backup; isDemo = false
                    self.error = L("Основной файл не удалось прочитать. Открыта последняя исправная резервная копия. Исходный файл сохранен.")
                    if let corrupt = try? Data(contentsOf: fileURL) { try? corrupt.write(to: directory.appendingPathComponent("ledger-unreadable-\(Int(Date().timeIntervalSince1970)).json"), options: .atomic) }
                } else { ledger = .empty; isDemo = false; writeBlocked = true; self.error = L("Не удалось открыть данные: \(error.localizedDescription). Исходный файл сохранен; восстановите резервную копию в настройках.") }
            }
        } else { ledger = .demo(); isDemo = true }
    }
    func reloadFromDisk() {
        guard !writeBlocked, !(isDemo && CommandLine.arguments.contains("--demo")), FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let version = DiskVersion(modified: attributes[.modificationDate] as? Date ?? .distantPast,
                                      size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                                      inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
            guard version != lastDiskVersion else { return }
            lastDiskVersion = version
            let latest = try LedgerFile.decode(Data(contentsOf: fileURL))
            if !isDemo, try LedgerFile.encode(latest) == LedgerFile.encode(ledger) { return }
            ledger = latest; isDemo = false
            notice = L("Данные обновлены из MCP или другого окна")
        } catch { self.error = error.localizedDescription }
    }
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
            // Merge into the latest ledger so edits made while downloading remain intact.
            reloadFromDisk()
            guard ledger.preferences.automaticRates else { return }
            var next = ledger
            try next.applyExchangeRates(snapshot)
            ledger = try LedgerFile.save(next, to: fileURL, expected: ledger, recordHistory: false)
        } catch is CancellationError {
            lastRateAttempt = nil
        } catch {
            guard ledger.preferences.automaticRates else { return }
            rateUpdateError = (error as? URLError) != nil ? L("Не удалось подключиться к сервису курсов. Проверьте интернет-соединение.") : error.localizedDescription
        }
    }

    func setAutomaticRates(_ enabled: Bool) {
        let success = update { next in
            next.preferences.automaticRates = enabled
            if enabled, let snapshot = next.preferences.exchangeRateSnapshot {
                next.preferences.rates = try snapshot.rates(in: next.preferences.baseCurrency)
            }
        }
        if success { rateUpdateError = nil; lastRateAttempt = nil }
    }

    @discardableResult
    func update(_ action: (inout Ledger) throws -> Void) -> Bool {
        do {
            guard !writeBlocked else { throw LedgerError.invalid(L("Исходный файл не удалось прочитать. Сначала восстановите исправную резервную копию в настройках; текущий файл не будет перезаписан.")) }
            reloadFromDisk()
            var next = ledger
            try action(&next); try next.validate()
            if !isDemo { next = try LedgerFile.save(next, to: fileURL, expected: ledger) }
            else if next != ledger { next.recordChange(from: ledger) }
            ledger = next
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func undo() {
        reloadFromDisk()
        guard undoCount > 0 else { return }
        do {
            if isDemo { try ledger.undoLastChange() }
            else { ledger = try LedgerFile.undo(at: fileURL, expected: ledger) }
            notice = L("Изменение отменено")
        } catch { self.error = error.localizedDescription }
    }
    func redo() {
        reloadFromDisk()
        guard redoCount > 0 else { return }
        do {
            if isDemo { try ledger.redoLastChange() }
            else { ledger = try LedgerFile.redo(at: fileURL, expected: ledger) }
            notice = L("Изменение возвращено")
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func startClean(baseCurrency: String = "RUB") -> Bool {
        do {
            var empty = try Ledger.personal(baseCurrency: baseCurrency)
            if let snapshot = ledger.preferences.exchangeRateSnapshot {
                empty.preferences.exchangeRateSnapshot = snapshot
                empty.preferences.rates = try snapshot.rates(in: empty.preferences.baseCurrency)
            }
            var existingData = false
            let initialized = try LedgerFile.mutate(at: fileURL) { current in
                // MCP may initialize the real database while the onboarding dialog is open.
                if FileManager.default.fileExists(atPath: fileURL.path) { existingData = true }
                else { current = empty }
            }
            ledger = initialized; isDemo = false
            notice = existingData ? L("Открыта ваша существующая база вместо демо") : L("Добавьте счет для учета операций.")
            lastRateAttempt = nil; Task { await refreshExchangeRates() }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func deleteTransaction(_ id: UUID) { update { $0.transactions.removeAll { $0.id == id } } }
    func setAccountArchived(_ id: UUID, archived: Bool) {
        if update({ try $0.setAccountArchived(id, archived: archived) }) {
            notice = archived ? L("Счет архивирован и исключен из расчетов") : L("Счет возвращен из архива")
            noticeAccountChange = true
        }
    }
    func deleteArchivedAccount(_ id: UUID) {
        if update({ try $0.deleteArchivedAccount(id) }) {
            notice = L("Счет удален. Удаление можно отменить в настройках.")
            noticeAccountChange = true
        }
    }
    @discardableResult
    func importPreparedCSV(_ prepared: CSVImportResult, filename: String, expected: Ledger) -> Bool {
        var batch: ImportBatch?
        let success = update { current in
            guard try LedgerFile.equivalent(current, expected), prepared.imported > 0 else { throw LedgerError.invalid(L("Данные изменились после предпросмотра. Проверьте обновленный список и повторите импорт.")) }
            let existing = Set(current.transactions.map(\.id))
            current = prepared.ledger
            batch = try current.recordImport(addedIDs: Set(current.transactions.map(\.id)).subtracting(existing), filename: filename,
                                              totalRows: prepared.rows.count, excluded: prepared.excluded, duplicates: prepared.duplicates, invalid: prepared.invalid)
        }
        if success, let batch {
            notice = L("Добавлено: \(prepared.imported). Исключено: \(prepared.excluded). Повторы: \(prepared.duplicates). Ошибки: \(prepared.invalid).")
            noticeImportID = batch.id
        }
        return success
    }
    @discardableResult
    func importCSV(_ table: CSVTable, mapping: CSVMapping, filename: String, expected: Ledger) -> Bool {
        var prepared: CSVImportResult?
        var batch: ImportBatch?
        let success = update { current in
            guard try LedgerFile.equivalent(current, expected) else { throw LedgerError.invalid(L("Данные изменились после предпросмотра. Проверьте обновленный список и повторите импорт.")) }
            let result = try CSVImporter.prepare(table, mapping: mapping, ledger: current)
            guard result.imported > 0, result.invalid == 0 || mapping.skipInvalid else { throw LedgerError.invalid(L("Выберите операции и исправьте ошибки перед импортом.")) }
            let existing = Set(current.transactions.map(\.id))
            current = result.ledger
            batch = try current.recordImport(addedIDs: Set(current.transactions.map(\.id)).subtracting(existing), filename: filename,
                                              totalRows: table.rows.count, excluded: result.excluded, duplicates: result.duplicates, invalid: result.invalid)
            prepared = result
        }
        if success, let result = prepared, let batch {
            notice = L("Добавлено: \(result.imported). Исключено: \(result.excluded). Повторы: \(result.duplicates). Ошибки: \(result.invalid).")
            noticeImportID = batch.id
        }
        return success
    }
    func rollbackImport(_ id: UUID, allowModified: Bool = false) {
        var removed = 0
        if update({ removed = try $0.rollbackImport(id, allowModified: allowModified) }) {
            notice = L("Импорт отменен. Удалено операций: \(removed).")
        }
    }
    func deleteCategory(_ id: UUID) {
        update { ledger in
            for i in ledger.transactions.indices where ledger.transactions[i].categoryID == id { ledger.transactions[i].categoryID = nil }
            for i in ledger.recurring.indices where ledger.recurring[i].categoryID == id { ledger.recurring[i].categoryID = nil }
            ledger.budgets.removeAll { $0.categoryID == id }; ledger.rules.removeAll { $0.categoryID == id }; ledger.categories.removeAll { $0.id == id }
        }
    }
    func pay(_ payment: RecurringPayment) {
        let success = update { ledger in
            guard let index = ledger.recurring.firstIndex(where: { $0.id == payment.id }) else { return }
            guard ledger.account(payment.accountID)?.archived == false else { throw LedgerError.invalid(L("Верните счет из архива перед учетом платежа.")) }
            let id = "recurring:\(payment.id):\(Dates.string(payment.nextDate))"
            guard !ledger.transactions.contains(where: { $0.externalID == id }) else { throw LedgerError.invalid(L("Этот платеж уже учтен.")) }
            ledger.transactions.append(Transaction(date: payment.nextDate, merchant: payment.name, amount: -payment.amount, accountID: payment.accountID, categoryID: payment.categoryID, kind: .expense, externalID: id, recurrenceID: payment.id))
            ledger.recurring[index].nextDate = payment.followingDate()
        }
        if success { notice = L("Платеж добавлен в операции") }
    }
    func applyRules() {
        var count = 0
        let success = update { ledger in
            for i in ledger.transactions.indices where ledger.transactions[i].categoryID == nil && ledger.transactions[i].kind != .transfer {
                if let id = ledger.matchingCategory(merchant: ledger.transactions[i].merchant, kind: ledger.transactions[i].kind) { ledger.transactions[i].categoryID = id; count += 1 }
            }
        }
        if success { notice = L("Категоризировано операций: \(count)") }
    }
    func exportCSV(_ transactions: [Transaction]? = nil) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "Mora-\(Dates.string(Date())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try CSVImporter.export(ledger, transactions: transactions).write(to: url, atomically: true, encoding: .utf8); notice = L("CSV сохранен") }
        catch { self.error = error.localizedDescription }
    }
    func backup() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Mora-backup-\(Dates.string(Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try LedgerFile.encode(ledger).write(to: url, options: .atomic); notice = L("Резервная копия сохранена") }
        catch { self.error = error.localizedDescription }
    }
    func readBackup() -> Ledger? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { return try LedgerFile.decode(Data(contentsOf: url)) }
        catch { self.error = error.localizedDescription; return nil }
    }
    func restore(_ ledger: Ledger) {
        do {
            if writeBlocked, FileManager.default.fileExists(atPath: fileURL.path) {
                let original = try Data(contentsOf: fileURL)
                try original.write(to: fileURL.deletingLastPathComponent().appendingPathComponent("ledger-unreadable-\(Int(Date().timeIntervalSince1970)).json"), options: .atomic)
            }
            self.ledger = try LedgerFile.save(ledger, to: fileURL)
            isDemo = false; writeBlocked = false; notice = L("Данные восстановлены")
            lastRateAttempt = nil; rateUpdateError = nil; Task { await refreshExchangeRates() }
        } catch { self.error = error.localizedDescription }
    }
}

enum Page: String, CaseIterable, Identifiable {
    case overview, transactions, accounts, analytics, categories, imports, budgets, goals, recurring, settings
    var id: String { rawValue }
    var title: String { switch self { case .overview: L("Обзор"); case .transactions: L("Операции"); case .accounts: L("Счета"); case .budgets: L("Бюджеты"); case .goals: L("Цели"); case .recurring: L("Регулярные платежи"); case .analytics: L("Аналитика"); case .categories: L("Категории и правила"); case .imports: L("История импортов"); case .settings: L("Настройки") } }
    var subtitle: String { switch self { case .overview: L("Балансы счетов и итоги выбранного месяца."); case .transactions: L("Поиск, добавление и редактирование операций."); case .accounts: L("Остатки, валюты и настройки счетов."); case .budgets: L("Месячные лимиты расходов по категориям."); case .goals: L("Суммы, сроки и прогресс накоплений."); case .recurring: L("Расписание платежей и добавление их в учет."); case .analytics: L("Доходы и расходы по месяцам, категориям и дням."); case .categories: L("Категории операций и правила их назначения."); case .imports: L("Операции из CSV и AI-агента. Просмотр и отмена импортов."); case .settings: L("Валюты, разделы приложения, импорт и резервные копии.") } }
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
    case welcome, transaction(Transaction?), split(Transaction), account(Account?), budget(Budget?), goal(Goal?), recurring(RecurringPayment?), category(Category?), rule(CategoryRule?), csv(CSVTable, String), aiImport
    var id: String { switch self { case .welcome: "welcome"; case .transaction(let t): "transaction-\(t?.id.uuidString ?? "new")"; case .split(let t): "split-\(t.id)"; case .account(let t): "account-\(t?.id.uuidString ?? "new")"; case .budget(let t): "budget-\(t?.id.uuidString ?? "new")"; case .goal(let t): "goal-\(t?.id.uuidString ?? "new")"; case .recurring(let t): "recurring-\(t?.id.uuidString ?? "new")"; case .category(let t): "category-\(t?.id.uuidString ?? "new")"; case .rule(let t): "rule-\(t?.id.uuidString ?? "new")"; case .csv: "csv"; case .aiImport: "ai-import" } }
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
    var save: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) { Text(L(title)).font(.title2.weight(.semibold)); if !subtitle.isEmpty { FinancialText(L(subtitle)).foregroundStyle(.secondary).font(.callout) } }.padding(24)
            Divider()
            content.padding(24)
            Divider()
            HStack { Button(L("Отмена")) { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button(L(saveTitle), action: save).buttonStyle(.borderedProminent).tint(.moraGreen).disabled(!canSave).keyboardShortcut(.defaultAction) }.padding(20)
        }.frame(width: 500)
    }
}

func replaceOrAppend<T: Identifiable>(_ value: T, in items: inout [T]) where T.ID == UUID {
    if let index = items.firstIndex(where: { $0.id == value.id }) { items[index] = value } else { items.append(value) }
}
