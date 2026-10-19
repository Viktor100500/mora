import Foundation

public enum TransactionKind: String, Codable, CaseIterable, Identifiable {
    case expense, income, transfer
    public var id: String { rawValue }
    public var title: String { switch self { case .expense: "Расход"; case .income: "Доход"; case .transfer: "Перевод" } }
}

public enum AccountKind: String, Codable, CaseIterable, Identifiable {
    case checking, savings, cash, investment, credit
    public var id: String { rawValue }
    public var title: String {
        switch self { case .checking: "Банковский счет"; case .savings: "Накопления"; case .cash: "Наличные"; case .investment: "Инвестиции"; case .credit: "Кредитный счет" }
    }
    public var icon: String { switch self { case .checking: "creditcard"; case .savings: "building.columns"; case .cash: "banknote"; case .investment: "chart.line.uptrend.xyaxis"; case .credit: "creditcard.trianglebadge.exclamationmark" } }
}

public struct Account: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var currency: String
    public var kind: AccountKind
    public var openingBalance: Decimal
    public var color: String
    public var archived: Bool
    /// Percentage added to foreign-currency debits; nil keeps legacy accounts fee-free.
    public var conversionFeePercent: Decimal?
    public var bankFeePercent: Decimal { conversionFeePercent ?? 0 }
    public init(id: UUID = UUID(), name: String, currency: String = "RUB", kind: AccountKind = .checking, openingBalance: Decimal = 0, color: String = "green", archived: Bool = false, conversionFeePercent: Decimal? = nil) {
        self.id = id; self.name = name; self.currency = currency; self.kind = kind; self.openingBalance = openingBalance; self.color = color; self.archived = archived; self.conversionFeePercent = conversionFeePercent
    }
}

public struct Category: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var icon: String
    public var color: String
    public var kind: TransactionKind
    public init(id: UUID = UUID(), name: String, icon: String = "tag", color: String = "green", kind: TransactionKind = .expense) {
        self.id = id; self.name = name; self.icon = icon; self.color = color; self.kind = kind
    }
}

public struct Transaction: Identifiable, Codable, Equatable {
    public var id: UUID
    public var date: Date
    public var merchant: String
    public var amount: Decimal
    public var accountID: UUID
    public var categoryID: UUID?
    public var kind: TransactionKind
    public var note: String
    public var tags: [String]
    public var destinationAccountID: UUID?
    public var destinationAmount: Decimal?
    public var externalID: String?
    public var recurrenceID: UUID?
    public var importBatchID: UUID?
    public var conversion: CardConversion?
    /// A transfer's remaining leg after the other account was deleted.
    public var removedTransferAccountName: String?
    public var isStandaloneTransfer: Bool { kind == .transfer && removedTransferAccountName != nil }
    public init(id: UUID = UUID(), date: Date, merchant: String, amount: Decimal, accountID: UUID, categoryID: UUID? = nil, kind: TransactionKind = .expense, note: String = "", tags: [String] = [], destinationAccountID: UUID? = nil, destinationAmount: Decimal? = nil, externalID: String? = nil, recurrenceID: UUID? = nil, importBatchID: UUID? = nil) {
        self.id = id; self.date = date; self.merchant = merchant; self.amount = amount; self.accountID = accountID; self.categoryID = categoryID; self.kind = kind; self.note = note; self.tags = tags; self.destinationAccountID = destinationAccountID; self.destinationAmount = destinationAmount; self.externalID = externalID; self.recurrenceID = recurrenceID; self.importBatchID = importBatchID
    }
}

public struct Budget: Identifiable, Codable, Equatable {
    public var id: UUID
    public var categoryID: UUID
    public var limit: Decimal
    public init(id: UUID = UUID(), categoryID: UUID, limit: Decimal) { self.id = id; self.categoryID = categoryID; self.limit = limit }
}

