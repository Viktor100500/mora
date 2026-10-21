import XCTest
import os
@testable import FinanceCore

final class AutomationTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("ledger.json") }
    private var automation: MoraAutomation { MoraAutomation(fileURL: file) }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraAutomation-\(UUID())")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func createAccounts() throws {
        _ = try automation.run("create_account", arguments: ["name": "Test bank, RSD", "currency": "RSD", "opening_balance": "1000", "kind": "checking"])
        _ = try automation.run("create_account", arguments: ["name": "Euros", "currency": "EUR", "opening_balance": "50", "kind": "cash"])
    }
    private func entry(_ amount: String = "-125.50", merchant: String = "Кафе, \"Белград\"") -> [String: Any] {
        ["date": "2026-10-11", "merchant": merchant, "amount": amount, "currency": "RSD", "account": "Test bank, RSD", "type": "expense", "category": "Кафе и рестораны", "note": "one\ntwo", "tags": ["личное"]]
    }
    private func read() throws -> Ledger { try LedgerFile.decode(Data(contentsOf: file)) }

    func testPreviewDoesNotWriteAndRetryPreservesSeparateIdenticalPurchases() throws {
        try createAccounts()
        let before = try Data(contentsOf: file)
        let args: [String: Any] = ["request_id": "batch-1", "entries": [entry(), entry()]]
        let preview = try automation.run("preview_entries", arguments: args)
        XCTAssertEqual(preview["imported"] as? Int, 2); XCTAssertEqual(preview["saved"] as? Bool, false)
        XCTAssertEqual(try Data(contentsOf: file), before)
        let result = try automation.run("add_entries", arguments: args)
        XCTAssertEqual(result["imported"] as? Int, 2)
        let repeated = try automation.run("add_entries", arguments: args)
        XCTAssertEqual(repeated["imported"] as? Int, 0); XCTAssertEqual(repeated["duplicates"] as? Int, 2)
        let again = try automation.run("add_entries", arguments: ["request_id": "new-purchase", "entries": [entry()]])
        XCTAssertEqual(again["imported"] as? Int, 1)
        XCTAssertEqual(try read().transactions.count, 3)
        XCTAssertEqual(try read().transactions[0].amount, Decimal(string: "-125.50"))
    }
    func testInvalidBatchAndChangedIdempotencyKeySaveNothing() throws {
        try createAccounts()
        let args: [String: Any] = ["request_id": "same", "entries": [entry()]]
        _ = try automation.run("add_entries", arguments: args)
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try automation.run("add_entries", arguments: ["request_id": "same", "entries": [entry("-126")]]))
        XCTAssertEqual(try Data(contentsOf: file), before)
        var invalid = entry(); invalid["currency"] = "EUR"
        XCTAssertThrowsError(try automation.run("add_entries", arguments: ["request_id": "invalid", "entries": [entry(), invalid]]))
        XCTAssertEqual(try Data(contentsOf: file), before)
        invalid = entry(); invalid["date"] = "2026-02-30"
        XCTAssertThrowsError(try automation.run("add_entries", arguments: ["request_id": "bad-date", "entries": [entry(), invalid]]))
        XCTAssertEqual(try Data(contentsOf: file), before)
        invalid = entry(); invalid["amount"] = 10
        XCTAssertThrowsError(try automation.run("add_entries", arguments: ["request_id": "numeric", "entries": [invalid]]))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testUnknownAccountsAndCategoriesRequireExplicitCreation() throws {
        try createAccounts()
        var unknown = entry(); unknown["account"] = "Does not exist"
        XCTAssertThrowsError(try automation.run("add_entries", arguments: ["request_id": "unknown", "entries": [unknown]]))
        XCTAssertEqual(try read().accounts.count, 2)
        unknown = entry(); unknown["category"] = "Новая"
        XCTAssertThrowsError(try automation.run("add_entries", arguments: ["request_id": "new-category", "entries": [unknown]]))
        _ = try automation.run("add_entries", arguments: ["request_id": "new-category", "entries": [unknown], "allow_new_categories": true])
        XCTAssertTrue(try read().categories.contains { $0.name == "Новая" })
    }
    func testTransfersUseActualDestinationAmountAndDoNotCountAsIncome() throws {
        try createAccounts()
        var transfer = entry("-500"); transfer["type"] = "transfer"; transfer["category"] = ""
        transfer["to_account"] = "Euros"; transfer["to_amount"] = "4.25"
        _ = try automation.run("add_entries", arguments: ["request_id": "fx-transfer", "entries": [transfer]])
        let ledger = try read()
        XCTAssertEqual(ledger.balance(ledger.accounts[0], through: Dates.parse("2026-10-11")!), 500)
        XCTAssertEqual(ledger.balance(ledger.accounts[1], through: Dates.parse("2026-10-11")!), Decimal(string: "54.25"))
        let summary = ledger.summary(in: Dates.parse("2026-10-01")!)
        XCTAssertEqual(summary.income, 0); XCTAssertEqual(summary.expense, 0)
    }
    func testOwnCSVExportReimportDoesNotDuplicateUUIDIdentifiers() throws {
        try createAccounts()
        var ledger = try read()
        ledger.transactions = [Transaction(date: Dates.parse("2026-10-11")!, merchant: "Original", amount: -20, accountID: ledger.accounts[0].id)]
        try LedgerFile.save(ledger, to: file)
        let result = try automation.run("import_csv", arguments: ["csv": CSVImporter.export(ledger), "dry_run": false])
        XCTAssertEqual(result["imported"] as? Int, 0); XCTAssertEqual(result["duplicates"] as? Int, 1)
        XCTAssertEqual(try read().transactions.count, 1)
    }
    func testCSVWithoutIDsPreservesMultiplicityAndRepairsPartialImport() throws {
        try createAccounts()
        let header = "date,merchant,amount,currency,account,category,type,note,tags,id,to_account,to_amount\n"
        let row = "2026-10-09,MTA,-2.68,EUR,Euros,Транспорт,expense,,,,,\n"
        _ = try automation.run("import_csv", arguments: ["csv": header + row, "dry_run": false])
        let before = try Data(contentsOf: file)
        let preview = try automation.run("import_csv", arguments: ["csv": header + row + row, "dry_run": true])
        XCTAssertEqual(preview["imported"] as? Int, 1); XCTAssertEqual(preview["duplicates"] as? Int, 1)
        XCTAssertEqual(try Data(contentsOf: file), before)
        let repair = try automation.run("import_csv", arguments: ["csv": header + row + row, "dry_run": false])
        XCTAssertEqual(repair["imported"] as? Int, 1); XCTAssertEqual(repair["duplicates"] as? Int, 1)
        XCTAssertEqual(try read().transactions.count, 2)
        XCTAssertEqual(try read().importHistory.count, 2)
        XCTAssertTrue(try read().importHistory.allSatisfy { $0.source == "MCP" })
        let retry = try automation.run("import_csv", arguments: ["csv": header + row + row, "dry_run": false])
        XCTAssertEqual(retry["imported"] as? Int, 0); XCTAssertEqual(retry["duplicates"] as? Int, 2)
        XCTAssertEqual(try read().transactions.count, 2)
        XCTAssertEqual(try read().importHistory.count, 2)
    }
    func testGoalBudgetAndRecurringWritesAreValidatedAndIdempotent() throws {
        try createAccounts()
        _ = try automation.run("set_budget", arguments: ["category": "Продукты", "limit": "1000"])
        _ = try automation.run("set_budget", arguments: ["category": "Продукты", "limit": "1500"])
        let goal: [String: Any] = ["request_id": "goal", "name": "Отпуск", "target": "5000", "saved": "200", "deadline": "2027-05-01"]
        _ = try automation.run("create_goal", arguments: goal)
        _ = try automation.run("create_goal", arguments: goal)
        let recurring: [String: Any] = ["request_id": "rent", "name": "Аренда", "amount": "100", "account": "Euros", "category": "Дом", "frequency": "monthly", "next_date": "2026-10-31"]
        _ = try automation.run("create_recurring", arguments: recurring)
        _ = try automation.run("create_recurring", arguments: recurring)
        let ledger = try read()
        XCTAssertEqual(ledger.budgets.count, 1); XCTAssertEqual(ledger.budgets[0].limit, 1500)
        XCTAssertEqual(ledger.goals.count, 1); XCTAssertEqual(ledger.recurring.count, 1)
        XCTAssertEqual(ledger.transactions.count, 0)
        XCTAssertEqual(ledger.recurring[0].followingDate(), Dates.parse("2026-11-30"))
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try automation.run("set_budget", arguments: ["category": "Продукты", "limit": "-10"]))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testOptimisticSaveDoesNotOverwriteAnExternalEdit() throws {
        try createAccounts()
        let stale = try read()
        _ = try LedgerFile.mutate(at: file) { $0.accounts.append(Account(name: "Added externally")) }
        var local = stale; local.accounts[0].name = "Edited locally"
        XCTAssertThrowsError(try LedgerFile.save(local, to: file, expected: stale))
        XCTAssertEqual(try read().accounts.count, 3)
        XCTAssertEqual(try read().accounts[0].name, stale.accounts[0].name)
    }
    func testConcurrentWritersDoNotLoseAccounts() throws {
        let target = file
        let failures = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            do { _ = try LedgerFile.mutate(at: target) { $0.accounts.append(Account(name: "Account \(index)")) } }
            catch { failures.withLock { $0 += 1 } }
        }
        XCTAssertEqual(failures.withLock { $0 }, 0)
        XCTAssertEqual(try read().accounts.count, 24)
    }
    func testOwnDateEncodingDoesNotLookLikeAnExternalConflict() throws {
        var ledger = Ledger.empty
        ledger.goals = [Goal(name: "Precise date", target: 100, deadline: Date(timeIntervalSince1970: 1_800_000_000.123456))]
        try LedgerFile.save(ledger, to: file)
        XCTAssertTrue(try LedgerFile.equivalent(read(), ledger))
        var next = ledger
        next.accounts.append(Account(name: "New"))
        XCTAssertNoThrow(try LedgerFile.save(next, to: file, expected: ledger))
        XCTAssertEqual(try read().accounts.count, 1)
    }
}
