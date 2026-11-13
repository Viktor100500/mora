import SwiftUI
import FinanceCore

/// The Shortcuts automations that collect purchases on this iPhone. Each one has its
/// own Mora action, its own setup and its own label in the journal.
enum CaptureAutomation: String, CaseIterable, Identifiable, Sendable {
    /// Wallet "Transaction" trigger → Start Wallet Payment + Finish Wallet Payment.
    case walletTransaction
    /// iOS 27 "Notification" trigger of the Wallet app → Log Wallet Notification.
    case walletNotification
    /// "Message" trigger → Log Bank Message.
    case bankSMS
    /// iOS 27 "Notification" trigger of a bank app → Log Bank Notification.
    case bankNotification

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walletTransaction: L("Транзакция Wallet")
        case .walletNotification: L("Уведомление Wallet")
        case .bankSMS: L("SMS банка")
        case .bankNotification: L("Уведомление банка")
        }
    }

    /// What the automation is for, shown under its title.
    var summary: String {
        switch self {
        case .walletTransaction: L("Записывает каждую оплату Apple Pay сразу после касания.")
        case .walletNotification: L("Дописывает сумму и продавца, когда Wallet сообщает их позже, например за проезд.")
        case .bankSMS: L("Читает покупки из SMS банка, в том числе по картам без Apple Pay.")
        case .bankNotification: L("Читает покупки из уведомлений приложений банков и карт.")
        }
    }

    var icon: String {
        switch self {
        case .walletTransaction: "wallet.pass"
        case .walletNotification: "bell.badge"
        case .bankSMS: "message"
        case .bankNotification: "app.badge"
        }
    }

    var color: String {
        switch self {
        case .walletTransaction: "green"
        case .walletNotification: "teal"
        case .bankSMS: "blue"
        case .bankNotification: "indigo"
        }
    }

    /// The Shortcuts trigger, as it is named in the Shortcuts app.
    var trigger: String {
        switch self {
        case .walletTransaction: L("Транзакция")
        case .walletNotification, .bankNotification: L("Уведомление")
        case .bankSMS: L("Сообщение")
        }
    }

    /// The Mora actions inside the automation.
    var actions: [String] {
        switch self {
        case .walletTransaction: ["Start Wallet Payment", "Finish Wallet Payment"]
        case .walletNotification: ["Log Wallet Notification"]
        case .bankSMS: ["Log Bank Message"]
        case .bankNotification: ["Log Bank Notification"]
        }
    }

    /// The "Notification" trigger exists only on iOS 27.
    var requiresIOS27: Bool { self == .walletNotification || self == .bankNotification }

    static var isIOS27: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--wallet-one-tap") { return true }
        #endif
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    }

    var available: Bool { !requiresIOS27 || Self.isIOS27 }

    /// Name of the signed shortcut bundled in Resources. iOS 27 keeps the trigger inside
    /// a shared shortcut, so the file adds the whole automation. See cloud/shortcuts/READY-AUTOMATIONS.md.
    /// "Mora Apple Pay" is built by build_wallet_automation.py; its signature expires on 8 Dec 2027.
    var templateName: String {
        switch self {
        case .walletTransaction: "Mora Apple Pay"
        case .walletNotification: "Mora Wallet Notification"
        case .bankSMS: "Mora Bank SMS"
        case .bankNotification: "Mora Bank Notification"
        }
    }

    var templateFile: URL? { Bundle.main.url(forResource: templateName, withExtension: "shortcut") }

    /// iOS 27 and a ready automation in the app: one tap instead of building it by hand.
    var oneTapAvailable: Bool { Self.isIOS27 && templateFile != nil }

    /// The automation of a journal entry.
    static func source(of alert: BankAlert) -> CaptureAutomation? {
        if alert.wallet == true { return .walletNotification }
        switch alert.channel {
        case .sms: return .bankSMS
        case .notification: return .bankNotification
        case nil: return nil
        }
    }

    /// When the user finished its setup guide on this iPhone. Until the automation runs
    /// after that, its card waits for the first purchase instead of offering setup.
    var setupFinishedAt: Date? {
        get { UserDefaults.standard.object(forKey: "mora.automation.setup.\(rawValue)") as? Date }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "mora.automation.setup.\(rawValue)") }
    }

    enum SetupState { case notSet, waiting, working }

    /// Told by the card's button alone: never set up, set up but no purchase since, or
    /// at least one purchase received through this automation.
    func setupState(runs: [WalletRun], alerts: [BankAlert]) -> SetupState {
        let finished = setupFinishedAt
        if let last = lastRun(runs: runs, alerts: alerts), finished.map({ last >= $0.addingTimeInterval(-60) }) ?? true { return .working }
        return finished == nil ? .notSet : .waiting
    }

    /// Mora 1.0.55 forgets once that the setup guides were completed, so they can be
    /// tried again. The journals are never touched here.
    static func resetOnceForFreshSetup() {
        let key = "mora.automation.reset.1.0.55"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        for automation in allCases { automation.setupFinishedAt = nil }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// When this automation last passed something to Mora.
    func lastRun(runs: [WalletRun], alerts: [BankAlert]) -> Date? {
        switch self {
        case .walletTransaction: runs.first?.receivedAt
        default: alerts.first { Self.source(of: $0) == self }?.receivedAt
        }
    }
}

