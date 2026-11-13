import Foundation
import AppIntents
import FinanceCore

/// A bank text message or app notification passed to Mora by a Shortcuts automation.
/// One-time codes and unrelated messages are kept only as a line without their text.
struct BankAlert: Codable, Identifiable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// Not a purchase: a code, a fraud check, a decline or an offer. The text is not kept.
        case ignored
        /// A new wording: the user checks the fields once and Mora remembers the format.
        case review
        /// Apple Pay is not turned on in Mora: nothing can be sent.
        case logged
        case waiting
        case delivered
        case failed
        /// The same purchase already came from the Wallet automation.
        case duplicate
        case skipped
    }

    var id = UUID()
    var receivedAt: Date
    /// The SMS sender or the app that sent the notification.
    var source: String
    var text: String
    var amount = ""
    var currency = ""
    var merchant = ""
    var cardLast4 = ""
    var income = false
    var state: State
    var ignoredReason: BankMessage.Ignored?
    /// The exact pieces of the text the amount and merchant came from.
    var amountText = ""
    var merchantText = ""
    var attempts = 0
    var lastError: String?
    var serverState: String?
    /// The Wallet run of the same purchase. A pair is never matched again.
    var walletRunID: UUID?
    /// Came from the Wallet notification action: it completes a Wallet purchase and is
    /// never booked by itself. `source` is the notification title, the card or its bank.
    var wallet: Bool?
    /// Another bank message confirmed to describe the same purchase.
    var sameAs: UUID?
    /// Which automation passed the message: an SMS or a bank app notification. Nil for
    /// messages saved before Mora 1.0.48 and for Wallet notifications, see `wallet`.
    var channel: Channel?
    /// The message only brought the amount of a Wallet purchase that came without one.
    var completedWallet: Bool?

    enum Channel: String, Codable, Sendable { case sms, notification }

    /// The card name sent to the shared database. Mora links it to an account
    /// the first time, like a Wallet card.
    var card: String {
        let name = source.trimmingCharacters(in: .whitespaces).isEmpty ? "SMS" : source
        return cardLast4.isEmpty ? name : "\(name) ··\(cardLast4)"
    }

    var needsUser: Bool { state == .review || state == .failed }

    var parsed: BankMessage.Parsed? {
        guard let value = Money.parse(amount), value > 0 else { return nil }
        return BankMessage.Parsed(amount: value, currency: currency.isEmpty ? nil : currency, merchant: merchant,
                                  cardLast4: cardLast4.isEmpty ? nil : cardLast4, direction: income ? .income : .expense,
                                  automatic: false, amountText: amountText, merchantText: merchantText, wallet: wallet == true)
    }
}

