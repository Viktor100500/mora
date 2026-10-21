import Foundation

public struct ExchangeRateSnapshot: Codable, Equatable, Sendable {
    public let ratesPerUSD: [String: Decimal]
    public let quotedAt: Date
    public let fetchedAt: Date
    public let nextUpdateAt: Date

    public static let providerURL = URL(string: "https://www.exchangerate-api.com")!

    public func validate() throws {
        let currencies = Set(Locale.commonISOCurrencyCodes)
        guard ratesPerUSD["USD"] == 1, ratesPerUSD.count > 1,
              ratesPerUSD.keys.allSatisfy({ currencies.contains($0) }),
              ratesPerUSD.values.allSatisfy({ !$0.isNaN && $0 > 0 }),
              quotedAt.timeIntervalSince1970.isFinite, quotedAt.timeIntervalSince1970 > 0,
              fetchedAt.timeIntervalSince1970.isFinite,
              quotedAt <= fetchedAt.addingTimeInterval(300),
              nextUpdateAt.timeIntervalSince1970.isFinite, nextUpdateAt > quotedAt
        else { throw LedgerError.invalid("Сервис прислал некорректные курсы валют.") }
    }

    // The API quotes currency units per USD; the ledger stores base units per currency unit.
    public func rates(in baseCurrency: String) throws -> [String: Decimal] {
        try validate()
        guard let base = ratesPerUSD[baseCurrency] else {
            throw LedgerError.invalid("Источник не поддерживает валюту \(baseCurrency). Выберите другую базовую валюту или ручной режим.")
        }
        var result = ratesPerUSD.mapValues { base / $0 }
        result[baseCurrency] = 1
        guard result.values.allSatisfy({ !$0.isNaN && $0 > 0 }) else {
            throw LedgerError.invalid("Не удалось пересчитать курсы валют.")
        }
        return result
    }

    public static func decodeResponse(_ data: Data, fetchedAt: Date = Date()) throws -> ExchangeRateSnapshot {
        guard data.count <= 128_000 else { throw LedgerError.invalid("Ответ сервиса курсов слишком большой.") }
        let response: APIResponse
        do { response = try JSONDecoder().decode(APIResponse.self, from: data) }
        catch { throw LedgerError.invalid("Не удалось прочитать ответ сервиса курсов.") }
        guard response.result == "success", response.base_code == "USD",
              let rates = response.rates, let quoted = response.time_last_update_unix,
              let next = response.time_next_update_unix else {
            throw LedgerError.invalid("Сервис курсов временно недоступен.")
        }
        let currencies = Set(Locale.commonISOCurrencyCodes)
        let snapshot = ExchangeRateSnapshot(
            ratesPerUSD: rates.filter { currencies.contains($0.key) },
            quotedAt: Date(timeIntervalSince1970: quoted), fetchedAt: fetchedAt,
            nextUpdateAt: Date(timeIntervalSince1970: next)
        )
        try snapshot.validate()
        guard fetchedAt.timeIntervalSince(snapshot.quotedAt) <= 7 * 86_400 else {
            throw LedgerError.invalid("Сервис прислал устаревшие курсы. Сохраненные курсы продолжат использоваться.")
        }
        return snapshot
    }

    private struct APIResponse: Decodable {
        let result: String
        let base_code: String?
        let time_last_update_unix: TimeInterval?
        let time_next_update_unix: TimeInterval?
        let rates: [String: Decimal]?
    }
}

public enum ExchangeRateRefreshPolicy: Sendable {
    public static func shouldRefresh(snapshot: ExchangeRateSnapshot?, lastAttempt: Date?, now: Date = Date(), force: Bool = false) -> Bool {
        if force { return true }
        // Retry unavailable networks at most once an hour; successful downloads live for 24 hours.
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < 3600 { return false }
        guard let snapshot else { return true }
        return now.timeIntervalSince(snapshot.fetchedAt) >= 86_400
    }
}

public struct ExchangeRateClient: Sendable {
    public static let endpoint = URL(string: "https://open.er-api.com/v6/latest/USD")!
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func fetch(now: Date = Date()) async throws -> ExchangeRateSnapshot {
        // A fixed public request: no account names, amounts, or transaction data leave the device.
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw LedgerError.invalid("Не удалось получить курсы валют.") }
        guard http.statusCode == 200 else {
            throw LedgerError.invalid(http.statusCode == 429 ? "Сервис ограничил частоту запросов. Попробуйте обновить курсы позже." : "Сервис курсов временно недоступен (\(http.statusCode)).")
        }
        return try ExchangeRateSnapshot.decodeResponse(data, fetchedAt: now)
    }
}
