import XCTest
import FinanceCore
@testable import MoraiOS

@MainActor
final class FinanceStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraiOSTests-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func personalStore() async -> FinanceStore {
        let store = FinanceStore(directory: directory, forcedDemo: false)
        await store.load()
        XCTAssertTrue(store.isDemo, "A missing ledger opens the demo first")
        let started = await store.startClean(baseCurrency: "USD")
        XCTAssertTrue(started)
        return store
    }

    func testFreshInstallShowsDemoWithoutWritingAFile() async {
        let store = FinanceStore(directory: directory, forcedDemo: false)
        await store.load()
        XCTAssertTrue(store.isDemo)
        XCTAssertFalse(store.ledger.transactions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testStartCleanCreatesPersonalLedgerOnDisk() async throws {
        let store = await personalStore()
        XCTAssertFalse(store.isDemo)
        XCTAssertEqual(store.baseCurrency, "USD")
        XCTAssertTrue(store.ledger.accounts.isEmpty)
        let saved = try LedgerFile.decode(Data(contentsOf: store.fileURL))
        XCTAssertEqual(saved.preferences.baseCurrency, "USD")
    }

    func testPurchaseFeeRepricesHistoryAndNewExpensesWithoutCompounding() async throws {
        let store = await personalStore()
        let account = Account(name: "Card", currency: "USD", openingBalance: 100)
        let added = await store.update { replaceOrAppend(account, in: &$0.accounts) }; XCTAssertTrue(added)
        let old = Transaction(date: .now, merchant: "Old", amount: -3, accountID: account.id)
        let oldSaved = await store.saveTransaction(old); XCTAssertTrue(oldSaved)
        let changed = await store.update { try $0.setPurchaseFee(2, accountID: account.id) }; XCTAssertTrue(changed)
        XCTAssertEqual(store.ledger.transactions.first?.amount, Decimal(string: "-3.06"))
        let purchase = Transaction(date: .now, merchant: "New", amount: -10, accountID: account.id)
        let savedOK = await store.saveTransaction(purchase); XCTAssertTrue(savedOK)
        let saved = try XCTUnwrap(store.ledger.transactions.first { $0.id == purchase.id })
        XCTAssertEqual(saved.amount, Decimal(string: "-10.20"))
        var edited = saved; edited.merchant = "Edited"; edited.amount = try XCTUnwrap(saved.sameCurrencyFee?.originalAmount)
        let editedOK = await store.saveTransaction(edited, original: saved); XCTAssertTrue(editedOK)
        XCTAssertEqual(store.ledger.transactions.first { $0.id == purchase.id }?.amount, Decimal(string: "-10.20"))
    }

    func testTransactionLifecycleWithUndo() async throws {
        let store = await personalStore()
        let account = Account(name: "Card", currency: "USD", openingBalance: 100)
        let added = await store.update { replaceOrAppend(account, in: &$0.accounts) }
        XCTAssertTrue(added)
        let groceries = try XCTUnwrap(store.ledger.categories.first { $0.name == "Продукты" })
        let purchase = Transaction(date: Date(), merchant: "Whole Foods", amount: -25, accountID: account.id, categoryID: groceries.id)
        let saved = await store.saveTransaction(purchase)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.balance(store.ledger.accounts[0]), 75)
        XCTAssertEqual(store.summary(in: Date()).expense, 25)

        var edited = purchase
        edited.amount = -40
        let updated = await store.saveTransaction(edited, original: purchase)
        XCTAssertTrue(updated)
        XCTAssertEqual(store.balance(store.ledger.accounts[0]), 60)

        await store.deleteTransactions([purchase.id])
        XCTAssertTrue(store.ledger.transactions.isEmpty)
        XCTAssertEqual(store.balance(store.ledger.accounts[0]), 100)

        await store.undo()
        XCTAssertEqual(store.ledger.transactions.first?.amount, -40)
        let reloaded = try LedgerFile.decode(Data(contentsOf: store.fileURL))
        XCTAssertEqual(reloaded.transactions.count, 1)
    }

    func testSplitKeepsTotalAndCategoriesTransactionsAutomatically() async throws {
        let store = await personalStore()
        let account = Account(name: "Card", currency: "USD")
        await store.update { replaceOrAppend(account, in: &$0.accounts) }
        let groceries = try XCTUnwrap(store.ledger.categories.first { $0.name == "Продукты" })
        let home = try XCTUnwrap(store.ledger.categories.first { $0.name == "Дом" })
        await store.update { $0.rules = [CategoryRule(keyword: "market", categoryID: groceries.id)] }
        let purchase = Transaction(date: Date(), merchant: "Corner Market", amount: -30, accountID: account.id)
        await store.saveTransaction(purchase)
        XCTAssertEqual(store.ledger.transactions.first?.categoryID, groceries.id, "Rules categorize a new purchase")

        let stored = try XCTUnwrap(store.ledger.transactions.first)
        let split = await store.split(stored, firstAmount: 10, firstCategory: groceries.id, secondCategory: home.id)
        XCTAssertTrue(split)
        XCTAssertEqual(store.ledger.transactions.count, 2)
        XCTAssertEqual(store.ledger.transactions.reduce(Decimal(0)) { $0 + $1.amount }, -30)
        XCTAssertEqual(Set(store.ledger.transactions.compactMap(\.categoryID)), [groceries.id, home.id])
    }

    func testArchivedAccountLeavesNetWorth() async {
        let store = await personalStore()
        let main = Account(name: "Main", currency: "USD", openingBalance: 500)
        let old = Account(name: "Old", currency: "USD", openingBalance: 200)
        await store.update { $0.accounts = [main, old] }
        XCTAssertEqual(store.netWorth, 700)
        await store.setAccountArchived(old.id, archived: true)
        XCTAssertEqual(store.netWorth, 500)
        await store.deleteArchivedAccount(old.id)
        XCTAssertEqual(store.ledger.accounts.map(\.id), [main.id])
    }

    func testArchivePreservesOctoberTotalsCalendarAndRecentTransactions() async throws {
        let store = await personalStore()
        let account = Account(name: "Old card", currency: "USD")
        let october = Dates.parse("2026-10-10")!
        await store.update { $0.accounts = [account] }
        let purchase = Transaction(date: october, merchant: "October purchase", amount: -40, accountID: account.id,
            categoryID: store.ledger.categories[0].id)
        let income = Transaction(date: october, merchant: "October income", amount: 100, accountID: account.id, kind: .income)
        await store.saveTransaction(purchase)
        await store.saveTransaction(income)
        XCTAssertEqual(store.summary(in: october).expense, 40)
        XCTAssertEqual(store.dailyExpenses(in: october)[10], 40)
        await store.setAccountArchived(account.id, archived: true)
        XCTAssertEqual(store.summary(in: october).expense, 40)
        XCTAssertEqual(store.summary(in: october).income, 100)
        XCTAssertEqual(store.dailyExpenses(in: october)[10], 40)
        XCTAssertEqual(Set(store.recentTransactions(in: october).map(\.id)), [purchase.id, income.id])
        XCTAssertEqual(store.categoryTotals(in: october).first?.amount, 40)
        XCTAssertEqual(store.analyticsReport(in: october, detail: .selectedDates, selectedDays: [10]).summary.expense, 40)
        let added = await store.saveTransaction(Transaction(date: Date(), merchant: "Blocked", amount: -1, accountID: account.id))
        XCTAssertFalse(added)
        let reopened = FinanceStore(directory: directory, forcedDemo: false)
        await reopened.load()
        XCTAssertEqual(reopened.summary(in: october).expense, 40)
        XCTAssertEqual(reopened.dailyExpenses(in: october)[10], 40)
    }

    func testCSVImportRecordsBatchAndRollsBack() async throws {
        let store = await personalStore()
        let account = Account(name: "Card", currency: "USD")
        await store.update { replaceOrAppend(account, in: &$0.accounts) }
        let table = try CSVTable.parse("date,merchant,amount\n2026-10-01,Coffee,-4.5\n2026-10-02,Salary,1000\n")
        var mapping = CSVMapping(headers: table.headers, defaultAccountID: account.id, currency: "USD")
        mapping.skipDuplicates = true
        let expected = store.ledger
        let prepared = try await CSVImporter.prepareAsync(table, mapping: mapping, ledger: expected)
        let imported = await store.importPreparedCSV(prepared, filename: "bank.csv", expected: expected)
        XCTAssertTrue(imported)
        XCTAssertEqual(store.ledger.transactions.count, 2)
        let batch = try XCTUnwrap(store.imports.batches.first)
        XCTAssertEqual(batch.filename, "bank.csv")
        await store.rollbackImport(batch.id)
        XCTAssertTrue(store.ledger.transactions.isEmpty)
    }

    func testBackupRoundTripMatchesMacFormat() async throws {
        let store = await personalStore()
        await store.update { replaceOrAppend(Account(name: "Cash", currency: "EUR", kind: .cash, openingBalance: 12), in: &$0.accounts) }
        let backup = await store.backupData()
        let data = try XCTUnwrap(backup)
        let decoded = try LedgerFile.decode(data)
        XCTAssertEqual(decoded.accounts.first?.name, "Cash")
        await store.update { $0.accounts.removeAll() }
        await store.restore(decoded)
        XCTAssertEqual(store.ledger.accounts.first?.currency, "EUR")
    }

    func testReportsFollowLedgerChanges() async {
        let store = await personalStore()
        let account = Account(name: "Card", currency: "USD")
        await store.update { replaceOrAppend(account, in: &$0.accounts) }
        XCTAssertEqual(store.summary(in: Date()).income, 0)
        await store.saveTransaction(Transaction(date: Date(), merchant: "Salary", amount: 900, accountID: account.id, kind: .income))
        XCTAssertEqual(store.summary(in: Date()).income, 900, "The cache is reset when the ledger changes")
        XCTAssertEqual(store.trend(ending: Date()).last?.income, 900)
        XCTAssertEqual(store.dailyExpenses(in: Date()), [:])
    }
}
