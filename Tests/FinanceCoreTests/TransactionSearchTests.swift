import XCTest
@testable import FinanceCore

final class TransactionSearchTests: XCTestCase {
    func testTransferDestinationAndTextFiltersKeepTotalsAndDatesConsistent() async throws {
        var ledger = Ledger.empty
        let source = Account(name: "Source"), destination = Account(name: "Destination")
        ledger.accounts = [source, destination]
        let date = Dates.parse("2026-10-10")!
        ledger.transactions = [
            Transaction(date: date, merchant: "Test cafe", amount: -12, accountID: source.id, tags: ["holiday"]),
            Transaction(date: date, merchant: "Transfer", amount: -20, accountID: source.id, kind: .transfer,
                destinationAccountID: destination.id, destinationAmount: 20),
            Transaction(date: Dates.parse("2026-09-10")!, merchant: "Earlier cafe", amount: -5, accountID: source.id)
        ]
        let snapshot = ledger
        let query = TransactionSearch(startDate: Dates.parse("2026-10-01")!, endDate: Dates.parse("2026-10-31")!, accountID: nil, kind: "all", category: "all", text: "HOLIDAY")
        let result = try await BackgroundWork.shared.perform { try query.prepare(in: snapshot) }
        XCTAssertEqual(result.rows.map(\.merchant), ["Test cafe"])
        XCTAssertEqual(result.expense, 12)
        let transfers = TransactionSearch(startDate: Dates.parse("2026-10-01")!, endDate: Dates.parse("2026-10-31")!, accountID: destination.id, kind: "all", category: "all", text: "")
        let transferResult = try await BackgroundWork.shared.perform { try transfers.prepare(in: snapshot) }
        XCTAssertEqual(transferResult.rows.map(\.merchant), ["Transfer"])
        XCTAssertEqual(transferResult.expense, 0)
    }

    @MainActor func testCancelledSearchDoesNotReturnAResult() async throws {
        let query = TransactionSearch(startDate: Date(), endDate: Date(), accountID: nil, kind: "all", category: "all", text: "")
        let task = Task { try await BackgroundWork.shared.perform { try query.prepare(in: .empty) } }
        task.cancel()
        do { _ = try await task.value; XCTFail("A cancelled search must not be published") }
        catch is CancellationError { }
    }

