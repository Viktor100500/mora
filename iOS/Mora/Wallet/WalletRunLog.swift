import Foundation
import AppIntents

/// One run of the Wallet automation as Mora received it. Its id is also the
/// event id sent to the server, so every retry of the same purchase is one capture.
struct WalletRun: Codable, Identifiable, Equatable, Sendable {
    enum Delivery: String, Codable, Sendable {
        /// Apple Pay is not turned on in Mora: the run is only logged.
        case logged
        /// No amount or merchant: never sent, so it cannot become an expense.
        case incomplete
        /// Saved and waiting to be sent.
        case waiting
        /// Not sent within 15 minutes: the user may have entered it by hand meanwhile.
        case late
        case delivered
        /// The server refused the purchase itself; retrying does not help.
        case failed
        /// The user entered it by hand or chose not to count it.
        case skipped
    }

    var id: UUID
    var receivedAt: Date
    var amount: String
    var merchant: String
    var card: String
    var delivery: Delivery = .logged
    var attempts = 0
    var lastError: String?
    /// The server's capture state, `recorded` or `pending`, and why it is pending.
    var serverState: String?
    var serverReason: String?
    /// The user sent a late purchase explicitly, so the 15-minute rule no longer holds it.
    var confirmed = false

    var isComplete: Bool { !amount.isEmpty && !merchant.isEmpty }

    init(id: UUID = UUID(), receivedAt: Date, amount: String, merchant: String, card: String, delivery: Delivery = .logged) {
        self.id = id; self.receivedAt = receivedAt; self.amount = amount; self.merchant = merchant; self.card = card; self.delivery = delivery
    }

    // Runs saved by Mora 1.0.15 have no delivery fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        receivedAt = try c.decode(Date.self, forKey: .receivedAt)
        amount = try c.decode(String.self, forKey: .amount)
        merchant = try c.decode(String.self, forKey: .merchant)
        card = try c.decode(String.self, forKey: .card)
        delivery = try c.decodeIfPresent(Delivery.self, forKey: .delivery) ?? .logged
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        serverState = try c.decodeIfPresent(String.self, forKey: .serverState)
        serverReason = try c.decodeIfPresent(String.self, forKey: .serverReason)
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
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
    static func record(amount: String?, merchant: String?, card: String?, sending: Bool, at date: Date = .now, in directory: URL = directory) throws -> WalletRun {
        var run = WalletRun(receivedAt: date, amount: clean(amount), merchant: clean(merchant), card: clean(card))
        run.delivery = !sending ? .logged : run.isComplete ? .waiting : .incomplete
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
    var needsDelivery: Bool { delivery == .waiting || delivery == .late }
}

/// The Shortcuts action of the Wallet "Transaction" automation. It runs without
/// opening Mora, also on a locked iPhone, and never fails the automation: the
/// purchase is saved first and sent when Apple Pay is turned on in Mora.
struct LogWalletPaymentIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Wallet Payment"
    static let description = IntentDescription("Saves the amount, merchant and card of a Wallet transaction on this iPhone. When Apple Pay is turned on in Mora, also sends the purchase to the shared database and retries it later without internet.")
    static let openAppWhenRun = false
    static let authenticationPolicy = IntentAuthenticationPolicy.alwaysAllowed

    @Parameter(title: "Amount") var amount: String?
    @Parameter(title: "Merchant") var merchant: String?
    @Parameter(title: "Card or Pass") var card: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) at \(\.$merchant) with \(\.$card)")
    }

    func perform() async throws -> some IntentResult {
        let sender = WalletSender.current()
        try? WalletRunLog.record(amount: amount, merchant: merchant, card: card, sending: sender != nil)
        if let sender { await WalletDelivery.shared.deliverWaiting(with: sender) }
        return .result()
    }
}

/// An App Shortcut makes iOS register Mora's actions with Shortcuts right after
/// installation, so the action is listed under Mora and found by search.
struct MoraAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LogWalletPaymentIntent(), phrases: ["Log Wallet payment in \(.applicationName)"],
                    shortTitle: "Log Wallet Payment", systemImageName: "wallet.pass")
    }
}