public struct Goal: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var target: Decimal
    public var saved: Decimal
    public var deadline: Date
    public var icon: String
    public init(id: UUID = UUID(), name: String, target: Decimal, saved: Decimal = 0, deadline: Date, icon: String = "flag") {
        self.id = id; self.name = name; self.target = target; self.saved = saved; self.deadline = deadline; self.icon = icon
    }
}

public enum Frequency: String, Codable, CaseIterable, Identifiable {
    case weekly, monthly, yearly
    public var id: String { rawValue }
    public var title: String { switch self { case .weekly: "Каждую неделю"; case .monthly: "Каждый месяц"; case .yearly: "Каждый год" } }
    public var months: Decimal { switch self { case .weekly: Decimal(52) / 12; case .monthly: 1; case .yearly: Decimal(1) / 12 } }
}

public struct RecurringPayment: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var amount: Decimal
    public var accountID: UUID
    public var categoryID: UUID?
    public var frequency: Frequency
    public var nextDate: Date
    public var anchorDay: Int
    public var active: Bool
    public init(id: UUID = UUID(), name: String, amount: Decimal, accountID: UUID, categoryID: UUID? = nil, frequency: Frequency = .monthly, nextDate: Date, active: Bool = true) {
        self.id = id; self.name = name; self.amount = amount; self.accountID = accountID; self.categoryID = categoryID; self.frequency = frequency; self.nextDate = nextDate; self.anchorDay = Calendar.current.component(.day, from: nextDate); self.active = active
    }
    public func followingDate(calendar: Calendar = .current) -> Date {
        if frequency == .weekly { return calendar.date(byAdding: .day, value: 7, to: nextDate)! }
        let months = frequency == .monthly ? 1 : 12
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: nextDate))!
        let nextMonth = calendar.date(byAdding: .month, value: months, to: start)!
        let lastDay = calendar.range(of: .day, in: .month, for: nextMonth)!.count
        return calendar.date(byAdding: .day, value: min(anchorDay, lastDay) - 1, to: nextMonth)!
    }
}

public struct CategoryRule: Identifiable, Codable, Equatable {
    public var id: UUID
    public var keyword: String
    public var categoryID: UUID
    public init(id: UUID = UUID(), keyword: String, categoryID: UUID) { self.id = id; self.keyword = keyword; self.categoryID = categoryID }
}

public struct Preferences: Codable, Equatable {
    public var baseCurrency: String = "RUB"
    // One unit of a currency is worth this many units of the base currency.
    public var rates: [String: Decimal] = ["RUB": 1]
    public var appearance: String = "system"
    public var automaticRates: Bool = true
    public var exchangeRateSnapshot: ExchangeRateSnapshot?
    public var showBudgets = false
    public var showGoals = false
    public var showRecurring = false
    public var aiAgent = "chatgpt"
    public init() {}

    private enum CodingKeys: String, CodingKey { case baseCurrency, rates, appearance, automaticRates, exchangeRateSnapshot, showBudgets, showGoals, showRecurring, aiAgent }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseCurrency = try values.decode(String.self, forKey: .baseCurrency)
        rates = try values.decode([String: Decimal].self, forKey: .rates)
        appearance = try values.decodeIfPresent(String.self, forKey: .appearance) ?? "system"
        automaticRates = try values.decodeIfPresent(Bool.self, forKey: .automaticRates) ?? true
        exchangeRateSnapshot = try values.decodeIfPresent(ExchangeRateSnapshot.self, forKey: .exchangeRateSnapshot)
        showBudgets = try values.decodeIfPresent(Bool.self, forKey: .showBudgets) ?? false
        showGoals = try values.decodeIfPresent(Bool.self, forKey: .showGoals) ?? false
        showRecurring = try values.decodeIfPresent(Bool.self, forKey: .showRecurring) ?? false
        aiAgent = try values.decodeIfPresent(String.self, forKey: .aiAgent) ?? "chatgpt"
        if aiAgent == "codex" { aiAgent = "chatgpt" }
    }
}

