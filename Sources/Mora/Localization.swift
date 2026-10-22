import SwiftUI
import AppKit
import FinanceCore

func L(_ value: String) -> String { UILocalization.shared.text(value, language: L10n.language) }

enum L10n {
    static var language: AppLanguage { AppLanguage(rawValue: UserDefaults.standard.string(forKey: "mora.language") ?? "ru") ?? .russian }
    static var locale: Locale { language.locale }
}

/// Size the native control itself, including room for the year and stepper.
struct EuropeanDatePicker: View {
    var title: String
    @Binding var selection: Date
    var body: some View {
        LabeledContent(title) {
            EuropeanDateField(title: title, selection: $selection)
                .frame(width: 128, height: 26)
        }
    }
}

struct EuropeanDateField: NSViewRepresentable {
    let title: String
    @Binding var selection: Date
    var embedded = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = embedded ? .textField : .textFieldAndStepper
        picker.datePickerElements = .yearMonthDay
        picker.datePickerMode = .single
        picker.locale = Locale(identifier: "en_GB")
        picker.font = .systemFont(ofSize: NSFont.systemFontSize)
        picker.controlSize = .regular
        picker.isBezeled = !embedded
        picker.drawsBackground = !embedded
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        return picker
    }
    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.parent = self
        if picker.dateValue != selection { picker.dateValue = selection }
        picker.isEnabled = context.environment.isEnabled
        picker.setAccessibilityLabel(title)
    }
    @MainActor final class Coordinator: NSObject {
        var parent: EuropeanDateField
        init(_ parent: EuropeanDateField) { self.parent = parent }
        @objc func changed(_ picker: NSDatePicker) { parent.selection = picker.dateValue }
    }
}

struct LanguageSettingsCard: View {
    @AppStorage("mora.language") private var language = "ru"
    var body: some View {
        Card {
            HStack {
                SectionHeading(title: L("Язык интерфейса"))
                Spacer()
                Picker(L("Язык"), selection: $language) {
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                }.pickerStyle(.menu).labelsHidden().fixedSize()
            }
        }
    }
}

/// Formatters are reused on the main actor instead of created for every view body.
@MainActor enum DisplayMoney {
    private static var formatters: [String: NumberFormatter] = [:]
    static func string(_ amount: Decimal, currency: String = "RUB") -> String {
        let whole = amount == amount.rounded
        let key = "\(L10n.language.rawValue)-\(currency)-\(whole)"
        let formatter: NumberFormatter
        if let cached = formatters[key] { formatter = cached }
        else {
            formatter = NumberFormatter(); formatter.locale = L10n.locale
            formatter.numberStyle = .currency; formatter.currencyCode = currency
            formatter.maximumFractionDigits = 2; formatter.minimumFractionDigits = whole ? 0 : 2
            formatters[key] = formatter
        }
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount) \(currency)"
    }
}
