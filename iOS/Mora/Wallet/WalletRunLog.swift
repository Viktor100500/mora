import Foundation
import AppIntents

/// One run of the Wallet automation as Mora received it. Its id is also the
/// event id sent to the server, so every retry of the same purchase is one capture.
struct WalletRun: Codable, Identifiable, Equatable, Sendable {
    enum Delivery: String, Codable, Sendable {
        /// Apple Pay is not turned on in Mora: the run is only logged.
        case logged
        /// No amount or merchant: never sent, waits for the user to process it.
        case incomplete
        /// The first action saved merchant and card; the amount action has not run yet.
        case awaitingAmount
        /// Saved and waiting to be sent.
        case waiting
        /// Saved by Mora 1.0.22 and older: not sent within 15 minutes, waits for the user.
        case late
        case delivered
        /// The server refused the purchase itself; retrying does not help.
        case failed
        /// The user booked it in the transaction form.
        case processed
        /// The user entered it by hand or chose not to count it.
        case skipped
        /// An empty run next to a complete run of the same payment.
        case duplicate
    }

    /// What happened to the run, for the run details on the iPhone.
    struct Event: Codable, Equatable, Sendable {
        var date: Date
        var text: String
    }

    var id: UUID
    var receivedAt: Date
    var amount: String
    var merchant: String
    var card: String
    /// The Wallet transaction's "Name", when the automation passes it.
    var name = ""
    /// The Wallet transaction's "Transaction" property as text, when the automation passes it.
    var transaction = ""
    /// The Mora action that saved the run.
    var action = ""
    /// "Finish Wallet Payment" ran for this purchase: the automation is set up in two steps.
    var amountActionRan = false
    var delivery: Delivery = .logged
    var attempts = 0
    var lastError: String?
    /// The server's capture state, `recorded` or `pending`, and why it is pending.
    var serverState: String?
    var serverReason: String?
    /// The user sent a late purchase explicitly, so the 15-minute rule no longer holds it.
    var confirmed = false
    var events: [Event] = []

    var isComplete: Bool { !amount.isEmpty && !merchant.isEmpty }
    /// Wallet passed nothing at all.
    var isEmpty: Bool { amount.isEmpty && merchant.isEmpty && card.isEmpty && name.isEmpty }
    /// Sent as the merchant: Wallet sometimes fills only the transaction name.
    var sentMerchant: String { merchant.isEmpty ? name : merchant }

    init(id: UUID = UUID(), receivedAt: Date, amount: String, merchant: String, card: String, name: String = "", delivery: Delivery = .logged) {
        self.id = id; self.receivedAt = receivedAt; self.amount = amount; self.merchant = merchant; self.card = card; self.name = name; self.delivery = delivery
    }

    mutating func log(_ text: String, at date: Date = .now) {
        events.append(Event(date: date, text: text))
        if events.count > 50 { events.removeFirst(events.count - 50) }
    }

    // Runs saved by Mora 1.0.15 have no delivery fields, 1.0.22 and older no events.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        receivedAt = try c.decode(Date.self, forKey: .receivedAt)
        amount = try c.decode(String.self, forKey: .amount)
        merchant = try c.decode(String.self, forKey: .merchant)
        card = try c.decode(String.self, forKey: .card)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        transaction = try c.decodeIfPresent(String.self, forKey: .transaction) ?? ""
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        amountActionRan = try c.decodeIfPresent(Bool.self, forKey: .amountActionRan) ?? false
        delivery = try c.decodeIfPresent(Delivery.self, forKey: .delivery) ?? .logged
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        serverState = try c.decodeIfPresent(String.self, forKey: .serverState)
        serverReason = try c.decodeIfPresent(String.self, forKey: .serverReason)
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        events = try c.decodeIfPresent([Event].self, forKey: .events) ?? []
    }
}