public struct Ledger: Codable, Equatable {
    public var schemaVersion: Int = 1
    public var accounts: [Account] = []
    public var categories: [Category] = []
    public var transactions: [Transaction] = []
    public var budgets: [Budget] = []
    public var goals: [Goal] = []
    public var recurring: [RecurringPayment] = []
    public var rules: [CategoryRule] = []
    public var preferences = Preferences()
    public var changeHistory: LedgerChangeHistory?
    public var imports: [ImportBatch]?
    public var importHistory: [ImportBatch] {
        get { imports ?? [] }
        set { imports = newValue }
    }
    public init() {}

    public static var empty: Ledger {
        var ledger = Ledger()
        ledger.categories = [
            Category(name: "Продукты", icon: "basket", color: "green"),
            Category(name: "Кафе и рестораны", icon: "cup.and.saucer", color: "orange"),
            Category(name: "Транспорт", icon: "tram", color: "blue"),
            Category(name: "Дом", icon: "house", color: "purple"),
            Category(name: "Покупки", icon: "bag", color: "pink"),
            Category(name: "Здоровье", icon: "heart", color: "red"),
            Category(name: "Развлечения", icon: "sparkles", color: "yellow"),
            Category(name: "Подписки", icon: "repeat", color: "blue"),
            Category(name: "Путешествия", icon: "airplane", color: "purple"),
            Category(name: "Другое", icon: "ellipsis", color: "gray"),
            Category(name: "Зарплата", icon: "briefcase", color: "green", kind: .income),
            Category(name: "Другой доход", icon: "arrow.down.left", color: "blue", kind: .income)
        ]
        return ledger
    }

