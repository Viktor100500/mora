import XCTest
@testable import FinanceCore

final class TrendDetailTests: XCTestCase {
    private func ledger() -> Ledger {
        var ledger = Ledger.empty
        let account = Account(name: "Synthetic account")
        ledger.accounts = [account]
        ledger.transactions = [
            Transaction(date: Dates.parse("2026-10-01")!, merchant: "Income", amount: 100, accountID: account.id, kind: .income),
            Transaction(date: Dates.parse("2026-10-04")!, merchant: "First week", amount: -10, accountID: account.id),
            Transaction(date: Dates.parse("2026-10-05")!, merchant: "Monday", amount: -20, accountID: account.id),
            Transaction(date: Dates.parse("2026-10-31")!, merchant: "Last day", amount: -30, accountID: account.id),
            Transaction(date: Dates.parse("2026-09-30")!, merchant: "Previous month", amount: -999, accountID: account.id),
            Transaction(date: Dates.parse("2026-11-01")!, merchant: "Next month", amount: -999, accountID: account.id)
        ]
        return ledger
    }

    func testDailyTotalsFillEmptyDaysAndExcludeNeighboringMonths() {
        let ledger = ledger(), month = Dates.parse("2026-10-15")!
        let trend = ledger.trend(ending: month, detail: .days)
        XCTAssertEqual(trend.count, 31)
        XCTAssertEqual(trend[0].income, 100)
        XCTAssertEqual(trend[1].expense, 0)
        XCTAssertEqual(trend[3].expense, 10)
        XCTAssertEqual(trend[4].expense, 20)
        XCTAssertEqual(trend[30].expense, 30)
        XCTAssertEqual(trend.reduce(0) { $0 + $1.expense }, ledger.summary(in: month).expense)
    }

    func testWeeksStartOnMondayAndClipBothEdgesToSelectedMonth() {
        let ledger = ledger(), month = Dates.parse("2026-10-15")!
        let trend = ledger.trend(ending: month, detail: .weeks)
        XCTAssertEqual(trend.map { Calendar.current.component(.day, from: $0.date) }, [1, 5, 12, 19, 26])
        XCTAssertEqual(trend.map(\.expense), [10, 20, 0, 0, 30])
        XCTAssertEqual(trend.reduce(0) { $0 + $1.income }, ledger.summary(in: month).income)
        XCTAssertEqual(trend.reduce(0) { $0 + $1.expense }, ledger.summary(in: month).expense)
    }

    func testDetailsUseBaseCurrencyAndExcludeArchivedAccountsAndTransfers() {
        var ledger = ledger()
        let foreign = Account(name: "Synthetic EUR", currency: "EUR")
        var archived = Account(name: "Archived"); archived.archived = true
        ledger.accounts += [foreign, archived]
        ledger.preferences.rates["EUR"] = 2
        let date = Dates.parse("2026-10-05")!
        ledger.transactions += [
            Transaction(date: date, merchant: "Foreign expense", amount: -10, accountID: foreign.id),
            Transaction(date: date, merchant: "Archived expense", amount: -1000, accountID: archived.id),
            Transaction(date: date, merchant: "Transfer", amount: -50, accountID: ledger.accounts[0].id,
                kind: .transfer, destinationAccountID: foreign.id, destinationAmount: 25)
        ]
        for detail in [TrendDetail.weeks, .days] {
            let trend = ledger.trend(ending: date, detail: detail)
            XCTAssertEqual(trend.reduce(0) { $0 + $1.expense }, ledger.summary(in: date).expense)
            XCTAssertEqual(trend.reduce(0) { $0 + $1.income }, 100)
        }
    }

    func testLeapMonthAndDaylightSavingMonthHaveEveryCalendarDay() {
        for (month, count) in [("2024-02-10", 29), ("2026-11-10", 30)] {
            let trend = Ledger.empty.trend(ending: Dates.parse(month)!, detail: .days)
            XCTAssertEqual(trend.count, count)
            XCTAssertEqual(Set(trend.map(\.date)).count, count)
            XCTAssertEqual(trend.map { Calendar.current.component(.day, from: $0.date) }, Array(1...count))
        }
    }

