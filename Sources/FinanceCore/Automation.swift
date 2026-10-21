import Foundation
import CryptoKit

public struct MoraAutomation {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    private func load() throws -> Ledger {
        FileManager.default.fileExists(atPath: fileURL.path) ? try LedgerFile.decode(Data(contentsOf: fileURL)) : .empty
    }
    public typealias ConversionFetcher = (Decimal, String, String, Date) async throws -> CardConversion
    public func runAsync(_ command: String, arguments: [String: Any], fetch: ConversionFetcher? = nil) async throws -> sending [String: Any] {
        let quote: ConversionFetcher = fetch ?? { amount, from, to, date in
            try await VisaRateClient.shared.conversion(amount: amount, from: from, to: to, date: date)
        }
        if command == "reassign_entries" { return try await reassign(arguments, fetch: quote) }
        guard ["preview_entries", "add_entries", "import_csv"].contains(command) else { return try run(command, arguments: arguments) }
        let ledger = try load()
        var normalized = try table(command, arguments: arguments)
        var conversions: [Int: CardConversion] = [:]
        var rates: [String: CardConversion] = [:]
        for i in normalized.rows.indices {
            let row = normalized.rows[i]
            guard row.count == 12 else { throw LedgerError.invalid("Строка \(i + 2): ожидается 12 колонок.") }
            let account = try account(named: row[4], ledger: ledger)
            let currency = row[3].uppercased()
            guard currency != account.currency else { continue }
            guard !["transfer", "transfer_in", "transfer_out"].contains(row[6]) else { throw LedgerError.invalid("У перевода сумма списания должна быть в валюте исходного счета; сумма зачисления — фактическая.") }
            let date = try isoDate(["date": row[0]], "date")
            let amount = try decimal(["amount": row[2]], "amount")
            let key = "\(row[0])|\(currency)|\(account.currency)"
            var conversion: CardConversion
            if let existing = ledger.transactions.first(where: { $0.externalID == row[9] && $0.accountID == account.id }),
               let saved = existing.conversion, saved.originalCurrency == currency,
               saved.originalAmount == amount, Dates.string(saved.date) == row[0] {
                conversion = saved
            } else if let cached = rates[key] {
                conversion = cached; conversion.originalAmount = amount
                conversion = conversion.applyingFee(of: account)
            } else {
                conversion = try await quote(amount, currency, account.currency, date)
                rates[key] = conversion
                conversion = conversion.applyingFee(of: account)
            }
            guard conversion.originalCurrency == currency, conversion.accountCurrency == account.currency,
                  conversion.originalAmount == amount, Dates.string(conversion.date) == row[0] else {
                throw LedgerError.invalid("Сервис вернул курс для другой валюты или даты.")
            }
            normalized.rows[i][2] = Money.plain(try conversion.convertedAmount())
            normalized.rows[i][3] = account.currency
            conversions[i] = conversion
        }
        var result = try run(command, arguments: arguments, normalizedTable: normalized, conversions: conversions)
        result["conversions"] = conversions.sorted { $0.key < $1.key }.map { index, value in
            ["row": index + 2, "original_amount": Money.plain(value.originalAmount), "original_currency": value.originalCurrency,
             "amount": Money.plain(try! value.convertedAmount()), "currency": value.accountCurrency,
             "rate": Money.plain(value.rate), "bank_fee_percent": Money.plain(value.feePercent), "date": Dates.string(value.date), "provider": value.provider] as [String: Any]
        }
        return result
    }

