import XCTest
@testable import FinanceCore

final class FinanceCoreTests: XCTestCase {
    private func date(_ value: String) -> Date { Dates.parse(value)! }
    private func basicLedger() -> Ledger {
        var l = Ledger.empty
        l.accounts = [Account(name: "Основной", openingBalance: 1000), Account(name: "Сбережения", kind: .savings)]
        return l
    }
    private func prepare(_ csv: String, ledger: Ledger? = nil, configure: (inout CSVMapping) -> Void = { _ in }) throws -> CSVImportResult {
        let l = ledger ?? basicLedger()
        let table = try CSVTable.parse(csv)
        var mapping = CSVMapping(headers: table.headers, defaultAccountID: l.accounts.first?.id)
        configure(&mapping)
        return try CSVImporter.prepare(table, mapping: mapping, ledger: l)
    }

    func testDecimalMoneyDoesNotLoseCents() {
        XCTAssertEqual(Money.parse("0.10")! + Money.parse("0.20")!, Money.parse("0.30"))
        XCTAssertEqual(Money.parse("−1 234,56 ₽"), Decimal(string: "-1234.56"))
        XCTAssertEqual(Money.parse("$1,234.56"), Decimal(string: "1234.56"))
        XCTAssertEqual(Money.parse("1.234,56"), Decimal(string: "1234.56"))
        XCTAssertEqual(Money.parse("(42.50)"), Decimal(string: "-42.50"))
        XCTAssertNil(Money.parse("abc123")); XCTAssertNil(Money.parse("1,2,3")); XCTAssertNil(Money.parse("NaN"))
    }
    func testCSVQuotesBOMMultilineAndCRLF() throws {
        let csv = "\u{feff}date,merchant,amount,note\r\n2026-10-01,\"Cafe, \"\"Hello\"\"\",-123.45,\"first\nsecond\"\r\n"
        let table = try CSVTable.parse(csv)
        XCTAssertEqual(table.headers, ["date", "merchant", "amount", "note"])
        XCTAssertEqual(table.rows.count, 1); XCTAssertEqual(table.rows[0][1], "Cafe, \"Hello\""); XCTAssertEqual(table.rows[0][3], "first\nsecond")
    }
    func testSemicolonCSVAndDecimalComma() throws {
        let result = try prepare("дата;описание;сумма\n01.10.2026;Магазин;-123,45\n")
        XCTAssertEqual(result.imported, 1); XCTAssertEqual(result.ledger.transactions[0].amount, Decimal(string: "-123.45"))
    }
    func testUTF16AndWindows1251() throws {
        let csv = "дата;описание;сумма\n01.10.2026;Продукты;-100\n"
        let utf16 = try XCTUnwrap(csv.data(using: .utf16))
        XCTAssertEqual(try CSVTable.read(utf16).rows[0][1], "Продукты")
        let legacy = try XCTUnwrap(csv.data(using: .windowsCP1251))
        XCTAssertEqual(try CSVTable.read(legacy).rows[0][1], "Продукты")
    }
    func testBrokenQuotesAreRejected() {
        XCTAssertThrowsError(try CSVTable.parse("date,merchant,amount\n2026-10-01,\"Cafe,-10"))
        XCTAssertThrowsError(try CSVTable.parse("date,merchant,amount\n2026-10-01,\"Cafe\"x,-10"))
        XCTAssertThrowsError(try CSVTable.parse("date,merchant,amount\n2026-10-01,Ca\"fe,-10"))
    }
    func testStrictDatesAndExplicitSlashConvention() {
        XCTAssertNil(Dates.parse("2026-02-30")); XCTAssertNotNil(Dates.parse("2024-02-29")); XCTAssertNil(Dates.parse("01/02/2026"))
        XCTAssertEqual(Dates.parse("01/02/2026", format: "dd/MM/yyyy"), date("2026-02-01"))
        XCTAssertEqual(Dates.parse("01/02/2026", format: "MM/dd/yyyy"), date("2026-01-02"))
    }
    func testPreviewDoesNotChangeOriginalAndInvalidRowsDoNotCreateAccounts() throws {
        let l = basicLedger()
        let result = try prepare("date,merchant,amount,account,currency,category\n2026-10-01,One,-100,New,FAKE,NewCategory\n2026-10-02,Two,-50,Основной,RUB,Продукты\n", ledger: l)
        XCTAssertEqual(result.invalid, 1); XCTAssertEqual(result.imported, 1); XCTAssertEqual(l.transactions.count, 0)
        XCTAssertEqual(result.ledger.accounts.count, l.accounts.count); XCTAssertEqual(result.ledger.categories.count, l.categories.count)
    }
    func testInvalidColumnCountAndDuplicateMappings() throws {
        let result = try prepare("date,merchant,amount\n2026-10-01,Cafe,-10,extra\n")
        XCTAssertEqual(result.invalid, 1); XCTAssertEqual(result.imported, 0)
        XCTAssertThrowsError(try prepare("date,merchant,amount\n2026-10-01,Cafe,-10\n", configure: { $0.columns[.note] = $0.columns[.merchant] }))
    }
    func testIncomeExpenseAndExplicitType() throws {
        let result = try prepare("date,merchant,amount,type\n2026-10-01,Salary,500,income\n2026-10-02,Cafe,100,expense\n2026-10-03,Unknown,-10,bad\n")
        XCTAssertEqual(result.imported, 2); XCTAssertEqual(result.invalid, 1)
        let summary = result.ledger.summary(in: date("2026-10-01"))
        XCTAssertEqual(summary.income, 500); XCTAssertEqual(summary.expense, 100); XCTAssertEqual(summary.net, 400)
    }
    func testSeparateDebitCreditColumns() throws {
        let result = try prepare("date,merchant,debit,credit\n2026-10-01,Salary,,500\n2026-10-02,Cafe,50,\n2026-10-03,Ambiguous,20,30\n")
        XCTAssertEqual(result.imported, 2); XCTAssertEqual(result.invalid, 1)
        XCTAssertEqual(result.ledger.summary(in: date("2026-10-01")).net, 450)
    }
    func testPositiveExpenseConvention() throws {
        let result = try prepare("date,merchant,amount\n2026-10-01,Cafe,50\n", configure: { $0.positiveIsExpense = true })
        XCTAssertEqual(result.ledger.transactions.first?.kind, .expense); XCTAssertEqual(result.ledger.transactions.first?.amount, -50)
    }
    func testIdenticalPurchasesWithoutIDsArePreservedAndReimportIsIdempotent() throws {
        let csv = "date,merchant,amount\n2026-10-01,Cafe,-50\n2026-10-01,Cafe,-50\n"
        let first = try prepare(csv)
        XCTAssertEqual(first.imported, 2); XCTAssertEqual(first.duplicates, 0)
        XCTAssertEqual(first.ledger.summary(in: date("2026-10-01")).expense, 100)
        let second = try prepare(csv, ledger: first.ledger)
        XCTAssertEqual(second.imported, 0); XCTAssertEqual(second.duplicates, 2)
        let allowed = try prepare(csv, configure: { $0.skipDuplicates = false })
        XCTAssertEqual(allowed.imported, 2)
    }
    func testReimportAddsOnlyMissingOccurrencesAfterPartialImport() throws {
        let header = "date,merchant,amount\n"
        let ninth = "2026-10-09,MTA,-2.68\n", tenth = "2026-10-10,MTA,-2.68\n"
        let partial = try prepare(header + ninth + tenth)
        let csv = header + ninth + tenth + tenth + ninth
        let repair = try prepare(csv, ledger: partial.ledger)
        XCTAssertEqual(repair.imported, 2); XCTAssertEqual(repair.duplicates, 2)
        XCTAssertEqual(repair.ledger.transactions.count, 4)
        XCTAssertEqual(repair.ledger.summary(in: date("2026-10-01")).expense, Decimal(string: "10.72"))
        let retry = try prepare(csv, ledger: repair.ledger)
        XCTAssertEqual(retry.imported, 0); XCTAssertEqual(retry.duplicates, 4)
    }
    func testInvalidRowsDoNotConsumeExistingContentMatches() throws {
        let original = try prepare("date,merchant,amount\n2026-10-09,MTA,-2.68\n").ledger
        let csv = "date,merchant,amount\n2026-10-09,MTA,-2.68,extra\n2026-10-09,MTA,-2.68\n2026-10-09,MTA,-2.68\n"
        let result = try prepare(csv, ledger: original)
        XCTAssertEqual(result.invalid, 1); XCTAssertEqual(result.duplicates, 1); XCTAssertEqual(result.imported, 1)
    }
    func testDistinctExternalIDsAllowIdenticalPurchases() throws {
        let csv = "date,merchant,amount,id\n2026-10-01,Cafe,-50,a\n2026-10-01,Cafe,-50,b\n2026-10-01,Cafe,-50,a\n"
        let first = try prepare(csv)
        XCTAssertEqual(first.imported, 2); XCTAssertEqual(first.duplicates, 1)
        let second = try prepare(csv, ledger: first.ledger)
        XCTAssertEqual(second.imported, 0); XCTAssertEqual(second.duplicates, 3)
    }
    func testRulesAndExplicitCategories() throws {
        var l = basicLedger(); l.rules = [CategoryRule(keyword: "cafe", categoryID: l.categories[1].id)]
        let result = try prepare("date,merchant,amount,category\n2026-10-01,CAFE,-50,\n2026-10-02,Cafe,-20,Покупки\n", ledger: l)
        XCTAssertEqual(result.ledger.transactions[0].categoryID, l.categories[1].id)
        XCTAssertEqual(result.ledger.category(result.ledger.transactions[1].categoryID)?.name, "Покупки")
    }
    func testTransfersKeepTotalAndDoNotAffectCashflow() throws {
        let result = try prepare("date,merchant,amount,account,type,to_account\n2026-10-01,Transfer,-300,Основной,transfer,Сбережения\n")
        let l = result.ledger
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(l.balance(l.accounts[0], through: date("2026-10-02")), 700)
        XCTAssertEqual(l.balance(l.accounts[1], through: date("2026-10-02")), 300)
        XCTAssertEqual(l.summary(in: date("2026-10-01")).expense, 0)
        XCTAssertEqual(l.summary(in: date("2026-10-01")).income, 0)
    }
    func testCrossCurrencyTransfersAndCurrencyMismatch() throws {
        var l = basicLedger(); l.accounts.append(Account(name: "Dollars", currency: "USD")); l.preferences.rates["USD"] = 100
        let r = try prepare("date,merchant,amount,currency,account,type,to_account,to_amount\n2026-10-01,Exchange,-500,RUB,Основной,transfer,Dollars,5\n2026-10-01,Error,-20,USD,Основной,expense,,\n", ledger: l)
        XCTAssertEqual(r.imported, 1); XCTAssertEqual(r.invalid, 1)
        XCTAssertEqual(r.ledger.balance(r.ledger.accounts[2], through: date("2026-10-02")), 5)
        XCTAssertEqual(r.ledger.netWorth, 1000)
    }
    func testTransferRequiresDestinationAndSameCurrencyEquality() throws {
        let result = try prepare("date,merchant,amount,account,type,to_account,to_amount\n2026-10-01,Invalid,-100,Основной,transfer,,\n2026-10-01,Invalid2,-100,Основной,transfer,Сбережения,90\n")
        XCTAssertEqual(result.invalid, 2); XCTAssertEqual(result.imported, 0)
    }
    func testExportReimportIsIdempotentAndPreservesNotes() throws {
        var l = basicLedger()
        l.transactions = [Transaction(date: date("2026-10-01"), merchant: "Cafe, Hello", amount: -50, accountID: l.accounts[0].id, note: "first\n\"second\"", tags: ["one", "two"])]
        let result = try prepare(CSVImporter.export(l), ledger: l)
        XCTAssertEqual(result.imported, 0); XCTAssertEqual(result.duplicates, 1)
        var empty = l; empty.transactions = []
        let imported = try prepare(CSVImporter.export(l), ledger: empty)
        XCTAssertEqual(imported.ledger.transactions[0].note, l.transactions[0].note); XCTAssertEqual(imported.ledger.transactions[0].tags, ["one", "two"])
    }
    func testFutureTransactionsDoNotChangeTodaysBalance() {
        var l = basicLedger()
        l.transactions = [Transaction(date: date("2030-01-01"), merchant: "Future", amount: -100, accountID: l.accounts[0].id)]
        XCTAssertEqual(l.balance(l.accounts[0], through: date("2026-10-11")), 1000)
        XCTAssertEqual(l.summary(in: date("2030-01-01")).expense, 100)
    }
    func testBaseCurrencyChangeConvertsBudgetsGoalsAndRates() throws {
        var l = basicLedger(); l.preferences.rates["USD"] = 100
        l.budgets = [Budget(categoryID: l.categories[0].id, limit: 20_000)]
        l.goals = [Goal(name: "Test", target: 100_000, saved: 50_000, deadline: date("2027-01-01"))]
        try l.changeBaseCurrency(to: "USD")
        XCTAssertEqual(l.preferences.baseCurrency, "USD"); XCTAssertEqual(l.preferences.rates["RUB"], Decimal(string: "0.01"))
        XCTAssertEqual(l.budgets[0].limit, 200); XCTAssertEqual(l.goals[0].target, 1000); XCTAssertEqual(l.goals[0].saved, 500)
        XCTAssertEqual(l.netWorth, 10); XCTAssertThrowsError(try l.changeBaseCurrency(to: "EUR"))
    }
    func testMissingRateIsExplicitAndNotAssumedToBeOne() {
        var l = basicLedger(); l.accounts.append(Account(name: "USD", currency: "USD", openingBalance: 100))
        XCTAssertEqual(l.missingCurrencies, ["USD"]); XCTAssertNil(l.convert(1, currency: "USD")); XCTAssertEqual(l.netWorth, 1000)
        XCTAssertTrue(l.insights(in: date("2026-10-01")).first!.contains("USD"))
    }
    func testRecurringMonthEndKeepsAnchor() {
        var p = RecurringPayment(name: "Rent", amount: 100, accountID: UUID(), nextDate: date("2026-01-31"))
        XCTAssertEqual(p.followingDate(), date("2026-02-28"))
        p.nextDate = p.followingDate(); XCTAssertEqual(p.followingDate(), date("2026-03-31"))
    }
    func testYearlyLeapDateAndWeeklyFrequency() {
        let p = RecurringPayment(name: "Test", amount: 100, accountID: UUID(), frequency: .yearly, nextDate: date("2024-02-29"))
        XCTAssertEqual(p.followingDate(), date("2025-02-28"))
        let w = RecurringPayment(name: "Weekly", amount: 100, accountID: UUID(), frequency: .weekly, nextDate: date("2026-10-01"))
        XCTAssertEqual(w.followingDate(), date("2026-10-08"))
    }
    func testRoundtripAndAtomicBackup() throws {
        let l = Ledger.demo(now: date("2026-10-11"))
        XCTAssertEqual(try LedgerFile.decode(LedgerFile.encode(l)), l)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json")
        try LedgerFile.save(l, to: url)
        var changed = l; changed.accounts[0].openingBalance += 1
        let saved = try LedgerFile.save(changed, to: url)
        XCTAssertEqual(try LedgerFile.decode(Data(contentsOf: url)), saved)
        XCTAssertEqual(saved.accounts, changed.accounts)
        XCTAssertEqual(saved.undoCount, 1)
        XCTAssertEqual(try LedgerFile.decode(Data(contentsOf: url.appendingPathExtension("backup"))), l)
    }
    func testBackupValidationRejectsDanglingReferencesAndSchema() throws {
        var l = basicLedger(); l.transactions = [Transaction(date: date("2026-10-01"), merchant: "Test", amount: -10, accountID: UUID())]
        XCTAssertThrowsError(try l.validate()); XCTAssertThrowsError(try LedgerFile.encode(l))
        l.transactions = []; l.schemaVersion = 99; XCTAssertThrowsError(try l.validate())
        l = basicLedger(); l.preferences.rates["USD"] = -1; XCTAssertThrowsError(try l.validate())
    }
    func testBudgetExpensesExcludeTransfersAndIncome() {
        var l = basicLedger(); let c = l.categories[0].id
        l.transactions = [Transaction(date: date("2026-10-01"), merchant: "Food", amount: -100, accountID: l.accounts[0].id, categoryID: c), Transaction(date: date("2026-09-30"), merchant: "Previous", amount: -50, accountID: l.accounts[0].id, categoryID: c)]
        XCTAssertEqual(l.spent(category: c, in: date("2026-10-01")), 100)
        XCTAssertEqual(l.categoryTotals(in: date("2026-10-01")).first?.amount, 100)
    }
    func testChartsCombineSmallCategoryShares() {
        func total(_ name: String, _ amount: Decimal) -> CategoryTotal { CategoryTotal(id: UUID(), name: name, color: "blue", icon: "tag", amount: amount) }
        let grouped = [total("Rent", 900), total("Food", 60), total("Taxi", 30), total("Books", 10)].groupingSmallShares(name: "Other")
        XCTAssertEqual(grouped.map(\.name), ["Rent", "Food", "Other"])
        XCTAssertEqual(grouped.last?.amount, 40); XCTAssertEqual(grouped.last?.id, CategoryTotal.otherID)
        XCTAssertEqual([total("Rent", 960), total("Taxi", 40)].groupingSmallShares().count, 2, "A single small category keeps its own slice")
    }
    func testLargeCSVStagesAllRowsWithoutDroppingOperations() throws {
        let rows = (0..<10_000).map { "2026-10-01,Purchase \($0),-0.10,bank-\($0)" }
        let result = try prepare((["date,merchant,amount,id"] + rows).joined(separator: "\n"))
        XCTAssertEqual(result.imported, 10_000); XCTAssertEqual(result.invalid, 0)
        XCTAssertEqual(result.ledger.summary(in: date("2026-10-01")).expense, 1000)
    }
}
