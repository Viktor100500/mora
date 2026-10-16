import XCTest
@testable import FinanceCore

final class AccountLifecycleTests: XCTestCase {
    private let date = Dates.parse("2026-01-10")!
    private func ledger() -> Ledger {
        var ledger = Ledger.empty
        ledger.preferences.baseCurrency = "USD"
        ledger.preferences.rates = ["USD": 1, "EUR": 2]
        ledger.accounts = [Account(name: "Card", currency: "USD", openingBalance: 100),
                           Account(name: "Investment", currency: "EUR", kind: .investment, openingBalance: 100)]
        return ledger
    }
    private func expense(_ ledger: Ledger, account: Int, amount: Decimal) -> Transaction {
        Transaction(date: date, merchant: "Purchase", amount: -amount, accountID: ledger.accounts[account].id,
                    categoryID: ledger.categories[0].id)
    }
    private func transfer(_ ledger: Ledger, from: Int, amount: Decimal, received: Decimal, date: Date? = nil) -> Transaction {
        Transaction(date: date ?? self.date, merchant: "Transfer", amount: -amount, accountID: ledger.accounts[from].id,
                    kind: .transfer, destinationAccountID: ledger.accounts[1 - from].id, destinationAmount: received)
    }

    func testArchiveExcludesOpeningBalanceIncomeExpensesBudgetsTrendAndRecurring() throws {
        var ledger = ledger()
        let removedID = ledger.accounts[1].id
        ledger.transactions = [expense(ledger, account: 0, amount: 10), expense(ledger, account: 1, amount: 20),
                               Transaction(date: date, merchant: "Salary", amount: 30, accountID: removedID, kind: .income)]
        ledger.recurring = [RecurringPayment(name: "Subscription", amount: 5, accountID: removedID, nextDate: date)]
        let original = ledger
        XCTAssertEqual(ledger.netWorth, 310)
        XCTAssertEqual(ledger.summary(in: date).expense, 50)
        try ledger.setAccountArchived(removedID, archived: true)
        XCTAssertEqual(ledger.netWorth, 90)
        XCTAssertEqual(ledger.summary(in: date).income, 0)
        XCTAssertEqual(ledger.summary(in: date).expense, 10)
        XCTAssertEqual(ledger.summary(in: date).count, 1)
        XCTAssertEqual(ledger.categoryTotals(in: date).first?.amount, 10)
        XCTAssertEqual(ledger.spent(category: ledger.categories[0].id, in: date), 10)
        XCTAssertEqual(ledger.trend(ending: date, count: 1).first?.expense, 10)
        XCTAssertEqual(ledger.monthlyRecurring, 0)
        XCTAssertEqual(ledger.transactions.count, 3)
        XCTAssertTrue(ledger.recurring[0].active)
        try ledger.setAccountArchived(removedID, archived: false)
        XCTAssertEqual(ledger, original)
    }

    func testArchiveMissingRatesAndNegativeCreditBalance() throws {
        var ledger = ledger()
        ledger.accounts[1].currency = "JPY"
        ledger.accounts[1].openingBalance = -100
        ledger.accounts[1].kind = .credit
        XCTAssertEqual(ledger.missingCurrencies, ["JPY"])
        ledger.preferences.rates["JPY"] = 1
        XCTAssertEqual(ledger.netWorth, 0)
        try ledger.setAccountArchived(ledger.accounts[1].id, archived: true)
        XCTAssertEqual(ledger.netWorth, 100)
        ledger.preferences.rates.removeValue(forKey: "JPY")
        XCTAssertTrue(ledger.missingCurrencies.isEmpty)
    }

    func testDeleteRetainsDatedTransferLegsAndNeverChangesOtherAccountsReports() throws {
        var ledger = ledger()
        let removed = ledger.accounts[1]
        ledger.transactions = [transfer(ledger, from: 0, amount: 20, received: 10),
                               transfer(ledger, from: 1, amount: 5, received: 10),
                               transfer(ledger, from: 1, amount: 2, received: 4, date: Dates.parse("2099-01-01")!),
                               expense(ledger, account: 1, amount: 3)]
        XCTAssertThrowsError(try ledger.deleteArchivedAccount(removed.id))
        try ledger.setAccountArchived(removed.id, archived: true)
        XCTAssertEqual(ledger.netWorth, 90)
        let before = ledger
        try ledger.deleteArchivedAccount(removed.id)
        XCTAssertEqual(ledger.accounts.count, 1)
        XCTAssertEqual(ledger.netWorth, before.netWorth)
        XCTAssertEqual(ledger.balance(ledger.accounts[0], through: Dates.parse("2099-01-01")!), 94)
        XCTAssertEqual(ledger.transactions.map(\.amount), [-20, 10, 4])
        XCTAssertTrue(ledger.transactions.allSatisfy { $0.isStandaloneTransfer && $0.removedTransferAccountName == removed.name })
        XCTAssertEqual(ledger.summary(in: date).income, 0)
        XCTAssertEqual(ledger.summary(in: date).expense, 0)
        XCTAssertEqual(try LedgerFile.decode(LedgerFile.encode(ledger)), ledger)
        XCTAssertTrue(try CloudMerge.same(CloudMerge.merge(base: before, local: ledger, remote: before), ledger))
        try ledger.setAccountArchived(ledger.accounts[0].id, archived: true)
        try ledger.deleteArchivedAccount(ledger.accounts[0].id)
        XCTAssertTrue(ledger.transactions.isEmpty)
    }

