import Foundation

public struct CSVTable {
    public var headers: [String]
    public var rows: [[String]]
    public var delimiter: Character
    public static func read(_ data: Data) throws -> CSVTable {
        guard data.count <= 20_000_000 else { throw LedgerError.invalid("Файл больше 20 МБ. Разделите его на несколько файлов.") }
        let bytes = Array(data.prefix(2))
        let utf16 = bytes == [0xff, 0xfe] || bytes == [0xfe, 0xff]
        guard let text = utf16 ? String(data: data, encoding: .utf16) : (String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251)) else { throw LedgerError.invalid("Не удалось прочитать кодировку CSV.") }
        return try parse(text)
    }
    public static func parse(_ input: String, delimiter explicit: Character? = nil) throws -> CSVTable {
        let text = input.hasPrefix("\u{feff}") ? String(input.dropFirst()) : input
        let delimiter = explicit ?? detectDelimiter(text)
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closedQuote = false, atFieldStart = true
        let characters = Array(text)
        var i = 0
        func finishField() { row.append(field); field = ""; atFieldStart = true; closedQuote = false }
        func finishRow() {
            finishField()
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { rows.append(row) }
            row = []
        }
        while i < characters.count {
            let c = characters[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < characters.count && characters[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false; closedQuote = true }
                } else { field.append(c) }
            } else if c == delimiter { finishField() }
            else if c == "\n" || c == "\r" || c == "\r\n" {
                finishRow()
                if c == "\r", i + 1 < characters.count, characters[i + 1] == "\n" { i += 1 }
            } else if c == "\"" && atFieldStart { quoted = true; atFieldStart = false }
            else if closedQuote {
                if !c.isWhitespace { throw LedgerError.invalid("Лишний символ после закрывающей кавычки в CSV.") }
            } else {
                if c == "\"" { throw LedgerError.invalid("Кавычки внутри поля должны быть экранированы двойными кавычками.") }
                field.append(c); atFieldStart = false
            }
            i += 1
            if rows.count > 100_000 { throw LedgerError.invalid("В файле больше 100 000 строк.") }
        }
        guard !quoted else { throw LedgerError.invalid("В CSV есть незакрытая кавычка.") }
        if !field.isEmpty || !row.isEmpty || closedQuote { finishRow() }
        guard rows.count > 1 else { throw LedgerError.invalid("В CSV нужны заголовки и хотя бы одна операция.") }
        let headers = rows.removeFirst().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard headers.count > 1 else { throw LedgerError.invalid("Не удалось определить колонки. Используйте запятую, точку с запятой или табуляцию.") }
        return CSVTable(headers: headers, rows: rows, delimiter: delimiter)
    }
    private static func detectDelimiter(_ text: String) -> Character {
        var quoted = false
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        for c in text {
            if c == "\"" { quoted.toggle() }
            if !quoted && (c == "\n" || c == "\r" || c == "\r\n") { break }
            if !quoted, counts[c] != nil { counts[c, default: 0] += 1 }
        }
        return counts.max { $0.value < $1.value }?.key ?? ","
    }
}

public enum CSVField: String, CaseIterable, Identifiable, Codable {
    case date, merchant, amount, debit, credit, currency, account, category, kind, note, tags, externalID, destination, destinationAmount
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .date: "Дата *"; case .merchant: "Описание *"; case .amount: "Сумма"; case .debit: "Расход (отдельная колонка)"; case .credit: "Доход (отдельная колонка)"; case .currency: "Валюта"; case .account: "Счет"; case .category: "Категория"; case .kind: "Тип операции"; case .note: "Заметка"; case .tags: "Теги"; case .externalID: "ID операции"; case .destination: "Счет назначения"; case .destinationAmount: "Сумма зачисления"
        }
    }
    public var aliases: [String] {
        switch self {
        case .date: ["date", "дата", "transaction date", "дата операции", "дата платежа"]
        case .merchant: ["merchant", "description", "payee", "описание", "получатель", "название", "контрагент"]
        case .amount: ["amount", "сумма", "сумма операции"]
        case .debit: ["debit", "withdrawal", "расход", "списание"]
        case .credit: ["credit", "deposit", "доход", "зачисление"]
        case .currency: ["currency", "валюта"]
        case .account: ["account", "account name", "счет", "счёт"]
        case .category: ["category", "категория"]
        case .kind: ["type", "kind", "тип", "тип операции"]
        case .note: ["note", "notes", "заметка", "комментарий"]
        case .tags: ["tags", "теги"]
        case .externalID: ["id", "transaction id", "идентификатор"]
        case .destination: ["to_account", "destination", "счет назначения", "счёт назначения"]
        case .destinationAmount: ["to_amount", "destination amount", "сумма зачисления"]
        }
    }
}