/// Label for messages saved before Mora knew which automation sent them.
let legacyBankSource = "SMS или уведомление банка"

/// One line of the automation journal: a Wallet run or a bank message, its source and
/// what happened to a duplicate of the same purchase.
struct AutomationEntry: Identifiable {
    enum Item { case wallet(WalletRun), bank(BankAlert) }
    let item: Item
    /// Where the same purchase was found again and how it was merged; nil without duplicates.
    let duplicate: String?

    var id: UUID {
        switch item { case .wallet(let run): run.id; case .bank(let alert): alert.id }
    }
    var date: Date {
        switch item { case .wallet(let run): run.receivedAt; case .bank(let alert): alert.receivedAt }
    }
    var source: CaptureAutomation? {
        switch item { case .wallet: .walletTransaction; case .bank(let alert): CaptureAutomation.source(of: alert) }
    }
}

enum AutomationJournal {
    /// Every saved run and message, newest first, with duplicates explained on both sides.
    static func entries(runs: [WalletRun], alerts: [BankAlert]) -> [AutomationEntry] {
        let wallet = runs.map { AutomationEntry(item: .wallet($0), duplicate: duplicateNote(for: $0, alerts: alerts)) }
        let bank = alerts.map { AutomationEntry(item: .bank($0), duplicate: duplicateNote(for: $0, alerts: alerts)) }
        return (wallet + bank).sorted { $0.date > $1.date }
    }

    static func entries() -> [AutomationEntry] { entries(runs: WalletRunLog.runs(), alerts: BankAlertLog.alerts()) }

    private static func name(_ alert: BankAlert) -> String {
        CaptureAutomation.source(of: alert)?.title ?? L(legacyBankSource)
    }

    static func duplicateNote(for run: WalletRun, alerts: [BankAlert]) -> String? {
        let paired = alerts.filter { $0.walletRunID == run.id }
        if run.delivery == .duplicate {
            if run.isEmpty { return L("Пустой повтор того же запуска Wallet: не учтён") }
            if let alert = paired.first { return L("Дубль: эта покупка уже записана из «\(name(alert))», запуск не отправлен") }
            return L("Дубль: покупка уже записана из SMS или уведомления банка, запуск не отправлен")
        }
        let notes = paired.map { alert -> String in
            if alert.completedWallet == true || alert.lastError?.hasPrefix("Сумма добавлена") == true {
                return L("Дополнено из «\(name(alert))»: сумма и продавец")
            }
            return L("Объединено: «\(name(alert))» о той же покупке не отправлено")
        }
        return notes.isEmpty ? nil : notes.joined(separator: "\n")
    }

    static func duplicateNote(for alert: BankAlert, alerts: [BankAlert]) -> String? {
        if alert.walletRunID != nil {
            if alert.completedWallet == true || alert.lastError?.hasPrefix("Сумма добавлена") == true {
                return L("Объединено: сумма добавлена к покупке из «Транзакция Wallet»")
            }
            return alert.state == .duplicate
                ? L("Дубль покупки из «Транзакция Wallet»: сообщение не отправлено")
                : L("Объединено: покупка записана отсюда, запуск «Транзакция Wallet» не отправлен")
        }
        if let id = alert.sameAs {
            let other = alerts.first { $0.id == id }
            return L("Дубль сообщения «\(other.map(name) ?? L(legacyBankSource))» о той же покупке: не отправлено")
        }
        if let other = alerts.first(where: { $0.sameAs == alert.id }) {
            return L("Объединено: «\(name(other))» о той же покупке не отправлено")
        }
        return nil
    }
}

/// A small colored label with the automation's name.
struct SourceBadge: View {
    let title: String
    var icon: String = "bolt"
    var color: String = "gray"

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(Color.token(color))
            .background(Color.token(color).opacity(0.13), in: Capsule())
    }

    init(_ source: CaptureAutomation?) {
        title = source?.title ?? L(legacyBankSource)
        icon = source?.icon ?? "text.bubble"
        color = source?.color ?? "gray"
    }

    init(title: String, icon: String, color: String) { self.title = title; self.icon = icon; self.color = color }
}

extension View {
    /// An inline title that wraps onto a second line. iOS large titles never wrap, so a
    /// long localized title such as "Texts and Notifications" was cut off.
    func wrappingTitle(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title).font(.headline).multilineTextAlignment(.center)
                        .lineLimit(2).minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                }
            }
    }
}
