import Foundation
import AppIntents

/// One run of the Wallet automation as Mora received it. Saving it is the first
/// thing the action does, so a missing run means the automation never reached Mora.
struct WalletRun: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var receivedAt: Date
    var amount: String
    var merchant: String
    var card: String

    var isComplete: Bool { !amount.isEmpty && !merchant.isEmpty }
}

/// Local journal of Wallet automation runs. Nothing is sent to the server.
/// Each run is its own file, so two payments in a row never rewrite each other,
/// and the files stay writable while the iPhone is locked after its first unlock.
enum WalletRunLog {
    static let keptDays = 14

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Mora/WalletRuns", directoryHint: .isDirectory)
    }

    @discardableResult
    static func record(amount: String?, merchant: String?, card: String?, at date: Date = .now, in directory: URL = directory) throws -> WalletRun {
        let run = WalletRun(id: UUID(), receivedAt: date, amount: clean(amount), merchant: clean(merchant), card: clean(card))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let file = directory.appending(path: "\(Int64(date.timeIntervalSince1970 * 1000))-\(run.id.uuidString).json")
        try encoder.encode(run).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        prune(before: date.addingTimeInterval(-Double(keptDays) * 86_400), in: directory)
        return run
    }

    /// Newest first. Unreadable files are skipped rather than hiding the rest.
    static func runs(in directory: URL = directory) -> [WalletRun] {
        files(in: directory)
            .compactMap { try? decoder.decode(WalletRun.self, from: Data(contentsOf: $0)) }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    static func clear(in directory: URL = directory) {
        for file in files(in: directory) { try? FileManager.default.removeItem(at: file) }
    }

    private static func prune(before date: Date, in directory: URL) {
        for file in files(in: directory) {
            guard let run = try? decoder.decode(WalletRun.self, from: Data(contentsOf: file)), run.receivedAt < date else { continue }
            try? FileManager.default.removeItem(at: file)
        }
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

/// The Shortcuts action placed first in the Wallet "Transaction" automation.
/// It runs without opening Mora, also on a locked iPhone, and never fails the
/// automation: a run that cannot be saved is simply missing from the journal.
struct LogWalletPaymentIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Wallet Payment"
    static let description = IntentDescription("Saves the amount, merchant and card of a Wallet transaction on this iPhone, so Mora can show that the automation ran. Nothing is sent.")
    static let openAppWhenRun = false
    static let authenticationPolicy = IntentAuthenticationPolicy.alwaysAllowed

    @Parameter(title: "Amount") var amount: String?
    @Parameter(title: "Merchant") var merchant: String?
    @Parameter(title: "Card or Pass") var card: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) at \(\.$merchant) with \(\.$card)")
    }

    func perform() async throws -> some IntentResult {
        try? WalletRunLog.record(amount: amount, merchant: merchant, card: card)
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
