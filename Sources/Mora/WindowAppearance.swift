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
            let section = convert(bounds, to: document)
            let clip = scroll.contentView
            let desiredY = document.isFlipped ? section.minY - 16 : section.maxY + 16 - clip.bounds.height
            let maximumY = max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)
            let y = min(max(document.bounds.minY, desiredY), maximumY)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scroll.reflectScrolledClipView(clip)
            self.request = nil
            onScroll(request)
        }
    }
}
