import Foundation
import WebKit
import AppKit

public struct CardConversion: Codable, Equatable {
    public var originalAmount: Decimal
    public var originalCurrency: String
    public var accountCurrency: String
    public var rate: Decimal
    public var date: Date
    public var provider: String = "Visa"
    /// Snapshot of the account fee at booking time, independent of later settings.
    public var bankFeePercent: Decimal? = nil
    public var feePercent: Decimal { bankFeePercent ?? 0 }

    public func applyingFee(of account: Account) -> CardConversion {
        var value = self
        value.bankFeePercent = originalAmount < 0 && account.bankFeePercent != 0 ? account.bankFeePercent : nil
        return value
    }

    public func convertedAmount() throws -> Decimal {
        guard originalAmount != 0, !originalAmount.isNaN, rate > 0, !rate.isNaN,
              !feePercent.isNaN, feePercent >= 0, feePercent <= 100,
              originalAmount < 0 || feePercent == 0,
              Locale.commonISOCurrencyCodes.contains(originalCurrency),
              Locale.commonISOCurrencyCodes.contains(accountCurrency), originalCurrency != accountCurrency else {
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

/// Uses the public Visa calculator. Only a unit amount, currencies and date leave the Mac.
/// No browser credentials, account names, card numbers or purchase amounts are sent.
@MainActor
public final class VisaRateClient {
    public static let shared = VisaRateClient()
    public static let calculatorURL = URL(string: "https://www.visa.co.uk/support/consumer/travel-support/exchange-rate-calculator.html")!
    private var cache: [String: Decimal] = [:]
    public init() {}

    public func conversion(amount: Decimal, from: String, to: String, date: Date) async throws -> CardConversion {
        guard Locale.commonISOCurrencyCodes.contains(from), Locale.commonISOCurrencyCodes.contains(to), from != to else {
            throw LedgerError.invalid("Выберите поддерживаемую валюту покупки и счет.")
        }
        let key = "\(Dates.string(date))|\(from)|\(to)"
        let rate: Decimal
        if let cached = cache[key] { rate = cached }
        else {
            rate = try await VisaCalculator().fetch(from: from, to: to, date: date)
            cache[key] = rate
        }
        let value = CardConversion(originalAmount: amount, originalCurrency: from, accountCurrency: to, rate: rate, date: Calendar.current.startOfDay(for: date))
        _ = try value.convertedAmount()
        return value
    }
}

@MainActor
private final class VisaCalculator: NSObject, WKNavigationDelegate {
    private var webView: WKWebView!
    private var navigationError: Error?

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationError = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationError = error }

    private func evaluate(_ script: String) async throws -> Any? {
        let wrapped = """
        (() => { const roots=[]; function scan(root) { roots.push(root); for(const el of root.querySelectorAll('*')) { if(el.shadowRoot) scan(el.shadowRoot); } } scan(document);
        const get=id=>roots.map(root=>root.querySelector('[id="'+id+'"]')).find(Boolean);
        const all=selector=>roots.flatMap(root=>Array.from(root.querySelectorAll(selector)));
        return (\(script)); })()
        """
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(wrapped) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }
    private func waitFor(_ script: String) async throws -> Any {
        for _ in 0..<80 {
            try Task.checkCancellation()
            if let navigationError { throw navigationError }
            if let result = try? await evaluate(script), !(result is NSNull), (result as? Bool) != false { return result }
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
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
        webView.navigationDelegate = self
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
        guard let text = result as? String, let rate = Decimal(string: text.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX")), rate > 0, !rate.isNaN else {
            throw LedgerError.invalid("Visa вернула некорректный курс. Операция не сохранена.")
        }
        return rate
    }
}
