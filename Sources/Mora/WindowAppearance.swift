import SwiftUI
import AppKit

struct ConsistentScrollEdges: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

/// Scroll to the section's laid-out AppKit frame, rather than SwiftUI's cached
/// target geometry from the page that occupied this scroll view previously.
struct SectionScrollAnchor: NSViewRepresentable {
    @Binding var request: UUID?

    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {
        view.request = request
        view.onScroll = { id in
            if request == id { request = nil }
        }
        view.scheduleScroll()
    }

    final class AnchorView: NSView {
        var request: UUID?
        var onScroll: (UUID) -> Void = { _ in }
        private var scheduled = false
        private weak var observedDocument: NSView?

        @objc private func documentFrameChanged(_ notification: Notification) { scheduleScroll() }

        private func observeDocument(_ document: NSView) {
            guard observedDocument !== document else { return }
            if let observedDocument {
                NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: observedDocument)
            }
            observedDocument = document
            document.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(documentFrameChanged(_:)),
                                                  name: NSView.frameDidChangeNotification, object: document)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleScroll()
        }
        override func layout() {
            super.layout()
            scheduleScroll()
        }

        func scheduleScroll() {
            guard request != nil, !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.scrollAfterLayout()
            }
        }

        private func scrollAfterLayout() {
            guard let request, let window else { return }
            // Finish the new Settings layout before measuring the section.
            // Queueing alone (including Task.yield) doesn't guarantee that pass.
            window.contentView?.layoutSubtreeIfNeeded()
            guard let scroll = enclosingScrollView, let document = scroll.documentView,
                  bounds.height > 0, scroll.contentView.bounds.height > 0 else { return }
            observeDocument(document)
            let section = convert(bounds, to: document)
            // SwiftUI can place the section before expanding the scroll document.
            // Keep the request pending until that document frame change arrives;
            // otherwise scrolling is clamped to the previous page's short height.
            guard section.minY >= document.bounds.minY - 1,
                  section.maxY <= document.bounds.maxY + 1 else { return }
            let clip = scroll.contentView
            let desiredY = document.isFlipped ? section.minY - 16 : section.maxY + 16 - clip.bounds.height
            let maximumY = max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)
            let y = min(max(document.bounds.minY, desiredY), maximumY)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scroll.reflectScrolledClipView(clip)
            // Confirm after the next display pass: the scroll document and the
            // section can finish changing in separate SwiftUI layout passes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
                guard let self, self.request == request, self.window != nil else { return }
                self.window?.contentView?.layoutSubtreeIfNeeded()
                let currentSection = self.convert(self.bounds, to: document)
                let visible = scroll.documentVisibleRect
                let heading = NSRect(x: currentSection.minX, y: currentSection.minY,
                                     width: min(currentSection.width, visible.width),
                                     height: min(currentSection.height, 200))
                guard currentSection == section, document.bounds.contains(currentSection),
                      visible.insetBy(dx: -1, dy: -1).contains(heading) else {
                    self.scheduleScroll()
                    return
                }
                self.request = nil
                self.onScroll(request)
            }
        }
    }
}
