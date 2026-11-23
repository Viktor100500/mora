import XCTest
import SwiftUI
@testable import FinanceCore
@testable import MoraiOS

@MainActor
final class CategoryDonutTests: XCTestCase {
    /// Exercise actual Charts rendering, with the same inherited spring as MonthSwitcher.
    /// Rapid replacements interrupt the previous transition while sectors appear/disappear.
    func testMonthChangesWhileCategoryChartIsRendering() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let state = ChartState()
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ChartHost(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        let ids = (0..<5).map { _ in UUID() }
        let months: [[Decimal]] = [
            [100], [70, 20, 10], [], [1, 999_999_999],
            [45, 30, 15, 9, 1], [1], [0.000001, 0.000002], [99, 1]
        ]
        for index in 0..<48 {
            let amounts = months[index % months.count]
            withAnimation(.snappy) {
                state.totals = amounts.enumerated().map { offset, amount in
                    CategoryTotal(id: ids[offset], name: "Category \(offset)", color: "orange", icon: "cart", amount: amount)
                }
            }
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(35))
        }
        // Let any remaining spring finish, including its late display-link frames.
        try await Task.sleep(for: .seconds(1))
        XCTAssertGreaterThan(host.view.bounds.width, 0)
        XCTAssertGreaterThan(host.view.bounds.height, 0)
    }
}

@MainActor
private final class ChartState: ObservableObject {
    @Published var totals: [CategoryTotal] = []
}

private struct ChartHost: View {
    @ObservedObject var state: ChartState

    var body: some View {
        VStack {
            if state.totals.isEmpty {
                Text("No expenses")
            } else {
                CategoryDonut(totals: state.totals, expense: state.totals.reduce(0) { $0 + $1.amount }, currency: "USD")
                    .frame(height: 210)
            }
        }
        .padding(16)
    }
}
