import SwiftUI
import AppKit
import FinanceCore

/// Correct the native editor as well as the binding. A filtered SwiftUI binding
/// alone can leave rejected characters in AppKit's active field editor when
/// the filtered value is equal to the previous model value.
struct DecimalAmountField: NSViewRepresentable {
    let title: String
    @Binding var text: String
    var plain = false
    var currency: String? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.controlSize = .regular
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.isEnabled = context.environment.isEnabled
        field.isBordered = !plain; field.isBezeled = !plain; field.drawsBackground = !plain
        field.focusRingType = plain ? .none : .default
        field.placeholderString = title
        field.setAccessibilityLabel(title)
        field.setAccessibilityHelp(currency)
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DecimalAmountField
        private var correcting = false
        init(_ parent: DecimalAmountField) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.onEditingChanged(true) }
        func controlTextDidEndEditing(_ notification: Notification) { parent.onEditingChanged(false) }
        func controlTextDidChange(_ notification: Notification) {
            guard !correcting, let field = notification.object as? NSTextField else { return }
            let original = field.stringValue, filtered = AmountInput.filtered(original)
            if original != filtered {
                correcting = true
                let editor = field.currentEditor() as? NSTextView
                let caret = min(editor?.selectedRange().location ?? original.utf16.count, original.utf16.count)
                let prefix = (original as NSString).substring(to: caret)
                let position = min(AmountInput.filtered(prefix).utf16.count, filtered.utf16.count)
                field.stringValue = filtered
                editor?.string = filtered
                editor?.setSelectedRange(NSRange(location: position, length: 0))
                correcting = false
            }
            parent.text = filtered
        }
        @objc func submit(_ sender: NSTextField) { parent.onSubmit() }
    }
}
