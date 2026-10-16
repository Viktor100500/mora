import XCTest
@testable import FinanceCore

final class CardConversionTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("ledger.json") }
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraConversion-\(UUID())") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func ledger() throws -> Ledger { try LedgerFile.decode(Data(contentsOf: file)) }
    private func accounts() throws -> MoraAutomation {
        let automation = MoraAutomation(fileURL: file)
        for (name, currency) in [("USD account", "USD"), ("EUR account", "EUR")] {
            _ = try automation.run("create_account", arguments: ["name": name, "currency": currency, "opening_balance": "1000", "kind": "checking"])
        }
        return automation
    }
    private func entry(currency: String = "USD", account: String = "EUR account") -> [String: Any] {
        ["date": "2026-10-09", "merchant": "MTA", "amount": "-3", "currency": currency, "account": account, "type": "expense", "category": "Транспорт"]
    }
    private func quote(_ amount: Decimal, _ from: String, _ to: String, _ date: Date) async throws -> CardConversion {
        CardConversion(originalAmount: amount, originalCurrency: from, accountCurrency: to, rate: Decimal(string: "0.895174")!, date: date)
    }
    func testBankFeeUsesUnroundedAmountAndSurvivesLegacyDecoding() throws {
        var account = Account(name: "Fee account", currency: "EUR", conversionFeePercent: Decimal(string: "0.23"))
        let base = CardConversion(originalAmount: -10, originalCurrency: "USD", accountCurrency: "EUR", rate: Decimal(string: "0.8014")!, date: Dates.parse("2026-10-09")!)
        let charged = base.applyingFee(of: account)
        XCTAssertEqual(try charged.convertedAmount(), Decimal(string: "-8.03"))
        account.conversionFeePercent = 10
        XCTAssertEqual(try charged.convertedAmount(), Decimal(string: "-8.03"))
        var income = base; income.originalAmount = 10
        XCTAssertEqual(try income.applyingFee(of: account).convertedAmount(), Decimal(string: "8.01"))
        var invalid = charged; invalid.bankFeePercent = -1
        XCTAssertThrowsError(try invalid.convertedAmount())
        invalid.bankFeePercent = 101
        XCTAssertThrowsError(try invalid.convertedAmount())
        let legacyAccount = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(Account(name: "Legacy")))
        XCTAssertEqual(legacyAccount.bankFeePercent, 0)
        let decoded = try JSONDecoder().decode(CardConversion.self, from: JSONEncoder().encode(base))
        XCTAssertEqual(decoded.feePercent, 0)
        XCTAssertEqual(try decoded.convertedAmount(), Decimal(string: "-8.01"))
        var ledger = Ledger.empty; ledger.accounts = [account]
        ledger.accounts[0].conversionFeePercent = -1
        XCTAssertThrowsError(try ledger.validate())
    }
    func testMCPFeesArePerAccountAndRetriesKeepOriginalFee() async throws {
        let automation = try accounts()
        var initial = try ledger()
        initial.accounts[1].conversionFeePercent = Decimal(string: "0.23")
        initial.accounts.append(Account(name: "Other EUR", currency: "EUR", conversionFeePercent: 1))
        try LedgerFile.save(initial, to: file)
        let entries = [entry(), entry(account: "Other EUR"), entry().merging(["amount": "3", "type": "income", "category": "Другой доход"]) { _, new in new }]
        let arguments: [String: Any] = ["request_id": "fee-batch", "entries": entries]
        _ = try await automation.runAsync("add_entries", arguments: arguments, fetch: quote)
        var saved = try ledger()
        XCTAssertEqual(saved.transactions.map(\.amount), [Decimal(string: "-2.69")!, Decimal(string: "-2.71")!, Decimal(string: "2.69")!])
        XCTAssertEqual(saved.transactions[0].conversion?.feePercent, Decimal(string: "0.23"))
        XCTAssertEqual(saved.transactions[1].conversion?.feePercent, 1)
        XCTAssertEqual(saved.transactions[2].conversion?.feePercent, 0)
        saved.accounts[1].conversionFeePercent = 5
        saved.accounts[2].conversionFeePercent = 5
        try LedgerFile.save(saved, to: file)
        let retry = try await automation.runAsync("add_entries", arguments: arguments, fetch: { _, _, _, _ in XCTFail("Retry must retain historical fee and rate"); throw LedgerError.invalid("offline") })
        XCTAssertEqual(retry["duplicates"] as? Int, 3)
        XCTAssertEqual(try ledger().transactions, saved.transactions)
    }
    func testCSVFeesDoNotLeakBetweenAccountsAndRetryRetainsHistory() async throws {
        _ = try accounts()
        var initial = try ledger()
        initial.accounts[1].conversionFeePercent = 1
        initial.accounts.append(Account(name: "No fee EUR", currency: "EUR"))
        let table = try CSVTable.parse("date,merchant,amount,currency,account\n2026-10-09,Fee,-10,USD,EUR account\n2026-10-09,No fee,-10,USD,No fee EUR\n2026-10-09,Income,10,USD,EUR account\n")
        let mapping = CSVMapping(headers: table.headers)
        let result = try await CSVImporter.prepareAsync(table, mapping: mapping, ledger: initial, fetch: quote)
        XCTAssertEqual(result.ledger.transactions.map(\.amount), [Decimal(string: "-9.04")!, Decimal(string: "-8.95")!, Decimal(string: "8.95")!])
        var updated = result.ledger
        updated.accounts[1].conversionFeePercent = 5
        let retry = try await CSVImporter.prepareAsync(table, mapping: mapping, ledger: updated, fetch: { _, _, _, _ in XCTFail("Historical rows should retain their saved quote"); throw LedgerError.invalid("offline") })
        XCTAssertEqual(retry.duplicates, 3)
        XCTAssertEqual(retry.ledger.transactions, result.ledger.transactions)
    }
    func testRoundingUsesAccountMinorUnitsAndRejectsInvalidRates() throws {
        var conversion = CardConversion(originalAmount: Decimal(string: "-7.34")!, originalCurrency: "USD", accountCurrency: "EUR", rate: Decimal(string: "0.893894")!, date: Dates.parse("2026-10-10")!)
        XCTAssertEqual(try conversion.convertedAmount(), Decimal(string: "-6.56"))
        conversion.accountCurrency = "JPY"; conversion.rate = Decimal(string: "150.25")!
        XCTAssertEqual(try conversion.convertedAmount(), -1103)
        conversion.rate = 0
        XCTAssertThrowsError(try conversion.convertedAmount())
    }
    func testAutomaticConversionHistoryRetryAndUndo() async throws {
        let automation = try accounts()
        let arguments: [String: Any] = ["request_id": "converted", "entries": [entry(), entry()]]
        let before = try Data(contentsOf: file)
        let preview = try await automation.runAsync("preview_entries", arguments: arguments, fetch: quote)
        XCTAssertEqual(preview["imported"] as? Int, 2)
        XCTAssertEqual(try Data(contentsOf: file), before)
        _ = try await automation.runAsync("add_entries", arguments: arguments, fetch: quote)
        let saved = try ledger()
        XCTAssertEqual(saved.transactions.count, 2); XCTAssertEqual(saved.importHistory.count, 1)
        XCTAssertEqual(saved.schemaVersion, 4)
        XCTAssertEqual(saved.balance(saved.accounts[0]), 1000)
        XCTAssertEqual(saved.balance(saved.accounts[1]), Decimal(string: "994.62"))
        XCTAssertEqual(saved.transactions[0].conversion?.originalAmount, -3)
        XCTAssertEqual(saved.transactions[0].conversion?.originalCurrency, "USD")
        XCTAssertEqual(saved.importHistory[0].transactions, saved.transactions)
        let retry = try await automation.runAsync("add_entries", arguments: arguments, fetch: { _, _, _, _ in XCTFail("Retry must reuse persisted conversion"); throw LedgerError.invalid("offline") })
        XCTAssertEqual(retry["duplicates"] as? Int, 2); XCTAssertEqual(try ledger().importHistory.count, 1)
        var undone = try ledger()
        XCTAssertEqual(try undone.rollbackImport(undone.importHistory[0].id), 2)
        XCTAssertEqual(undone.balance(undone.accounts[1]), 1000)
    }
    func testSameCurrencyNeverFetchesAndMCPAddsVisibleHistory() async throws {
        let automation = try accounts()
        _ = try await automation.runAsync("add_entries", arguments: ["request_id": "same", "entries": [entry(account: "USD account")]], fetch: { _, _, _, _ in XCTFail("Same currency must not need network"); throw LedgerError.invalid("offline") })
        XCTAssertEqual(try ledger().transactions[0].amount, -3)
        XCTAssertNil(try ledger().transactions[0].conversion)
        XCTAssertEqual(try ledger().importHistory[0].filename, "Операции через MCP")
    }
    func testUnavailableAndWrongPairSaveNothing() async throws {
        let automation = try accounts()
        let before = try Data(contentsOf: file)
        do {
            _ = try await automation.runAsync("add_entries", arguments: ["request_id": "offline", "entries": [entry()]], fetch: { _, _, _, _ in throw LedgerError.invalid("offline") })
            XCTFail("Unavailable rates must reject the batch")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: file), before)
        do {
            _ = try await automation.runAsync("add_entries", arguments: ["request_id": "wrong", "entries": [entry()]], fetch: { amount, from, _, date in CardConversion(originalAmount: amount, originalCurrency: from, accountCurrency: "JPY", rate: 1, date: date) })
            XCTFail("Wrong currency pair must reject the batch")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testCorrectionPreservesIDsAndCategoryAndCreatesHistoryForLegacyBatch() async throws {
        let automation = try accounts()
        var initial = try ledger()
        initial.transactions = [Transaction(date: Dates.parse("2026-10-09")!, merchant: "MTA", amount: -3, accountID: initial.accounts[0].id, categoryID: initial.categories[2].id, note: "keep", externalID: "mcp:old:1")]
        let original = initial.transactions[0]
        initial = try LedgerFile.save(initial, to: file)
        var arguments: [String: Any] = ["request_id": "fix", "transaction_ids": [original.id.uuidString], "expected_account": "USD account", "account": "EUR account", "dry_run": true]
        _ = try await automation.runAsync("reassign_entries", arguments: arguments, fetch: quote)
        XCTAssertEqual(try ledger(), initial)
        arguments["dry_run"] = false
        _ = try await automation.runAsync("reassign_entries", arguments: arguments, fetch: quote)
        let corrected = try ledger()
        XCTAssertEqual(corrected.transactions.count, 1); XCTAssertEqual(corrected.transactions[0].id, original.id)
        XCTAssertEqual(corrected.transactions[0].categoryID, original.categoryID); XCTAssertEqual(corrected.transactions[0].note, "keep")
        XCTAssertEqual(corrected.balance(corrected.accounts[0]), 1000)
        XCTAssertEqual(corrected.balance(corrected.accounts[1]), Decimal(string: "997.31"))
        XCTAssertEqual(corrected.importHistory.count, 1)
        _ = try await automation.runAsync("reassign_entries", arguments: arguments, fetch: quote)
        XCTAssertEqual(try ledger(), corrected)
        arguments["transaction_ids"] = [original.id.uuidString, UUID().uuidString]
        do { _ = try await automation.runAsync("reassign_entries", arguments: arguments, fetch: quote); XCTFail("Missing ID must fail") } catch { }
        XCTAssertEqual(try ledger(), corrected)
    }
    func testCSVConversionPreservesMultiplicityAndExportRetry() async throws {
        _ = try accounts()
        let initial = try ledger()
        let text = "date,merchant,amount,currency,account,category,type,note,tags,id,to_account,to_amount\n2026-10-09,MTA,-3,USD,EUR account,Транспорт,expense,,,,,\n2026-10-09,MTA,-3,USD,EUR account,Транспорт,expense,,,,,\n"
        let table = try CSVTable.parse(text)
        let mapping = CSVMapping(headers: table.headers)
        let result = try await CSVImporter.prepareAsync(table, mapping: mapping, ledger: initial, fetch: quote)
        XCTAssertEqual(result.imported, 2); XCTAssertEqual(result.invalid, 0)
        XCTAssertEqual(result.rows[0].currency, "EUR")
        XCTAssertEqual(result.rows[0].conversion?.originalCurrency, "USD")
        XCTAssertEqual(result.ledger.transactions[0].amount, Decimal(string: "-2.69"))
        let retry = try await CSVImporter.prepareAsync(table, mapping: mapping, ledger: result.ledger, fetch: { _, _, _, _ in XCTFail("Repeated CSV must reuse historical quote"); throw LedgerError.invalid("offline") })
        XCTAssertEqual(retry.duplicates, 2); XCTAssertEqual(retry.imported, 0)
        try LedgerFile.save(result.ledger, to: file)
        let automation = MoraAutomation(fileURL: file)
        let exported = try await automation.runAsync("import_csv", arguments: ["csv": CSVImporter.export(result.ledger), "dry_run": false], fetch: quote)
        XCTAssertEqual(exported["duplicates"] as? Int, 2)
        XCTAssertEqual(try ledger().transactions.count, 2)
    }
    func testCSVExcludedRowsNeedNoRateOrAccountSelection() async throws {
        _ = try accounts()
        let initial = try ledger()
        let table = try CSVTable.parse("date,merchant,amount,currency,account\n2026-10-09,Skip,-3,USD,EUR account\n2026-10-09,Keep,-1,EUR,EUR account\n")
        var mapping = CSVMapping(headers: table.headers)
        mapping.excludedRows = [2]
        let result = try await CSVImporter.prepareAsync(table, mapping: mapping, ledger: initial, fetch: { _, _, _, _ in XCTFail("Excluded rows must not request conversion"); throw LedgerError.invalid("offline") })
        XCTAssertEqual(result.excluded, 1); XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.ledger.transactions[0].merchant, "Keep")
    }
}
