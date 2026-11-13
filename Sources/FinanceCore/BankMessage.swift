import Foundation

/// A bank text message read by the Shortcuts "Message" automation. One-time codes,
/// fraud checks and declined payments are dropped before anything is saved; the
/// rest becomes a purchase or an income. Only a message matching a template the
/// user confirmed is booked automatically; anything else waits for review.
public enum BankMessage {
    public enum Direction: String, Codable, Sendable { case expense, income }

    public enum Ignored: String, Codable, Sendable {
        /// A login or payment code: never stored or sent anywhere.
        case oneTimeCode
        /// The bank asks whether the user made a payment.
        case fraudCheck
        case declined
        /// Only a balance, a limit or an offer.
        case noTransaction
    }

    public struct Parsed: Equatable, Sendable {
        public var amount: Decimal
        /// An ISO code, or nil when the text has no currency; the account currency applies then.
        public var currency: String?
        public var merchant: String
        public var cardLast4: String?
        public var direction: Direction
        /// Matched a confirmed template, so it may be booked without review.
        public var automatic: Bool
        /// The exact pieces of text the values came from, for learning a template.
        public var amountText: String
        public var merchantText: String
        /// Read from a Wallet notification: it completes a Wallet purchase and is never booked by itself.
        public var wallet: Bool

        public init(amount: Decimal, currency: String?, merchant: String, cardLast4: String?, direction: Direction,
                    automatic: Bool, amountText: String, merchantText: String, wallet: Bool = false) {
            self.amount = amount; self.currency = currency; self.merchant = merchant; self.cardLast4 = cardLast4
            self.direction = direction; self.automatic = automatic; self.amountText = amountText; self.merchantText = merchantText
            self.wallet = wallet
        }
    }

    public enum Result: Equatable, Sendable {
        case ignored(Ignored)
        case parsed(Parsed)
    }

    public static func parse(_ text: String, sender: String = "", templates: [BankMessageTemplate] = []) -> Result {
        let text = normalized(text)
        if let reason = ignoredReason(text) { return .ignored(reason) }
        if let match = templates.lazy.compactMap({ $0.match(text, sender: sender) }).first { return .parsed(match) }
        guard let amount = transactionAmount(in: text) else { return .ignored(.noTransaction) }
        let card = cardLast4(in: text)
        let direction: Direction? = contains(text, incomeWords) ? .income : contains(text, expenseWords) ? .expense : nil
        // An amount alone is an offer or a balance; a card or a payment word makes it a transaction.
        guard direction != nil || card != nil else { return .ignored(.noTransaction) }
        let merchant = merchant(in: text, excluding: amount.text)
        return .parsed(Parsed(amount: amount.value, currency: amount.currency, merchant: merchant.map(cleanMerchant) ?? "",
                              cardLast4: card, direction: direction ?? .expense, automatic: false,
                              amountText: amount.text, merchantText: merchant ?? ""))
    }

    /// A Wallet notification of a card payment, read field by field and never as a bank
    /// message. The merchant is the subtitle or a line of the body, as "Merchant, City, ST";
    /// the amount stands alone on a line or ends one:
    ///
    ///     Njtransit Paygo Iron, Jersey City, NJ
    ///     $5.45
    public static func walletNotification(subtitle: String, body: String) -> Parsed? {
        let text = normalized(subtitle) + "\n" + normalized(body)
        guard ignoredReason(text) == nil, !contains(text, incomeWords) else { return nil }
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let priced = lines.last(where: { !amounts(in: $0).isEmpty }), let amount = amounts(in: priced).last,
              priced.hasSuffix(amount.text) else { return nil }
        let line = lines.map { $0 == priced ? String($0.dropLast(amount.text.count)).trimmingCharacters(in: .whitespaces) : $0 }
            .first { $0.contains(where: \.isLetter) && amounts(in: $0).isEmpty } ?? ""
        // The place follows the merchant: "…, Jersey City, NJ".
        var parts = line.components(separatedBy: ", ")
        if parts.count >= 3, let region = parts.last, region.count == 2, region == region.uppercased() { parts.removeLast(2) }
        return Parsed(amount: amount.value, currency: amount.currency, merchant: cleanMerchant(parts.joined(separator: ", ")),
                      cardLast4: nil, direction: .expense, automatic: false, amountText: amount.text, merchantText: line, wallet: true)
    }

    // MARK: Filters

