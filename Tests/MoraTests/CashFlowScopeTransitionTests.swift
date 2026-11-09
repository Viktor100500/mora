import AppKit
import SwiftUI
import XCTest
import FinanceCore
@testable import Mora

@MainActor final class CashFlowScopeTransitionTests: XCTestCase {
    private final class ScopeState: ObservableObject {
        @Published var detail: TrendDetail = .months
    }

    private struct Fixture: View {
        var ledger: Ledger
        var month: Date
        @ObservedObject var state: ScopeState
        var body: some View {
            TrendChart(ledger: ledger, month: month, cachedTrend: ledger.trend(ending: month, detail: state.detail),
                detail: state.detail, timeline: CashFlowTimeline(ledger: ledger, month: month, detail: state.detail))
                .frame(width: 700, height: 280).padding(20).background(.white).preferredColorScheme(.light)
        }
    }

    func testSwitchingEachDetailAfterScrollingUsesFinalScaleFromItsFirstFrame() async throws {
        _ = NSApplication.shared
        let month = Dates.parse("2026-11-01")!
        var ledger = Ledger.empty
        ledger.preferences.baseCurrency = "USD"; ledger.preferences.rates = ["USD": 1]
        let account = Account(name: "Synthetic", currency: "USD")
        ledger.accounts = [account]
        ledger.transactions = [
            Transaction(date: Dates.parse("2026-10-16")!, merchant: "Previous peak", amount: 6689, accountID: account.id, kind: .income),
            Transaction(date: Dates.parse("2026-11-16")!, merchant: "Current income", amount: 1140, accountID: account.id, kind: .income)
        ]
        let state = ScopeState(), host = NSHostingView(rootView: Fixture(ledger: ledger, month: month, state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(100))

        func input(in view: NSView) -> CashFlowInteractionLayer.InputView? {
            if let input = view as? CashFlowInteractionLayer.InputView { return input }
            return view.subviews.lazy.compactMap { input(in: $0) }.first
        }

        func curveTop(_ label: String) throws -> Double {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let prefix = ProcessInfo.processInfo.environment["MORA_SCOPE_SNAPSHOT"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: prefix + "-" + label + ".png"))
            }
            var top: Int?
            for x in stride(from: 60, to: bitmap.pixelsWide - 20, by: 12) {
                for y in 0..<(top ?? bitmap.pixelsHigh) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                    // During the crossfade the new line is intentionally pale;
                    // measure its geometry independently of its opacity.
                    if (g - r > 0.012 && g - b > 0.006) || (r - g > 0.018 && g - b > 0.01) {
                        top = y; break
                    }
                }
            }
            return Double(try XCTUnwrap(top, "The rendered curve must remain visible"))
        }

        for detail: TrendDetail in [.days, .weeks, .months] {
            let oldInput = try XCTUnwrap(input(in: host))
            oldInput.onScroll(-oldInput.bounds.width * 7)
            try await Task.sleep(for: .milliseconds(600))
            let scrolledTop = try curveTop(detail.rawValue + "-scrolled")
            AppMotion.update { state.detail = detail }
            try await Task.sleep(for: .milliseconds(90))
            let firstFrame = try curveTop(detail.rawValue + "-first")
            try await Task.sleep(for: .milliseconds(450))
            let settled = try curveTop(detail.rawValue + "-settled")
            XCTAssertFalse(input(in: host) === oldInput, "Changing aggregation must discard the previous viewport and scale state")
            XCTAssertLessThan(settled, scrolledTop - 20, "The selected month must be restored after scrolling")
            // Fading a steep antialiased stroke can hide a few edge pixels;
            // reusing the old scale instead displaces the curve by most of the plot.
            XCTAssertEqual(firstFrame, settled, accuracy: 8, "A mode transition must not first display the previous scale and then jump")
        }
    }
}
