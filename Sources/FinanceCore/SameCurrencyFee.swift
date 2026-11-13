import Foundation

/// A durable snapshot of the original purchase amount and the percentage charged.
public struct SameCurrencyFee: Codable, Equatable, Sendable {
    public var originalAmount: Decimal
    public var percent: Decimal
    /// At most one minor unit allocated to a split so the two debits keep their original total.
    public var roundingAdjustment: Decimal? = nil
    public init(originalAmount: Decimal, percent: Decimal) {
        self.originalAmount = originalAmount; self.percent = percent
    }
    public func chargedAmount(currency: String) throws -> Decimal {
        guard originalAmount < 0, !originalAmount.isNaN, percent > 0, percent <= 100,
              !percent.isNaN, Locale.isoCurrencyCodeSet.contains(currency) else {
            throw LedgerError.invalid("Некорректная комиссия операции.")
        }
        let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = currency
        var raw = originalAmount * (1 + percent / 100), rounded = Decimal()
        NSDecimalRound(&rounded, &raw, formatter.maximumFractionDigits, .plain)
        let minorUnit = (0..<formatter.maximumFractionDigits).reduce(Decimal(1)) { value, _ in value / 10 }
        let adjustment = roundingAdjustment ?? 0
        guard !adjustment.isNaN, abs(adjustment) <= minorUnit else { throw LedgerError.invalid("Некорректное округление комиссии.") }
        rounded += adjustment
        guard rounded < 0, !rounded.isNaN else { throw LedgerError.invalid("Некорректная сумма операции.") }
        return rounded
    }
}

public extension Ledger {
    /// Older versions discarded structured conversion data when splitting a foreign purchase.
    /// Its pieces cannot be safely repriced without knowing how the original amount was allocated.
    private func isLegacyForeignSplit(_ transaction: Transaction) -> Bool {
        guard transaction.kind == .expense, transaction.conversion == nil else { return false }
        return transaction.note.components(separatedBy: .newlines).contains {
            $0.hasPrefix("Исходная покупка: ") || $0.hasPrefix("Original purchase: ")
        }
    }
    private func requireRepriceableExpenses(accountID: UUID) throws {
        let hasLegacySplit = transactions.contains { $0.accountID == accountID && isLegacyForeignSplit($0) }
        guard !hasLegacySplit else {
            throw LedgerError.invalid("В счете есть разделенные расходы с конвертацией. Их исходные суммы не сохранены по частям, поэтому автоматически пересчитать комиссию нельзя.")
        }
    }

    /// Recalculate historic foreign-currency expenses using each saved exchange rate.
    mutating func setConversionFee(_ percent: Decimal, accountID: UUID) throws {
        guard !percent.isNaN, (0...100).contains(percent), let index = accounts.firstIndex(where: { $0.id == accountID }) else {
            throw LedgerError.invalid("Комиссия должна быть от 0 до 100%.")
        }
        guard accounts[index].bankFeePercent != percent else { return }
        try requireRepriceableExpenses(accountID: accountID)
        accounts[index].conversionFeePercent = percent == 0 ? nil : percent
        let account = accounts[index]
        func reprice(_ transaction: inout Transaction) throws {
            guard transaction.accountID == accountID, transaction.kind == .expense, let original = transaction.conversion else { return }
            let conversion = original.applyingFee(of: account)
            transaction.amount = try conversion.convertedAmount(); transaction.conversion = conversion
        }
        for i in transactions.indices { try reprice(&transactions[i]) }
        if var batches = imports {
            for i in batches.indices { for j in batches[i].transactions.indices { try reprice(&batches[i].transactions[j]) } }
            imports = batches
        }
    }

    /// Recalculate from the recorded purchase amount, never from a previously charged total.
    func applyingPurchaseFee(to transaction: Transaction) throws -> Transaction {
        var result = transaction
        guard let account = account(result.accountID) else { return result }
        if result.sameCurrencyFee == nil && isLegacyForeignSplit(result) { return result }
        let original: Decimal
        if let saved = result.sameCurrencyFee,
           result.amount == saved.originalAmount || result.amount == (try? saved.chargedAmount(currency: account.currency)) {
            if result.kind == .expense, result.conversion == nil, saved.percent == account.purchaseFeePercent {
                result.amount = try saved.chargedAmount(currency: account.currency); return result
            }
            original = saved.originalAmount
        } else { original = result.amount }
        result.sameCurrencyFee = nil
        if result.kind == .expense, result.conversion == nil, account.purchaseFeePercent > 0 {
            let fee = SameCurrencyFee(originalAmount: original, percent: account.purchaseFeePercent)
            result.amount = try fee.chargedAmount(currency: account.currency); result.sameCurrencyFee = fee
        } else if transaction.sameCurrencyFee != nil && result.conversion == nil { result.amount = original }
        return result
    }

    /// Split a charged amount without changing the total or applying the fee twice.
    func allocatingPurchaseFee(from original: Transaction, first: Transaction, second: Transaction) throws -> (Transaction, Transaction) {
        guard let fee = original.sameCurrencyFee, let account = account(original.accountID) else { return (first, second) }
        let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = account.currency
        var raw = fee.originalAmount * abs(first.amount) / abs(original.amount), firstOriginal = Decimal()
        NSDecimalRound(&firstOriginal, &raw, formatter.maximumFractionDigits, .plain)
        let secondOriginal = fee.originalAmount - firstOriginal
        guard firstOriginal < 0, secondOriginal < 0 else { throw LedgerError.invalid("Не удалось разделить комиссию: измените суммы частей.") }
        var firstFee = SameCurrencyFee(originalAmount: firstOriginal, percent: fee.percent)
        var secondFee = SameCurrencyFee(originalAmount: secondOriginal, percent: fee.percent)
        firstFee.roundingAdjustment = first.amount - (try firstFee.chargedAmount(currency: account.currency))
        secondFee.roundingAdjustment = second.amount - (try secondFee.chargedAmount(currency: account.currency))
        guard try firstFee.chargedAmount(currency: account.currency) == first.amount,
              try secondFee.chargedAmount(currency: account.currency) == second.amount else {
            throw LedgerError.invalid("Не удалось разделить комиссию: измените суммы частей.")
        }
        var first = first, second = second
        first.sameCurrencyFee = firstFee; second.sameCurrencyFee = secondFee
        return (first, second)
    }

    /// Called atomically with changing the account fee; existing debits are re-priced once.
    mutating func setPurchaseFee(_ percent: Decimal, accountID: UUID) throws {
        guard !percent.isNaN, (0...100).contains(percent), let index = accounts.firstIndex(where: { $0.id == accountID }) else {
            throw LedgerError.invalid("Комиссия должна быть от 0 до 100%.")
        }
        guard accounts[index].purchaseFeePercent != percent else { return }
        accounts[index].sameCurrencyFeePercent = percent == 0 ? nil : percent
        if percent > 0 { schemaVersion = max(schemaVersion, 5) }
        for i in transactions.indices where transactions[i].accountID == accountID && transactions[i].kind == .expense && transactions[i].conversion == nil && !isLegacyForeignSplit(transactions[i]) {
            transactions[i] = try applyingPurchaseFee(to: transactions[i])
        }
        if var batches = imports {
            for i in batches.indices {
                for j in batches[i].transactions.indices where batches[i].transactions[j].accountID == accountID && batches[i].transactions[j].kind == .expense && batches[i].transactions[j].conversion == nil && !isLegacyForeignSplit(batches[i].transactions[j]) {
                    batches[i].transactions[j] = try applyingPurchaseFee(to: batches[i].transactions[j])
                }
            }
            imports = batches
        }
    }
}
