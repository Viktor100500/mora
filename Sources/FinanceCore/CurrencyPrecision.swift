import Foundation

/// Calculation precision shared by iOS and macOS and mirrored by
/// `mora_currency_decimals` in PostgreSQL. Display formatters must not price payments:
/// Foundation formats some currencies (including RSD) without their ISO minor units.
public enum CurrencyPrecision {
    public static func minorUnits(for currency: String) -> Int {
        switch currency {
        case "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF": 0
        case "BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND": 3
        case "CLF", "UYW": 4
        default: 2
        }
    }

    public static func rounded(_ amount: Decimal, currency: String) -> Decimal {
        var raw = amount, result = Decimal()
        NSDecimalRound(&result, &raw, minorUnits(for: currency), .plain)
        return result
    }
}
