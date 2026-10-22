import AppKit
import SwiftUI

struct CalendarDaySelection {
    private(set) var days: Set<Int> = []
    private(set) var anchor: Int?

    mutating func select(_ day: Int, extending: Bool = false, additive: Bool = false) {
        if extending, let anchor {
            let range = Set(min(anchor, day)...max(anchor, day))
            days = additive ? days.union(range) : range
        } else {
            if additive {
                if !days.insert(day).inserted { days.remove(day) }
            } else {
                days = days == [day] ? [] : [day]
            }
            anchor = days.isEmpty ? nil : day
        }
    }

    var dayList: String {
        var ranges: [ClosedRange<Int>] = []
        for day in days.sorted() {
            if let last = ranges.last, last.upperBound + 1 == day {
                ranges[ranges.count - 1] = last.lowerBound...day
            } else {
                ranges.append(day...day)
            }
        }
        return ranges.map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)–\($0.upperBound)" }.joined(separator: ", ")
    }
}

/// A native hit target also handles Control-click, which macOS can dispatch as
/// rightMouseDown instead of a regular SwiftUI button action.
struct CalendarDayHitTarget: NSViewRepresentable {
    var label: String
    var selected: Bool
    var action: (NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> CalendarDayButton {
        let button = CalendarDayButton()
        button.title = ""
        button.isBordered = false
        button.isTransparent = true
        button.setButtonType(.momentaryChange)
        button.target = button
        button.action = #selector(CalendarDayButton.activate)
        return button
    }

    func updateNSView(_ button: CalendarDayButton, context: Context) {
        button.onSelect = action
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityLabel(label)
        button.setAccessibilityValue(selected ? L("Выбрано") : nil)
        button.setAccessibilityHelp(L("Ctrl/⌘ — отдельные дни · Shift — диапазон"))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CalendarDayButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 62)
    }
}

final class CalendarDayButton: NSButton {
    var onSelect: ((NSEvent.ModifierFlags) -> Void)?
    private var clickModifiers: NSEvent.ModifierFlags = []

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.modifierFlags.contains(.control) {
            onSelect?(event.modifierFlags)
        } else {
            clickModifiers = event.modifierFlags
            defer { clickModifiers = [] }
            super.mouseDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if isEnabled && event.modifierFlags.contains(.control) {
            onSelect?(event.modifierFlags)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    @objc func activate() { onSelect?(clickModifiers) }
}