    func testRangeIncludesWholeFinalDayAcrossMonthsAndExportMatchesFilteredRows() throws {
        var ledger = Ledger.empty
        let account = Account(name: "Synthetic")
        ledger.accounts = [account]
        let end = Dates.parse("2026-11-02")!
        let lateOnFinalDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: end)!
        ledger.transactions = [
            Transaction(date: Dates.parse("2026-10-30")!, merchant: "Before", amount: -1, accountID: account.id),
            Transaction(date: Dates.parse("2026-10-31")!, merchant: "Start", amount: -2, accountID: account.id),
            Transaction(date: lateOnFinalDay, merchant: "End", amount: -3, accountID: account.id),
            Transaction(date: Dates.parse("2026-11-03")!, merchant: "After", amount: -4, accountID: account.id)
        ]
        let query = TransactionSearch(startDate: Dates.parse("2026-10-31")!, endDate: end, accountID: nil, kind: "all", category: "all", text: "")
        let result = try query.prepare(in: ledger)
        XCTAssertEqual(result.rows.map(\.merchant), ["End", "Start"])
        XCTAssertEqual(result.expense, 5)
        let csv = CSVImporter.export(ledger, transactions: result.rows)
        XCTAssertTrue(csv.contains("End")); XCTAssertTrue(csv.contains("Start"))
        XCTAssertFalse(csv.contains("Before")); XCTAssertFalse(csv.contains("After"))
    }

    func testSameDayRangeIncludesAllTimesAndNotesRemainSearchable() throws {
        var ledger = Ledger.empty
        let account = Account(name: "Synthetic"), date = Dates.parse("2026-10-10")!
        ledger.accounts = [account]
        ledger.transactions = [Transaction(date: date, merchant: "Cafe", amount: -10, accountID: account.id, note: "Business lunch")]
        let midday = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date)!
        let query = TransactionSearch(startDate: midday, endDate: midday, accountID: nil, kind: "all", category: "all", text: "BUSINESS")
        XCTAssertEqual(try query.prepare(in: ledger).rows.count, 1)
    }

    func testReversedDateRangeIsRejected() {
        let query = TransactionSearch(startDate: Dates.parse("2026-10-11")!, endDate: Dates.parse("2026-10-10")!, accountID: nil, kind: "all", category: "all", text: "")
        XCTAssertThrowsError(try query.prepare(in: .empty))
    }
    func testMultipleChoicesUseUnionWithinEachFilterAndIntersectionBetweenFilters() throws {
        let day = Dates.parse("2026-10-10")!
        let first = Account(name: "First"), second = Account(name: "Second"), other = Account(name: "Other")
        let food = UUID(), transport = UUID(), salary = UUID()
        var ledger = Ledger.empty
        ledger.accounts = [first, second, other]
        ledger.transactions = [
            Transaction(date: day, merchant: "Food", amount: -10, accountID: first.id, categoryID: food),
            Transaction(date: day, merchant: "Salary", amount: 100, accountID: second.id, categoryID: salary, kind: .income),
            Transaction(date: day, merchant: "Uncategorized", amount: -5, accountID: second.id),
            Transaction(date: day, merchant: "Transport", amount: -3, accountID: first.id, categoryID: transport),
            Transaction(date: day, merchant: "Other account", amount: -20, accountID: other.id, categoryID: food),
            Transaction(date: day, merchant: "Transfer", amount: -30, accountID: other.id, kind: .transfer, destinationAccountID: first.id, destinationAmount: 30)
        ]
        var query = TransactionSearch(startDate: day, endDate: day, accountIDs: [first.id, second.id],
            kinds: [.expense, .income], categoryIDs: [food, salary], includesUncategorized: true)
        let result = try query.prepare(in: ledger)
        XCTAssertEqual(Set(result.rows.map(\.merchant)), ["Food", "Salary", "Uncategorized"])
        XCTAssertEqual(result.expense, 15); XCTAssertEqual(result.income, 100)
        query.categoryIDs = []; query.includesUncategorized = false
        XCTAssertTrue(try query.prepare(in: ledger).rows.isEmpty, "Clearing all category checkboxes must match nothing")
        query.categoryIDs = nil; query.kinds = [.transfer]; query.accountIDs = [first.id, other.id]
        let transfer = try query.prepare(in: ledger)
        XCTAssertEqual(transfer.rows.map(\.merchant), ["Transfer"], "Either transfer leg may match, without duplicate rows")
        XCTAssertEqual(transfer.expense, 0); XCTAssertEqual(transfer.income, 0)
        query.accountIDs = []
        XCTAssertTrue(try query.prepare(in: ledger).rows.isEmpty)
        query.accountIDs = nil; query.kinds = []
        XCTAssertTrue(try query.prepare(in: ledger).rows.isEmpty)
    }

    func testIdenticalCopiesFollowExistingRowsRegardlessOfTheirUUID() throws {
        let day = Dates.parse("2026-10-01")!, account = Account(name: "Synthetic")
        var original = Transaction(date: day, merchant: "Purchase", amount: -10, accountID: account.id)
        original.id = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        var copy = original; copy.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var ledger = Ledger.empty; ledger.accounts = [account]; ledger.transactions = [original, copy]
        let query = TransactionSearch(startDate: day, endDate: day)
        XCTAssertEqual(try query.prepare(in: ledger).rows.map(\.id), [original.id, copy.id])
        var secondCopy = original; secondCopy.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        ledger.transactions.append(secondCopy)
        XCTAssertEqual(try query.prepare(in: ledger).rows.map(\.id), [original.id, copy.id, secondCopy.id])
    }

}