/// Local journal and outbox of Wallet automation runs: one file per run, so two
/// payments in a row never rewrite each other. The files stay writable while the
/// iPhone is locked after its first unlock. Writes after `record` go through
/// `WalletDelivery`, which serializes them.
enum WalletRunLog {
    static let keptDays = 14

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Mora/WalletRuns", directoryHint: .isDirectory)
    }

    @discardableResult
    static func record(amount: String?, merchant: String?, card: String?, name: String? = nil, action: String = "Log Wallet Payment",
                       awaitingAmount: Bool = false, sending: Bool, at date: Date = .now, in directory: URL = directory) throws -> WalletRun {
        var run = WalletRun(receivedAt: date, amount: clean(amount), merchant: clean(merchant), card: clean(card), name: clean(name))
        run.action = action
        // An incomplete purchase is kept as waiting until a possible repeat run is seen, then left for the user.
        run.delivery = !sending ? .logged : awaitingAmount ? .awaitingAmount : .waiting
        let missing = [(run.amount, "сумма"), (run.merchant, "продавец"), (run.card, "карта")]
            .filter { $0.0.isEmpty && !(awaitingAmount && $0.1 == "сумма") }.map(\.1)
        run.log(missing.isEmpty ? "Получено действием «\(action)»" : "Получено действием «\(action)». Wallet не передал: \(missing.joined(separator: ", "))", at: date)
        if !sending { run.log("Apple Pay в Mora не включён: покупка только в журнале", at: date) }
        try save(run, in: directory)
        prune(before: date.addingTimeInterval(-Double(keptDays) * 86_400), in: directory)
        return run
    }

    static func save(_ run: WalletRun, in directory: URL = directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try encoder.encode(run).write(to: file(for: run.id, in: directory), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Newest first. Unreadable files are skipped rather than hiding the rest.
    static func runs(in directory: URL = directory) -> [WalletRun] {
        files(in: directory)
            .compactMap { try? decoder.decode(WalletRun.self, from: Data(contentsOf: $0)) }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    /// The first money value in the text of a Wallet transaction, such as "$12.40" or "12,40 €".
    static func amount(in text: String) -> String? {
        let number = #"[0-9]{1,3}(?:[ ,.\u00A0\u202F][0-9]{3})*(?:[.,][0-9]{1,2})?"#
        let symbol = #"(?:[$€£¥₽]|[A-Z]{3})"#
        for pattern in [symbol + #"\s?"# + number, number + #"\s?"# + symbol] {
            if let range = text.range(of: pattern, options: .regularExpression) { return String(text[range]) }
        }
        return nil
    }

    /// Merchant, card and name missing from the first action, taken from the whole transaction
    /// as text. A line equal to a card already seen on this iPhone is the card; the first
    /// other line without the amount is the merchant.
    static func fill(_ run: inout WalletRun, from text: String, knownCards: [String]) {
        let amount = Self.amount(in: text)
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let cards = Set(knownCards.map { $0.lowercased() })
        let card = lines.first { cards.contains($0.lowercased()) }
        let merchant = lines.first { $0 != card && $0 != amount && Self.amount(in: $0) == nil }
        if run.card.isEmpty, let card { run.card = card }
        if run.merchant.isEmpty && run.name.isEmpty, let merchant { run.name = merchant }
    }

    /// Every run with all fields Wallet passed, to study what the automation sends.
    static func export(in directory: URL = directory) -> String {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(runs(in: directory))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// Removes the journal but keeps purchases that still wait for sending or a decision.
    static func clear(in directory: URL = directory) {
        for run in runs(in: directory) where !run.needsDelivery {
            try? FileManager.default.removeItem(at: file(for: run.id, in: directory))
        }
    }

    private static func prune(before date: Date, in directory: URL) {
        for run in runs(in: directory) where run.receivedAt < date && !run.needsDelivery {
            try? FileManager.default.removeItem(at: file(for: run.id, in: directory))
        }
    }

    /// Mora 1.0.15 named files `<milliseconds>-<id>.json`; newer runs use `<id>.json`.
    private static func file(for id: UUID, in directory: URL) -> URL {
        let name = id.uuidString + ".json"
        return files(in: directory).first { $0.lastPathComponent.hasSuffix(name) } ?? directory.appending(path: name)
    }

    private static func files(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    private static func clean(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}

extension WalletRun {
    /// Still has to reach the server or needs the user's decision.
    var needsDelivery: Bool { delivery == .waiting || delivery == .late || delivery == .awaitingAmount || delivery == .incomplete || delivery == .failed }
    /// Broken: the user books it in the transaction form.
    var needsProcessing: Bool { delivery == .incomplete || delivery == .late || delivery == .failed }
}

/// The Shortcuts action of the Wallet "Transaction" automation. It runs without
/// opening Mora, also on a locked iPhone, and never fails the automation: the
/// purchase is saved first and sent when Apple Pay is turned on in Mora.
struct LogWalletPaymentIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Wallet Payment"
    /// Replaced by the two-step automation: automations that already use it keep
    /// working, but it is no longer offered in Shortcuts.
    static let isDiscoverable = false
    static let description = IntentDescription("Saves the amount, merchant and card of a Wallet transaction on this iPhone. When Apple Pay is turned on in Mora, also sends the purchase to the shared database and retries it later without internet.")
    static let openAppWhenRun = false
    static let authenticationPolicy = IntentAuthenticationPolicy.alwaysAllowed

    @Parameter(title: "Amount") var amount: String?
    @Parameter(title: "Merchant") var merchant: String?
    @Parameter(title: "Card or Pass") var card: String?
    @Parameter(title: "Name") var name: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) at \(\.$merchant) with \(\.$card) named \(\.$name)")
    }

    func perform() async throws -> some IntentResult {
        let sender = WalletSender.current()
        try? WalletRunLog.record(amount: amount, merchant: merchant, card: card, name: name, sending: sender != nil)
        BankAlertLog.reconcileWallet()
        if let sender { await WalletDelivery.shared.deliverWaiting(with: sender) }
        await WalletBackgroundDelivery.scheduleIfNeeded()
        return .result()
    }
}

/// First action of the two-step automation. iOS 26 Shortcuts crashes while
/// reading the Amount of a transaction that has no price yet (transit taps,
/// deferred authorizations), and the whole automation stops. Saving merchant
/// and card before the amount is read keeps such a purchase for the user to process.
struct StartWalletPaymentIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Wallet Payment"
    static let description = IntentDescription("First action of the Wallet automation: saves the merchant, card and name of the transaction on this iPhone. Add “Finish Wallet Payment” after it.")
    static let openAppWhenRun = false
    static let authenticationPolicy = IntentAuthenticationPolicy.alwaysAllowed

    @Parameter(title: "Merchant") var merchant: String?
    @Parameter(title: "Card or Pass") var card: String?
    @Parameter(title: "Name") var name: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Start payment at \(\.$merchant) named \(\.$name) with \(\.$card)")
    }

    func perform() async throws -> some IntentResult {
        try? WalletRunLog.record(amount: nil, merchant: merchant, card: card, name: name, action: "Start Wallet Payment",
                                 awaitingAmount: true, sending: WalletSender.current() != nil)
        // Sends it without amount later if the amount action never runs.
        await WalletBackgroundDelivery.scheduleIfNeeded()
        return .result()
    }
}

