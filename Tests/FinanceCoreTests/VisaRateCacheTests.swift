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
    func testFallbackSurvivesRestartPreservesPurchaseDateAndSkipsRepeatedFailedRequests() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("VisaFallback-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let date = date
        let seed = VisaRateClient(cacheURL: file, now: { date }) { _, _, _ in Decimal(string: "0.9")! }
        _ = try await seed.conversion(amount: -10, from: "USD", to: "EUR", date: date)
        let tomorrow = date.addingTimeInterval(86_400)
        var calls = 0
        let offline = VisaRateClient(cacheURL: file, now: { tomorrow }) { _, _, _ in
            calls += 1; throw URLError(.notConnectedToInternet)
        }
        let fallback = try await offline.conversion(amount: -20, from: "USD", to: "EUR", date: tomorrow)
        XCTAssertEqual(fallback.date, tomorrow)
        XCTAssertEqual(fallback.cachedRateDate, date)
        XCTAssertEqual(try fallback.convertedAmount(), -18)
        let note = fallback.annotating("Original note")
        XCTAssertTrue(note.contains(Dates.string(date)))
        XCTAssertEqual(fallback.annotating(note), note)
        let saved = try JSONDecoder().decode(CardConversion.self, from: JSONEncoder().encode(fallback))
        XCTAssertEqual(saved, fallback)
        _ = try await offline.conversion(amount: -30, from: "USD", to: "EUR", date: tomorrow)
        XCTAssertEqual(calls, 1)
        do { _ = try await offline.rate(from: "EUR", to: "USD", date: tomorrow); XCTFail("Never invert or substitute a different pair") } catch { }
        XCTAssertEqual(calls, 2)
        let recovered = VisaRateClient(cacheURL: file, now: { tomorrow }) { _, _, _ in 1 }
        let fresh = try await recovered.conversion(amount: -20, from: "USD", to: "EUR", date: tomorrow)
        XCTAssertNil(fresh.cachedRateDate)
        XCTAssertEqual(fresh.rate, 1)
    }

    func testTotalDeadlineFallsBackEvenWhenFetcherIgnoresCancellation() async throws {
        let date = date
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("VisaTimeout-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let seed = VisaRateClient(cacheURL: file, now: { date }) { _, _, _ in 1 }
        _ = try await seed.rate(from: "USD", to: "EUR", date: date)
        let tomorrow = date.addingTimeInterval(86_400)
        var resume: CheckedContinuation<Decimal, Never>?
        let slow = VisaRateClient(cacheURL: file, now: { tomorrow }, timeout: 0.03) { _, _, _ in
            await withCheckedContinuation { resume = $0 }
        }
        let start = ContinuousClock.now
        let result = try await slow.conversion(amount: -7, from: "USD", to: "EUR", date: tomorrow)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(result.cachedRateDate, date)
        resume?.resume(returning: 9)
        await Task.yield()
        let again = try await slow.conversion(amount: -7, from: "USD", to: "EUR", date: tomorrow)
        XCTAssertEqual(again.rate, 1, "A late callback cannot replace the timed-out quote")
    }

    func testLegacyCacheMigratesAndRetainsOtherPairsOnRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VisaMigration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("old.json"), file = directory.appendingPathComponent("new.json")
        let date = date
        let day = Int(floor(date.timeIntervalSince1970 / 86_400))
        let key = "\(day)|\(Dates.string(date))|USD|EUR"
        try JSONEncoder().encode([key: Decimal(string: "0.9")!]).write(to: old)
        let tomorrow = date.addingTimeInterval(86_400)
        let client = VisaRateClient(cacheURL: file, legacyCacheURL: old, now: { tomorrow }) { _, _, _ in throw URLError(.timedOut) }
        let migrated = try await client.conversion(amount: -10, from: "USD", to: "EUR", date: tomorrow)
        XCTAssertEqual(migrated.cachedRateDate, date)
        try FileManager.default.removeItem(at: old)
        let other = VisaRateClient(cacheURL: file, now: { tomorrow }) { _, _, _ in 150 }
        _ = try await other.rate(from: "USD", to: "JPY", date: tomorrow)
        let restarted = VisaRateClient(cacheURL: file, now: { tomorrow }) { _, _, _ in throw URLError(.timedOut) }
        let retained = try await restarted.conversion(amount: -10, from: "USD", to: "EUR", date: tomorrow)
        XCTAssertEqual(retained.rate, Decimal(string: "0.9"))
    }

}
