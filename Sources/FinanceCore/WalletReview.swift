import Foundation

/// Prefill for the shared transaction form. An ambiguous symbol never silently
/// turns a foreign purchase into a debit in the account's currency.
public struct WalletReviewDraft {
    public static let unknownCurrency = "wallet-unknown-currency"
    public let merchant: String
    public let note: String
    public let amount: String
    public let currency: String
    public let date: Date
    public let accountID: UUID?
    public let tags = ["Apple Wallet"]

    public init(capture: CloudCapture, ledger: Ledger, locale: Locale = .current, timeZone: TimeZone = .current) {
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.timeZone = timeZone
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        merchant = capture.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        note = ["Apple Wallet", capture.label,
                    formatter.string(from: capture.date)].filter { !$0.isEmpty }.joined(separator: " · ")
        amount = Money.parse(capture.amount).flatMap { $0 > 0 ? Money.plain($0) : nil } ?? ""
        date = capture.date
        accountID = ledger.account(capture.account_id)?.archived == false ? capture.account_id : nil
        let explicit = capture.currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if Locale.commonISOCurrencyCodes.contains(explicit) { currency = explicit }
        else {
            let raw = capture.amount.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let code = Locale.commonISOCurrencyCodes.first { raw.hasPrefix($0) || raw.hasSuffix($0) }
            currency = code ?? (raw.contains("€") ? "EUR" : raw.contains("₽") ? "RUB" : Self.unknownCurrency)
        }
    }

    public static func transaction(_ transaction: Transaction, for capture: CloudCapture, in ledger: Ledger) throws -> Transaction {
        guard ledger.account(transaction.accountID)?.archived == false else {
            throw LedgerError.invalid("Верните счет из архива перед добавлением операций.")
        }
        if let destination = transaction.destinationAccountID, ledger.account(destination)?.archived != false {
            throw LedgerError.invalid("Верните счет из архива перед добавлением операций.")
        }
        var value = transaction
        value.id = capture.id
        value.externalID = "wallet:" + capture.id.uuidString.lowercased()
        var validation = ledger
        // A retry after a lost response must be allowed to fetch the committed result.
        validation.transactions.removeAll { $0.id == value.id && $0.externalID == value.externalID }
        validation.transactions.append(value)
        try validation.validate()
        return value
    }
}
