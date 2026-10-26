import XCTest
import FinanceCore
@testable import Mora

@MainActor
final class ReportContinuityTests: XCTestCase {
    private func fixture() async throws -> (FinanceStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraReports-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var ledger = Ledger.empty
        ledger.preferences.automaticRates = false
        ledger.preferences.baseCurrency = "USD"; ledger.preferences.rates = ["USD": 1]
        let account = Account(name: "Synthetic account", currency: "USD", openingBalance: 100)
        ledger.accounts = [account]
        ledger.transactions = [Transaction(date: Date(), merchant: "First purchase", amount: -20,
            accountID: account.id, categoryID: ledger.categories[0].id)]
        try LedgerFile.encode(ledger).write(to: directory.appendingPathComponent("ledger.json"))
        let store = FinanceStore(directory: directory)
        await store.load()
        return (store, directory)
    }

    private func finishReports(_ store: FinanceStore) async throws {
        for _ in 0..<200 {
            if store.reports.pending.isEmpty { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Report calculations did not complete")
    }

    func testInitialLoadHasReportsAndRefreshNeverPublishesEmptyOrOpeningBalances() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = store.ledger.accounts[0], month = Dates.month(Date())
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.reportBalance(account), 80, "Initial loading ends only after the first report is ready")
        XCTAssertEqual(store.reportSummary(in: month).expense, 20)
        _ = store.reportTrend(ending: month, detail: .days)
        _ = store.reportAnalytics(in: month, detail: .days, selectedDays: [])
        try await finishReports(store)
        let value = Transaction(date: Date(), merchant: "Second purchase", amount: -5, accountID: account.id,
            categoryID: store.ledger.categories[0].id)
        expectTrue(await store.saveTransaction(value))
        // All of these reads happen before the new asynchronous generation can finish.
        XCTAssertEqual(store.reportBalance(account), 80)
        XCTAssertEqual(store.reportNetWorth, 80)
        XCTAssertEqual(store.reportSummary(in: month).expense, 20)
        XCTAssertEqual(store.reportTransactions(in: month).count, 1)
        XCTAssertEqual(store.reportRecentTransactions(in: month).count, 1)
        XCTAssertEqual(store.reportCategories(in: month).first?.amount, 20)
        XCTAssertEqual(store.reportTrend(ending: month).last?.expense, 20)
        XCTAssertEqual(store.reportTrend(ending: month, detail: .days).reduce(Decimal(0)) { $0 + $1.expense }, 20)
        XCTAssertEqual(store.reportAnalytics(in: month, detail: .days, selectedDays: []).summary.expense, 20)
        try await finishReports(store)
        XCTAssertEqual(store.reportBalance(account), 75)
        XCTAssertEqual(store.reportNetWorth, 75)
        XCTAssertEqual(store.reportSummary(in: month).expense, 25)
        XCTAssertEqual(store.reportTransactions(in: month).count, 2)
        XCTAssertEqual(store.reportRecentTransactions(in: month).count, 2)
        XCTAssertEqual(store.reportCategories(in: month).first?.amount, 25)
        XCTAssertEqual(store.reportTrend(ending: month).last?.expense, 25)
        XCTAssertEqual(store.reportTrend(ending: month, detail: .days).reduce(Decimal(0)) { $0 + $1.expense }, 25)
        XCTAssertEqual(store.reportAnalytics(in: month, detail: .days, selectedDays: []).summary.expense, 25)
        XCTAssertTrue(store.reports.pending.isEmpty, "Cached completed results must not recalculate on every view redraw")
    }

    func testARealEmptyResultReplacesPreviousDataAndConcurrentChangesReachLatestValues() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = store.ledger.accounts[0], month = Dates.month(Date())
        expectTrue(await store.update { $0.transactions.removeAll() })
        XCTAssertEqual(store.reportSummary(in: month).expense, 20)
        XCTAssertEqual(store.reportRecentTransactions(in: month).count, 1)
        try await finishReports(store)
        XCTAssertEqual(store.reportSummary(in: month).expense, 0)
        XCTAssertTrue(store.reportCategories(in: month).isEmpty)
        XCTAssertTrue(store.reportRecentTransactions(in: month).isEmpty)
        XCTAssertEqual(store.reportBalance(account), 100)
        for index in 1...5 {
            expectTrue(await store.update { $0.accounts[0].openingBalance = Decimal(100 + index) })
            _ = store.reportBalance(account)
        }
        try await finishReports(store)
        XCTAssertEqual(store.reportBalance(store.ledger.accounts[0]), 105, "Late calculations must not replace the latest generation")
    }

    func testChangingBaseCurrencyDoesNotReuseAmountsInTheOldUnit() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        expectTrue(await store.update { ledger in
            ledger.preferences.rates["EUR"] = 2
            try ledger.changeBaseCurrency(to: "EUR")
        })
        await store.prepareInitialReports()
        XCTAssertEqual(store.reportNetWorth, 40)
        XCTAssertEqual(store.reportSummary(in: Date()).expense, 10)
    }
    func testNewMonthAndAnalysisScopesAreReadyBeforePresentationChanges() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = Calendar.current.date(byAdding: .month, value: -1, to: Dates.month(Date()))!
        let account = store.ledger.accounts[0]
        let value = Transaction(date: previous, merchant: "Previous month purchase", amount: -7, accountID: account.id,
            categoryID: store.ledger.categories[0].id)
        expectTrue(await store.saveTransaction(value))
        await store.prepareReportsForPresentation(in: previous, includingAllScopes: true)
        XCTAssertEqual(store.reportSummary(in: previous).expense, 7)
        XCTAssertEqual(store.reportAnalytics(in: previous, detail: .days, selectedDays: []).summary.expense, 7)
        XCTAssertEqual(store.reportTrend(ending: previous, detail: .weeks).reduce(Decimal(0)) { $0 + $1.expense }, 7)
        await store.prepareAnalyticsForPresentation(in: previous, detail: .selectedDates, selectedDays: [1])
        XCTAssertEqual(store.reportAnalytics(in: previous, detail: .selectedDates, selectedDays: [1]).summary.expense, 7)
        await store.prepareTrendForPresentation(in: previous, detail: .days)
        XCTAssertEqual(store.reportTrend(ending: previous, detail: .days).reduce(Decimal(0)) { $0 + $1.expense }, 7)
        XCTAssertTrue(store.reports.pending.isEmpty)
    }

}
