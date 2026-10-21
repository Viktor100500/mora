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
        let query = TransactionSearch(month: date, allTime: false, accountID: nil, kind: "all", category: "all", text: "HOLIDAY")
        let result = try await BackgroundWork.shared.perform { try query.prepare(in: snapshot) }
        XCTAssertEqual(result.rows.map(\.merchant), ["Test cafe"])
        XCTAssertEqual(result.expense, 12)
        let transfers = TransactionSearch(month: date, allTime: false, accountID: destination.id, kind: "all", category: "all", text: "")
        let transferResult = try await BackgroundWork.shared.perform { try transfers.prepare(in: snapshot) }
        XCTAssertEqual(transferResult.rows.map(\.merchant), ["Transfer"])
        XCTAssertEqual(transferResult.expense, 0)
    }

    @MainActor func testCancelledSearchDoesNotReturnAResult() async throws {
        let query = TransactionSearch(month: Date(), allTime: true, accountID: nil, kind: "all", category: "all", text: "")
        let task = Task { try await BackgroundWork.shared.perform { try query.prepare(in: .empty) } }
        task.cancel()
        do { _ = try await task.value; XCTFail("A cancelled search must not be published") }
        catch is CancellationError { }
    }
}
