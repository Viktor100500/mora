import XCTest
import FinanceCore
@testable import MoraiOS

final class BankAlertLogTests: XCTestCase {
    private var directory: URL!
    private var templates: URL!
    private let start = Date(timeIntervalSince1970: 1_793_000_000)
    private let sms = """
        Koriscenje kartice 4054**5109
        Datum: 04.11.2026 22:07:20
        Iznos: 8,40 USD
        Raspolozivo: 3.195,32 EUR
        Mesto: NJT BUS MY-TIX NEWARK US
        """

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appending(path: "BankAlerts-\(UUID().uuidString)")
        templates = directory.appending(path: "templates.json")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testCodesAreLoggedWithoutTheirText() throws {
        let alert = try BankAlertLog.record(text: "Your verification code is 552901. Do not share it.", source: "Chase",
                                            sending: true, at: start, directory: directory, templates: [], walletRuns: [])
        XCTAssertEqual(alert.state, .ignored)
        XCTAssertEqual(alert.ignoredReason, .oneTimeCode)
        XCTAssertEqual(BankAlertLog.alerts(in: directory).first?.text, "")
    }

    func testNewFormatWaitsForReviewThenLearnedFormatIsSent() throws {
        let first = try BankAlertLog.record(text: sms, source: "Raiffeisen", sending: true, at: start, directory: directory,
                                            templates: [], walletRuns: [])
        XCTAssertEqual(first.state, .review)
        XCTAssertEqual(first.card, "Raiffeisen ··5109")
        XCTAssertEqual(first.amount, "8.4")
        XCTAssertEqual(first.currency, "USD")

        let parsed = try XCTUnwrap(first.parsed)
        XCTAssertNotNil(try BankAlertLog.learn(from: first.text, source: first.source, parsed: parsed, in: templates))
        let next = try BankAlertLog.record(text: sms.replacingOccurrences(of: "8,40", with: "2,90"), source: "Raiffeisen", sending: true,
                                           at: start.addingTimeInterval(3600), directory: directory,
                                           templates: BankAlertLog.templates(in: templates), walletRuns: [])
        XCTAssertEqual(next.state, .waiting)
        XCTAssertEqual(next.amount, "2.9")
        XCTAssertEqual(next.merchant, "NJT BUS MY-TIX NEWARK")
    }

    func testSamePurchaseFromWalletIsNotSentTwice() throws {
        let parsed = try XCTUnwrap(BankAlertLog.record(text: sms, source: "Raiffeisen", sending: false, at: start, directory: directory,
                                                       templates: [], walletRuns: []).parsed)
        let template = try XCTUnwrap(BankMessageTemplate(learningFrom: BankMessage.normalized(sms), sender: "Raiffeisen", parsed: parsed))
        let wallet = WalletRun(receivedAt: start.addingTimeInterval(-40), amount: "$8.40", merchant: "NJ Transit", card: "Raiffeisen Visa")
        let alert = try BankAlertLog.record(text: sms, source: "Raiffeisen", sending: true, at: start, directory: directory,
                                            templates: [template], walletRuns: [wallet])
        XCTAssertEqual(alert.state, .duplicate)
    }

