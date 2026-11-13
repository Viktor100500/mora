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

    private func matchingAlert(text: String = "Card purchase", offset: TimeInterval = 0) -> BankAlert {
        var alert = BankAlert(receivedAt: start.addingTimeInterval(offset), source: "Raiffeisen", text: text, state: .review)
        alert.amount = "8.4"; alert.currency = "USD"; alert.cardLast4 = "5109"; alert.merchant = "NJT BUS MY-TIX NEWARK"
        return alert
    }

    func testSameAmountCannotHideAnotherBankMerchantCardOrCurrency() throws {
        let original = matchingAlert()
        try BankAlertLog.save(original, in: directory)
        let push = matchingAlert(text: "Plaćanje karticom", offset: 4)
        XCTAssertEqual(BankAlertLog.samePurchase(as: push, in: directory)?.id, original.id)
        let cases: [(String, (inout BankAlert) -> Void)] = [
            ("another bank", { $0.source = "Chase" }),
            ("another merchant", { $0.merchant = "Cafe" }),
            ("another card", { $0.cardLast4 = "1234" }),
            ("another currency", { $0.currency = "EUR" }),
            ("missing source", { $0.source = "" }),
            ("missing merchant", { $0.merchant = "" }),
            ("missing card", { $0.cardLast4 = "" }),
            ("missing currency", { $0.currency = "" }),
            ("another amount", { $0.amount = "8.41" }),
            ("an income", { $0.income = true }),
            ("Wallet notification", { $0.wallet = true }),
            ("same wording", { $0.text = "Card purchase" }),
            ("outside time window", { $0.receivedAt = self.start.addingTimeInterval(601) }),
        ]
        for (label, change) in cases {
            var candidate = push; change(&candidate)
            XCTAssertNil(BankAlertLog.samePurchase(as: candidate, in: directory), label)
        }
    }

    func testIncompleteOrUnsendableOriginalCannotSuppressNewPurchase() throws {
        let push = matchingAlert(text: "Plaćanje karticom", offset: 4)
        let cases: [(String, (inout BankAlert) -> Void)] = [
            ("missing card", { $0.cardLast4 = "" }),
            ("missing currency", { $0.currency = "" }),
            ("missing merchant", { $0.merchant = "" }),
            ("missing bank", { $0.source = "" }),
            ("Wallet notification", { $0.wallet = true }),
            ("logged while sending off", { $0.state = .logged }),
            ("refused by server", { $0.state = .failed }),
            ("skipped", { $0.state = .skipped }),
        ]
        for (index, entry) in cases.enumerated() {
            var original = matchingAlert(); entry.1(&original)
            let folder = directory.appending(path: "case-\(index)")
            try BankAlertLog.save(original, in: folder)
            XCTAssertNil(BankAlertLog.samePurchase(as: push, in: folder), entry.0)
        }
    }

    func testAmbiguousSamePricePurchasesRemainSeparate() throws {
        try BankAlertLog.save(matchingAlert(), in: directory)
        try BankAlertLog.save(matchingAlert(offset: 60), in: directory)
        XCTAssertNil(BankAlertLog.samePurchase(as: matchingAlert(text: "Plaćanje karticom", offset: 90), in: directory))
    }

    func testAlreadyDeliveredPurchaseRetainsItsIdentity() throws {
        var sent = matchingAlert(); sent.state = .delivered
        try BankAlertLog.save(sent, in: directory)
        let push = matchingAlert(text: "Plaćanje karticom", offset: 4)
        XCTAssertEqual(BankAlertLog.samePurchase(as: push, in: directory)?.id, sent.id)
        var sms = sent; sms.state = .duplicate; sms.walletRunID = UUID()
        try BankAlertLog.save(sms, in: directory)
        XCTAssertEqual(BankAlertLog.samePurchase(as: push, in: directory)?.id, sms.id,
                       "a bank message already completed Wallet; its push must not create another purchase")
    }

    func testOldJournalWithoutPairingFieldStillDecodes() throws {
        let alert = matchingAlert()
        try BankAlertLog.save(alert, in: directory)
        let loaded = try XCTUnwrap(BankAlertLog.alerts(in: directory).first)
        XCTAssertEqual(loaded.id, alert.id)
        XCTAssertNil(loaded.sameAs)
    }

    func testSimultaneousSmsAndPushAreRecordedAsOnePair() async throws {
        let delivery = BankAlertDelivery(directory: directory)
        let push = "Plaćanje karticom\n4054**5109 | Iznos 8,40 USD | Gde: NJT BUS MY-TIX NEWARK US"
        let smsText = sms
        async let smsRun = delivery.record(text: smsText, source: "Raiffeisen", sending: true)
        async let pushRun = delivery.record(text: push, source: "Raiffeisen", sending: true)
        _ = try await (smsRun, pushRun)
        let saved = BankAlertLog.alerts(in: directory)
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.filter { $0.state == .review }.count, 1)
        XCTAssertEqual(saved.filter { $0.state == .duplicate }.count, 1)
        let duplicate = try XCTUnwrap(saved.first { $0.state == .duplicate })
        XCTAssertEqual(duplicate.sameAs, saved.first { $0.state == .review }?.id)
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
