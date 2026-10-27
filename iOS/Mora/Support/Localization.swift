import SwiftUI
import FinanceCore

typealias Transaction = FinanceCore.Transaction
typealias Category = FinanceCore.Category

/// Shared macOS translations plus strings that exist only in the iPhone interface.
private let mobileLocalization: UILocalization = {
    let supplement = Bundle.main.url(forResource: "MobileStrings", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    return UILocalization(supplement: supplement)
}()

func L(_ value: String) -> String { mobileLocalization.text(value, language: L10n.language) }

/// The interface follows the iPhone language: Russian when iOS picks the Russian
/// localization for Mora (system or per-app language in Settings), English otherwise.
enum L10n {
    /// Tests pin a language without changing the simulator.
    nonisolated(unsafe) static var override: AppLanguage?
    static var system: AppLanguage { Bundle.main.preferredLocalizations.first?.hasPrefix("ru") == true ? .russian : .english }
    static var language: AppLanguage { override ?? system }
    static var locale: Locale { language.locale }
}

let currencyList = ["RUB", "USD", "EUR", "RSD", "GBP", "CHF", "CNY", "JPY", "AED", "GEL", "TRY", "KZT", "CAD", "AUD", "INR"]

/// Formatters are reused on the main actor instead of created for every view body.
@MainActor enum DisplayMoney {
    private static var formatters: [String: NumberFormatter] = [:]
    static func string(_ amount: Decimal, currency: String) -> String {
        let whole = amount == amount.rounded
        let key = "\(L10n.language.rawValue)-\(currency)-\(whole)"
        let formatter: NumberFormatter
        if let cached = formatters[key] { formatter = cached }
        else {
            formatter = NumberFormatter(); formatter.locale = L10n.locale
            formatter.numberStyle = .currency; formatter.currencyCode = currency
            formatter.maximumFractionDigits = 2; formatter.minimumFractionDigits = whole ? 0 : 2
            formatters[key] = formatter
        }
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount) \(currency)"
    }
    /// Signed amount for lists: income gets an explicit plus.
    static func signed(_ transaction: Transaction, currency: String) -> String {
        (transaction.kind == .income ? "+" : "") + string(transaction.amount, currency: currency)
    }
}

extension Date {
    var monthTitle: String { formatted(.dateTime.month(.wide).year().locale(L10n.locale)) }
    var dayTitle: String { formatted(.dateTime.day().month(.wide).locale(L10n.locale)) }
    var shortDay: String { formatted(.dateTime.day().month(.abbreviated).locale(L10n.locale)) }
}
