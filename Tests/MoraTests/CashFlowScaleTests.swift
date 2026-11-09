import XCTest
import SwiftUI
import Charts
import AppKit
import FinanceCore
@testable import Mora

final class CashFlowScaleTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private func buckets(_ amounts: [Int]) -> [MonthTotal] {
        amounts.enumerated().map { index, amount in
            MonthTotal(date: origin.addingTimeInterval(Double(index) * 100), income: Decimal(amount), expense: 0)
        }
    }

    func testPeakLeavingViewportRemainsInScaleUntilItsVisibleTailLeaves() {
        let data = buckets([0, 6689, 1140, 0, 0])
        func scale(_ offset: Double) -> CashFlowScale {
            CashFlowScale(buckets: data, start: origin.addingTimeInterval(offset), duration: 100)
        }
        let before = scale(100 - 0.001), after = scale(100 + 0.001)
        XCTAssertEqual(before.upper, after.upper, accuracy: 0.01, "Crossing the peak's date must not drop straight to 1140")
        let halfway = scale(150)
        XCTAssertGreaterThan(halfway.upper, 1140 * 1.1)
        XCTAssertLessThan(halfway.upper, after.upper)
        XCTAssertEqual(scale(200).upper, 1140 * 1.1, accuracy: 0.0001)
        let sequence = stride(from: 100.0, through: 200, by: 2).map { scale($0).upper }
        for (first, next) in zip(sequence, sequence.dropFirst()) {
            XCTAssertGreaterThanOrEqual(first, next)
            XCTAssertLessThan(first - next, 200, "No large change between neighboring scroll positions")
        }
    }

    func testPeakEnteringViewportAndBothSidesOfDateBoundaryStayContinuous() {
        let data = buckets([0, 1140, 6689, 0, 0])
        let before = CashFlowScale(buckets: data, start: origin.addingTimeInterval(100 - 0.001), duration: 100)
        let after = CashFlowScale(buckets: data, start: origin.addingTimeInterval(100 + 0.001), duration: 100)
        XCTAssertEqual(before.upper, after.upper, accuracy: 0.01)
        XCTAssertGreaterThan(before.upper, 6688 * 1.1)
    }

    func testFlatSingleEmptyAndNegativeAmountsHaveValidDomains() {
        XCTAssertEqual(CashFlowScale(buckets: [], start: origin, duration: 100).domain, 0...1)
        XCTAssertEqual(CashFlowScale(buckets: buckets([0, 0]), start: origin, duration: 100).domain, 0...1)
        XCTAssertEqual(CashFlowScale(buckets: buckets([10]), start: origin, duration: 100).domain, 0...11)
        let negative = CashFlowScale(buckets: buckets([-10, -20, 5]), start: origin, duration: 200)
        XCTAssertEqual(negative.lower, -20)
        XCTAssertEqual(negative.upper, 5.5)
    }

    @MainActor private final class ScaleState: ObservableObject {
        @Published var scale = CashFlowScale(upper: 7000)
    }

    @MainActor private struct ScaleFixture: View {
        @ObservedObject var state: ScaleState
        var body: some View {
            Chart {
                LineMark(x: .value("X", 0), y: .value("Amount", 1000))
                LineMark(x: .value("X", 1), y: .value("Amount", 1000))
            }
            .foregroundStyle(Color.blue).chartXAxis(.hidden).chartYAxis(.hidden)
            .modifier(CashFlowScaleModifier(scale: state.scale))
            .frame(width: 420, height: 260).padding(20).background(.white)
        }
    }

    @MainActor func testRenderedScalePassesThroughIntermediateHeights() async throws {
        _ = NSApplication.shared
        let state = ScaleState(), host = NSHostingView(rootView: ScaleFixture(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(100))

        func lineHeight(_ label: String) throws -> Double {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let prefix = ProcessInfo.processInfo.environment["MORA_SCALE_SNAPSHOT"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: prefix + "-" + label + ".png"))
            }
            let rows = (0..<bitmap.pixelsHigh).filter { row in
                guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: row)?.usingColorSpace(.deviceRGB) else { return false }
                return color.blueComponent > 0.7 && color.redComponent < 0.3
            }
            XCTAssertFalse(rows.isEmpty)
            return Double(rows.reduce(0, +)) / Double(max(1, rows.count))
        }

        let before = try lineHeight("before")
        withAnimation(.linear(duration: 0.5)) { state.scale = CashFlowScale(upper: 1254) }
        try await Task.sleep(for: .milliseconds(150))
        let middle = try lineHeight("middle")
        try await Task.sleep(for: .milliseconds(500))
        let after = try lineHeight("after")
        XCTAssertGreaterThan(abs(middle - before), 2)
        XCTAssertGreaterThan(abs(after - middle), 2, "The vertical scale must interpolate, not jump to its final height")
        XCTAssertGreaterThan((middle - before) * (after - middle), 0, "The scale must move without bouncing")
    }
}