public struct CSVMapping: Equatable {
    public var columns: [CSVField: Int] = [:]
    public var defaultAccountID: UUID?
    public var defaultCurrency: String = "RUB"
    public var dateFormat = "auto"
    public var positiveIsExpense = false
    public var skipDuplicates = true
    public var skipInvalid = false
    public var excludedRows: Set<Int> = []
    public init(headers: [String], defaultAccountID: UUID? = nil, currency: String = "RUB") {
        for f in CSVField.allCases {
            if let index = headers.firstIndex(where: { f.aliases.contains($0.lowercased()) }) { columns[f] = index }
        }
        self.defaultAccountID = defaultAccountID; self.defaultCurrency = currency
    }
}

public struct CSVPreviewRow: Identifiable {
    public var id: Int
    public var date: Date?
    public var merchant: String
    public var amount: Decimal?
    public var currency: String
    public var account: String
    public var category: String
    public var error: String?
    public var duplicate: Bool
    public var excluded = false
    public var conversion: CardConversion?
}

public struct CSVImportResult {
    public var ledger: Ledger
    public var rows: [CSVPreviewRow]
    public var imported: Int
    public var duplicates: Int
    public var invalid: Int
    public var excluded: Int
}

public enum CSVImporter {
    public static func prepareAsync(_ table: CSVTable, mapping: CSVMapping, ledger: Ledger, fetch: MoraAutomation.ConversionFetcher? = nil) async throws -> CSVImportResult {
        let columns = Array(mapping.columns.values)
        guard Set(columns).count == columns.count, mapping.columns[.date] != nil, mapping.columns[.merchant] != nil,
              mapping.columns[.amount] != nil || mapping.columns[.debit] != nil || mapping.columns[.credit] != nil else {
            throw LedgerError.invalid("Сопоставьте дату, описание и сумму; одна колонка не может соответствовать нескольким полям.")
        }
        let quote: MoraAutomation.ConversionFetcher = fetch ?? { amount, from, to, date in
            try await VisaRateClient.shared.conversion(amount: amount, from: from, to: to, date: date)
        }
        var normalized = table, adjusted = mapping
        var conversions: [Int: CardConversion] = [:]
        var rates: [String: CardConversion] = [:]
        let newAmountColumn = table.headers.count
        normalized.headers.append("__mora_account_amount")
        adjusted.columns[.amount] = newAmountColumn
        adjusted.columns.removeValue(forKey: .debit); adjusted.columns.removeValue(forKey: .credit)
        adjusted.positiveIsExpense = false
        for i in table.rows.indices {
            let row = table.rows[i]
            func cell(_ field: CSVField) -> String {
                guard let column = mapping.columns[field], row.indices.contains(column) else { return "" }
                return row[column].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var amount: Decimal?
            if mapping.columns[.amount] != nil { amount = Money.parse(cell(.amount)).map { mapping.positiveIsExpense ? -$0 : $0 } }
            else {
                let debit = cell(.debit).isEmpty ? Decimal(0) : Money.parse(cell(.debit))
                let credit = cell(.credit).isEmpty ? Decimal(0) : Money.parse(cell(.credit))
                if let debit, let credit, debit >= 0, credit >= 0, (debit > 0) != (credit > 0) { amount = credit - debit }
            }
            let kind = cell(.kind).lowercased()
            if ["expense", "расход", "debit", "transfer", "перевод", "transfer_out"].contains(kind) { amount = amount.map { -abs($0) } }
            if ["income", "доход", "credit", "transfer_in"].contains(kind) { amount = amount.map(abs) }
            normalized.rows[i].append(amount.map(Money.plain) ?? "")
            guard row.count == table.headers.count, !mapping.excludedRows.contains(i + 2),
                  let amount, amount != 0, let date = Dates.parse(cell(.date), format: mapping.dateFormat) else { continue }
            let selected = cell(.account).isEmpty ? mapping.defaultAccountID.flatMap { ledger.account($0) } : ledger.accounts.first { $0.name.localizedCaseInsensitiveCompare(cell(.account)) == .orderedSame }
            guard let selected, let column = mapping.columns[.currency], !cell(.currency).isEmpty,
                  cell(.currency).uppercased() != selected.currency else { continue }
            guard !["transfer", "перевод", "transfer_in", "transfer_out"].contains(kind) else { throw LedgerError.invalid("Сумма списания перевода должна быть в валюте исходного счета.") }
            let currency = cell(.currency).uppercased()
            let key = "\(Dates.string(date))|\(currency)|\(selected.currency)"
            var conversion: CardConversion
            if let saved = ledger.transactions.first(where: { $0.accountID == selected.id && $0.merchant == cell(.merchant) && $0.date == date && $0.conversion?.originalAmount == amount && $0.conversion?.originalCurrency == currency })?.conversion {
                conversion = saved
            } else {
                if let cached = rates[key] { conversion = cached; conversion.originalAmount = amount }
                else { conversion = try await quote(amount, currency, selected.currency, date); rates[key] = conversion }
                conversion = conversion.applyingFee(of: selected)
            }
            guard conversion.originalAmount == amount, conversion.originalCurrency == currency,
                  conversion.accountCurrency == selected.currency, Dates.string(conversion.date) == Dates.string(date) else { throw LedgerError.invalid("Сервис вернул курс для другой валюты или даты.") }
            normalized.rows[i][newAmountColumn] = Money.plain(try conversion.convertedAmount())
            normalized.rows[i][column] = selected.currency
            conversions[i] = conversion
        }
        return try prepare(normalized, mapping: adjusted, ledger: ledger, conversions: conversions)
    }

    public static func prepare(_ table: CSVTable, mapping: CSVMapping, ledger original: Ledger, conversions: [Int: CardConversion] = [:]) throws -> CSVImportResult {
        guard mapping.columns[.date] != nil, mapping.columns[.merchant] != nil else { throw LedgerError.invalid("Сопоставьте дату и описание операции.") }
        guard mapping.columns[.amount] != nil || mapping.columns[.debit] != nil || mapping.columns[.credit] != nil else { throw LedgerError.invalid("Сопоставьте сумму или колонки расхода и дохода.") }
        let assigned = Array(mapping.columns.values)
        guard Set(assigned).count == assigned.count else { throw LedgerError.invalid("Одна колонка не может соответствовать нескольким полям.") }
        var ledger = original
        var previews: [CSVPreviewRow] = []
        var contentMatches = CSVContentMatches(ledger: original)
        var externalIDs = Set(original.transactions.map { "\($0.accountID)|\($0.externalID ?? $0.id.uuidString)" })
        var imported = 0, duplicates = 0, invalid = 0
        for (index, row) in table.rows.enumerated() {
            if index % 256 == 0 && Task.isCancelled { throw CancellationError() }
            func cell(_ field: CSVField) -> String {
                guard let i = mapping.columns[field], row.indices.contains(i) else { return "" }
                return row[i].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var preview = CSVPreviewRow(id: index + 2, date: Dates.parse(cell(.date), format: mapping.dateFormat), merchant: cell(.merchant), amount: nil, currency: cell(.currency).uppercased(), account: cell(.account), category: cell(.category), error: nil, duplicate: false)
            preview.conversion = conversions[index]
            preview.excluded = mapping.excludedRows.contains(preview.id)
            // Each row is staged independently. Invalid rows must not create accounts or categories.
            var staged = ledger
            do {
                guard row.count == table.headers.count else { throw LedgerError.invalid("\(row.count) колонок вместо \(table.headers.count)") }
                guard let date = preview.date else { throw LedgerError.invalid("Неверная дата: \(cell(.date))") }
                guard !preview.merchant.isEmpty else { throw LedgerError.invalid("Пустое описание") }
                var amount: Decimal
                if mapping.columns[.amount] != nil {
                    guard let parsed = Money.parse(cell(.amount)), parsed != 0 else { throw LedgerError.invalid("Неверная или нулевая сумма") }
                    amount = mapping.positiveIsExpense ? -parsed : parsed
                } else {
                    let debit = cell(.debit).isEmpty ? Decimal(0) : Money.parse(cell(.debit))
                    let credit = cell(.credit).isEmpty ? Decimal(0) : Money.parse(cell(.credit))
                    guard let debit, let credit, debit >= 0, credit >= 0, (debit > 0) != (credit > 0) else { throw LedgerError.invalid("Укажите только расход или только доход") }
                    amount = credit - debit
                }
                let rawKind = cell(.kind).lowercased()
                let kind: TransactionKind
                switch rawKind {
                case "", "automatic": kind = amount < 0 ? .expense : .income
                case "expense", "расход", "debit": kind = .expense; amount = -abs(amount)
                case "income", "доход", "credit": kind = .income; amount = abs(amount)
                case "transfer", "перевод": kind = .transfer; amount = -abs(amount)
                case "transfer_in": kind = .transfer; amount = abs(amount)
                case "transfer_out": kind = .transfer; amount = -abs(amount)
                default: throw LedgerError.invalid("Неизвестный тип: \(rawKind)")
                }
                var account: Account
                if !preview.account.isEmpty {
                    if let existing = staged.accounts.first(where: { $0.name.localizedCaseInsensitiveCompare(preview.account) == .orderedSame }) { account = existing }
                    else {
                        account = Account(name: preview.account, currency: preview.currency.isEmpty ? mapping.defaultCurrency : preview.currency)
                        staged.accounts.append(account)
                    }
                } else if let id = mapping.defaultAccountID, let existing = staged.account(id) { account = existing }
                else { throw LedgerError.invalid("Не выбран счет") }
                if preview.currency.isEmpty { preview.currency = account.currency }
                guard Locale.commonISOCurrencyCodes.contains(preview.currency) else { throw LedgerError.invalid("Неизвестная валюта: \(preview.currency)") }
                guard account.currency == preview.currency else { throw LedgerError.invalid("Валюта строки отличается от валюты счета \(account.name)") }
                preview.account = account.name; preview.amount = amount
                guard !account.archived else { throw LedgerError.invalid("Верните счет из архива перед добавлением операций.") }
                let standalone = rawKind == "transfer_in" || rawKind == "transfer_out"
                var categoryID: UUID?
                if kind != .transfer {
                    if !preview.category.isEmpty {
                        if let existing = staged.categories.first(where: { $0.name.localizedCaseInsensitiveCompare(preview.category) == .orderedSame && $0.kind == kind }) { categoryID = existing.id }
                        else { let c = Category(name: preview.category, kind: kind); staged.categories.append(c); categoryID = c.id }
                    } else { categoryID = staged.matchingCategory(merchant: preview.merchant, kind: kind) }
                }
                var destination: Account?, destinationAmount: Decimal?
                if standalone {
                    guard !cell(.destination).isEmpty else { throw LedgerError.invalid("Укажите название удаленного счета") }
                } else if kind == .transfer {
                    guard !cell(.destination).isEmpty else { throw LedgerError.invalid("У перевода нет счета назначения") }
                    destination = staged.accounts.first { $0.name.localizedCaseInsensitiveCompare(cell(.destination)) == .orderedSame }
                    guard let destination, destination.id != account.id else { throw LedgerError.invalid("Сначала создайте отдельный счет назначения") }
                    guard !destination.archived else { throw LedgerError.invalid("Верните счет из архива перед добавлением операций.") }
                    destinationAmount = cell(.destinationAmount).isEmpty && destination.currency == account.currency ? abs(amount) : Money.parse(cell(.destinationAmount))
                    guard let destinationAmount, destinationAmount > 0 else { throw LedgerError.invalid("Укажите сумму зачисления в валюте второго счета") }
                    if destination.currency == account.currency && destinationAmount != abs(amount) { throw LedgerError.invalid("Суммы перевода в одной валюте должны совпадать") }
                }
                let externalID = cell(.externalID).isEmpty ? nil : cell(.externalID)
                var t = Transaction(date: date, merchant: preview.merchant, amount: amount, accountID: account.id, categoryID: categoryID, kind: kind, note: cell(.note), tags: cell(.tags).split(separator: "|").map(String.init), destinationAccountID: destination?.id, destinationAmount: destinationAmount, externalID: externalID)
                t.conversion = conversions[index]
                if standalone { t.removedTransferAccountName = cell(.destination) }
                if t.conversion == nil, let externalID, let existing = original.transactions.first(where: { ($0.externalID ?? $0.id.uuidString) == externalID && $0.accountID == t.accountID && $0.amount == t.amount && $0.date == t.date && $0.merchant == t.merchant }) { t.conversion = existing.conversion }
                let key = fingerprint(t, ledger: staged)
                let externalKey = externalID.map { "\(account.id)|\($0)" }
                if preview.excluded { previews.append(preview); continue }
                // Stable external IDs take precedence over a content heuristic.
                preview.duplicate = externalKey.map { externalIDs.contains($0) } ?? contentMatches.consume(key)
                if preview.duplicate && mapping.skipDuplicates { duplicates += 1 }
                else {
                    ledger.accounts = staged.accounts
                    ledger.categories = staged.categories
                    // Release the staged array before appending to avoid a full copy per row.
                    staged.transactions = []
                    ledger.transactions.append(t)
                    if let externalKey { externalIDs.insert(externalKey) }
                    imported += 1
                }
            } catch { preview.error = error.localizedDescription; if !preview.excluded { invalid += 1 } }
            previews.append(preview)
        }
        try ledger.validate()
        return CSVImportResult(ledger: ledger, rows: previews, imported: imported, duplicates: duplicates, invalid: invalid, excluded: previews.filter(\.excluded).count)
    }
    public static func fingerprint(_ t: Transaction, ledger: Ledger) -> String {
        var fields = [Dates.string(t.date), t.merchant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), Money.plain(t.amount), t.accountID.uuidString, t.kind.rawValue, t.destinationAccountID?.uuidString ?? "", t.destinationAmount.map(Money.plain) ?? ""]
        if let conversion = t.conversion { fields += [conversion.originalCurrency, Money.plain(conversion.originalAmount)] }
        return fields.joined(separator: "|")
    }
    public static func export(_ ledger: Ledger, transactions: [Transaction]? = nil) -> String {
        func escape(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let header = "date,merchant,amount,currency,account,category,type,note,tags,id,to_account,to_amount"
        let rows = (transactions ?? ledger.transactions).sorted { $0.date < $1.date }.map { t -> String in
            let a = ledger.account(t.accountID)
            let kind = t.isStandaloneTransfer ? (t.amount > 0 ? "transfer_in" : "transfer_out") : t.kind.rawValue
            return [Dates.string(t.date), t.merchant, Money.plain(t.amount), a?.currency ?? "", a?.name ?? "", ledger.category(t.categoryID)?.name ?? "", kind, t.note, t.tags.joined(separator: "|"), t.externalID ?? t.id.uuidString, t.removedTransferAccountName ?? t.destinationAccountID.flatMap { ledger.account($0)?.name } ?? "", t.destinationAmount.map(Money.plain) ?? ""].map(escape).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }
}

// Match each existing purchase at most once. Newly imported rows do not consume
// other identical rows in this file; only a stable bank ID can establish that.
struct CSVContentMatches {
    private var remaining: [String: Int] = [:]
    init(ledger: Ledger) {
        for transaction in ledger.transactions {
            remaining[CSVImporter.fingerprint(transaction, ledger: ledger), default: 0] += 1
        }
    }
    mutating func consume(_ key: String) -> Bool {
        guard let count = remaining[key], count > 0 else { return false }
        remaining[key] = count - 1
        return true
    }
}