    func testDeletionUndoRedoSurvivesRestartImportHistoryAndCloudEcho() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ledger.json")
        var ledger = ledger()
        let removedID = ledger.accounts[1].id
        ledger.transactions = [expense(ledger, account: 1, amount: 10), transfer(ledger, from: 1, amount: 10, received: 20)]
        ledger.recurring = [RecurringPayment(name: "Subscription", amount: 5, accountID: removedID, nextDate: date)]
        try ledger.recordImport(addedIDs: Set(ledger.transactions.map(\.id)), filename: "test.csv", totalRows: 2, now: date)
        try ledger.setAccountArchived(removedID, archived: true)
        try LedgerFile.save(ledger, to: file)
        let deleted = try LedgerFile.mutate(at: file) { try $0.deleteArchivedAccount(removedID) }
        XCTAssertTrue(deleted.recurring.isEmpty)
        XCTAssertEqual(deleted.undoCount, 1)
        let echo = try LedgerFile.applyCloud(CloudMerge.shared(deleted), at: file, mergeAgainst: deleted)
        XCTAssertEqual(echo.undoCount, 1)
        var remote = echo
        remote.transactions.append(expense(echo, account: 0, amount: 1))
        let applied = try LedgerFile.applyCloud(remote, at: file, mergeAgainst: echo)
        XCTAssertEqual(applied.undoCount, 1)
        let reopened = try LedgerFile.decode(Data(contentsOf: file))
        let undone = try LedgerFile.undo(at: file, expected: reopened)
        XCTAssertEqual(undone.accounts, ledger.accounts)
        XCTAssertEqual(undone.recurring, ledger.recurring)
        XCTAssertEqual(undone.importHistory, ledger.importHistory)
        XCTAssertEqual(Set(undone.transactions.map(\.id)), Set(remote.transactions.map(\.id)).union(ledger.transactions.map(\.id)))
        let redone = try LedgerFile.redo(at: file, expected: undone)
        XCTAssertTrue(try LedgerFile.equivalent(redone, applied))
    }

    func testStandaloneTransfersRoundTripCSVWithoutTurningIntoIncomeOrExpense() throws {
        var ledger = ledger()
        ledger.transactions = [transfer(ledger, from: 0, amount: 20, received: 10), transfer(ledger, from: 1, amount: 5, received: 10)]
        try ledger.setAccountArchived(ledger.accounts[1].id, archived: true)
        try ledger.deleteArchivedAccount(ledger.accounts[1].id)
        let csv = try CSVTable.parse(CSVImporter.export(ledger))
        var empty = ledger; empty.transactions = []
        let result = try CSVImporter.prepare(csv, mapping: CSVMapping(headers: csv.headers, defaultAccountID: empty.accounts[0].id), ledger: empty)
        XCTAssertEqual(result.invalid, 0)
        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.ledger.balance(empty.accounts[0]), 90)
        XCTAssertTrue(result.ledger.transactions.allSatisfy(\.isStandaloneTransfer))
        XCTAssertEqual(result.ledger.summary(in: date).count, 0)
    }

    func testCloudConflictDropsOnlyOlderUnsafeUndoStates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ledger.json")
        let initial = ledger()
        try LedgerFile.save(initial, to: file)
        _ = try LedgerFile.mutate(at: file) { $0.accounts[0].name = "Renamed" }
        let deleted = try LedgerFile.mutate(at: file) {
            try $0.setAccountArchived(initial.accounts[1].id, archived: true)
            try $0.deleteArchivedAccount(initial.accounts[1].id)
        }
        var remote = deleted
        remote.accounts[0].name = "Remote name"
        let applied = try LedgerFile.applyCloud(remote, at: file, mergeAgainst: deleted)
        XCTAssertEqual(applied.undoCount, 1)
        let undone = try LedgerFile.undo(at: file, expected: applied)
        XCTAssertEqual(undone.accounts.count, 2)
        XCTAssertEqual(undone.accounts[0].name, "Remote name")
        XCTAssertEqual(undone.undoCount, 0)
        XCTAssertThrowsError(try LedgerFile.undo(at: file, expected: undone))
    }

    func testUnmarkedOrMalformedSingleSidedTransfersAreRejected() throws {
        var ledger = ledger()
        var value = Transaction(date: date, merchant: "Transfer", amount: -10, accountID: ledger.accounts[0].id, kind: .transfer)
        ledger.transactions = [value]
        XCTAssertThrowsError(try ledger.validate())
        value.removedTransferAccountName = "Deleted"
        value.destinationAmount = 10
        ledger.transactions = [value]
        XCTAssertThrowsError(try ledger.validate())
    }
}
