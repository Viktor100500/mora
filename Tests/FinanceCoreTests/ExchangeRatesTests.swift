import XCTest
import os
@testable import FinanceCore

final class ExchangeRatesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_705_600)
    private func response(rates: String = #""USD":1,"RUB":100,"EUR":0.8,"RSD":125"#,
                          quoted: Int = 1_791_676_800, next: Int = 1_791_763_200) -> Data {
        Data("{\"result\":\"success\",\"base_code\":\"USD\",\"time_last_update_unix\":\(quoted),\"time_next_update_unix\":\(next),\"rates\":{\(rates)}}".utf8)
    }

    func testQuoteDirectionAndCrossRatesIncludeSerbianDinar() throws {
        let snapshot = try ExchangeRateSnapshot.decodeResponse(response(), fetchedAt: now)
        let rubles = try snapshot.rates(in: "RUB")
        XCTAssertEqual(rubles["RUB"], 1)
        XCTAssertEqual(rubles["USD"], 100)
        XCTAssertEqual(rubles["EUR"], 125)
        XCTAssertEqual(rubles["RSD"], Decimal(string: "0.8"))
        let dinars = try snapshot.rates(in: "RSD")
        XCTAssertEqual(dinars["RSD"], 1)
        XCTAssertEqual(dinars["RUB"], Decimal(string: "1.25"))
        XCTAssertEqual(dinars["EUR"], Decimal(string: "156.25"))
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "Dinari", currency: "RSD", openingBalance: 125), Account(name: "Euros", currency: "EUR", openingBalance: 8)]
        ledger.preferences.rates = rubles
        XCTAssertEqual(ledger.netWorth, 1100)
        XCTAssertTrue(ledger.missingCurrencies.isEmpty)
    }

    func testInvalidRatesNeverBecomeAUsableSnapshot() throws {
        for rates in [#""USD":1,"RUB":0"#, #""USD":1,"RSD":-125"#, #""USD":2,"EUR":0.8"#, #""EUR":0.8"#] {
            XCTAssertThrowsError(try ExchangeRateSnapshot.decodeResponse(response(rates: rates), fetchedAt: now))
        }
        XCTAssertThrowsError(try ExchangeRateSnapshot.decodeResponse(Data(#"{"result":"error","error-type":"unknown-code"}"#.utf8), fetchedAt: now))
        XCTAssertThrowsError(try ExchangeRateSnapshot.decodeResponse(Data("<html>Unavailable</html>".utf8), fetchedAt: now))
        XCTAssertThrowsError(try ExchangeRateSnapshot.decodeResponse(Data(repeating: 32, count: 128_001), fetchedAt: now))
        XCTAssertThrowsError(try ExchangeRateSnapshot.decodeResponse(response(quoted: 1_791_763_200, next: 1_791_849_600), fetchedAt: now))
        XCTAssertThrowsError(try ExchangeRateSnapshot.decodeResponse(response(), fetchedAt: now.addingTimeInterval(8 * 86_400)))
        XCTAssertThrowsError(try ExchangeRateSnapshot.decodeResponse(response(next: 1_791_676_800), fetchedAt: now))
    }

    func testUnsupportedProviderCodesAreFilteredAndMissingBaseIsExplicit() throws {
        let snapshot = try ExchangeRateSnapshot.decodeResponse(response(rates: #""USD":1,"RUB":100,"RSD":125,"NOT_ISO":42"#), fetchedAt: now)
        XCTAssertNil(snapshot.ratesPerUSD["NOT_ISO"])
        XCTAssertThrowsError(try snapshot.rates(in: "EUR"))
    }

    func testRefreshScheduleAvoidsRepeatLaunchAndRetriesAfterNetworkFailure() throws {
        let snapshot = try ExchangeRateSnapshot.decodeResponse(response(), fetchedAt: now)
        XCTAssertTrue(ExchangeRateRefreshPolicy.shouldRefresh(snapshot: nil, lastAttempt: nil, now: now))
        XCTAssertFalse(ExchangeRateRefreshPolicy.shouldRefresh(snapshot: snapshot, lastAttempt: nil, now: now.addingTimeInterval(86_399)))
        XCTAssertTrue(ExchangeRateRefreshPolicy.shouldRefresh(snapshot: snapshot, lastAttempt: nil, now: now.addingTimeInterval(86_400)))
        XCTAssertFalse(ExchangeRateRefreshPolicy.shouldRefresh(snapshot: nil, lastAttempt: now, now: now.addingTimeInterval(3599)))
        XCTAssertTrue(ExchangeRateRefreshPolicy.shouldRefresh(snapshot: nil, lastAttempt: now, now: now.addingTimeInterval(3600)))
        XCTAssertTrue(ExchangeRateRefreshPolicy.shouldRefresh(snapshot: snapshot, lastAttempt: now, now: now, force: true))
    }

    func testExistingFilesMigrateWithoutLosingAccountsOrManualRates() throws {
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "Existing", currency: "RSD", openingBalance: Decimal(string: "26784.09")!)]
        ledger.preferences.rates["RSD"] = Decimal(string: "0.8")!
        let json = String(decoding: try LedgerFile.encode(ledger), as: UTF8.self)
            .replacingOccurrences(of: #""automaticRates"\s*:\s*true\s*,\s*"#, with: "", options: .regularExpression)
        let restored = try LedgerFile.decode(Data(json.utf8))
        XCTAssertEqual(restored.accounts, ledger.accounts)
        XCTAssertEqual(restored.preferences.rates, ledger.preferences.rates)
        XCTAssertTrue(restored.preferences.automaticRates)
        XCTAssertNil(restored.preferences.exchangeRateSnapshot)
    }

    func testApplyingSnapshotPreservesEditsAndFailuresLeaveCachedRatesIntact() throws {
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "Edited while downloading", currency: "RSD", openingBalance: 125)]
        ledger.budgets = [Budget(categoryID: ledger.categories[0].id, limit: 1000)]
        ledger.goals = [Goal(name: "Goal", target: 5000, saved: 300, deadline: now)]
        let snapshot = try ExchangeRateSnapshot.decodeResponse(response(), fetchedAt: now)
        let before = ledger
        try ledger.applyExchangeRates(snapshot)
        XCTAssertEqual(ledger.accounts, before.accounts)
        XCTAssertEqual(ledger.transactions, before.transactions)
        XCTAssertEqual(ledger.budgets, before.budgets)
        XCTAssertEqual(ledger.goals, before.goals)
        XCTAssertEqual(ledger.netWorth, 100)
        let cached = ledger
        let older = try ExchangeRateSnapshot.decodeResponse(response(quoted: 1_791_590_400, next: 1_791_676_800), fetchedAt: now)
        XCTAssertThrowsError(try ledger.applyExchangeRates(older))
        XCTAssertEqual(ledger, cached)
        ledger.preferences.baseCurrency = "KPW"
        ledger.preferences.rates["KPW"] = 1
        let unsupported = ledger
        XCTAssertThrowsError(try ledger.applyExchangeRates(snapshot))
        XCTAssertEqual(ledger, unsupported)
    }

    func testSnapshotSurvivesBackupAndBaseCurrencyChange() throws {
        var ledger = Ledger.empty
        let snapshot = try ExchangeRateSnapshot.decodeResponse(response(), fetchedAt: now)
        ledger.preferences.exchangeRateSnapshot = snapshot
        ledger.preferences.rates = try snapshot.rates(in: "RUB")
        ledger.budgets = [Budget(categoryID: ledger.categories[0].id, limit: 1000)]
        try ledger.changeBaseCurrency(to: "RSD")
        XCTAssertEqual(ledger.budgets[0].limit, 1250)
        XCTAssertEqual(try LedgerFile.decode(LedgerFile.encode(ledger)), ledger)
        ledger.preferences.automaticRates = false
        XCTAssertFalse(try LedgerFile.decode(LedgerFile.encode(ledger)).preferences.automaticRates)
    }

    private func client(status: Int = 200, data: Data? = nil, failure: URLError? = nil) -> ExchangeRateClient {
        RateURLProtocol.handler = { request in
            XCTAssertEqual(request.url, ExchangeRateClient.endpoint)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            if let failure { throw failure }
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, data ?? self.response())
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateURLProtocol.self]
        return ExchangeRateClient(session: URLSession(configuration: configuration))
    }

    func testClientUsesPublicRequestAndRejectsHTTPAndOfflineErrors() async throws {
        let snapshot = try await client().fetch(now: now)
        XCTAssertEqual(try snapshot.rates(in: "RUB")["RSD"], Decimal(string: "0.8"))
        for status in [429, 503] {
            do { _ = try await client(status: status).fetch(now: now); XCTFail("HTTP errors must fail") }
            catch { XCTAssertTrue(error.localizedDescription.contains(status == 429 ? "частоту" : "503")) }
        }
        do { _ = try await client(failure: URLError(.notConnectedToInternet)).fetch(now: now); XCTFail("Offline request must fail") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        // Failure returns no replacement snapshot; the previous rates remain valid offline.
        XCTAssertEqual(try snapshot.rates(in: "RUB")["RSD"], Decimal(string: "0.8"))
    }
}

private final class RateURLProtocol: URLProtocol {
    // Test callbacks are installed before requests and executed under this lock.
    private static let handlers = OSAllocatedUnfairLock<((URLRequest) throws -> (HTTPURLResponse, Data))?>(uncheckedState: nil)
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { handlers.withLockUnchecked { $0 } }
        set { handlers.withLockUnchecked { $0 = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = request
        do {
            let (response, data) = try Self.handlers.withLockUnchecked { try $0!(request) }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
