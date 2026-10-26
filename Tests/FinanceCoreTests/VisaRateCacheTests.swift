import XCTest
@testable import FinanceCore

@MainActor
final class VisaRateCacheTests: XCTestCase {
    private let date = Dates.parse("2026-10-25")!

    func testDiskCacheSurvivesRestartAndSeparatesPairDateAndUTCDay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VisaCache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rates.json")
        let now = Dates.parse("2026-10-25T18:00:00Z") ?? date.addingTimeInterval(18 * 3600)
        var calls = 0
        let client = VisaRateClient(cacheURL: file, now: { now }) { _, _, _ in calls += 1; return Decimal(string: "0.9")! }
        let first = try await client.conversion(amount: -10, from: "USD", to: "EUR", date: date)
        XCTAssertEqual(try first.convertedAmount(), -9)
        let changedAmount = try await client.conversion(amount: -20, from: "USD", to: "EUR", date: date)
        let feeAccount = Account(name: "Fee", currency: "EUR", conversionFeePercent: 1)
        XCTAssertEqual(try changedAmount.applyingFee(of: feeAccount).convertedAmount(), Decimal(string: "-18.18"))
        XCTAssertEqual(calls, 1)
        let restarted = VisaRateClient(cacheURL: file, now: { now }) { _, _, _ in
            XCTFail("The disk cache must survive a restart"); throw URLError(.notConnectedToInternet)
        }
        let restored = try await restarted.conversion(amount: 30, from: "USD", to: "EUR", date: date)
        XCTAssertEqual(try restored.convertedAmount(), 27)
        _ = try await client.rate(from: "EUR", to: "USD", date: date)
        _ = try await client.rate(from: "USD", to: "EUR", date: date.addingTimeInterval(-86_400))
        XCTAssertEqual(calls, 3)
        let tomorrow = now.addingTimeInterval(86_400)
        let nextDay = VisaRateClient(cacheURL: file, now: { tomorrow }) { _, _, _ in calls += 1; return 1 }
        let refreshed = try await nextDay.rate(from: "USD", to: "EUR", date: date)
        XCTAssertEqual(refreshed, 1)
        XCTAssertEqual(calls, 4)
    }

    func testCancelledPreviewSharesFetchWithSaveAndStillWarmsCache() async throws {
        var calls = 0
        var resume: CheckedContinuation<Decimal, Never>?
        let client = VisaRateClient(cacheURL: nil) { _, _, _ in
            calls += 1
            return await withCheckedContinuation { resume = $0 }
        }
        let date = date
        let preview = Task { try await client.conversion(amount: -10, from: "USD", to: "EUR", date: date) }
        for _ in 0..<100 where resume == nil { try await Task.sleep(for: .milliseconds(5)) }
        let continuation = try XCTUnwrap(resume)
        let save = Task { try await client.conversion(amount: -20, from: "USD", to: "EUR", date: date) }
        try await Task.sleep(for: .milliseconds(20))
        preview.cancel()
        continuation.resume(returning: Decimal(string: "0.9")!)
        do { _ = try await preview.value; XCTFail("Cancelled preview must not publish") } catch is CancellationError { }
        let converted = try await save.value
        XCTAssertEqual(try converted.convertedAmount(), -18)
        XCTAssertEqual(calls, 1)
        _ = try await client.conversion(amount: -50, from: "USD", to: "EUR", date: date)
        XCTAssertEqual(calls, 1)
    }

    func testFailuresAndCorruptCacheCanBeRetried() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("VisaCorrupt-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("broken".utf8).write(to: file)
        var calls = 0
        let client = VisaRateClient(cacheURL: file) { _, _, _ in
            calls += 1
            if calls == 1 { throw URLError(.notConnectedToInternet) }
            if calls == 2 { return 0 }
            return 1
        }
        for _ in 0..<2 {
            do { _ = try await client.rate(from: "USD", to: "EUR", date: date); XCTFail("Invalid quotes must fail") } catch { }
        }
        let rate = try await client.rate(from: "USD", to: "EUR", date: date)
        XCTAssertEqual(rate, 1)
        XCTAssertEqual(calls, 3)
    }
}
