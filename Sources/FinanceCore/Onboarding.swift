import Foundation

public extension Ledger {
    /// A clean personal ledger never contains demo accounts or transactions.
    static func personal(baseCurrency: String) throws -> Ledger {
        guard Locale.commonISOCurrencyCodes.contains(baseCurrency) else {
            throw LedgerError.invalid("Выберите поддерживаемую валюту отчетов.")
        }
        var ledger = Ledger.empty
        ledger.preferences.baseCurrency = baseCurrency
        ledger.preferences.rates = [baseCurrency: 1]
        try ledger.validate()
        return ledger
    }
}
