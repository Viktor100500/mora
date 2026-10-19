import SwiftUI
import FinanceCore

func L(_ value: String) -> String { UILocalization.shared.text(value, language: L10n.language) }

enum L10n {
    static var language: AppLanguage { AppLanguage(rawValue: UserDefaults.standard.string(forKey: "mora.language") ?? "ru") ?? .russian }
    static var locale: Locale { language.locale }
}

/// Keep day/month/year order independently of the interface language, and let
/// the native field use its intrinsic width so the four-digit year stays visible.
struct EuropeanDatePicker: View {
    var title: String
    @Binding var selection: Date
    var body: some View {
        LabeledContent(title) {
            DatePicker("", selection: $selection, displayedComponents: .date)
                .labelsHidden().datePickerStyle(.stepperField)
                .environment(\.locale, Locale(identifier: "en_GB"))
                .fixedSize().frame(minWidth: 160, alignment: .leading)
                .accessibilityLabel(title)
        }
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
