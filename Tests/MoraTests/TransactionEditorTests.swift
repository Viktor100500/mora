import AppKit
import SwiftUI
import XCTest
@testable import FinanceCore
@testable import Mora

@MainActor
final class TransactionEditorTests: XCTestCase {
    func testReviewFormDisplaysCaptureDateInsteadOfToday() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraEditor-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var ledger = Ledger.empty
        ledger.preferences.automaticRates = false
        ledger.accounts = [Account(name: "Test account", currency: "USD")]
        try LedgerFile.encode(ledger).write(to: directory.appendingPathComponent("ledger.json"))
        let store = FinanceStore(directory: directory)
        await store.load()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let capture = try decoder.decode(CloudCapture.self, from: JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "merchant": "Test purchase", "amount": "12.50", "currency": "USD",
            "account_id": ledger.accounts[0].id.uuidString, "date": "2026-10-16T20:19:00Z", "label": "Test phone"
        ]))
        let editor = WalletReviewForm(capture: capture)
            .environmentObject(store).environmentObject(CloudSync())
        let host = NSHostingView(rootView: editor.background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light).tint(.moraGreen))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 850),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        func datePickers(in view: NSView) -> [NSDatePicker] {
            (view as? NSDatePicker).map { [$0] } ?? view.subviews.flatMap { datePickers(in: $0) }
        }
        let picker = try XCTUnwrap(datePickers(in: host).first)
        XCTAssertEqual(picker.dateValue, capture.date)
        window.makeFirstResponder(picker)
        XCTAssertEqual(picker.dateValue, capture.date)

        // SwiftUI can reuse the sheet's subtree for the next incoming purchase.
        // Its State must come from that purchase rather than the previous form.
        let next = try decoder.decode(CloudCapture.self, from: JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "merchant": "Another purchase", "amount": "15.00", "currency": "USD",
            "account_id": ledger.accounts[0].id.uuidString, "date": "2026-10-15T08:09:10Z", "label": "Test phone"
        ]))
        host.rootView = WalletReviewForm(capture: next)
            .environmentObject(store).environmentObject(CloudSync())
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light).tint(.moraGreen)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(datePickers(in: host).first).dateValue, next.date)

    }
    func testForeignCurrencyPreviewKeepsHeightWhenQuoteArrives() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraEditorQuote-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var ledger = Ledger.empty
        ledger.preferences.automaticRates = false
        ledger.preferences.baseCurrency = "USD"; ledger.preferences.rates = ["USD": 1]
        ledger.accounts = [Account(name: "Synthetic account", currency: "USD", openingBalance: 100)]
        try LedgerFile.encode(ledger).write(to: directory.appendingPathComponent("ledger.json"))
        let store = FinanceStore(directory: directory)
        await store.load()
        var continuation: CheckedContinuation<Decimal, Never>?
        var calls = 0
        let client = VisaRateClient(cacheURL: nil) { _, _, _ in
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        var template = FinanceCore.Transaction(date: Date(), merchant: "Synthetic foreign purchase", amount: -12, accountID: ledger.accounts[0].id)
        template.conversion = CardConversion(originalAmount: -10, originalCurrency: "EUR", accountCurrency: "USD", rate: Decimal(string: "1.2")!, date: template.date)
        let editor = TransactionEditor(template: template, ledger: ledger, rateClient: client)
            .environmentObject(store).environmentObject(CloudSync())
        let host = NSHostingView(rootView: editor.background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light).tint(.moraGreen))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        for _ in 0..<100 where continuation == nil { try await Task.sleep(for: .milliseconds(5)) }
        let resume = try XCTUnwrap(continuation)
        let loadingSize = host.fittingSize
        XCTAssertLessThan(loadingSize.height, 600, "Reserve the quote's text lines, not an oversized blank footer")
        resume.resume(returning: Decimal(string: "1.2")!)
        for _ in 0..<40 { try await Task.sleep(for: .milliseconds(5)) }
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, loadingSize.height, accuracy: 1)
        let nextHost = host
        if let path = ProcessInfo.processInfo.environment["MORA_EDITOR_SNAPSHOT"],
           let bitmap = nextHost.bitmapImageRepForCachingDisplay(in: nextHost.bounds) {
            nextHost.cacheDisplay(in: nextHost.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        XCTAssertEqual(calls, 1)
    }

}