    public func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }
    public func category(_ id: UUID?) -> Category? { categories.first { $0.id == id } }
    public func convert(_ amount: Decimal, currency: String) -> Decimal? {
        if currency == preferences.baseCurrency { return amount }
        guard let rate = preferences.rates[currency], rate > 0 else { return nil }
        return amount * rate
    }
    public func value(_ transaction: Transaction) -> Decimal? {
        guard let account = account(transaction.accountID) else { return nil }
        return convert(transaction.amount, currency: account.currency)
    }
    public func balance(_ account: Account, through date: Date = Date()) -> Decimal {
        transactions.filter { $0.date < Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date))! }.reduce(account.openingBalance) { sum, t in
            var result = sum
            if t.accountID == account.id { result += t.amount }
            if t.kind == .transfer && t.destinationAccountID == account.id { result += t.destinationAmount ?? 0 }
            return result
        }
    }
    public var missingCurrencies: [String] {
        Array(Set(accounts.filter { !$0.archived }.map(\.currency).filter { convert(1, currency: $0) == nil })).sorted()
    }
    public func matchingCategory(merchant: String, kind: TransactionKind) -> UUID? {
        rules.first { rule in
            !rule.keyword.trimmingCharacters(in: .whitespaces).isEmpty && merchant.localizedCaseInsensitiveContains(rule.keyword) && category(rule.categoryID)?.kind == kind
        }?.categoryID
    }
    public mutating func changeBaseCurrency(to currency: String) throws {
        guard currency != preferences.baseCurrency else { return }
        guard let rate = preferences.rates[currency], rate > 0 else { throw LedgerError.invalid("Сначала задайте курс \(currency).") }
        for i in budgets.indices { budgets[i].limit /= rate }
        for i in goals.indices { goals[i].target /= rate; goals[i].saved /= rate }
        preferences.rates = preferences.rates.mapValues { $0 / rate }
        preferences.rates[currency] = 1
        preferences.baseCurrency = currency
    }
    public mutating func applyExchangeRates(_ snapshot: ExchangeRateSnapshot) throws {
        if let current = preferences.exchangeRateSnapshot, snapshot.quotedAt < current.quotedAt {
            throw LedgerError.invalid("Сервис прислал более старые курсы. Продолжаем использовать сохраненные значения.")
        }
        let rates = try snapshot.rates(in: preferences.baseCurrency)
        preferences.rates = rates
        preferences.exchangeRateSnapshot = snapshot
    }
    public func validate() throws {
        guard (1...4).contains(schemaVersion) else { throw LedgerError.invalid("Эта версия резервной копии не поддерживается.") }
        if let history = changeHistory {
            guard history.undo.count + history.redo.count <= 20,
                  (history.undo + history.redo).allSatisfy({ $0.changeHistory == nil }) else {
                throw LedgerError.invalid("Некорректная история изменений.")
            }
            for snapshot in history.undo + history.redo { try snapshot.validate() }
        }
        func unique(_ ids: [UUID]) -> Bool { Set(ids).count == ids.count }
        guard unique(accounts.map(\.id)), unique(categories.map(\.id)), unique(transactions.map(\.id)), unique(budgets.map(\.id)), unique(goals.map(\.id)), unique(recurring.map(\.id)), unique(rules.map(\.id)) else { throw LedgerError.invalid("В данных найдены повторяющиеся идентификаторы.") }
        let currencies = Set(Locale.commonISOCurrencyCodes)
        guard currencies.contains(preferences.baseCurrency), preferences.rates[preferences.baseCurrency] == 1, preferences.rates.keys.allSatisfy({ currencies.contains($0) }), preferences.rates.values.allSatisfy({ $0 > 0 && !$0.isNaN }) else { throw LedgerError.invalid("Некорректные курсы валют.") }
        try preferences.exchangeRateSnapshot?.validate()
        guard accounts.allSatisfy({ currencies.contains($0.currency) && !$0.openingBalance.isNaN && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }) else { throw LedgerError.invalid("Проверьте названия и валюты счетов.") }
        guard accounts.allSatisfy({ !$0.bankFeePercent.isNaN && $0.bankFeePercent >= 0 && $0.bankFeePercent <= 100 }) else { throw LedgerError.invalid("Комиссия за конвертацию должна быть от 0 до 100%.") }
        guard categories.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && $0.kind != .transfer }) else { throw LedgerError.invalid("Некорректная категория.") }
        for t in transactions {
            guard account(t.accountID) != nil, !t.merchant.trimmingCharacters(in: .whitespaces).isEmpty, !t.amount.isNaN, t.date.timeIntervalSince1970.isFinite else { throw LedgerError.invalid("Некорректная операция.") }
            if let id = t.categoryID, category(id)?.kind != t.kind { throw LedgerError.invalid("Категория не соответствует операции.") }
            guard t.isStandaloneTransfer ? t.amount != 0 : (t.kind == .income ? t.amount > 0 : t.amount < 0) else { throw LedgerError.invalid("Некорректный знак суммы операции.") }
            if let removed = t.removedTransferAccountName {
                guard t.kind == .transfer, !removed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      t.destinationAccountID == nil, t.destinationAmount == nil, t.categoryID == nil else {
                    throw LedgerError.invalid("Некорректный перевод с удаленным счетом.")
                }
            }
            if let conversion = t.conversion {
                guard t.kind != .transfer, conversion.accountCurrency == account(t.accountID)?.currency,
                      Dates.string(conversion.date) == Dates.string(t.date), try conversion.convertedAmount() == t.amount else {
                    throw LedgerError.invalid("Пересчет не соответствует сумме, дате или валюте счета.")
                }
            }
            if t.kind == .transfer && !t.isStandaloneTransfer {
                guard let dest = t.destinationAccountID, dest != t.accountID, account(dest) != nil, let amount = t.destinationAmount, amount > 0, !amount.isNaN else { throw LedgerError.invalid("Перевод требует второго счета и суммы зачисления.") }
                if account(dest)?.currency == account(t.accountID)?.currency, amount != -t.amount { throw LedgerError.invalid("Суммы перевода в одной валюте должны совпадать.") }
            }
        }
        guard budgets.allSatisfy({ category($0.categoryID)?.kind == .expense && $0.limit > 0 && !$0.limit.isNaN }), Set(budgets.map(\.categoryID)).count == budgets.count else { throw LedgerError.invalid("Проверьте лимиты бюджетов.") }
        guard goals.allSatisfy({ !$0.name.isEmpty && $0.target > 0 && $0.saved >= 0 && !$0.target.isNaN && !$0.saved.isNaN && $0.deadline.timeIntervalSince1970.isFinite }) else { throw LedgerError.invalid("Проверьте суммы целей.") }
        guard recurring.allSatisfy({ account($0.accountID) != nil && $0.amount > 0 && !$0.amount.isNaN && !$0.name.isEmpty && ($0.categoryID == nil || category($0.categoryID)?.kind == .expense) && $0.nextDate.timeIntervalSince1970.isFinite && (1...31).contains($0.anchorDay) }) else { throw LedgerError.invalid("Проверьте регулярные платежи.") }
        guard rules.allSatisfy({ !$0.keyword.trimmingCharacters(in: .whitespaces).isEmpty && category($0.categoryID) != nil }) else { throw LedgerError.invalid("Проверьте правила категоризации.") }
        guard unique(importHistory.map(\.id)), importHistory.allSatisfy({
            !$0.filename.isEmpty && $0.createdAt.timeIntervalSince1970.isFinite &&
            ($0.rolledBackAt?.timeIntervalSince1970.isFinite ?? true) &&
            !$0.transactions.isEmpty && unique($0.transactions.map(\.id)) &&
            $0.totalRows >= $0.transactions.count && $0.excluded >= 0 && $0.duplicates >= 0 && $0.invalid >= 0
        }) else { throw LedgerError.invalid("Некорректная история импортов.") }
    }
}

