import AppKit
import SwiftUI
import XCTest
import FinanceCore
@testable import Mora

@MainActor
final class NotificationPopoverTests: XCTestCase {
    func testSwiftUIToolbarKeepsTheSameAnchorWhenUnreadStateAndHistoryChange() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraBellAnchor-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FinanceStore(directory: directory), cloud = CloudSync()
        let history = AppNotifications()
        history.record("Synthetic unread event")
        let host = NSHostingView(rootView: AppNotificationBell(notifications: history)
            .environmentObject(store).environmentObject(cloud).frame(width: 100, height: 80))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 100, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func anchor(in view: NSView) -> NSView? {
            if view.className.contains("NotificationPopoverAnchorView") { return view }
            for child in view.subviews { if let result = anchor(in: child) { return result } }
            return nil
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let original = try XCTUnwrap(anchor(in: host))
        XCTAssertTrue(original.window === window)
        XCTAssertGreaterThanOrEqual(original.bounds.width, 36)
        XCTAssertGreaterThanOrEqual(original.bounds.height, 36)
        history.markRecentRead()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(anchor(in: host) === original, "Marking read must not detach an opening popup's anchor")
        history.record("Synthetic new arrival")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(anchor(in: host) === original)
        XCTAssertTrue(original.window === window)
        await history.flush()
    }

    func testRealPopoverRepeatedOpenCloseAndLateDismissalKeepFullContentSize() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraPopover-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notification-history.json")
        try await BackgroundWork.shared.perform {
            let events = (0..<10_000).map { AppNotification(message: "Synthetic event \($0)", detail: "Synthetic purchase · 12.50 USD") }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(events).write(to: file)
        }
        let history = AppNotifications(fileURL: file)
        await history.load()
        let store = FinanceStore(directory: directory), cloud = CloudSync()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Mora notification regression · synthetic data"
        let anchor = NSView(frame: NSRect(x: 580, y: 620, width: 36, height: 36))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        let presenter = NotificationPopoverPresenter()
        presenter.anchor = anchor
        defer { presenter.close() }
        let content: @MainActor ([NotificationListEntry], @escaping () -> Void) -> AnyView = { rows, close in
            XCTAssertLessThanOrEqual(rows.count, 100)
            return AnyView(NotificationsPanel(notifications: history, initialRows: rows, close: close)
                .environmentObject(store).environmentObject(cloud).preferredColorScheme(.dark))
        }
        // The toolbar warms its bounded content before the first click.
        await presenter.warmUp(notifications: history, content: content)
        XCTAssertNil(presenter.popover)
        XCTAssertEqual(history.unreadCount, 100, "Preloading must not mark notifications as read")
        func waitForOpening() async throws {
            for _ in 0..<100 where presenter.isPreparing { try await Task.sleep(for: .milliseconds(10)) }
            try await Task.sleep(for: .milliseconds(20))
        }
        var previous: NSPopover?
        var durations: [Duration] = []
        for index in 0..<20 {
            let started = ContinuousClock.now
            presenter.toggle(notifications: history, content: content)
            try await waitForOpening()
            durations.append(started.duration(to: .now))
            let current = try XCTUnwrap(presenter.popover, "Opening \(index) must have content")
            XCTAssertTrue(current.isShown, "Opening \(index) must display a real native popover")
            XCTAssertEqual(current.contentSize, NSSize(width: 420, height: 500))
            XCTAssertEqual(current.contentViewController?.view.bounds.size, NSSize(width: 420, height: 500))
            XCTAssertGreaterThanOrEqual(current.contentViewController?.view.window?.frame.height ?? 0, 500)
            if let previous {
                presenter.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: previous))
                XCTAssertTrue(presenter.popover === current, "A late close must not remove a newer popup")
            }
            if index == 0 {
                history.record("Synthetic new arrival", kind: .warning)
                await presenter.warmUp(notifications: history, content: content)
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(history.unreadCount, 0)
                XCTAssertEqual(current.contentSize, NSSize(width: 420, height: 500))
                if let path = ProcessInfo.processInfo.environment["MORA_POPOVER_SNAPSHOT"],
                   let view = current.contentViewController?.view,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
            previous = current
            if index.isMultiple(of: 2) { presenter.close() }
            else { current.performClose(nil) }
            XCTAssertFalse(current.isShown)
        }
        // Repeated clicks while background preparation is suspended cancel the old request.
        let cold = NotificationPopoverPresenter()
        cold.anchor = anchor
        defer { cold.close() }
        cold.toggle(notifications: history, content: content)
        cold.toggle(notifications: history, content: content)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(cold.popover)
        cold.toggle(notifications: history, content: content)
        cold.toggle(notifications: history, content: content)
        cold.toggle(notifications: history, content: content)
        for _ in 0..<100 where cold.isPreparing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(cold.popover?.isShown == true)
        XCTAssertEqual(cold.popover?.contentSize, NSSize(width: 420, height: 500))
        cold.close()
        let empty = AppNotifications()
        presenter.toggle(notifications: empty) { rows, close in
            AnyView(NotificationsPanel(notifications: empty, initialRows: rows, close: close)
                .environmentObject(store).environmentObject(cloud))
        }
        try await waitForOpening()
        XCTAssertTrue(presenter.popover?.isShown == true)
        XCTAssertEqual(presenter.popover?.contentSize, NSSize(width: 420, height: 500))
        print("Real notification popovers: 20 open/close cycles, maximum opening including settling: \(durations.max() ?? .zero)")
        presenter.close()
        await history.flush()
    }
}
