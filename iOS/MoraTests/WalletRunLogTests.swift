import XCTest
import FinanceCore
@testable import MoraiOS

final class WalletRunLogTests: XCTestCase {
    private var directory: URL!
    private let start = Date(timeIntervalSince1970: 1_793_000_000)
    private let sender = WalletSender(projectURL: URL(string: "https://example.supabase.co")!, publicKey: "sb_publishable_test",
                                      token: String(repeating: "a", count: 64), tokenID: UUID(), householdID: UUID(), label: "Test iPhone")

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appending(path: "WalletRuns-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testEachRunIsKeptSeparatelyNewestFirst() throws {
        try WalletRunLog.record(amount: " $3.00 ", merchant: "MTA", card: "Chase", sending: false, at: start, in: directory)
        try WalletRunLog.record(amount: "$3.00", merchant: "MTA", card: "Chase", sending: true, at: start, in: directory)
        try WalletRunLog.record(amount: nil, merchant: "  ", card: nil, sending: true, at: start.addingTimeInterval(15), in: directory)

        let runs = WalletRunLog.runs(in: directory)
        XCTAssertEqual(runs.count, 3, "identical payments at the same moment are separate runs")
        XCTAssertEqual(runs.first?.delivery, .waiting, "a run without amount or merchant is kept, never dropped")
        XCTAssertEqual(runs.first?.merchant, "")
        XCTAssertEqual(Set(runs.dropFirst().map(\.delivery)), [.logged, .waiting])
        XCTAssertEqual(runs.last?.amount, "$3.00")
    }