public enum LedgerError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let text): text } }
}

public enum Money {
    public static func parse(_ input: String) -> Decimal? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "−", with: "-")
        for symbol in ["₽", "$", "€", "£", "¥", "RUB", "USD", "EUR", "GBP", "руб."] { s = s.replacingOccurrences(of: symbol, with: "", options: .caseInsensitive) }
        s = s.filter { !$0.isWhitespace && $0 != "\u{00a0}" && $0 != "\u{202f}" && $0 != "'" }
        if s.hasPrefix("("), s.hasSuffix(")") { s = "-" + s.dropFirst().dropLast() }
        if s.contains(","), s.contains(".") {
            if s.lastIndex(of: ",")! > s.lastIndex(of: ".")! { s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
            else { s = s.replacingOccurrences(of: ",", with: "") }
        } else { s = s.replacingOccurrences(of: ",", with: ".") }
        guard s.range(of: "^[+-]?[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil else { return nil }
        guard let value = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
        return value
    }
    public static func string(_ amount: Decimal, currency: String = "RUB") -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.numberStyle = .currency; formatter.currencyCode = currency
        formatter.maximumFractionDigits = 2; formatter.minimumFractionDigits = amount == amount.rounded ? 0 : 2
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount) \(currency)"
    }
    public static func plain(_ amount: Decimal) -> String { NSDecimalNumber(decimal: amount).stringValue }
}

public extension Decimal {
    var double: Double { NSDecimalNumber(decimal: self).doubleValue }
    var rounded: Decimal { var value = self; var result = Decimal(); NSDecimalRound(&result, &value, 0, .plain); return result }
}

public enum Dates {
    public static func month(_ date: Date) -> Date { Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: date))! }
    public static func string(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    public static func parse(_ string: String, format: String = "auto") -> Date? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = format == "auto" ? ["yyyy-MM-dd", "dd.MM.yyyy", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"] : [format]
        for pattern in formats {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = pattern; f.isLenient = false
            if let date = f.date(from: s), f.string(from: date) == s { return Calendar.current.startOfDay(for: date) }
        }
        if format == "auto", let date = ISO8601DateFormatter().date(from: s) { return Calendar.current.startOfDay(for: date) }
        return nil
    }
}