    static let codeWords = [#"\b(one[- ]time|verification|security|confirmation|login|sign[- ]in)\s+(code|passcode|pin)\b"#,
                            #"\b(code|passcode|otp|код|пароль)\b\D{0,20}\b\d{4,8}\b"#, #"\b\d{4,8}\b\D{0,20}\b(is your|это ваш|ваш код)\b"#,
                            #"\b(do not|don['’]t|never) share\b"#, #"никому не (сообщайте|говорите)"#]
    static let fraudWords = [#"\breply\s+(yes|no|y|n|1|2)\b"#, #"\bdid you (use|attempt|make|authorize)\b"#,
                             #"\bответьте\s+(да|нет|1|2)\b"#, #"\bэто были вы\b"#]
    static let declinedWords = [#"\bdeclined\b"#, #"\bwas not (approved|authorized)\b"#, #"\binsufficient funds\b"#,
                                #"\bотклонен"#, #"\bотказ\b"#, #"\bнедостаточно средств\b"#]
    static let incomeWords = [#"\brefund(ed)?\b"#, #"\bcredited\b"#, #"\bcredit of\b"#, #"\bdeposit(ed)?\b"#, #"\byou (received|got)\b"#,
                              #"\breturn(ed)? to your\b"#, #"\bвозврат"#, #"\bзачислен"#, #"\bпоступлени"#, #"\bпополнени"#, #"\bперевод от\b"#,
                              #"\buplata\b"#, #"\bpovra[cć]aj"#, #"\bodobrenje\b"#]
    static let expenseWords = [#"\bpurchase\b"#, #"\btransaction\b"#, #"\bcharged?\b"#, #"\bspent\b"#, #"\bpaid\b"#, #"\bpayment\b"#,
                               #"\bdebit(ed)?\b"#, #"\bwithdrawal\b"#, #"\bпокупк"#, #"\bоплат"#, #"\bсписан"#, #"\bснятие\b"#, #"\bплатеж"#, #"\bплатёж"#,
                               #"\bkori[sš][cć]enje\b"#, #"\bpla[cć]anje\b"#, #"\bisplata\b"#, #"\bzadu[zž]enje\b"#,
                               #"\bперевод\b"#, #"\bсбп\b"#]
    static let balanceWords = #"(balance|available|avail\.?|limit|баланс|доступно|остаток|лимит|raspolo[zž]ivo|stanje|saldo)\W{0,4}$"#

    private static func ignoredReason(_ text: String) -> Ignored? {
        if contains(text, codeWords) { return .oneTimeCode }
        if contains(text, fraudWords) { return .fraudCheck }
        if contains(text, declinedWords) { return .declined }
        return nil
    }

    private static func contains(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// Single spaces, line breaks kept: fields such as "Mesto:" stay on their own line.
    public static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "[\u{00a0}\u{202f}\u{2009}]", with: " ", options: .regularExpression)
            // "4054**5109 | Iznos 3,00 USD | Gde: …": fields separated by bars read like lines.
            .replacingOccurrences(of: "\\s*\\|\\s*", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ?\\n[\\s]*", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Amount

    struct Amount { var value: Decimal; var currency: String?; var text: String; var range: Range<String.Index> }

    static let number = #"[0-9]{1,3}(?:[ ,.][0-9]{3})+(?:[.,][0-9]{1,2})?|[0-9]+(?:[.,][0-9]{1,2})?"#
    static let symbols: [String: String] = ["$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₽": "RUB", "₸": "KZT", "₺": "TRY", "₾": "GEL"]
    static let words: [String: String] = ["руб": "RUB", "руб.": "RUB", "р.": "RUB", "р": "RUB", "rub": "RUB", "usd": "USD", "eur": "EUR"]

    /// Every amount with a currency in reading order. A bare number is never an amount:
    /// dates, times and card numbers would look like one.
    static func amounts(in text: String) -> [Amount] {
        let symbol = "[" + symbols.keys.joined() + "]"
        let code = "[A-Z]{3}|руб\\.?|р\\.?"
        let pattern = "(?<pre>\(symbol)|\\b(?:\(code)))\\s?(?<a>\(number))(?![0-9])|(?<![0-9.,])(?<b>\(number))\\s?(?<post>\(symbol)|(?:\(code))(?![\\p{L}]))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            func group(_ name: String) -> String? { Range(match.range(withName: name), in: text).map { String(text[$0]) } }
            guard let digits = group("a") ?? group("b"), let marker = group("pre") ?? group("post"),
                  let whole = Range(match.range, in: text), let value = amountValue(digits), value > 0 else { return nil }
            let currency = symbols[marker] ?? words[marker.lowercased()]
                ?? (Locale.isoCurrencyCodeSet.contains(marker) ? marker : nil)
            guard let currency else { return nil }
            return Amount(value: value, currency: currency, text: String(text[whole]), range: whole)
        }
    }

    /// The first amount that is not a balance or a limit.
    static func transactionAmount(in text: String) -> Amount? {
        amounts(in: text).first { amount in
            let before = text[text.index(amount.range.lowerBound, offsetBy: -min(24, text.distance(from: text.startIndex, to: amount.range.lowerBound)))..<amount.range.lowerBound]
            return before.range(of: balanceWords, options: [.regularExpression, .caseInsensitive]) == nil
        }
    }

    /// The last separator followed by one or two digits is the decimal point; others group thousands.
    static func amountValue(_ digits: String) -> Decimal? {
        var value = digits.replacingOccurrences(of: " ", with: "")
        if let last = value.lastIndex(where: { $0 == "," || $0 == "." }), value.distance(from: last, to: value.endIndex) <= 3 {
            let whole = value[..<last].filter(\.isNumber)
            value = whole + "." + value[value.index(after: last)...]
        } else {
            value = value.filter(\.isNumber)
        }
        guard let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), amount <= 999_999_999 else { return nil }
        return amount
    }

    // MARK: Card and merchant

    static let cardPatterns = [#"(?:[*•·xX]|\.{2,3}|…)\s?([0-9]{4})\b"#,
                               #"(?:ending(?: in)?|last 4(?: digits)?|оканчивающ\p{L}*(?: на)?)\D{0,6}([0-9]{4})\b"#,
                               #"(?:card|карт\p{L}*|acct|account|счет\p{L}*|счёт\p{L}*)\s?#?\s?([0-9]{4})\b"#,
                               // Sberbank texts start with the card: "MIR-1234 14:35 Покупка …".
                               #"\b(?:mir|visa|mc|ecmc|maes|amex|мир)[-\s]?([0-9]{4})\b"#]

    static func cardLast4(in text: String) -> String? {
        for pattern in cardPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return String(text[range])
        }
        return nil
    }

    /// "at STARBUCKS", "with Amazon.com", "в PYATEROCHKA"; otherwise a separate segment in capitals,
    /// as in "Покупка 450 RUB. PYATEROCHKA. Доступно 1200 RUB".
    static func merchant(in text: String, excluding amountText: String) -> String? {
        // A field on its own line: "Mesto: TARGET STORE NEW YORK US", "Merchant: UBER".
        let label = #"(?im)^\s*(?:mesto|gde|gdje|prodavac|trgovac|merchant|location|место|магазин|получатель)\s*:\s*(?<m>.+?)\s*$"#
        if let regex = try? NSRegularExpression(pattern: label),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(withName: "m"), in: text) { return String(text[range]) }
        let stop = #"(?=\s+(?:on|using|with|from|was|has|for|via|at [0-9]|card|ending|по карте|карт\p{L}*|on your)\b|[;(]|\.\s|\.$|,\s|\s[0-9]{1,2}[:/.][0-9]|$)"#
        let pattern = #"(?:\b(?:at|with|to|from|merchant:?)|\bв|\bу)\s+(?<m>[\p{L}0-9][^;(\n]*?)"# + stop
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(withName: "m"), in: text) else { continue }
                let candidate = String(text[range]).trimmingCharacters(in: .whitespaces)
                if isMerchant(candidate, amountText: amountText) { return candidate }
            }
        }
        // Right after the amount: "Покупка 450р PYATEROCHKA Баланс …", "Оплата СБП 780 ₽, Кофемания."
        if let amount = text.range(of: amountText) {
            let after = text[amount.upperBound...]
                .replacingOccurrences(of: #"\s(баланс|доступно|остаток|balance|available|raspolo[zž]ivo)\b.*"#,
                                      with: "", options: [.regularExpression, .caseInsensitive])
            let chunk = after.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ."))  }
                .flatMap { $0.components(separatedBy: ". ") }
                .first { !$0.isEmpty && cardLast4(in: $0) == nil && isMerchant($0, amountText: amountText) }
            if let chunk { return chunk }
        }
        return text.components(separatedBy: CharacterSet(charactersIn: ".;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { segment in
                let letters = segment.filter(\.isLetter)
                return letters.count >= 2 && Double(letters.filter(\.isUppercase).count) / Double(letters.count) > 0.7
                    && isMerchant(segment, amountText: amountText)
            }
    }

    private static func isMerchant(_ candidate: String, amountText: String) -> Bool {
        let lower = candidate.lowercased()
        guard candidate.count >= 2, candidate.count <= 60, candidate.contains(where: \.isLetter),
              !candidate.contains(amountText), amounts(in: candidate).isEmpty,
              !contains(candidate, expenseWords + incomeWords), lower.range(of: balanceWords, options: .regularExpression) == nil else { return false }
        let notNames = ["your", "you", "the", "a", "an", "card", "your card", "your account", "account", "ваш", "вашей карте", "карта", "счет"]
        return !notNames.contains(lower) && !lower.hasPrefix("your ") && !lower.hasPrefix("ваш")
    }

    /// Card descriptors end with a country code: "NJT BUS MY-TIX NEWARK US" is kept without "US".
    static func cleanMerchant(_ text: String) -> String {
        var name = text.trimmingCharacters(in: CharacterSet(charactersIn: " .,:-\"'«»"))
        if let space = name.lastIndex(of: " "), name.split(separator: " ").count >= 3 {
            let code = String(name[name.index(after: space)...])
            if code.count == 2, code == code.uppercased(), Locale.Region.isoRegions.contains(where: { $0.identifier == code }) {
                name = String(name[..<space])
            }
        }
        return name
    }
}

/// The wording of one bank's message with the amount, merchant and card left open.
/// Learned from a message the user confirmed; later messages in the same wording
/// are booked without review.
public struct BankMessageTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The sender the template was learned from; empty matches any sender.
    public var sender: String
    /// Message text with `{amount}`, `{merchant}` and `{card}` in place of the values.
    public var pattern: String
    public var direction: BankMessage.Direction

