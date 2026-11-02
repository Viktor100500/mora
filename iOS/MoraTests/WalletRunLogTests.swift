import XCTest
@testable import MoraiOS

final class WalletRunLogTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appending(path: "WalletRuns-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testEachRunIsKeptSeparatelyNewestFirst() throws {
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        try WalletRunLog.record(amount: " $3.00 ", merchant: "MTA", card: "Chase", at: start, in: directory)
        try WalletRunLog.record(amount: "$3.00", merchant: "MTA", card: "Chase", at: start, in: directory)
        try WalletRunLog.record(amount: nil, merchant: "  ", card: nil, at: start.addingTimeInterval(15), in: directory)

        let runs = WalletRunLog.runs(in: directory)
        XCTAssertEqual(runs.count, 3, "identical payments at the same moment are separate runs")
        XCTAssertEqual(runs.first?.receivedAt, start.addingTimeInterval(15))
        XCTAssertEqual(runs.first?.isComplete, false)
        XCTAssertEqual(runs.first?.merchant, "")
        XCTAssertEqual(runs.last?.amount, "$3.00")
        XCTAssertEqual(runs.last?.isComplete, true)
    }

    func testOldRunsArePrunedAndClearRemovesAll() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        try WalletRunLog.record(amount: "$1", merchant: "Old", card: "", at: now.addingTimeInterval(-15 * 86_400), in: directory)
        try WalletRunLog.record(amount: "$2", merchant: "New", card: "", at: now, in: directory)
        XCTAssertEqual(WalletRunLog.runs(in: directory).map(\.merchant), ["New"])

        WalletRunLog.clear(in: directory)
        XCTAssertTrue(WalletRunLog.runs(in: directory).isEmpty)
    }
}
