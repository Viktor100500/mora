import AppKit
import SwiftUI
import XCTest
import FinanceCore
@testable import Mora

@MainActor
private struct NoticeGeometryProbe: NSViewRepresentable {
    let capture: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); capture(view); return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

@MainActor
private struct NoticeOverlayHarness: View {
    @ObservedObject var store: FinanceStore
    let capture: (NSView) -> Void
    var body: some View {
        VStack(spacing: 0) {
            NoticeGeometryProbe(capture: capture).frame(height: 60)
            Text("Synthetic account · 100.00 USD").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 1040, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .modifier(FloatingNotificationOverlay(event: store.activeNotice, close: { store.notice = nil }))
        .environmentObject(store).environmentObject(CloudSync())
    }
}

@MainActor
final class FloatingNotificationTests: XCTestCase {
    func testProgressCompletionReplacementAndDismissalDoNotMovePageContent() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraOverlay-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var ledger = Ledger.empty
        ledger.preferences.automaticRates = false
        ledger.preferences.baseCurrency = "USD"; ledger.preferences.rates = ["USD": 1]
        ledger.accounts = [Account(name: "Synthetic", currency: "USD", openingBalance: 1000)]
        ledger.transactions = [Transaction(date: Date(), merchant: "Synthetic purchase", amount: -12.50,
            accountID: ledger.accounts[0].id, categoryID: ledger.categories[0].id)]
        try LedgerFile.encode(ledger).write(to: directory.appendingPathComponent("ledger.json"))
        let store = FinanceStore(directory: directory)
        await store.load()
        var marker: NSView?
        let host = NSHostingView(rootView: NoticeOverlayHarness(store: store, capture: { marker = $0 }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let probe = try XCTUnwrap(marker)
        let baseline = probe.convert(probe.bounds, to: host)
        let hostSize = host.fittingSize
        let progress = store.beginProgressNotice("Synthetic saving progress", detail: "Synthetic purchase")
        try await Task.sleep(for: .milliseconds(30)); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(probe.convert(probe.bounds, to: host), baseline)
        XCTAssertEqual(host.fittingSize, hostSize)
        store.finishProgressNotice(progress, message: "Synthetic saved", actions: store.undoNotificationActions, dismissAfter: nil)
        try await Task.sleep(for: .milliseconds(30)); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(probe.convert(probe.bounds, to: host), baseline)
        store.showNotice("Synthetic warning", detail: "Details that can change notification height without moving the page", kind: .warning)
        try await Task.sleep(for: .milliseconds(30)); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(probe.convert(probe.bounds, to: host), baseline)
        if let path = ProcessInfo.processInfo.environment["MORA_NOTICE_SNAPSHOT"] {
            let preview = ContentView(page: .constant(.overview), sheet: .constant(nil))
                .environmentObject(store).environmentObject(CloudSync()).environmentObject(MerchantCategorizer())
                .preferredColorScheme(.dark).tint(.moraGreen)
            let previewHost = NSHostingView(rootView: preview)
            let previewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
            previewWindow.contentView = previewHost
            defer { previewWindow.contentView = nil }
            try await Task.sleep(for: .milliseconds(300)); previewHost.layoutSubtreeIfNeeded()
            if let bitmap = previewHost.bitmapImageRepForCachingDisplay(in: previewHost.bounds) {
                previewHost.cacheDisplay(in: previewHost.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        store.notice = nil
        try await Task.sleep(for: .milliseconds(30)); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(probe.convert(probe.bounds, to: host), baseline)
        XCTAssertEqual(host.fittingSize, hostSize)
        await store.notifications.flush()
    }
}