    func testMonthlyHistoryKeepsItsPreviousLengthAndTotals() {
        let ledger = ledger(), month = Dates.parse("2026-10-01")!
        let trend = ledger.trend(ending: month, count: 12)
        XCTAssertEqual(trend.count, 12)
        XCTAssertEqual(trend.last?.date, month)
        XCTAssertEqual(trend.last?.expense, 60)
        XCTAssertEqual(trend.last?.income, 100)
    }

    func testSelectedDatesCompareOnlySelectedDaysInChronologicalOrder() {
        let ledger = ledger(), month = Dates.parse("2026-10-01")!
        let trend = ledger.trend(ending: month, detail: .selectedDates, selectedDays: [31, 1, 5])
        XCTAssertEqual(trend.map { Calendar.current.component(.day, from: $0.date) }, [1, 5, 31])
        XCTAssertEqual(trend.map(\.expense), [0, 20, 30])
        XCTAssertEqual(trend.map(\.income), [100, 0, 0])
    }

    func testSelectedRangeKeepsZeroDaysAndEmptySelectionHasNoBars() {
        let ledger = ledger(), month = Dates.parse("2026-10-01")!
        let trend = ledger.trend(ending: month, detail: .selectedDates, selectedDays: Set(4...6))
        XCTAssertEqual(trend.map { Calendar.current.component(.day, from: $0.date) }, [4, 5, 6])
        XCTAssertEqual(trend.map(\.expense), [10, 20, 0])
        XCTAssertTrue(ledger.trend(ending: month, detail: .selectedDates).isEmpty)
        XCTAssertTrue(ledger.trend(ending: Dates.parse("2026-02-01")!, detail: .selectedDates, selectedDays: [31]).isEmpty)
    }

    func testSharedAnalyticsScopeChangesCategoriesWithTheChart() {
        let ledger = ledger(), month = Dates.parse("2026-10-15")!
        for (detail, days, expense) in [
            (TrendDetail.months, Set<Int>(), Decimal(1059)),
            (.weeks, [], 60), (.days, [], 60), (.selectedDates, [4, 5], 30)
        ] {
            let report = ledger.analyticsReport(ending: month, detail: detail, selectedDays: days)
            XCTAssertEqual(report.summary.expense, expense)
            XCTAssertEqual(report.trend.reduce(0) { $0 + $1.expense }, expense)
            XCTAssertEqual(report.categories.reduce(0) { $0 + $1.amount }, expense)
        }
        let empty = ledger.analyticsReport(ending: month, detail: .selectedDates)
        XCTAssertTrue(empty.trend.isEmpty)
        XCTAssertTrue(empty.categories.isEmpty)
        XCTAssertEqual(empty.summary.expense, 0)
        XCTAssertEqual(empty.summary.income, 0)
    }

    func testSelectedCategoryReportKeepsAppearanceAndExcludesTransfersAndArchivedAccounts() {
        var ledger = ledger()
        let category = Category(name: "Synthetic category", icon: "basket", color: "orange")
        ledger.categories = [category]
        let foreign = Account(name: "EUR", currency: "EUR")
        var archived = Account(name: "Archived"); archived.archived = true
        ledger.accounts += [foreign, archived]
        ledger.preferences.rates["EUR"] = 2
        let date = Dates.parse("2026-10-05")!
        ledger.transactions += [
            Transaction(date: date, merchant: "Foreign", amount: -10, accountID: foreign.id, categoryID: category.id),
            Transaction(date: date, merchant: "Archived", amount: -1000, accountID: archived.id, categoryID: category.id),
            Transaction(date: date, merchant: "Transfer", amount: -200, accountID: ledger.accounts[0].id, categoryID: category.id, kind: .transfer, destinationAccountID: foreign.id, destinationAmount: 100)
        ]
        let report = ledger.analyticsReport(ending: date, detail: .selectedDates, selectedDays: [5])
        XCTAssertEqual(report.summary.expense, 40)
        XCTAssertEqual(report.summary.count, 2)
        let total = report.categories.first { $0.id == category.id }
        XCTAssertEqual(total?.amount, 20)
        XCTAssertEqual(total?.icon, "basket")
        XCTAssertEqual(total?.color, "orange")
        XCTAssertEqual(report.categories.reduce(0) { $0 + $1.amount }, report.summary.expense)
        XCTAssertEqual(report.trend.reduce(0) { $0 + $1.expense }, report.summary.expense)
    }
}