/// One file per message like the Wallet journal, writable while the iPhone is
/// locked after its first unlock. Writes after `record` go through `BankAlertDelivery`.
enum BankAlertLog {
    static let keptDays = 14

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Mora/BankAlerts", directoryHint: .isDirectory)
    }
    static var templatesFile: URL {
        URL.applicationSupportDirectory.appending(path: "Mora/BankTemplates.json")
    }

    @discardableResult
    static func record(text: String, source: String, channel: BankAlert.Channel? = nil, sending: Bool, at date: Date = .now,
                       directory: URL = directory, templates: [BankMessageTemplate] = templates(),
                       walletRuns: [WalletRun] = WalletRunLog.runs()) throws -> BankAlert {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        var alert: BankAlert
        switch BankMessage.parse(text, sender: source, templates: templates) {
        case .ignored(let reason):
            alert = BankAlert(receivedAt: date, source: source, text: "", state: .ignored, ignoredReason: reason, channel: channel)
        case .parsed(let value):
            alert = BankAlert(receivedAt: date, source: source, text: BankMessage.normalized(text), state: .review, channel: channel)
            alert.apply(value)
            // Nothing is saved before both lookups, so one read serves them.
            let existing = alerts(in: directory)
            if let run = pairableRun(for: alert, in: walletRuns, pairedIn: directory, existing: existing) {
                alert.state = .duplicate; alert.walletRunID = run.id
                alert.lastError = "Эта покупка уже пришла из Wallet: сообщение не отправлено."
            } else {
                if value.automatic && !alert.income { alert.state = sending ? .waiting : .logged }
                if var other = samePurchase(as: alert, in: directory, existing: existing) {
                    if other.state == .review && other.attempts == 0 && alert.state == .waiting {
                        // Save the winning purchase before suppressing the earlier review.
                        try save(alert, in: directory)
                        other.state = .duplicate; other.sameAs = alert.id; other.lastError = otherMessageNote
                        try save(other, in: directory)
                    } else {
                        alert.state = .duplicate; alert.sameAs = other.id; alert.lastError = otherMessageNote
                    }
                }
            }
        }
        try save(alert, in: directory)
        prune(before: date.addingTimeInterval(-Double(keptDays) * 86_400), in: directory)
        return alert
    }

    /// A Wallet notification, passed field by field by its own action and never read as a
    /// bank message. Its fields are kept as received, also when no purchase is found in them.
    @discardableResult
    static func recordWallet(title: String, subtitle: String, body: String, at date: Date = .now,
                             directory: URL = directory, walletRuns: [WalletRun] = WalletRunLog.runs()) throws -> BankAlert {
        let fields = [("Title", title), ("Subtitle", subtitle), ("Body", body)]
            .map { ($0.0, BankMessage.normalized($0.1)) }.filter { !$0.1.isEmpty }
        // Wallet is reported to name the card in the title; on some iPhones it is the card's bank.
        let card = BankMessage.normalized(title).components(separatedBy: "\n").first ?? ""
        var alert = BankAlert(receivedAt: date, source: card.isEmpty ? "Wallet" : card,
                              text: fields.map { "\($0.0): \($0.1)" }.joined(separator: "\n"), state: .ignored, ignoredReason: .noTransaction)
        if let value = BankMessage.walletNotification(subtitle: subtitle, body: body) {
            alert.state = .review; alert.ignoredReason = nil
            alert.apply(value)
            if let run = pairableRun(for: alert, in: walletRuns, pairedIn: directory) {
                alert.state = .duplicate; alert.walletRunID = run.id
                alert.lastError = "Эта покупка уже пришла из Wallet: сообщение не отправлено."
            }
        }
        alert.wallet = true
        try save(alert, in: directory)
        prune(before: date.addingTimeInterval(-Double(keptDays) * 86_400), in: directory)
        return alert
    }

    // MARK: One purchase from several bank messages

    static let otherMessageNote = "Эта покупка уже пришла другим сообщением банка: не отправлено."

    /// Different SMS/push wordings can describe one purchase. Require every identity
    /// field and exactly one candidate; missing data never authorizes suppressing a purchase.
    static func samePurchase(as alert: BankAlert, in directory: URL, existing: [BankAlert]? = nil) -> BankAlert? {
        let source = BankMessage.normalized(alert.source).lowercased()
        let merchant = MerchantName.normalized(alert.merchant)
        guard alert.wallet != true, !alert.income, !source.isEmpty, !merchant.isEmpty,
              alert.cardLast4.count == 4, alert.cardLast4.allSatisfy(\.isNumber),
              Locale.isoCurrencyCodeSet.contains(alert.currency),
              let amount = Money.parse(alert.amount), amount > 0 else { return nil }
        let key = formatKey(alert.text)
        guard !key.isEmpty else { return nil }
        let all = existing ?? alerts(in: directory)
        let paired = Set(all.compactMap(\.sameAs)).union(all.filter { $0.sameAs != nil }.map(\.id))
        let candidates = all.filter { other in
            other.id != alert.id && !paired.contains(other.id) && other.wallet != true && !other.income
                && ([.review, .waiting, .delivered].contains(other.state) || (other.state == .duplicate && other.walletRunID != nil))
                && Money.parse(other.amount) == amount
                && abs(other.receivedAt.timeIntervalSince(alert.receivedAt)) < pairWindow
                && BankMessage.normalized(other.source).lowercased() == source
                && other.cardLast4 == alert.cardLast4 && other.currency == alert.currency
                && MerchantName.normalized(other.merchant) == merchant
                && !formatKey(other.text).isEmpty && formatKey(other.text) != key
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Repeated messages with the same wording remain separate purchases.
    static func formatKey(_ text: String) -> String {
        String(text.split(separator: "\n").first ?? "").lowercased().filter(\.isLetter)
    }

    // MARK: Working together with the Wallet automation

    /// A tap in a shop starts the Wallet automation and the bank reports the same purchase.
    /// Wallet keeps the purchase; the message only completes what Wallet did not pass.
    static let pairWindow: TimeInterval = 10 * 60

    static func isSamePurchase(_ alert: BankAlert, _ run: WalletRun) -> Bool {
        guard !alert.income, let amount = Money.parse(alert.amount), amount > 0,
              let paid = Money.parse(run.amount).map(abs) else { return false }
        let walletCurrency = BankMessage.walletNotification(subtitle: "", body: run.amount)?.currency
        if let walletCurrency, !alert.currency.isEmpty, alert.currency != walletCurrency { return false }
        let window = alert.wallet == true ? WalletDelivery.completionHold : pairWindow
        return paid == amount && abs(run.receivedAt.timeIntervalSince(alert.receivedAt)) < window
    }

    static func pairableRun(for alert: BankAlert, in runs: [WalletRun], pairedIn directory: URL, existing: [BankAlert]? = nil) -> WalletRun? {
        let paired = Set((existing ?? alerts(in: directory)).compactMap(\.walletRunID))
        var candidates = runs.filter { !paired.contains($0.id) && $0.delivery != .duplicate && $0.delivery != .skipped && isSamePurchase(alert, $0) }
        guard alert.wallet == true else { return candidates.first }
        // A same-price run still missing its merchant must be completed, not
        // treated as an already complete duplicate of this notification.
        candidates = candidates.filter { !$0.sentMerchant.isEmpty }
        let cardKey = BankMessage.normalized(alert.source).lowercased()
        if runs.contains(where: { !$0.card.isEmpty && BankMessage.normalized($0.card).lowercased() == cardKey }) {
            candidates = candidates.filter { BankMessage.normalized($0.card).lowercased() == cardKey }
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Runs right after a Wallet purchase is saved or gets its amount, before it is sent.
    /// A message of the same purchase not sent yet is dropped; one already sent keeps
    /// the purchase and the Wallet run is not sent.
    static func reconcileWallet(now: Date = .now, directory: URL = directory, walletDirectory: URL = WalletRunLog.directory) {
        var alerts = alerts(in: directory)
        let paired = Set(alerts.compactMap(\.walletRunID))
        for var run in WalletRunLog.runs(in: walletDirectory)
        where run.delivery == .waiting && !paired.contains(run.id) && now.timeIntervalSince(run.receivedAt) < pairWindow {
            guard let index = alerts.firstIndex(where: {
                $0.walletRunID == nil && [.review, .waiting, .logged, .delivered].contains($0.state) && isSamePurchase($0, run)
                    && ($0.wallet != true || pairableRun(for: $0, in: WalletRunLog.runs(in: walletDirectory), pairedIn: directory)?.id == run.id)
            }) else { continue }
            alerts[index].walletRunID = run.id
            if alerts[index].state == .delivered {
                run.delivery = .duplicate
                run.log("Уже записано из SMS или уведомления банка: не отправлено", at: now)
                try? WalletRunLog.save(run, in: walletDirectory)
            } else {
                alerts[index].state = .duplicate
                alerts[index].lastError = "Эта покупка уже пришла из Wallet: сообщение не отправлено."
            }
            try? save(alerts[index], in: directory)
        }
    }

    static func save(_ alert: BankAlert, in directory: URL = directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try encoder.encode(alert).write(to: directory.appending(path: alert.id.uuidString + ".json"),
                                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Newest first.
    static func alerts(in directory: URL = directory) -> [BankAlert] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(BankAlert.self, from: Data(contentsOf: $0)) }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    /// Removes the journal but keeps messages that still wait for sending or a check.
    static func clear(in directory: URL = directory) {
        for alert in alerts(in: directory) where !alert.needsUser && alert.state != .waiting { remove(alert.id, in: directory) }
    }

    static func remove(_ id: UUID, in directory: URL = directory) {
        try? FileManager.default.removeItem(at: directory.appending(path: id.uuidString + ".json"))
    }

    private static func prune(before date: Date, in directory: URL) {
        for alert in alerts(in: directory) where alert.receivedAt < date && !alert.needsUser && alert.state != .waiting {
            remove(alert.id, in: directory)
        }
    }

    // MARK: Formats

    static func templates(in file: URL = templatesFile) -> [BankMessageTemplate] {
        (try? decoder.decode([BankMessageTemplate].self, from: Data(contentsOf: file))) ?? []
    }

    static func saveTemplates(_ templates: [BankMessageTemplate], in file: URL = templatesFile) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(templates).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Remembers the wording of a confirmed message. Nil when the merchant is not part of the text.
    @discardableResult
    static func learn(from text: String, source: String, parsed: BankMessage.Parsed, in file: URL = templatesFile) throws -> BankMessageTemplate? {
        guard let template = BankMessageTemplate(learningFrom: text, sender: source, parsed: parsed) else { return nil }
        var all = templates(in: file).filter { $0.pattern != template.pattern || $0.sender != template.sender }
        all.append(template)
        try saveTemplates(all, in: file)
        return template
    }

    private nonisolated(unsafe) static let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder
    }()

    private nonisolated(unsafe) static let decoder: JSONDecoder = {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }()
}

extension BankAlert {
    mutating func apply(_ value: BankMessage.Parsed) {
        amount = Money.plain(value.amount); currency = value.currency ?? ""
        merchant = value.merchant; cardLast4 = value.cardLast4 ?? ""; income = value.direction == .income
        amountText = value.amountText; merchantText = value.merchantText; wallet = value.wallet ? true : nil
    }
}

/// Sends confirmed bank messages to `mora_capture_payment` with the Wallet phone key.
/// The message id is the event id, so a retry never books a purchase twice.
actor BankAlertDelivery {
    static let shared = BankAlertDelivery()
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let directory: URL
    private let wallet: WalletDelivery
    private let transport: Transport

    init(directory: URL = BankAlertLog.directory, wallet: WalletDelivery = .shared,
         transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.directory = directory; self.wallet = wallet; self.transport = transport
    }

    func record(text: String, source: String, channel: BankAlert.Channel? = nil, sending: Bool) throws -> BankAlert {
        try BankAlertLog.record(text: text, source: source, channel: channel, sending: sending, directory: directory)
    }

    func deliverWaiting(with sender: WalletSender? = WalletSender.current()) async {
        guard let sender else { return }
        for var alert in BankAlertLog.alerts(in: directory).reversed() where alert.state == .waiting {
            alert.attempts += 1
            let outcome: WalletDelivery.Outcome
            do {
                let (data, response) = try await transport(Self.request(for: alert, with: sender))
                outcome = WalletDelivery.outcome(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
            } catch { outcome = .retry(error.localizedDescription) }
            switch outcome {
            case .delivered(let state, _): alert.state = .delivered; alert.serverState = state; alert.lastError = nil
            case .retry(let message): alert.lastError = message
            case .keyRejected: alert.lastError = "Ключ телефона не принят: включите Apple Pay на iPhone заново."
            case .refused(let message): alert.state = .failed; alert.lastError = message
            }
            try? BankAlertLog.save(alert, in: directory)
            if case .retry = outcome { return }
            if case .keyRejected = outcome { return }
        }
    }

    /// The user checked the fields: Mora remembers the wording and sends the purchase.
    func confirm(_ edited: BankAlert, sending: Bool) async -> Bool {
        var alert = edited
        var learned = false
        // A Wallet notification already has a fixed format; a learned one would book it without a card.
        if alert.wallet == true { learned = true }
        else if let parsed = alert.parsed { learned = (try? BankAlertLog.learn(from: alert.text, source: alert.source, parsed: parsed)) != nil }
        guard alert.state != .duplicate else { try? BankAlertLog.save(alert, in: directory); return learned }
        alert.state = alert.income ? .skipped : sending ? .waiting : .logged
        if alert.income { alert.lastError = "Возвраты и зачисления пока добавляются вручную." }
        try? BankAlertLog.save(alert, in: directory)
        if sending { await deliverWaiting() }
        return learned
    }

    /// Wallet passes no amount, and often no merchant, for transit taps and deferred
    /// authorizations. When the bank or Wallet's own notification reports them meanwhile,
    /// they complete the Wallet purchase instead of becoming a second one.
    func completeWallet(_ id: UUID, now: Date = .now) async {
        guard var alert = BankAlertLog.alerts(in: directory).first(where: { $0.id == id }),
              alert.state != .duplicate, alert.state != .ignored, !alert.income, !alert.amount.isEmpty,
              let run = await wallet.complete(amount: [alert.amount, alert.currency].filter { !$0.isEmpty }.joined(separator: " "),
                                              merchant: alert.merchant, card: alert.wallet == true ? alert.source : nil,
                                              reportedAt: alert.receivedAt, now: now) else { return }
        alert.state = .duplicate; alert.walletRunID = run.id; alert.completedWallet = true
        alert.lastError = "Сумма добавлена к покупке из Wallet, которая пришла без суммы."
        try? BankAlertLog.save(alert, in: directory)
    }

    func skip(_ id: UUID) {
        guard var alert = BankAlertLog.alerts(in: directory).first(where: { $0.id == id }) else { return }
        alert.state = .skipped
        try? BankAlertLog.save(alert, in: directory)
    }

    static func request(for alert: BankAlert, with sender: WalletSender) -> URLRequest {
        var request = URLRequest(url: sender.projectURL.appending(path: "rest/v1/rpc/mora_capture_payment"), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sender.publicKey, forHTTPHeaderField: "apikey")
        let body: [String: String] = [
            "p_token": sender.token, "p_event_id": alert.id.uuidString.lowercased(),
            "p_amount": alert.amount, "p_currency": alert.currency, "p_merchant": alert.merchant,
            "p_occurred_at": alert.receivedAt.ISO8601Format(), "p_card": alert.card,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }
}

/// The Shortcuts action for the "Message" automation (bank SMS). Every parameter is in
/// its sentence; bank app notifications use `LogBankNotificationIntent`. Runs without
/// opening Mora, also on a locked iPhone, and never fails the automation.
struct LogBankMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Bank Message"
    static let description = IntentDescription("Reads a purchase from a bank text message. One-time codes and other messages are dropped without saving their text. A new message format waits for review in Mora once; later messages in the same format are sent automatically.")
    static let openAppWhenRun = false
    static let authenticationPolicy = IntentAuthenticationPolicy.alwaysAllowed

    @Parameter(title: "Text") var text: String?
    @Parameter(title: "From") var source: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$text) from \(\.$source)")
    }

    func perform() async throws -> some IntentResult {
        await BankAlertDelivery.logFromShortcut(title: nil, text: text, source: source ?? "", channel: .sms)
        return .result()
    }
}

/// The Shortcuts action for the iOS 27 "Notification" automation of a bank or card app.
/// Separate from SMS so the journal knows where each purchase came from.
struct LogBankNotificationIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Bank Notification"
    static let description = IntentDescription("Reads a purchase from a notification of a bank or card app. Pass the notification's Title and Body and the app name. Notifications without a purchase are dropped without saving their text. A new format waits for review in Mora once.")
    static let openAppWhenRun = false
    static let authenticationPolicy = IntentAuthenticationPolicy.alwaysAllowed

    @Parameter(title: "Title") var title: String?
    @Parameter(title: "Body") var body: String?
    @Parameter(title: "App") var app: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log notification \(\.$title), \(\.$body) from \(\.$app)")
    }

    func perform() async throws -> some IntentResult {
        await BankAlertDelivery.logFromShortcut(title: title, text: body, source: app ?? "", channel: .notification)
        return .result()
    }
}

