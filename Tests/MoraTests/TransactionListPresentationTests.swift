import XCTest
import FinanceCore
@testable import Mora

final class TransactionListPresentationTests: XCTestCase {
    func testCopiesAndSelectionPublishTogetherAfterPersistenceAndFiltering() throws {
        let day = Dates.parse("2026-10-01")!, account = Account(name: "Synthetic")
        var ledger = Ledger.empty; ledger.accounts = [account]
        let original = Transaction(date: day, merchant: "Original", amount: -10, accountID: account.id)
        ledger.transactions = [original]
        let query = TransactionSearch(startDate: day, endDate: day)
        var state = TransactionListPresentation()
        state.apply(try query.prepare(in: ledger)); state.selection = [original.id]
        XCTAssertTrue(state.beginDuplication())
        XCTAssertFalse(state.beginDuplication(), "Do not accept overlapping clicks during the same duplication")
        var copy = original; copy.id = UUID()
        state.completedDuplication([copy.id])
        XCTAssertEqual(state.rows.map(\.id), [original.id])
        XCTAssertEqual(state.selection, [original.id], "Do not deselect originals while copies are still absent")
        ledger.transactions.append(copy)
        state.apply(try query.prepare(in: ledger))
        XCTAssertEqual(state.visibleIDs, [original.id, copy.id])
        XCTAssertEqual(state.selection, [copy.id])
        XCTAssertEqual(state.expense, 20)
        XCTAssertFalse(state.duplicating)
    }

    func testFailureCanRetryAndChangedFilterDoesNotSelectInvisibleCopies() throws {
        let day = Dates.parse("2026-10-01")!, account = Account(name: "Synthetic")
        var ledger = Ledger.empty; ledger.accounts = [account]
        let original = Transaction(date: day, merchant: "Original", amount: -10, accountID: account.id)
        ledger.transactions = [original]
        var state = TransactionListPresentation()
        let query = TransactionSearch(startDate: day, endDate: day)
        state.apply(try query.prepare(in: ledger)); state.selection = [original.id]
        XCTAssertTrue(state.beginDuplication())
        state.completedDuplication(nil)
        XCTAssertFalse(state.duplicating)
        XCTAssertEqual(state.selection, [original.id])
        XCTAssertTrue(state.beginDuplication())
        state.completedDuplication([UUID()])
        var differentFilter = query; differentFilter.kinds = [.income]
        state.apply(try differentFilter.prepare(in: ledger))
        XCTAssertTrue(state.selection.isEmpty)
        XCTAssertTrue(state.rows.isEmpty)
        XCTAssertFalse(state.duplicating)
    }
}
