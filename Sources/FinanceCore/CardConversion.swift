import Foundation
import WebKit
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct CardConversion: Codable, Equatable, Sendable {
    public var originalAmount: Decimal
    public var originalCurrency: String
    public var accountCurrency: String
    public var rate: Decimal
    public var date: Date
    public var provider: String = "Visa"
    /// Snapshot of the account fee at booking time, independent of later settings.
    public var bankFeePercent: Decimal? = nil
    public var feePercent: Decimal { bankFeePercent ?? 0 }
    /// Present only when a failed refresh used the last successful quote for this pair.
    public var cachedRateDate: Date? = nil
    public var rateDate: Date { cachedRateDate ?? date }
    public var cachedRateNote: String? {
        cachedRateDate.map { "Visa: использован сохранённый курс от \(Dates.string($0))." }
    }
    public func annotating(_ note: String) -> String {
        guard let cachedRateNote, !note.contains(cachedRateNote) else { return note }
        return [note, cachedRateNote].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public init(originalAmount: Decimal, originalCurrency: String, accountCurrency: String, rate: Decimal, date: Date,
                provider: String = "Visa", bankFeePercent: Decimal? = nil) {
        self.originalAmount = originalAmount; self.originalCurrency = originalCurrency; self.accountCurrency = accountCurrency
        self.rate = rate; self.date = date; self.provider = provider; self.bankFeePercent = bankFeePercent
    }

    public func applyingFee(of account: Account) -> CardConversion {
        var value = self
        value.bankFeePercent = originalAmount < 0 && account.bankFeePercent != 0 ? account.bankFeePercent : nil
        return value
    }

    public func convertedAmount() throws -> Decimal {
        guard originalAmount != 0, !originalAmount.isNaN, rate > 0, !rate.isNaN,
              !feePercent.isNaN, feePercent >= 0, feePercent <= 100,
              originalAmount < 0 || feePercent == 0,
              Locale.isoCurrencyCodeSet.contains(originalCurrency),
              Locale.isoCurrencyCodeSet.contains(accountCurrency), originalCurrency != accountCurrency else {
            throw LedgerError.invalid("Некорректный пересчет валюты операции.")
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency; formatter.currencyCode = accountCurrency
        var raw = originalAmount * rate * (1 + feePercent / 100), rounded = Decimal()
        NSDecimalRound(&rounded, &raw, formatter.maximumFractionDigits, .plain)
        guard rounded != 0, !rounded.isNaN else { throw LedgerError.invalid("Сумма после пересчета меньше минимальной единицы валюты счета.") }
        return rounded
    }
}

/// Uses the public Visa calculator. Only a unit amount, currencies and date leave the device.
@MainActor
public final class VisaRateClient {
    public static let shared = VisaRateClient()
    public static let calculatorURL = URL(string: "https://www.visa.co.uk/support/consumer/travel-support/exchange-rate-calculator.html")!
    /// One deadline for loading the page, selecting currencies and calculating the quote.
    public static let requestTimeout: TimeInterval = 25
    private let cache: VisaRateCache
    private let fetchRate: @MainActor @Sendable (String, String, Date) async throws -> Decimal
    private let now: @Sendable () -> Date
    private let timeout: TimeInterval
    private var inFlight: [String: Task<VisaRateResult, Error>] = [:]
    private var failedAt: [String: Date] = [:]

    public convenience init() {
        let files = FileManager.default
        let directory = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.mora.finance.local", isDirectory: true)
        let legacy = files.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.mora.finance.local/visa-rates.json")
        self.init(cacheURL: directory.appendingPathComponent("visa-rates.json"), legacyCacheURL: legacy,
                  fetchRate: { try await VisaCalculator().fetch(from: $0, to: $1, date: $2) })
    }

    init(cacheURL: URL?, legacyCacheURL: URL? = nil, now: @escaping @Sendable () -> Date = { Date() },
         timeout: TimeInterval = VisaRateClient.requestTimeout,
         fetchRate: @escaping @MainActor @Sendable (String, String, Date) async throws -> Decimal) {
        cache = VisaRateCache(fileURL: cacheURL, legacyURL: legacyCacheURL)
        self.now = now; self.timeout = timeout; self.fetchRate = fetchRate
    }

    public func conversion(amount: Decimal, from: String, to: String, date: Date) async throws -> CardConversion {
        let result = try await quote(from: from, to: to, date: date)
        var value = CardConversion(originalAmount: amount, originalCurrency: from, accountCurrency: to,
                                   rate: result.quote.rate, date: Calendar.current.startOfDay(for: date))
        value.cachedRateDate = result.isFallback ? result.quote.date : nil
        _ = try value.convertedAmount()
        return value
    }

    public func rate(from: String, to: String, date: Date) async throws -> Decimal {
        try await quote(from: from, to: to, date: date).quote.rate
    }

    private func quote(from: String, to: String, date: Date) async throws -> VisaRateResult {
        try Task.checkCancellation()
        guard Locale.isoCurrencyCodeSet.contains(from), Locale.isoCurrencyCodeSet.contains(to), from != to else {
            throw LedgerError.invalid("Выберите поддерживаемую валюту покупки и счет.")
        }
        let timestamp = now()
        let day = Int(floor(timestamp.timeIntervalSince1970 / 86_400))
        let pair = "\(from)|\(to)"
        let key = "\(day)|\(Dates.string(date))|\(pair)"
        let result: VisaRateResult
        if let cached = await cache.quote(for: key) {
            result = VisaRateResult(quote: cached, isFallback: false)
        } else if let failed = failedAt[pair], timestamp.timeIntervalSince(failed) >= 0,
                  timestamp.timeIntervalSince(failed) < 60, let last = await cache.latest(for: pair) {
            result = VisaRateResult(quote: last, isFallback: true)
        } else if let task = inFlight[key] {
            result = try await task.value
        } else {
            // Shared work survives a cancelled editor preview so a queued save can reuse it.
            let task = Task { [self] in
                do {
                    let rate = try await VisaRateRequest().run(timeout: timeout) { [fetchRate] in
                        try await fetchRate(from, to, date)
                    }
                    guard rate > 0, !rate.isNaN else { throw LedgerError.invalid("Visa вернула некорректный курс. Операция не сохранена.") }
                    let quote = VisaQuote(rate: rate, date: Calendar.current.startOfDay(for: date), fetchedAt: now())
                    await cache.store(quote, for: key, pair: pair, day: day)
                    failedAt[pair] = nil
                    return VisaRateResult(quote: quote, isFallback: false)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    failedAt[pair] = now()
                    guard let last = await cache.latest(for: pair) else { throw error }
                    return VisaRateResult(quote: last, isFallback: true)
                }
            }
            inFlight[key] = task
            defer { inFlight[key] = nil }
            result = try await task.value
        }
        try Task.checkCancellation()
        return result
    }
}

private struct VisaQuote: Codable, Sendable {
    let rate: Decimal
    let date: Date
    let fetchedAt: Date
    var isValid: Bool {
        rate > 0 && !rate.isNaN && date.timeIntervalSince1970.isFinite && fetchedAt.timeIntervalSince1970.isFinite
    }
}
private struct VisaRateResult: Sendable {
    let quote: VisaQuote
    let isFallback: Bool
}

/// An unstructured race bounds even a non-cooperative web callback. Late results cannot
/// overwrite a timeout or warm the cache; cancellation stops the calculator's polling.
@MainActor
private final class VisaRateRequest {
    private var continuation: CheckedContinuation<Decimal, Error>?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    func run(timeout: TimeInterval, fetch: @escaping @MainActor @Sendable () async throws -> Decimal) async throws -> Decimal {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            worker = Task {
                do { finish(.success(try await fetch())) }
                catch { finish(.failure(error)) }
            }
            timer = Task {
                do { try await Task.sleep(for: .seconds(timeout)); finish(.failure(URLError(.timedOut))) }
                catch { }
            }
        }
    }
    private func finish(_ result: Result<Decimal, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        worker?.cancel(); timer?.cancel()
        worker = nil; timer = nil
        continuation.resume(with: result)
    }
}

/// Application Support keeps last-known pairs across restarts and system cache cleanup.
/// Optional persistence never turns a successful quote into a failed purchase.
private actor VisaRateCache {
    private struct Contents: Codable {
        var daily: [String: VisaQuote] = [:]
        var latest: [String: VisaQuote] = [:]
    }
    private let fileURL: URL?
    private let legacyURL: URL?
    private var contents: Contents?
    init(fileURL: URL?, legacyURL: URL?) { self.fileURL = fileURL; self.legacyURL = legacyURL }
    private func load() {
        guard contents == nil else { return }
        contents = Contents()
        for url in [fileURL, legacyURL].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let decoded = try? JSONDecoder().decode(Contents.self, from: data) {
                contents = Contents(daily: decoded.daily.filter { $0.value.isValid }, latest: decoded.latest.filter { $0.value.isValid })
                return
            }
            // Migrate the old day|purchase-date|from|to decimal dictionary, preserving all pairs.
            guard let legacy = try? JSONDecoder().decode([String: Decimal].self, from: data) else { continue }
            for (key, rate) in legacy {
                let parts = key.split(separator: "|").map(String.init)
                guard parts.count == 4, let day = Int(parts[0]), let date = Dates.parse(parts[1]),
                      Locale.isoCurrencyCodeSet.contains(parts[2]), Locale.isoCurrencyCodeSet.contains(parts[3]),
                      parts[2] != parts[3] else { continue }
                let quote = VisaQuote(rate: rate, date: date, fetchedAt: Date(timeIntervalSince1970: Double(day) * 86_400))
                guard quote.isValid else { continue }
                contents?.daily[key] = quote
                let pair = "\(parts[2])|\(parts[3])"
                if contents?.latest[pair].map({ $0.fetchedAt > quote.fetchedAt || ($0.fetchedAt == quote.fetchedAt && $0.date > quote.date) }) != true {
                    contents?.latest[pair] = quote
                }
            }
            persist()
            return
        }
    }
    func quote(for key: String) -> VisaQuote? { load(); return contents?.daily[key] }
    func latest(for pair: String) -> VisaQuote? { load(); return contents?.latest[pair] }
    func store(_ quote: VisaQuote, for key: String, pair: String, day: Int) {
        load()
        let daily = contents?.daily.filter { $0.key.hasPrefix("\(day)|") } ?? [:]
        contents?.daily = daily
        contents?.daily[key] = quote
        contents?.latest[pair] = quote
        persist()
    }
    private func persist() {
        guard let fileURL, let contents, let data = try? JSONEncoder().encode(contents) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

@MainActor
private final class VisaCalculator: NSObject, WKNavigationDelegate {
    private var webView: WKWebView!
    private var navigationError: Error?

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationError = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationError = error }

    private enum ScriptValue: Sendable, Equatable { case text(String), flag(Bool) }
    private func evaluate(_ script: String) async throws -> ScriptValue? {
        let wrapped = """
        (() => { const roots=[]; function scan(root) { roots.push(root); for(const el of root.querySelectorAll('*')) { if(el.shadowRoot) scan(el.shadowRoot); } } scan(document);
        const get=id=>roots.map(root=>root.querySelector('[id="'+id+'"]')).find(Boolean);
        const all=selector=>roots.flatMap(root=>Array.from(root.querySelectorAll(selector)));
        return (\(script)); })()
        """
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(wrapped) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let text = value as? String { continuation.resume(returning: .text(text)) }
                else if let flag = value as? Bool { continuation.resume(returning: .flag(flag)) }
                else { continuation.resume(returning: nil) }
            }
        }
    }
    private func waitFor(_ script: String) async throws -> ScriptValue {
        for _ in 0..<80 {
            try Task.checkCancellation()
            if let navigationError { throw navigationError }
            if let result = try? await evaluate(script), result != .flag(false) { return result }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw LedgerError.invalid("Visa не вернула курс. Проверьте интернет-соединение и повторите получение курса. Операция не сохранена.")
    }
    private func fill(_ id: String, _ value: String) async throws {
        let values = try JSONSerialization.data(withJSONObject: [id, value])
        let json = String(decoding: values, as: UTF8.self)
        _ = try await evaluate("""
        (() => { const [id,value] = \(json); const el=get(id);
        if(!el) throw Error('Missing calculator input');
        el.focus();
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(el,value);
        el.dispatchEvent(new InputEvent('input',{bubbles:true,composed:true,data:value,inputType:'insertText'}));
        el.dispatchEvent(new Event('change',{bubbles:true,composed:true}));
        el.dispatchEvent(new KeyboardEvent('keyup',{key:value.slice(-1),bubbles:true,composed:true})); return true; })()
        """)
    }
    private func currency(_ field: String, _ code: String) async throws {
        try await fill("autosuggestinput_" + field, code)
        _ = try await waitFor("""
        (() => { const list=get('listbox-\(field)');
        const option=list && all('[id^="listbox-item-"]').find(el=>el.textContent.trim().startsWith('\(code)'));
        if(!option) return false; option.click(); return true; })()
        """)
    }
    func fetch(from: String, to: String, date: Date) async throws -> Decimal {
        #if canImport(AppKit)
        _ = NSApplication.shared
        #endif
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
        webView.navigationDelegate = self
        #if canImport(UIKit) && !canImport(AppKit)
        // iOS throttles scripts in a web view outside a window. Keep the
        // calculator in the key window, invisible and without touches.
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.01
        webView.frame.origin = CGPoint(x: -2000, y: 0)
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        window?.insertSubview(webView, at: 0)
        defer { webView.removeFromSuperview() }
        #endif
        defer { webView.stopLoading(); webView.navigationDelegate = nil }
        webView.load(URLRequest(url: VisaRateClient.calculatorURL, timeoutInterval: 20))
        _ = try await waitFor("Boolean(get('input_amount_paid'))")
        _ = try await evaluate("all('button').find(el=>el.textContent.trim()==='Reject all')?.click()")
        try await fill("input_amount_paid", "1")
        try await currency("from", from); try await currency("to", to)
        _ = try await evaluate("all('button').find(el=>(el.getAttribute('aria-label')||'').toLowerCase().includes('edit date'))?.click()")
        _ = try await waitFor("Boolean(get('dateinput_date'))")
        let parts = Dates.string(date).split(separator: "-")
        try await fill("dateinput_date", "\(parts[1])/\(parts[2])/\(parts[0])")
        try await fill("input_bank_rate", "0")
        _ = try await evaluate("all('button').find(el=>el.textContent.trim()==='Calculate Conversion')?.click()")
        let result = try await waitFor("""
        (() => { const h=all('h2').find(el=>el.textContent.trim().startsWith('1 \(from) ='));
        if(!h) return false; const text=h.textContent.trim();
        const match=text.match(/^1 \(from)\\s*=\\s*([0-9.,]+)\\s*\(to)$/); return match ? match[1] : false; })()
        """)
        guard case .text(let text) = result, let rate = Decimal(string: text.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX")), rate > 0, !rate.isNaN else {
            throw LedgerError.invalid("Visa вернула некорректный курс. Операция не сохранена.")
        }
        return rate
    }
}