extension BankAlertDelivery {
    /// Shared by the SMS and notification actions: save, complete a Wallet purchase, send.
    static func logFromShortcut(title: String?, text: String?, source: String, channel: BankAlert.Channel) async {
        let body = [title, text].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
        guard !body.isEmpty else { return }
        let sender = WalletSender.current()
        if let alert = try? await shared.record(text: body, source: source, channel: channel, sending: sender != nil) {
            await shared.completeWallet(alert.id)
        }
        if let sender {
            await WalletDelivery.shared.deliverWaiting(with: sender)
            await shared.deliverWaiting(with: sender)
        }
    }
}

/// The Shortcuts action for the iOS 27 "Notification" automation of the Wallet app. Wallet
/// starts the "Transaction" automation before a transit tap is priced; its notification
/// brings the amount and merchant later and completes that purchase. Separate from bank
/// messages: nothing here is read as a text message. Each field of the notification is
/// picked once, in the sentence of the action.
struct LogWalletNotificationIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Wallet Notification"
    static let description = IntentDescription("Completes a Wallet purchase that arrived without amount or merchant, such as a transit tap, from the Wallet notification. Pass the Title, Subtitle and Body of the notification.")
    static let openAppWhenRun = false
    static let authenticationPolicy = IntentAuthenticationPolicy.alwaysAllowed

    @Parameter(title: "Title") var title: String?
    @Parameter(title: "Subtitle") var subtitle: String?
    @Parameter(title: "Body") var body: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log Wallet notification \(\.$title), \(\.$subtitle), \(\.$body)")
    }

    func perform() async throws -> some IntentResult {
        guard let alert = try? BankAlertLog.recordWallet(title: title ?? "", subtitle: subtitle ?? "", body: body ?? "") else { return .result() }
        await BankAlertDelivery.shared.completeWallet(alert.id)
        if let sender = WalletSender.current() { await WalletDelivery.shared.deliverWaiting(with: sender) }
        await WalletBackgroundDelivery.scheduleIfNeeded()
        return .result()
    }
}
