import AppKit
import SwiftUI
import XCTest
import FinanceCore
@testable import Mora

@MainActor
final class StartupPerformanceTests: XCTestCase {
    func testFirstNotificationPanelRenderWithLargeHistory() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraNotificationPerformance-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notification-history.json")
        try await BackgroundWork.shared.perform {
            let events = (0..<10_000).map { AppNotification(message: "Synthetic event \($0)", detail: "Synthetic purchase · 12.50 USD") }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(events).write(to: file)
        }
        let notifications = AppNotifications(fileURL: file)
        await notifications.load()
        let store = FinanceStore(directory: directory)
        notifications.markRecentRead()
        let preparationStarted = ContinuousClock.now
        let rows = await notifications.preparePage()
        print("Notification preparation off the UI thread: \(preparationStarted.duration(to: .now))")
        XCTAssertEqual(rows.count, 100)
        let clock = ContinuousClock(), drawingStarted = clock.now
        let view = NotificationsPanel(notifications: notifications, initialRows: rows, close: {})
            .environmentObject(store).environmentObject(CloudSync())
        let host = NotificationPanelRendering.prepare(view)
        print("Notification layout/render completed before presentation: \(drawingStarted.duration(to: clock.now))")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let start = clock.now
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        print("Notification first layout/render (10,000 archived events): \(start.duration(to: clock.now))")
        XCTAssertEqual(notifications.events.count, 10_000)
        await notifications.flush()
    }

    func testLaunchMinimumAndAlreadyCompletedMinimum() async throws {
        let start = ContinuousClock.now
        var ready = false
        let waiting = Task { try await LaunchTiming.waitForMinimum(since: start); ready = true }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(ready)
        try await waiting.value
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .seconds(3))
        let slowLoadFinished = ContinuousClock.now
        try await LaunchTiming.waitForMinimum(since: slowLoadFinished.advanced(by: .seconds(-5)))
        XCTAssertLessThan(slowLoadFinished.duration(to: .now), .seconds(1))
    }

    func testNotificationTimerStartsAfterTheSplashHasFinished() async throws {
        let store = FinanceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("MoraLaunchNotice-\(UUID())"))
        store.beginLaunchPresentation()
        store.showTransientNotice("Synthetic review reminder", kind: .warning, actions: [.inbox], dismissAfter: .milliseconds(30))
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertNotNil(store.activeNotice)
        store.endLaunchPresentation()
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertNil(store.activeNotice)
    }

    func testDenserLaunchParticleRenderingBudget() throws {
        let view = LaunchParticleView(frame: NSRect(x: 0, y: 0, width: 1320, height: 900))
        view.layout()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1320, pixelsHigh: 900,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let start = ContinuousClock.now
        for _ in 0..<60 { view.draw(view.bounds) }
        let average = start.duration(to: .now) / 60
        print("Launch particles: 178 nodes, average frame rendering \(average)")
        XCTAssertLessThan(average, .milliseconds(50), "Reject a severe rendering regression even in debug builds")
    }

    func testLaunchPreparesTheInterfaceBeforeRevealingIt() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraLaunchPerformance-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var ledger = Ledger.empty
        ledger.preferences.automaticRates = false
        ledger.preferences.baseCurrency = "USD"; ledger.preferences.rates = ["USD": 1]
        ledger.accounts = [Account(name: "Synthetic account", currency: "USD", openingBalance: 10_000)]
        ledger.transactions = (0..<1000).map { index in
            Transaction(date: Date().addingTimeInterval(-Double(index) * 3600), merchant: "Synthetic purchase",
                amount: -12.50, accountID: ledger.accounts[0].id, categoryID: ledger.categories[0].id)
        }
        try LedgerFile.encode(ledger).write(to: directory.appendingPathComponent("ledger.json"))
        let store = FinanceStore(directory: directory), cloud = CloudSync()
        let suite = "MoraLaunchPerformance-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "mora.merchantCategories.online")
        let categorizer = MerchantCategorizer(preferences: preferences, lookup: { _ in nil })
        let host = NSHostingView(rootView: ContentView(page: .constant(.overview), sheet: .constant(nil))
            .environmentObject(store).environmentObject(cloud).environmentObject(categorizer).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func hasParticles(_ view: NSView) -> Bool {
            view is LaunchParticleView || view.subviews.contains { hasParticles($0) }
        }
        let started = ContinuousClock.now
        var last = started
        var gaps: [Duration] = []
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = ContinuousClock.now
                if started.duration(to: now) > .seconds(2.5) { gaps.append(last.duration(to: now)) }
                last = now
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(2_700))
        XCTAssertTrue(hasParticles(host), "The launch screen must remain visible for the full minimum")
        try await Task.sleep(for: .milliseconds(1_800))
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(hasParticles(host), "Prepared data must reveal the interface after the minimum and fade")
        XCTAssertEqual(store.ledger.transactions.count, 1000)
        print("Launch reveal: maximum main-run-loop interval \(gaps.max() ?? .zero)")
        if let output = ProcessInfo.processInfo.environment["MORA_LAUNCH_RESULT_SNAPSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        }
        await cloud.finishPendingWrites()
        await categorizer.finishPendingWrites()
        await store.notifications.flush()
    }
}