    private func reassign(_ arguments: [String: Any], fetch: ConversionFetcher) async throws -> sending [String: Any] {
        let requestID = try stableID(arguments)
        let targetName = try string(arguments, "account", max: 256)
        let expectedName = try string(arguments, "expected_account", max: 256)
        guard let texts = arguments["transaction_ids"] as? [String], !texts.isEmpty, texts.count <= 1000,
              texts.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw LedgerError.invalid("Нужны идентификаторы существующих операций.") }
        let ids = Set(texts.compactMap(UUID.init(uuidString:)))
        guard ids.count == texts.count else { throw LedgerError.invalid("Идентификаторы операций повторяются.") }
        let initial = try load()
        let target = try account(named: targetName, ledger: initial)
        let expected = try account(named: expectedName, ledger: initial)
        let originals = initial.transactions.filter { ids.contains($0.id) }
        guard originals.count == ids.count, originals.allSatisfy({ $0.kind != .transfer && ($0.accountID == expected.id || $0.accountID == target.id) }) else {
            throw LedgerError.invalid("Операции не найдены, являются переводами или находятся на другом счете.")
        }
        var values: [Transaction] = []
        var rates: [String: CardConversion] = [:]
        for var value in originals {
            if value.accountID == target.id { values.append(value); continue }
            let currency = value.conversion?.originalCurrency ?? expected.currency
            let amount = value.conversion?.originalAmount ?? value.amount
            if currency == target.currency { value.amount = amount; value.conversion = nil }
            else {
                let key = "\(Dates.string(value.date))|\(currency)|\(target.currency)"
                var conversion: CardConversion
                if let cached = rates[key] { conversion = cached; conversion.originalAmount = amount }
                else { conversion = try await fetch(amount, currency, target.currency, value.date); rates[key] = conversion }
                guard conversion.originalAmount == amount, conversion.originalCurrency == currency,
                      conversion.accountCurrency == target.currency, Dates.string(conversion.date) == Dates.string(value.date) else {
                    throw LedgerError.invalid("Сервис вернул курс для другой валюты или даты.")
                }
                conversion = conversion.applyingFee(of: target)
                value.amount = try conversion.convertedAmount(); value.conversion = conversion
            }
            value.accountID = target.id
            values.append(value)
        }
        let dryRun = arguments["dry_run"] as? Bool ?? true
        if !dryRun {
            _ = try LedgerFile.mutate(at: fileURL) { ledger in
                guard try account(named: targetName, ledger: ledger) == target,
                      originals.allSatisfy({ original in ledger.transactions.first { $0.id == original.id } == original }) else {
                    throw LedgerError.invalid("Данные изменились во время пересчета. Повторите предпросмотр.")
                }
                for value in values {
                    let index = ledger.transactions.firstIndex { $0.id == value.id }!
                    ledger.transactions[index] = value
                }
                let untracked = Set(values.filter { $0.importBatchID == nil }.map(\.id))
                if !untracked.isEmpty {
                    try ledger.recordImport(addedIDs: untracked, filename: "Исправленный пакет MCP", source: "MCP", totalRows: values.count, batchID: requestID)
                }
            }
        }
        return ["saved": !dryRun, "updated": zip(values, originals).filter { $0 != $1 }.count,
                "entries": values.map { entry($0, ledger: initial) }, "account": target.name, "currency": target.currency]
    }
    public func run(_ command: String, arguments: [String: Any], normalizedTable: CSVTable? = nil, conversions: [Int: CardConversion] = [:]) throws -> sending [String: Any] {
        switch command {
        case "context":
            let ledger = try load()
            return [
                "today": Dates.string(Date()), "time_zone": TimeZone.current.identifier,
                "base_currency": ledger.preferences.baseCurrency,
                "accounts": ledger.accounts.map { ["id": $0.id.uuidString, "name": $0.name, "currency": $0.currency, "kind": $0.kind.rawValue, "opening_balance": Money.plain($0.openingBalance), "balance": Money.plain(ledger.balance($0)), "archived": $0.archived, "conversion_fee_percent": Money.plain($0.bankFeePercent)] as [String: Any] },
                "categories": ledger.categories.map { ["name": $0.name, "type": $0.kind.rawValue] },
                "budgets": ledger.budgets.map { ["category": ledger.category($0.categoryID)?.name ?? "", "limit": Money.plain($0.limit)] },
                "goals": ledger.goals.map { ["name": $0.name, "target": Money.plain($0.target), "saved": Money.plain($0.saved), "deadline": Dates.string($0.deadline)] },
                "recurring": ledger.recurring.map { ["name": $0.name, "amount": Money.plain($0.amount), "account": ledger.account($0.accountID)?.name ?? "", "frequency": $0.frequency.rawValue, "next_date": Dates.string($0.nextDate), "active": $0.active] as [String: Any] },
                "import_history": ledger.importHistory.map { ["id": $0.id.uuidString, "name": $0.filename, "source": $0.source, "transactions": $0.transactions.count, "rolled_back": $0.rolledBackAt != nil] as [String: Any] },
                "rates_missing": ledger.missingCurrencies
            ]
        case "preview_entries", "add_entries", "import_csv":
            let table = try normalizedTable ?? self.table(command, arguments: arguments)
            let allowCategories = arguments["allow_new_categories"] as? Bool ?? false
            let dryRun = command == "preview_entries" || (command == "import_csv" && (arguments["dry_run"] as? Bool ?? true))
            if dryRun {
                let prepared = try prepare(table, ledger: load(), allowCategories: allowCategories, conversions: conversions)
                return preview(prepared, saved: false)
            }
            var result: CSVImportResult?
            _ = try LedgerFile.mutate(at: fileURL) { ledger in
                var prepared = try prepare(table, ledger: ledger, allowCategories: allowCategories, conversions: conversions)
                guard prepared.invalid == 0 else {
                    let issues = prepared.rows.filter { $0.error != nil }.prefix(10).map { "Строка \($0.id): \($0.error!)" }.joined(separator: "\n")
                    throw LedgerError.invalid("Ничего не записано: исправьте ошибки.\n" + issues)
                }
                do {
                    let existing = Set(ledger.transactions.map(\.id))
                    try prepared.ledger.recordImport(addedIDs: Set(prepared.ledger.transactions.map(\.id)).subtracting(existing),
                                                      filename: command == "import_csv" ? "CSV через MCP" : "Операции через MCP", source: "MCP", totalRows: table.rows.count,
                                                      duplicates: prepared.duplicates, invalid: prepared.invalid)
                }
                ledger = prepared.ledger
                result = prepared
            }
            return preview(result!, saved: true)
        case "create_account":
            let name = try string(arguments, "name", max: 256)
            let currency = try string(arguments, "currency").uppercased()
            let opening = try decimal(arguments, "opening_balance")
            guard let kind = AccountKind(rawValue: try string(arguments, "kind")) else { throw LedgerError.invalid("Неизвестный тип счета.") }
            var created = false
            let ledger = try LedgerFile.mutate(at: fileURL) { ledger in
                let matches = ledger.accounts.filter { equal($0.name, name) }
                if let existing = matches.first {
                    guard matches.count == 1, existing.currency == currency, existing.openingBalance == opening, existing.kind == kind else { throw LedgerError.invalid("Счет с таким названием уже существует с другими параметрами. Выберите другое название.") }
                } else { ledger.accounts.append(Account(name: name, currency: currency, kind: kind, openingBalance: opening)); created = true }
            }
            let account = ledger.accounts.first { equal($0.name, name) }!
            return ["status": created ? "created" : "already_exists", "id": account.id.uuidString, "name": account.name, "currency": account.currency]
        case "set_budget":
            let name = try string(arguments, "category", max: 256)
            let limit = try decimal(arguments, "limit")
            let ledger = try LedgerFile.mutate(at: fileURL) { ledger in
                guard let category = ledger.categories.first(where: { equal($0.name, name) && $0.kind == .expense }) else { throw LedgerError.invalid("Нет такой категории расходов.") }
                if let i = ledger.budgets.firstIndex(where: { $0.categoryID == category.id }) { ledger.budgets[i].limit = limit }
                else { ledger.budgets.append(Budget(categoryID: category.id, limit: limit)) }
            }
            return ["status": "saved", "category": name, "limit": Money.plain(limit), "currency": ledger.preferences.baseCurrency]
        case "create_goal":
            let id = try stableID(arguments)
            let name = try string(arguments, "name", max: 256)
            let target = try decimal(arguments, "target")
            let saved = try decimal(arguments, "saved")
            let deadline = try isoDate(arguments, "deadline")
            let goal = Goal(id: id, name: name, target: target, saved: saved, deadline: deadline)
            let ledger = try LedgerFile.mutate(at: fileURL) { ledger in
                if let existing = ledger.goals.first(where: { $0.id == id }) { guard existing == goal else { throw LedgerError.invalid("request_id уже использован с другими данными.") }; return }
                guard !ledger.goals.contains(where: { equal($0.name, name) }) else { throw LedgerError.invalid("Цель с таким названием уже существует.") }
                ledger.goals.append(goal)
            }
            return ["status": "saved", "id": id.uuidString, "name": name, "currency": ledger.preferences.baseCurrency]
        case "create_recurring":
            let id = try stableID(arguments)
            let name = try string(arguments, "name", max: 256)
            let amount = try decimal(arguments, "amount")
            let accountName = try string(arguments, "account", max: 256)
            let categoryName = try string(arguments, "category", required: false, max: 256)
            let nextDate = try isoDate(arguments, "next_date")
            guard let frequency = Frequency(rawValue: try string(arguments, "frequency")) else { throw LedgerError.invalid("Некорректная периодичность.") }
            let ledger = try LedgerFile.mutate(at: fileURL) { ledger in
                let account = try account(named: accountName, ledger: ledger)
                let category = categoryName.isEmpty ? nil : ledger.categories.first { equal($0.name, categoryName) && $0.kind == .expense }
                guard categoryName.isEmpty || category != nil else { throw LedgerError.invalid("Нет такой категории расходов.") }
                var payment = RecurringPayment(name: name, amount: amount, accountID: account.id, categoryID: category?.id, frequency: frequency, nextDate: nextDate)
                payment.id = id
                if let existing = ledger.recurring.first(where: { $0.id == id }) { guard existing == payment else { throw LedgerError.invalid("request_id уже использован с другими данными.") }; return }
                guard !ledger.recurring.contains(where: { equal($0.name, name) && $0.accountID == account.id }) else { throw LedgerError.invalid("Такой регулярный платеж уже существует.") }
                ledger.recurring.append(payment)
            }
            return ["status": "saved", "id": id.uuidString, "name": name, "currency": try account(named: accountName, ledger: ledger).currency]
        case "list_entries":
            let ledger = try load()
            let start = try optionalDate(arguments, "from_date")
            let end = try optionalDate(arguments, "to_date")
            guard start == nil || end == nil || start! <= end! else { throw LedgerError.invalid("Начало периода позже конца.") }
            let name = try string(arguments, "account", required: false, max: 256)
            let accountID = name.isEmpty ? nil : try account(named: name, ledger: ledger).id
            let limit = min(max(arguments["limit"] as? Int ?? 100, 1), 200)
            let matches = ledger.transactions.filter { (start == nil || $0.date >= start!) && (end == nil || $0.date <= end!) && (accountID == nil || $0.accountID == accountID! || $0.destinationAccountID == accountID!) }.sorted { $0.date > $1.date }
            return ["total": matches.count, "entries": matches.prefix(limit).map { entry($0, ledger: ledger) }, "limit": limit]
        case "monthly_summary":
            let ledger = try load()
            let monthString = try string(arguments, "month")
            guard monthString.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil, let date = Dates.parse(monthString + "-01") else { throw LedgerError.invalid("Месяц должен иметь формат YYYY-MM.") }
            let summary = ledger.summary(in: date)
            return ["month": monthString, "currency": ledger.preferences.baseCurrency, "income": Money.plain(summary.income), "expense": Money.plain(summary.expense), "net": Money.plain(summary.net), "rates_missing": ledger.missingCurrencies]
        default: throw LedgerError.invalid("Неизвестная команда.")
        }
    }
    private func table(_ command: String, arguments: [String: Any]) throws -> CSVTable {
    let table: CSVTable
    if command == "import_csv" {
        let csv = try string(arguments, "csv", max: 2_000_000)
        table = try CSVTable.parse(csv)
    } else {
        let requestID = try string(arguments, "request_id", max: 128)
        guard let entries = arguments["entries"] as? [[String: Any]], !entries.isEmpty, entries.count <= 1000 else { throw LedgerError.invalid("Нужны от 1 до 1000 операций.") }
        var lines = [Self.csvHeader]
        for (index, entry) in entries.enumerated() {
            let date = try isoDate(entry, "date")
            let merchant = try string(entry, "merchant", max: 400)
            let amount = try decimal(entry, "amount")
            let kind = try string(entry, "type")
            guard let transactionKind = TransactionKind(rawValue: kind),
                  transactionKind == .income ? amount > 0 : amount < 0 else { throw LedgerError.invalid("Проверьте тип и знак суммы операции \(index + 1).") }
            let currency = try string(entry, "currency").uppercased()
            let account = try string(entry, "account", max: 256)
            let category = try string(entry, "category", required: false, max: 256)
            let note = try string(entry, "note", required: false, max: 16_000)
            let tags = entry["tags"] as? [String] ?? []
            guard tags.count <= 30, tags.allSatisfy({ !$0.contains("|") && $0.count <= 128 }) else { throw LedgerError.invalid("Некорректные теги.") }
            let external = try string(entry, "id", required: false, max: 256)
            let to = try string(entry, "to_account", required: false, max: 256)
            let toAmount = try string(entry, "to_amount", required: false, max: 80)
            guard kind == "transfer" || (to.isEmpty && toAmount.isEmpty) else { throw LedgerError.invalid("Счет назначения допускается только у перевода.") }
            lines.append([Dates.string(date), merchant, Money.plain(amount), currency, account, category, kind, note, tags.joined(separator: "|"), external.isEmpty ? "mcp:\(requestID):\(index + 1)" : external, to, toAmount].map(Self.escape).joined(separator: ","))
        }
        table = try CSVTable.parse(lines.joined(separator: "\r\n") + "\r\n")
    }
    guard table.headers == Self.csvHeader.components(separatedBy: ","), table.rows.count <= 10_000 else { throw LedgerError.invalid("Ожидается стандартный CSV Mora с 12 колонками и не более 10000 строк.") }
        return table
    }

    public static let csvHeader = "date,merchant,amount,currency,account,category,type,note,tags,id,to_account,to_amount"
    private static func escape(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private func equal(_ lhs: String, _ rhs: String) -> Bool { lhs.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }
    private func account(named name: String, ledger: Ledger) throws -> Account {
        let matches = ledger.accounts.filter { equal($0.name, name) }
        guard matches.count == 1, !matches[0].archived else { throw LedgerError.invalid("Счет «\(name)» не найден, неоднозначен или архивирован. Используйте точное название активного счета.") }
        return matches[0]
    }
    private func string(_ arguments: [String: Any], _ key: String, required: Bool = true, max: Int = 128) throws -> String {
        guard let value = arguments[key] as? String else {
            if !required, arguments[key] == nil || arguments[key] is NSNull { return "" }
            throw LedgerError.invalid("Поле \(key) должно быть строкой.")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= max, !required || !trimmed.isEmpty else { throw LedgerError.invalid("Проверьте поле \(key).") }
        return trimmed
    }
    private func decimal(_ args: [String: Any], _ key: String) throws -> Decimal {
        let text = try string(args, key, max: 80)
        guard text.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil, let amount = Money.parse(text) else { throw LedgerError.invalid("Поле \(key): нужна сумма строкой с десятичной точкой.") }
        return amount
    }
    private func isoDate(_ args: [String: Any], _ key: String) throws -> Date {
        let value = try string(args, key)
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil, let date = Dates.parse(value) else { throw LedgerError.invalid("Поле \(key): нужна существующая дата YYYY-MM-DD.") }
        return date
    }
    private func optionalDate(_ args: [String: Any], _ key: String) throws -> Date? {
        let value = try string(args, key, required: false)
        return value.isEmpty ? nil : try isoDate(args, key)
    }
    private func stableID(_ args: [String: Any]) throws -> UUID {
        let request = try string(args, "request_id", max: 128)
        var bytes = Array(SHA256.hash(data: Data(("mora:" + request).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let slices = [(0,8),(8,4),(12,4),(16,4),(20,12)].map { offset, length in String(hex.dropFirst(offset).prefix(length)) }
        return UUID(uuidString: slices.joined(separator: "-"))!
    }
    private func prepare(_ table: CSVTable, ledger: Ledger, allowCategories: Bool, conversions: [Int: CardConversion] = [:]) throws -> CSVImportResult {
        var corrected = table
        for i in corrected.rows.indices {
            guard corrected.rows[i].count == 12 else { continue }
            do {
                let source = try account(named: corrected.rows[i][4], ledger: ledger)
                corrected.rows[i][4] = source.name
                let standalone = ["transfer_in", "transfer_out"].contains(corrected.rows[i][6])
                if !standalone && !corrected.rows[i][10].isEmpty { corrected.rows[i][10] = try account(named: corrected.rows[i][10], ledger: ledger).name }
                guard standalone || TransactionKind(rawValue: corrected.rows[i][6]) != nil else { throw LedgerError.invalid("Тип должен быть expense, income или transfer.") }
                _ = try isoDate(["date": corrected.rows[i][0]], "date")
                let category = corrected.rows[i][5].trimmingCharacters(in: .whitespacesAndNewlines)
                let kind = corrected.rows[i][6].lowercased()
                if !allowCategories, !category.isEmpty, kind != "transfer",
                   !ledger.categories.contains(where: { equal($0.name, category) && $0.kind.rawValue == kind }) { throw LedgerError.invalid("Неизвестная категория «\(category)». Используйте существующую или разрешите создание новой явно.") }
            } catch { throw LedgerError.invalid("Строка \(i + 2): \(error.localizedDescription)") }
        }
        var mapping = CSVMapping(headers: corrected.headers); mapping.skipDuplicates = false
        var result = try CSVImporter.prepare(corrected, mapping: mapping, ledger: ledger, conversions: conversions)
        var candidates = Array(result.ledger.transactions.dropFirst(ledger.transactions.count))
        let successfulRows = result.rows.filter { $0.error == nil && !$0.excluded }
        guard candidates.count == successfulRows.count else { throw LedgerError.invalid("Не удалось сопоставить пересчет со строками импорта.") }
        for index in candidates.indices { if let conversion = conversions[successfulRows[index].id - 2] { candidates[index].conversion = conversion } }
        result.ledger.transactions = ledger.transactions; result.imported = 0; result.duplicates = 0
        var identifiers: [String: Transaction] = [:]
        var contentMatches = CSVContentMatches(ledger: ledger)
        for existing in ledger.transactions {
            identifiers["\(existing.accountID)|\(existing.externalID ?? existing.id.uuidString)"] = existing
        }
        for transaction in candidates {
            let fingerprint = CSVImporter.fingerprint(transaction, ledger: result.ledger)
            if let id = transaction.externalID {
                let key = "\(transaction.accountID)|\(id)"
                if let existing = identifiers[key] {
                    guard CSVImporter.fingerprint(existing, ledger: result.ledger) == fingerprint,
                          existing.categoryID == transaction.categoryID, existing.note == transaction.note, existing.tags == transaction.tags, existing.conversion == transaction.conversion else {
                        throw LedgerError.invalid("ID \(id) уже использован для другой операции. Ничего не записано.")
                    }
                    result.duplicates += 1; continue
                }
                identifiers[key] = transaction
            } else if contentMatches.consume(fingerprint) { result.duplicates += 1; continue }
            result.ledger.transactions.append(transaction); result.imported += 1
        }
        return result
    }
    private func preview(_ result: CSVImportResult, saved: Bool) -> sending [String: Any] {
        ["saved": saved, "valid": result.invalid == 0, "imported": result.imported, "duplicates": result.duplicates, "invalid": result.invalid,
         "issues": result.rows.filter { $0.error != nil }.prefix(100).map { ["row": $0.id, "error": $0.error!] as [String: Any] }]
    }
    private func entry(_ value: Transaction, ledger: Ledger) -> sending [String: Any] {
        ["id": value.id.uuidString, "date": Dates.string(value.date), "merchant": value.merchant, "amount": Money.plain(value.amount),
         "currency": ledger.account(value.accountID)?.currency ?? "", "account": ledger.account(value.accountID)?.name ?? "",
         "category": ledger.category(value.categoryID)?.name ?? "", "type": value.kind.rawValue, "note": value.note,
         "tags": value.tags, "external_id": value.externalID ?? "", "to_account": value.destinationAccountID.flatMap { ledger.account($0)?.name } ?? "",
         "to_amount": value.destinationAmount.map(Money.plain) ?? "",
         "original_amount": value.conversion.map { Money.plain($0.originalAmount) } ?? Money.plain(value.amount),
         "original_currency": value.conversion?.originalCurrency ?? ledger.account(value.accountID)?.currency ?? "",
         "bank_fee_percent": value.conversion.map { Money.plain($0.feePercent) } ?? "0",
         "exchange_rate": value.conversion.map { Money.plain($0.rate) } ?? "1", "exchange_provider": value.conversion?.provider ?? ""]
    }
}