    func testWalletPurchaseAfterAMessageIsKeptOnce() throws {
        let wallet = directory.appending(path: "wallet")
        var sent = BankAlert(receivedAt: start, source: "Raiffeisen", text: sms, state: .delivered)
        sent.amount = "8.4"; sent.currency = "USD"
        var waiting = BankAlert(receivedAt: start.addingTimeInterval(5), source: "Bybit", text: "x", state: .waiting)
        waiting.amount = "3"; waiting.currency = "USD"
        try BankAlertLog.save(sent, in: directory); try BankAlertLog.save(waiting, in: directory)
        let first = try WalletRunLog.record(amount: "$8.40", merchant: "NJ Transit", card: "Raiffeisen Visa", sending: true,
                                            at: start.addingTimeInterval(20), in: wallet)
        let second = try WalletRunLog.record(amount: "$3.00", merchant: "MTA", card: "Bybit", sending: true,
                                             at: start.addingTimeInterval(30), in: wallet)
        BankAlertLog.reconcileWallet(now: start.addingTimeInterval(60), directory: directory, walletDirectory: wallet)

        let runs = WalletRunLog.runs(in: wallet)
        XCTAssertEqual(runs.first { $0.id == first.id }?.delivery, .duplicate, "the message was already sent, so Wallet is not sent again")
        XCTAssertEqual(runs.first { $0.id == second.id }?.delivery, .waiting, "Wallet keeps a purchase whose message was not sent yet")
        let alerts = BankAlertLog.alerts(in: directory)
        XCTAssertEqual(alerts.first { $0.id == waiting.id }?.state, .duplicate)
        XCTAssertEqual(alerts.first { $0.id == waiting.id }?.walletRunID, second.id)

        BankAlertLog.reconcileWallet(now: start.addingTimeInterval(90), directory: directory, walletDirectory: wallet)
        XCTAssertEqual(WalletRunLog.runs(in: wallet).first { $0.id == second.id }?.delivery, .waiting, "a pair is never matched again")
    }

    func testSmsAndAppNotificationOfOnePurchaseAreSentOnce() throws {
        let push = "Plaćanje karticom\n4054**5109 | Iznos 8,40 USD | Gde: NJT BUS MY-TIX NEWARK US | Raspoloživo 3.195,32 EUR"
        let smsFirst = try BankAlertLog.record(text: sms, source: "Raiffeisen", sending: true, at: start, directory: directory,
                                               templates: [], walletRuns: [])
        let pushParsed = try XCTUnwrap(BankAlertLog.record(text: push, source: "Raiffeisen", sending: false,
                                                           at: start.addingTimeInterval(-3600), directory: directory.appending(path: "other"),
                                                           templates: [], walletRuns: []).parsed)
        let template = try XCTUnwrap(BankMessageTemplate(learningFrom: BankMessage.normalized(push), sender: "Raiffeisen", parsed: pushParsed))
        let known = try BankAlertLog.record(text: push, source: "Raiffeisen", sending: true, at: start.addingTimeInterval(4),
                                            directory: directory, templates: [template], walletRuns: [])
        XCTAssertEqual(known.state, .waiting, "the remembered push format is sent")
        let alerts = BankAlertLog.alerts(in: directory)
        XCTAssertEqual(alerts.first { $0.id == smsFirst.id }?.state, .duplicate, "the SMS still waiting for a check gives way")
        XCTAssertEqual(alerts.first { $0.id == smsFirst.id }?.sameAs, known.id)

        let secondRide = try BankAlertLog.record(text: sms.replacingOccurrences(of: "22:07:20", with: "22:09:02"), source: "Raiffeisen",
                                                 sending: true, at: start.addingTimeInterval(120), directory: directory, templates: [], walletRuns: [])
        XCTAssertEqual(secondRide.state, .review, "the same wording twice is two purchases")
    }

    func testRequestSendsCurrencyAndCardName() throws {
        let sender = WalletSender(projectURL: URL(string: "https://example.supabase.co")!, publicKey: "sb_publishable_test",
                                  token: String(repeating: "a", count: 64), tokenID: UUID(), householdID: UUID(), label: "Test iPhone")
        var alert = BankAlert(receivedAt: start, source: "Bybit", text: "", state: .waiting)
        alert.amount = "12.5"; alert.currency = "EUR"; alert.merchant = "LIDL"; alert.cardLast4 = "7788"
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(BankAlertDelivery.request(for: alert, with: sender).httpBody)) as? [String: String])
        XCTAssertEqual(body["p_card"], "Bybit ··7788")
        XCTAssertEqual(body["p_currency"], "EUR")
        XCTAssertEqual(body["p_amount"], "12.5")
        XCTAssertEqual(body["p_event_id"], alert.id.uuidString.lowercased())
    }
}
