import Foundation
import Security
import BackgroundTasks
import FinanceCore

/// The phone key that lets this iPhone send Wallet purchases. It is created by
/// Mora on the iPhone, so no shortcut file or key text is needed. Kept in the
/// Keychain, readable while the iPhone is locked after its first unlock.
struct WalletSender: Codable, Equatable, Sendable {
    var projectURL: URL
    var publicKey: String
    var token: String
    var tokenID: UUID
    var householdID: UUID
    var label: String

    private static let service = "com.mora.finance.wallet"
    private static let account = "sender"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func current() -> WalletSender? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(WalletSender.self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        SecItemDelete(Self.query as CFDictionary)
        var item = Self.query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw LedgerError.invalid("Не удалось сохранить ключ Apple Pay в Связке ключей (\(status)).") }
    }

    static func remove() { SecItemDelete(query as CFDictionary) }
}

/// Sends saved Wallet purchases to `mora_capture_payment`. One actor serializes
/// sending and every change of a saved run. The server ignores a repeated event
/// id, so retrying after a lost response never books a purchase twice. Nothing
/// is dropped: a purchase without amount or merchant waits on the iPhone until
/// the user processes it in the transaction form.
actor WalletDelivery {
    static let shared = WalletDelivery()
    /// How long the first action of the automation waits for its amount action,
    /// and an empty run waits for a complete run of the same payment.
    static let amountGrace: TimeInterval = 2 * 60

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let directory: URL
    private let transport: Transport

    init(directory: URL = WalletRunLog.directory, transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.directory = directory; self.transport = transport
    }

    enum Outcome: Equatable {
        case delivered(state: String, reason: String?)
        /// No connection or a server failure: keep the purchase and stop until the next attempt.
        case retry(String)
        /// The phone key is revoked or wrong: keep the purchase, Apple Pay must be set up again.
        case keyRejected
        case refused(String)
    }

    /// The amount action of the automation: completes the newest run of the first action.
    func addAmount(_ amount: String, transaction: String = "", now: Date = .now) {
        let value = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = transaction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var run = WalletRunLog.runs(in: directory).first(where: {
            $0.delivery == .awaitingAmount && now.timeIntervalSince($0.receivedAt) < Self.amountGrace
        }) else {
            // The first action did not run or ran too long ago: keep the amount as its own run.
            if var run = try? WalletRunLog.record(amount: value, merchant: nil, card: nil, action: "Add Wallet Amount",
                                                  sending: WalletSender.current() != nil, at: now, in: directory), !details.isEmpty {
                run.transaction = details
                try? WalletRunLog.save(run, in: directory)
            }
            return
        }
        run.amount = value; run.transaction = details; run.delivery = .waiting
        run.log(value.isEmpty ? "Действие «Add Wallet Amount»: Wallet не передал сумму" : "Сумма получена действием «Add Wallet Amount»", at: now)
        try? WalletRunLog.save(run, in: directory)
    }

    /// Sends complete purchases oldest first and stops at the first connection problem.
    /// A purchase without amount or merchant stays on the iPhone for the user to process.
    func deliverWaiting(with sender: WalletSender, now: Date = .now) async {
        let all = WalletRunLog.runs(in: directory)
        for var run in all.reversed() where run.delivery == .waiting || run.delivery == .awaitingAmount {
            if run.delivery == .awaitingAmount {
                guard now.timeIntervalSince(run.receivedAt) >= Self.amountGrace else { continue }
                run.log("Сумма не пришла: «Быстрые команды» прервались, читая сумму", at: now)
            }
            if run.isEmpty {
                // Wallet can start the automation twice for one tap, once without any data.
                if all.contains(where: { $0.id != run.id && !$0.isEmpty && abs($0.receivedAt.timeIntervalSince(run.receivedAt)) <= Self.amountGrace }) {
                    run.delivery = .duplicate
                    run.log("Пустой запуск рядом с полной покупкой", at: now)
                    try? WalletRunLog.save(run, in: directory)
                    continue
                }
                if now.timeIntervalSince(run.receivedAt) < Self.amountGrace { continue }
            }
            guard run.isComplete else {
                run.delivery = .incomplete
                try? WalletRunLog.save(run, in: directory)
                continue
            }
            run.attempts += 1
            let outcome = await send(run, with: sender)
            switch outcome {
            case .delivered(let state, let reason):
                run.delivery = .delivered; run.serverState = state; run.serverReason = reason; run.lastError = nil
                run.log("Отправлено, ответ сервера: \(state)" + (reason.map { " — \($0)" } ?? ""), at: now)
            case .retry(let message):
                run.lastError = message
                run.log("Не отправлено (попытка \(run.attempts)): \(message)", at: now)
            case .keyRejected:
                run.lastError = "Ключ телефона не принят: включите Apple Pay на iPhone заново."
                run.log("Сервер не принял ключ телефона (попытка \(run.attempts))", at: now)
            case .refused(let message):
                run.delivery = .failed; run.lastError = message
                run.log("Сервер отказал: \(message)", at: now)
            }
            try? WalletRunLog.save(run, in: directory)
            if case .retry = outcome { return }
            if case .keyRejected = outcome { return }
        }
    }

    /// The user booked the purchase in the transaction form.
    func markProcessed(_ id: UUID) { update(id) { $0.delivery = .processed; $0.lastError = nil; $0.log("Обработано вручную") } }

    /// The user entered the purchase by hand or does not want to count it.
    func skip(_ id: UUID) { update(id) { $0.delivery = .skipped; $0.log("Не учитывается") } }

    private func update(_ id: UUID, _ change: (inout WalletRun) -> Void) {
        guard var run = WalletRunLog.runs(in: directory).first(where: { $0.id == id }) else { return }
        change(&run)
        try? WalletRunLog.save(run, in: directory)
    }

    /// Waiting purchases that the system should retry in the background.
    var hasWaiting: Bool { WalletRunLog.runs(in: directory).contains { $0.delivery == .waiting || $0.delivery == .awaitingAmount } }

    private func send(_ run: WalletRun, with sender: WalletSender) async -> Outcome {
        do {
            let (data, response) = try await transport(Self.request(for: run, with: sender))
            return Self.outcome(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        } catch {
            return .retry(error.localizedDescription)
        }
    }

    static func request(for run: WalletRun, with sender: WalletSender) -> URLRequest {
        var request = URLRequest(url: sender.projectURL.appending(path: "rest/v1/rpc/mora_capture_payment"), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sender.publicKey, forHTTPHeaderField: "apikey")
        let body: [String: String] = [
            "p_token": sender.token, "p_event_id": run.id.uuidString.lowercased(),
            "p_amount": run.amount, "p_currency": "", "p_merchant": run.sentMerchant,
            "p_occurred_at": run.receivedAt.ISO8601Format(), "p_card": run.card,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    static func outcome(status: Int, data: Data) -> Outcome {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = object?["message"] as? String ?? "HTTP \(status)"
        switch status {
        case 200..<300:
            guard let state = object?["state"] as? String else { return .retry("Неожиданный ответ сервера.") }
            return .delivered(state: state, reason: object?["reason"] as? String)
        case 401, 403: return .keyRejected
        case 400..<500 where status != 408 && status != 429: return .refused(message)
        default: return .retry(message)
        }
    }
}

/// Background retry of purchases saved without internet: iOS wakes Mora some time
/// after the connection returns, also when Mora is not opened.
enum WalletBackgroundDelivery {
    static let identifier = "com.mora.finance.wallet.delivery"

    /// Sends what waits and asks iOS for another attempt while something still waits.
    static func run() async {
        if let sender = WalletSender.current() {
            BankAlertLog.reconcileWallet()
            await WalletDelivery.shared.deliverWaiting(with: sender)
            await BankAlertDelivery.shared.deliverWaiting(with: sender)
        }
        await scheduleIfNeeded()
    }

    static func scheduleIfNeeded() async {
        guard await WalletDelivery.shared.hasWaiting else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// When the development signature of this build stops the app from launching.
/// A free team signs for 7 days; afterwards the Wallet action stops working too.
enum AppSignature {
    static let expiration: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8)),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }()

    static func expiresSoon(now: Date = .now) -> Bool {
        expiration.map { $0.timeIntervalSince(now) < 2 * 86_400 } ?? false
    }
}