    public init(id: UUID = UUID(), sender: String, pattern: String, direction: BankMessage.Direction) {
        self.id = id; self.sender = sender; self.pattern = pattern; self.direction = direction
    }

    /// Nil when the confirmed merchant or amount is not literally in the message.
    public init?(learningFrom text: String, sender: String, parsed: BankMessage.Parsed) {
        func flat(_ value: String) -> String {
            BankMessage.normalized(value).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
        var pattern = flat(text)
        guard !parsed.amountText.isEmpty, !parsed.merchantText.isEmpty,
              let amount = pattern.range(of: flat(parsed.amountText)) else { return nil }
        pattern.replaceSubrange(amount, with: "{amount}")
        guard let merchant = pattern.range(of: flat(parsed.merchantText)) else { return nil }
        pattern.replaceSubrange(merchant, with: "{merchant}")
        if let card = parsed.cardLast4, let range = pattern.range(of: card) { pattern.replaceSubrange(range, with: "{card}") }
        self.init(sender: sender.trimmingCharacters(in: .whitespaces), pattern: pattern, direction: parsed.direction)
    }

    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
                         "янв", "фев", "мар", "апр", "мая", "май", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"]

    /// Literal text must repeat; numbers (dates, times, balances) and month names may change.
    var regex: NSRegularExpression? {
        var expression = "^"
        var rest = Substring(pattern)
        while !rest.isEmpty {
            if let slot = ["{amount}", "{merchant}", "{card}"].first(where: { rest.hasPrefix($0) }) {
                expression += slot == "{amount}" ? "(?<amount>.+?)" : slot == "{merchant}" ? "(?<merchant>.+?)" : "(?<card>[0-9]{4})"
                rest = rest.dropFirst(slot.count)
                continue
            }
            let word = rest.prefix { !$0.isWhitespace && $0 != "{" }
            if word.isEmpty {
                let space = rest.prefix { $0.isWhitespace }
                if space.isEmpty { expression += NSRegularExpression.escapedPattern(for: String(rest.prefix(1))); rest = rest.dropFirst() }
                else { expression += "\\s+"; rest = rest.dropFirst(space.count) }
                continue
            }
            // "3.219,62" and "20:26:33" become any number, so a later balance or time still matches.
            expression += NSRegularExpression.escapedPattern(for: String(word.replacingOccurrences(
                of: "[0-9][0-9.,:]*[0-9]|[0-9]", with: "\u{1}", options: .regularExpression)))
                .replacingOccurrences(of: "\u{1}", with: "[0-9][0-9.,:]*")
                .replacingOccurrences(of: "(?<=\\*)(AM|PM)(?=\\W|$)", with: "(?:AM|PM)", options: [.regularExpression, .caseInsensitive])
            if Self.months.contains(where: { word.lowercased().hasPrefix($0) }), word.allSatisfy(\.isLetter) {
                expression = String(expression.dropLast(word.count)) + "\\p{L}+"
            }
            rest = rest.dropFirst(word.count)
        }
        return try? NSRegularExpression(pattern: expression + "$", options: .caseInsensitive)
    }

    func match(_ text: String, sender: String) -> BankMessage.Parsed? {
        guard self.sender.isEmpty || sender.isEmpty || self.sender.caseInsensitiveCompare(sender) == .orderedSame,
              let regex, let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ name: String) -> String? {
            Range(match.range(withName: name), in: text).map { String(text[$0]) }
        }
        guard let amountText = group("amount"), let amount = BankMessage.amounts(in: amountText).first,
              amount.text == amountText.trimmingCharacters(in: .whitespaces),
              let merchantText = group("merchant") else { return nil }
        let merchant = BankMessage.cleanMerchant(merchantText)
        guard !merchant.isEmpty else { return nil }
        return BankMessage.Parsed(amount: amount.value, currency: amount.currency, merchant: merchant,
                                  cardLast4: group("card") ?? BankMessage.cardLast4(in: text), direction: direction,
                                  automatic: true, amountText: amountText, merchantText: merchantText)
    }
}