/// Second, last action: receives the whole transaction ("Shortcut Input"), takes
/// the amount from it and sends the purchase saved a moment ago. If iOS fails
/// while turning the transaction into text, the purchase is already saved.
struct AddWalletAmountIntent: AppIntent {
    static let title: LocalizedStringResource = "Finish Wallet Payment"
    static let description = IntentDescription("Last action of the Wallet automation: pass Shortcut Input as is. Mora takes the amount from the transaction, completes the purchase saved by “Start Wallet Payment” and sends it.")
    static let openAppWhenRun = false
    static let authenticationPolicy = IntentAuthenticationPolicy.alwaysAllowed

    @Parameter(title: "Transaction") var transaction: String?
    /// Kept for automations set up with an explicit Amount property; used before the parsed amount.
    @Parameter(title: "Amount") var amount: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Finish payment with \(\.$transaction)") { \.$amount }
    }

    func perform() async throws -> some IntentResult {
        await WalletDelivery.shared.addAmount(amount ?? "", transaction: transaction ?? "")
        BankAlertLog.reconcileWallet()
        await WalletBackgroundDelivery.run()
        return .result()
    }
}

/// An App Shortcut makes iOS register Mora's actions with Shortcuts right after
/// installation, so the action is listed under Mora and found by search.
struct MoraAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartWalletPaymentIntent(), phrases: ["Start Wallet payment in \(.applicationName)"],
                    shortTitle: "Start Wallet Payment", systemImageName: "wallet.pass")
        AppShortcut(intent: AddWalletAmountIntent(), phrases: ["Add Wallet amount in \(.applicationName)"],
                    shortTitle: "Finish Wallet Payment", systemImageName: "dollarsign.circle")
        AppShortcut(intent: LogBankMessageIntent(), phrases: ["Log bank message in \(.applicationName)"],
                    shortTitle: "Log Bank Message", systemImageName: "message")
    }
}
