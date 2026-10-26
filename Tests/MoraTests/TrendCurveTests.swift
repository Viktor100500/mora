import AppKit
import XCTest
import SwiftUI
@testable import FinanceCore
@testable import Mora

final class TrendCurveTests: XCTestCase {
    func testDaysAndWeeksHaveFixedTopologyAndPreserveActualEndpointValues() {
        let month = Dates.parse("2026-10-01")!
        var ledger = Ledger.empty
        let account = Account(name: "Synthetic")
        ledger.accounts = [account]
        ledger.transactions = [
            Transaction(date: month, merchant: "First", amount: -10, accountID: account.id),
            Transaction(date: Dates.parse("2026-10-26")!, merchant: "Last week", amount: -20, accountID: account.id),
            Transaction(date: Dates.parse("2026-10-31")!, merchant: "Last day", amount: -30, accountID: account.id)
        ]
        let days = ledger.trend(ending: month, detail: .days)
        let weeks = ledger.trend(ending: month, detail: .weeks)
        let daily = TrendCurveGeometry(days), weekly = TrendCurveGeometry(weeks)
        XCTAssertEqual(daily.expense.values.count, weekly.expense.values.count)
        XCTAssertEqual(daily.expense.values.first!, days.first!.expense.double / daily.upper, accuracy: 1e-10)
        XCTAssertEqual(daily.expense.values.last!, days.last!.expense.double / daily.upper, accuracy: 1e-10)
        XCTAssertEqual(weekly.expense.values.last!, weeks.last!.expense.double / weekly.upper, accuracy: 1e-10)
        XCTAssertEqual(daily.position(days.last!.date), 1, accuracy: 1e-10)
        XCTAssertEqual(weekly.position(weeks.last!.date), 1, accuracy: 1e-10)
        var delta = weekly.expense - daily.expense
        delta.scale(by: 0.5)
        let intermediate = daily.expense + delta
        XCTAssertTrue(intermediate.values.allSatisfy { $0.isFinite && (0...1).contains($0) })
        XCTAssertGreaterThan(delta.magnitudeSquared, 0)
        let path = TrendCurveShape(samples: intermediate, baseline: 0).path(in: CGRect(x: 0, y: 0, width: 600, height: 250))
        XCTAssertGreaterThan(path.boundingRect.width, 599)
        XCTAssertGreaterThanOrEqual(path.boundingRect.minY, -0.0001)
        XCTAssertLessThanOrEqual(path.boundingRect.maxY, 250.0001)
    }

    func testIrregularBucketSpacingNeverIntroducesOvershootOrNegativeExpenses() {
        let x = [0.0, 0.08, 0.73, 1.0], y = [0.0, 0.9, 0.1, 0.4]
        let curve = TrendCurveGeometry.sample(x: x, y: y)
        for (index, value) in curve.values.enumerated() {
            let position = Double(index) / Double(TrendCurveVector.count - 1)
            let segment = min(x.count - 2, x.indices.dropLast().last(where: { x[$0] <= position }) ?? 0)
            XCTAssertTrue(value.isFinite)
            XCTAssertGreaterThanOrEqual(value, min(y[segment], y[segment + 1]) - 1e-10)
            XCTAssertLessThanOrEqual(value, max(y[segment], y[segment + 1]) + 1e-10)
        }
    }

    func testEmptyFlatAndSingleBucketCurvesStayFinite() {
        XCTAssertEqual(TrendCurveGeometry([]).income, .zero)
        let flat = TrendCurveGeometry.sample(x: [0, 1], y: [0.4, 0.4])
        XCTAssertTrue(flat.values.allSatisfy { abs($0 - 0.4) < 1e-10 })
        let single = TrendCurveGeometry.sample(x: [0], y: [0.7])
        XCTAssertTrue(single.values.allSatisfy { $0 == 0.7 })
        var scaled = single
        scaled.scale(by: 0.5)
        XCTAssertEqual(scaled.magnitudeSquared, single.magnitudeSquared / 4, accuracy: 1e-10)
    }
    @MainActor func testChangingAggregationKeepsPlotInsetAndSizeStable() async throws {
        _ = NSApplication.shared
        let month = Dates.parse("2026-10-01")!
        var ledger = Ledger.empty
        ledger.preferences.baseCurrency = "USD"; ledger.preferences.rates = ["USD": 1]
        let account = Account(name: "Synthetic", currency: "USD"); ledger.accounts = [account]
        for (day, amount) in [(1, 50), (3, -12), (6, -40), (10, 20), (13, -30), (19, -10), (25, -45), (26, -20)] {
            let date = Calendar.current.date(byAdding: .day, value: day - 1, to: month)!
            ledger.transactions.append(Transaction(date: date, merchant: "Synthetic purchase", amount: Decimal(amount),
                accountID: account.id, kind: amount > 0 ? .income : .expense))
        }
        var inset: CGFloat?
        func chart(_ detail: TrendDetail) -> some View {
            TrendChart(ledger: ledger, month: month, cachedTrend: ledger.trend(ending: month, detail: detail), detail: detail)
                .frame(width: 700, height: 280).padding(20)
                .onPreferenceChange(ChartPlotInsetKey.self) { inset = $0 }
                .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light)
                .transaction { $0.disablesAnimations = true; $0.animation = nil }
        }
        let host = NSHostingView(rootView: chart(.days))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<40 where inset == nil { try await Task.sleep(for: .milliseconds(5)) }
        host.layoutSubtreeIfNeeded()
        let dailyInset = try XCTUnwrap(inset), dailySize = host.fittingSize
        if let prefix = ProcessInfo.processInfo.environment["MORA_CURVE_SNAPSHOT"] {
            try snapshot(host, path: prefix + "-days.png")
        }
        host.rootView = chart(.weeks)
        try await Task.sleep(for: .milliseconds(500)); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(inset), dailyInset, accuracy: 0.5)
        XCTAssertEqual(host.fittingSize, dailySize)
        if let prefix = ProcessInfo.processInfo.environment["MORA_CURVE_SNAPSHOT"] {
            try snapshot(host, path: prefix + "-weeks.png")
        }
    }

    @MainActor private func snapshot<Content: View>(_ host: NSHostingView<Content>, path: String) throws {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

}