    func testRunsSavedByStageZeroStillLoad() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = #"{"id":"6F1C2C55-1111-4A4A-9999-000000000001","receivedAt":"2026-11-01T21:25:03Z","amount":"$3.00","merchant":"MTA","card":"Chase"}"#
        try Data(old.utf8).write(to: directory.appending(path: "1793589903000-6F1C2C55-1111-4A4A-9999-000000000001.json"))
        XCTAssertEqual(WalletRunLog.runs(in: directory).first?.delivery, .logged)
    }

    func testOldJournalIsPrunedButUnsentPurchasesStay() throws {
        try WalletRunLog.record(amount: "$1", merchant: "Old", card: "", sending: false, at: start.addingTimeInterval(-15 * 86_400), in: directory)
        try WalletRunLog.record(amount: "$1", merchant: "Old unsent", card: "", sending: true, at: start.addingTimeInterval(-15 * 86_400), in: directory)
        try WalletRunLog.record(amount: "$2", merchant: "New", card: "", sending: false, at: start, in: directory)
        XCTAssertEqual(WalletRunLog.runs(in: directory).map(\.merchant), ["New", "Old unsent"])

        WalletRunLog.clear(in: directory)
        XCTAssertEqual(WalletRunLog.runs(in: directory).map(\.merchant), ["Old unsent"])
    }

    func testOfflinePurchaseIsKeptAndRetriedWithTheSameEventID() async throws {
        let run = try WalletRunLog.record(amount: "$3.00", merchant: "MTA", card: "Chase", sending: true, at: start, in: directory)
        let requests = Requests()
        let offline = WalletDelivery(directory: directory) { request in
            await requests.add(request); throw URLError(.notConnectedToInternet)
        }
        await offline.deliverWaiting(with: sender, now: start.addingTimeInterval(5))
        var saved = try XCTUnwrap(WalletRunLog.runs(in: directory).first)
        XCTAssertEqual(saved.delivery, .waiting); XCTAssertEqual(saved.attempts, 1); XCTAssertNotNil(saved.lastError)

        let online = WalletDelivery(directory: directory) { request in
            await requests.add(request)
            return (Data(#"{"id":"c1","state":"recorded","duplicate":false}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await online.deliverWaiting(with: sender, now: start.addingTimeInterval(60))
        saved = try XCTUnwrap(WalletRunLog.runs(in: directory).first)
        XCTAssertEqual(saved.delivery, .delivered); XCTAssertEqual(saved.serverState, "recorded"); XCTAssertNil(saved.lastError)

        let bodies = try await requests.all.map { try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap($0.httpBody)) as? [String: String]) }
        XCTAssertEqual(bodies.map { $0["p_event_id"] }, [run.id.uuidString.lowercased(), run.id.uuidString.lowercased()])
        XCTAssertEqual(bodies.last?["p_card"], "Chase"); XCTAssertEqual(bodies.last?["p_occurred_at"], start.ISO8601Format())
        await online.deliverWaiting(with: sender, now: start.addingTimeInterval(120))
        let count = await requests.all.count
        XCTAssertEqual(count, 2, "a delivered purchase is not sent again")
    }

    func testPurchaseSavedOfflineIsSentEvenADayLater() async throws {
        try WalletRunLog.record(amount: "$3.00", merchant: "MTA", card: "Chase", sending: true, at: start, in: directory)
        let requests = Requests()
        let delivery = WalletDelivery(directory: directory) { request in
            await requests.add(request)
            return (Data(#"{"id":"c1","state":"pending","reason":"Новая карта: выберите для неё счёт"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await delivery.deliverWaiting(with: sender, now: start.addingTimeInterval(86_400))
        let run = try XCTUnwrap(WalletRunLog.runs(in: directory).first)
        XCTAssertEqual(run.delivery, .delivered); XCTAssertEqual(run.serverState, "pending")
        XCTAssertEqual(run.events.count, 2, "receipt and delivery are logged")
    }

    func testAmountActionCompletesTheStartedPurchase() async throws {
        try WalletRunLog.record(amount: nil, merchant: "Target", card: "Chase", name: "Target", action: "Start Wallet Payment",
                                awaitingAmount: true, sending: true, at: start, in: directory)
        let requests = Requests()
        let delivery = WalletDelivery(directory: directory) { request in
            await requests.add(request)
            return (Data(#"{"id":"c1","state":"recorded"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await delivery.deliverWaiting(with: sender, now: start.addingTimeInterval(5))
        let sentEarly = await requests.all.count
        XCTAssertEqual(sentEarly, 0, "the purchase waits for its amount action")

        await delivery.addAmount(" $12.40 ", now: start.addingTimeInterval(6))
        await delivery.deliverWaiting(with: sender, now: start.addingTimeInterval(6))
        let runs = WalletRunLog.runs(in: directory)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.amount, "$12.40"); XCTAssertEqual(runs.first?.delivery, .delivered)
        let sent = await requests.all
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.first?.httpBody)) as? [String: String])
        XCTAssertEqual(body["p_amount"], "$12.40"); XCTAssertEqual(body["p_merchant"], "Target")
    }

    func testPurchaseWithoutAmountGoesToTheSharedInbox() async throws {
        try WalletRunLog.record(amount: nil, merchant: "", card: "Chase", name: "NJ Transit", action: "Start Wallet Payment",
                                awaitingAmount: true, sending: true, at: start, in: directory)
        let requests = Requests()
        let delivery = WalletDelivery(directory: directory) { request in
            await requests.add(request)
            return (Data(#"{"id":"c1","state":"pending","reason":"Не получена положительная сумма"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await delivery.deliverWaiting(with: sender, now: start.addingTimeInterval(WalletDelivery.amountGrace + 1))
        let run = try XCTUnwrap(WalletRunLog.runs(in: directory).first)
        XCTAssertEqual(run.delivery, .delivered); XCTAssertEqual(run.serverState, "pending"); XCTAssertFalse(run.needsProcessing)
        let sent = await requests.all
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.first?.httpBody)) as? [String: String])
        XCTAssertEqual(body["p_amount"], ""); XCTAssertEqual(body["p_merchant"], "NJ Transit")
    }

    func testPurchasesKeptOnTheIPhoneByOlderBuildsAreSent() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var old = WalletRun(receivedAt: start, amount: "", merchant: "K1 Grocery 1", card: "Visa", delivery: .incomplete)
        old.action = "Start Wallet Payment"
        try WalletRunLog.save(old, in: directory)
        let delivery = WalletDelivery(directory: directory) { request in
            (Data(#"{"id":"c1","state":"pending"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await delivery.deliverWaiting(with: sender, now: start.addingTimeInterval(86_400))
        XCTAssertEqual(WalletRunLog.runs(in: directory).first?.delivery, .delivered)
    }

    func testEmptyRunNextToACompleteRunIsADuplicate() async throws {
        try WalletRunLog.record(amount: nil, merchant: nil, card: nil, sending: true, at: start, in: directory)
        try WalletRunLog.record(amount: "$3.00", merchant: "MTA", card: "Chase", sending: true, at: start.addingTimeInterval(5), in: directory)
        try WalletRunLog.record(amount: nil, merchant: nil, card: nil, sending: true, at: start.addingTimeInterval(3_600), in: directory)
        let delivery = WalletDelivery(directory: directory) { request in
            (Data(#"{"id":"c1","state":"recorded"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await delivery.deliverWaiting(with: sender, now: start.addingTimeInterval(3_610))
        var runs = WalletRunLog.runs(in: directory)
        XCTAssertEqual(runs.map(\.delivery), [.waiting, .delivered, .duplicate], "a lone empty run waits for a possible complete run first")

        await delivery.deliverWaiting(with: sender, now: start.addingTimeInterval(3_600 + WalletDelivery.amountGrace + 1))
        runs = WalletRunLog.runs(in: directory)
        XCTAssertEqual(runs.first?.delivery, .delivered, "then it goes to the shared inbox with its time")
    }

    /// Seen on the iPhone 8 Nov 2026: for a transit tap Wallet passes no merchant and
    /// the card (or the word "Transaction") as the Name.
    func testCardNameIsNeverTheMerchant() {
        XCTAssertEqual(WalletRun(receivedAt: start, amount: "", merchant: "", card: "Visa Debit for Priv Individuals",
                                 name: "Visa Debit for Priv Individuals").sentMerchant, "")
        XCTAssertEqual(WalletRun(receivedAt: start, amount: "", merchant: "", card: "Bybit Mastercard", name: "Transaction").sentMerchant, "")
        XCTAssertEqual(WalletRun(receivedAt: start, amount: "", merchant: "SQ * Monoblend", card: "Visa", name: "SQ * Monoblend").sentMerchant, "SQ * Monoblend")
    }

    /// Seen on the iPhone 9 Nov 2026: two transit taps came with an empty "Card or Pass" and
    /// the card as the Name, so the card went out as the merchant.
    func testCardPassedOnlyAsTheNameIsStillTheCard() throws {
        try WalletRunLog.record(amount: "$70.47", merchant: "Greenwich Gourmet Mark", card: "Visa Debit for Priv Individuals", sending: true, at: start, in: directory)
        let tap = try WalletRunLog.record(amount: nil, merchant: nil, card: nil, name: "visa debit for priv individuals", action: "Start Wallet Payment",
                                          awaitingAmount: true, sending: true, at: start.addingTimeInterval(60), in: directory)
        XCTAssertEqual(tap.card, "Visa Debit for Priv Individuals"); XCTAssertEqual(tap.sentMerchant, "")
        let shop = try WalletRunLog.record(amount: nil, merchant: nil, card: nil, name: "Some Shop", sending: true, at: start.addingTimeInterval(90), in: directory)
        XCTAssertEqual(shop.card, ""); XCTAssertEqual(shop.sentMerchant, "")
    }

    /// 9 Nov 2026: NJ Transit was tapped at 18:07 and Wallet reported "$5.45" at 18:20.
    func testTransitTapWaitsForItsNotificationAndIsSentComplete() async throws {
        let alerts = directory.appending(path: "alerts")
        try BankAlertLog.save(BankAlert(receivedAt: start.addingTimeInterval(-86_400), source: "Wallet", text: "", state: .duplicate), in: alerts)
        try WalletRunLog.record(amount: nil, merchant: nil, card: "Visa", name: "Transaction", action: "Start Wallet Payment",
                                awaitingAmount: true, sending: true, at: start, in: directory)
        let requests = Requests()
        let delivery = WalletDelivery(directory: directory, bankAlerts: alerts) { request in
            await requests.add(request)
            return (Data(#"{"id":"c1","state":"recorded"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await delivery.addAmount("", now: start.addingTimeInterval(1))
        await delivery.deliverWaiting(with: sender, now: start.addingTimeInterval(10 * 60))
        let early = await requests.all.count
        XCTAssertEqual(early, 0, "a purchase without amount waits for the notification")

        let alert = try BankAlertLog.recordWallet(title: "Raiffeisen banka a.d. Beograd", subtitle: "", body: "Njtransit Paygo Iron, Jersey City, NJ\n$5.45",
                                                  at: start.addingTimeInterval(13 * 60), directory: alerts, walletRuns: WalletRunLog.runs(in: directory))
        XCTAssertEqual(alert.state, .review); XCTAssertEqual(alert.wallet, true)
        XCTAssertEqual(alert.text, "Title: Raiffeisen banka a.d. Beograd\nBody: Njtransit Paygo Iron, Jersey City, NJ\n$5.45", "the fields are kept as received")
        await BankAlertDelivery(directory: alerts, wallet: delivery).completeWallet(alert.id, now: start.addingTimeInterval(13 * 60))
        await delivery.deliverWaiting(with: sender, now: start.addingTimeInterval(13 * 60))
        let sent = await requests.all
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.first?.httpBody)) as? [String: String])
        XCTAssertEqual(body["p_amount"], "5.45 USD"); XCTAssertEqual(body["p_merchant"], "Njtransit Paygo Iron"); XCTAssertEqual(body["p_card"], "Visa")
        XCTAssertEqual(body["p_occurred_at"], start.ISO8601Format(), "the purchase keeps the time of the tap")
        XCTAssertEqual(BankAlertLog.alerts(in: alerts).first?.state, .duplicate, "the notification is not a second purchase")
        XCTAssertEqual(WalletRunLog.runs(in: directory).first?.delivery, .delivered)
    }

    func testNotificationCompletesThePurchaseOfTheCardItNames() async throws {
        let alerts = directory.appending(path: "alerts")
        try WalletRunLog.record(amount: nil, merchant: nil, card: "Visa Debit", sending: true, at: start, in: directory)
        try WalletRunLog.record(amount: nil, merchant: nil, card: "Bybit Mastercard", sending: true, at: start.addingTimeInterval(60), in: directory)
        let delivery = WalletDelivery(directory: directory, bankAlerts: alerts) { request in
            (Data(#"{"id":"c1","state":"recorded"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let alert = try BankAlertLog.recordWallet(title: "Visa Debit", subtitle: "Metropolitan Transportation Authority", body: "$3.00",
                                                  at: start.addingTimeInterval(120), directory: alerts, walletRuns: WalletRunLog.runs(in: directory))
        await BankAlertDelivery(directory: alerts, wallet: delivery).completeWallet(alert.id, now: start.addingTimeInterval(120))
        let runs = WalletRunLog.runs(in: directory)
        XCTAssertEqual(runs.first { $0.card == "Visa Debit" }?.amount, "3 USD")
        XCTAssertEqual(runs.first { $0.card == "Visa Debit" }?.merchant, "Metropolitan Transportation Authority")
        XCTAssertEqual(runs.first { $0.card == "Bybit Mastercard" }?.amount, "")

        let other = try BankAlertLog.recordWallet(title: "Wallet", subtitle: "", body: "Your card is ready for Apple Pay",
                                                  at: start.addingTimeInterval(130), directory: alerts, walletRuns: runs)
        XCTAssertEqual(other.state, .ignored)
    }

    func testPurchaseWithoutAmountGoesToReviewWhenNothingReportsIt() async throws {
        let alerts = directory.appending(path: "alerts")
        try BankAlertLog.save(BankAlert(receivedAt: start, source: "Wallet", text: "", state: .duplicate), in: alerts)
        try WalletRunLog.record(amount: nil, merchant: "MTA", card: "Visa", sending: true, at: start, in: directory)
        let delivery = WalletDelivery(directory: directory, bankAlerts: alerts) { request in
            (Data(#"{"id":"c1","state":"pending"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await delivery.deliverWaiting(with: sender, now: start.addingTimeInterval(WalletDelivery.completionHold - 1))
        XCTAssertEqual(WalletRunLog.runs(in: directory).first?.delivery, .waiting)
        await delivery.deliverWaiting(with: sender, now: start.addingTimeInterval(WalletDelivery.completionHold + 1))
        XCTAssertEqual(WalletRunLog.runs(in: directory).first?.delivery, .delivered)
    }

    func testFirstNotificationHasTimeToArriveAndAmbiguousTapsAreNotGuessed() async throws {
        let alerts = directory.appending(path: "alerts")
        let delivery = WalletDelivery(directory: directory, bankAlerts: alerts) { _ in
            XCTFail("An incomplete tap must wait for its first notification")
            throw URLError(.notConnectedToInternet)
        }
        try WalletRunLog.record(amount: nil, merchant: nil, card: "Visa", sending: true, at: start, in: directory)
        await delivery.deliverWaiting(with: sender, now: start.addingTimeInterval(5 * 60))
        XCTAssertEqual(WalletRunLog.runs(in: directory).first?.attempts, 0)
        try WalletRunLog.record(amount: nil, merchant: nil, card: "Bybit", sending: true, at: start.addingTimeInterval(60), in: directory)
        let ambiguous = await delivery.complete(amount: "3 USD", merchant: "MTA", card: "Issuer", reportedAt: start.addingTimeInterval(120))
        XCTAssertNil(ambiguous)
        let exact = await delivery.complete(amount: "3 USD", merchant: "MTA", card: "Visa", reportedAt: start.addingTimeInterval(120))
        XCTAssertEqual(exact?.card, "Visa")
        let repeated = await delivery.complete(amount: "3 USD", merchant: "MTA", card: "Visa", reportedAt: start.addingTimeInterval(121))
        XCTAssertNil(repeated, "a repeated Visa notification cannot complete the Bybit tap")
    }

    func testCardInMerchantAndUnknownNameNeverBecomeAMerchant() {
        XCTAssertEqual(WalletRun(receivedAt: start, amount: "", merchant: " Visa   Debit ", card: "Visa Debit", name: "Transaction").sentMerchant, "")
        XCTAssertEqual(WalletRun(receivedAt: start, amount: "", merchant: "", card: "", name: "Unknown card").sentMerchant, "")
    }

    func testNotificationCompletesMissingMerchantWithoutChangingTheEvent() async throws {
        let run = try WalletRunLog.record(amount: "$3.00", merchant: nil, card: "Visa", name: "Visa", sending: true, at: start, in: directory)
        let delivery = WalletDelivery(directory: directory)
        let alert = try BankAlertLog.recordWallet(title: "Visa", subtitle: "MTA", body: "$3.00", at: start.addingTimeInterval(60),
                                                  directory: directory.appending(path: "alerts"), walletRuns: [run])
        XCTAssertEqual(alert.state, .review, "the notification must supply the missing merchant")
        let completed = await delivery.complete(amount: "3 USD", merchant: alert.merchant, card: alert.source, reportedAt: alert.receivedAt)
        XCTAssertEqual(completed?.id, run.id)
        XCTAssertEqual(completed?.receivedAt, start)
        XCTAssertEqual(completed?.sentMerchant, "MTA")
        XCTAssertEqual(completed?.card, "Visa")
    }

    func testSamePriceNotificationsAreMatchedToTheirOwnCard() throws {
        let first = WalletRun(receivedAt: start, amount: "$3.00", merchant: "MTA", card: "Visa")
        let second = WalletRun(receivedAt: start.addingTimeInterval(30), amount: "$3.00", merchant: "MTA", card: "Bybit")
        let alert = try BankAlertLog.recordWallet(title: "Visa", subtitle: "MTA", body: "$3.00", at: start.addingTimeInterval(60),
                                                  directory: directory, walletRuns: [second, first])
        XCTAssertEqual(alert.walletRunID, first.id)
    }

    func testServerAnswersMapToRetryOrDecision() {
        XCTAssertEqual(WalletDelivery.outcome(status: 200, data: Data(#"{"state":"pending","reason":"x"}"#.utf8)), .delivered(state: "pending", reason: "x"))
        XCTAssertEqual(WalletDelivery.outcome(status: 401, data: Data()), .keyRejected)
        XCTAssertEqual(WalletDelivery.outcome(status: 400, data: Data(#"{"message":"Invalid payment input"}"#.utf8)), .refused("Invalid payment input"))
        XCTAssertEqual(WalletDelivery.outcome(status: 503, data: Data()), .retry("HTTP 503"))
        XCTAssertEqual(WalletDelivery.outcome(status: 200, data: Data("[]".utf8)), .retry("Неожиданный ответ сервера."))
    }
}

private actor Requests {
    private(set) var all: [URLRequest] = []
    func add(_ request: URLRequest) { all.append(request) }
}

final class CardCurrencyAccountsTests: XCTestCase {
    func testOneAccountPerOtherCurrencyIsKept() {
        let eur = Account(name: "Raif EUR", currency: "EUR"), rsd = Account(name: "Raif RSD", currency: "RSD")
        let rsd2 = Account(name: "Other RSD", currency: "RSD"), eur2 = Account(name: "Other EUR", currency: "EUR")
        let accounts = [eur, rsd, rsd2, eur2]
        XCTAssertEqual(CardCurrencyAccounts.valid([rsd.id, rsd2.id, eur2.id, eur.id, UUID()], main: eur.id, in: accounts), [rsd.id])
    }
}
