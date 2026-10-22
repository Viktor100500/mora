import Foundation

/// Shared Wallet currency detection, automatic booking and review prefill.
/// A bare dollar symbol is USD; foreign purchases use the regular card conversion.
public struct WalletReviewDraft: Sendable {
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
            currency = code ?? (raw.contains("€") ? "EUR" : raw.contains("₽") ? "RUB" : raw.contains("$") ? "USD" : Self.unknownCurrency)
        }
    }

    private static func automaticAmount(_ input: String) -> Decimal? {
        guard input.count <= 64 else { return nil }
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let affix = "([$€£¥₽]|USD|EUR|GBP|RUB|JPY|CAD|AUD|CHF|CNY)"
        let prefixRemoved = value.replacingOccurrences(of: "^" + affix, with: "", options: [.regularExpression, .caseInsensitive])
        if prefixRemoved != value { value = prefixRemoved }
        else { value = value.replacingOccurrences(of: affix + "$", with: "", options: [.regularExpression, .caseInsensitive]) }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
        if matches(#"^[0-9]{1,3}(,[0-9]{3})+\.[0-9]{1,6}$"#) {
            value = value.replacingOccurrences(of: ",", with: "")
        } else if matches(#"^[0-9]{1,3}(\.[0-9]{3})+,[0-9]{1,6}$"#) {
            value = value.replacingOccurrences(of: ".", with: "")
        } else if matches(#"^[0-9]{1,3}([   ][0-9]{3})+([.,][0-9]{1,6})?$"#) {
            value = value.replacingOccurrences(of: "[   ]", with: "", options: .regularExpression)
        }
        guard matches(#"^[0-9]{1,12}([.,][0-9]{1,6})?$"#),
              let amount = Decimal(string: value.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX")),
              amount > 0, amount <= 999999999999 else { return nil }
        return amount
    }

    public static func automaticTransaction(for capture: CloudCapture, in ledger: Ledger,
        fetch: @Sendable (Decimal, String, String, Date) async throws -> CardConversion) async throws -> Transaction? {
        let externalID = "wallet:" + capture.id.uuidString.lowercased()
        // A lost booking response must preserve its original quote and fee.
        if let existing = ledger.transactions.first(where: { $0.id == capture.id && $0.externalID == externalID }) {
            return existing
        }
        let draft = WalletReviewDraft(capture: capture, ledger: ledger)
        guard let accountID = draft.accountID, let account = ledger.account(accountID),
              !draft.merchant.isEmpty, let amount = automaticAmount(capture.amount),
              draft.currency != unknownCurrency else { return nil }
        var value = Transaction(date: capture.date, merchant: draft.merchant, amount: -amount,
            accountID: accountID, categoryID: ledger.suggestedCategory(merchant: draft.merchant, kind: .expense),
            note: draft.note, tags: draft.tags)
        if draft.currency != account.currency {
            let conversion = try await fetch(-amount, draft.currency, account.currency, capture.date).applyingFee(of: account)
            value.amount = try conversion.convertedAmount()
            value.conversion = conversion
        }
        return try transaction(value, for: capture, in: ledger)
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
