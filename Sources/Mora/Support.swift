import SwiftUI
import AppKit

enum SupportContact {
    static let email = "yar.thedeveloper@proton.me"
    static let emailURL = URL(string: "mailto:\(email)")!
}

struct FeedbackButton: View {
    var shortLabel = false
    var body: some View {
        Link(destination: SupportContact.emailURL) {
            Label(L(shortLabel ? "Обратная связь" : "Обратная связь и помощь"), systemImage: "envelope")
        }
        .help(L("Обратная связь и помощь"))
    }
}

struct FeedbackFooter: ViewModifier {
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, alignment: .leading, spacing: 0) {
            FeedbackContact()
                .font(.caption)
                .padding(.horizontal, 24).padding(.bottom, 12)
        }
    }
}

struct FeedbackContact: View {
    @EnvironmentObject private var store: FinanceStore
    var compact = false
    var body: some View {
        ViewThatFits(in: .horizontal) {
            if !compact { HStack(spacing: 12) { FeedbackButton(shortLabel: true); email } }
            VStack(alignment: .leading, spacing: 6) { FeedbackButton(shortLabel: true); email }
        }.buttonStyle(.plain).foregroundStyle(.secondary)
    }
    private var email: some View {
        Button {
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(SupportContact.email, forType: .string) {
                store.notice = L("Адрес почты скопирован")
            }
        } label: {
            Text(SupportContact.email)
        }
        .font(.system(size: 10)).fixedSize().help(L("Скопировать адрес почты"))
    }
}

struct DonationMethod: Identifiable {
    let id: String
    let detail: String
    let value: String
    static let all: [DonationMethod] = [
        .init(id: "TRON", detail: "Любые TRON-ассеты, например USDT", value: "TXrM9XwdrBpYz1yjYayBCeMhXnzDBgQq1C"),
        .init(id: "GRAM / TON", detail: "Любые TON-ассеты, например GRAM", value: "UQAOF5V5InATZOOcHqfP9qOnmuk0cJvt-H_kcQzA-NpDmlsO"),
        .init(id: "Рубли", detail: "Т-Банк", value: "https://t.tb.ru/pm_short/3DshhujwKyI"),
        .init(id: "Serbia Prenesi", detail: "", value: "069671074"),
        .init(id: "Zelle", detail: "", value: "+13472787634")
    ]
}

struct DonationButton: View {
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: { Label(L("Поддержать Mora"), systemImage: "heart") }
            .sheet(isPresented: $presented) { DonationSheet() }
    }
}

struct DonationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(L("Поддержать Mora"), systemImage: "heart.fill").font(.title2.bold()).foregroundStyle(Color.moraGreen)
                Spacer()
                Button(L("Закрыть")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(L("Спасибо за поддержку! Нажмите на реквизиты, чтобы скопировать их.")).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(DonationMethod.all) { method in
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(method.value, forType: .string)
                            copied = method.id
                        } label: {
                            HStack(alignment: .center, spacing: 16) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L(method.id)).font(.headline)
                                    if !method.detail.isEmpty { Text(L(method.detail)).font(.caption).foregroundStyle(.secondary) }
                                    Text(method.value).font(.system(size: 12, design: .monospaced))
                                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: copied == method.id ? "checkmark.circle.fill" : "doc.on.doc")
                                    .foregroundStyle(Color.moraGreen).frame(width: 22)
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.moraGreen.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).help(L("Скопировать реквизиты"))
                            .accessibilityLabel(L(method.id) + ": " + method.value)
                            .accessibilityValue(copied == method.id ? L("Скопировано") : "")
                    }
                }
            }
            HStack {
                Text(copied.map { L("Скопировано") + ": " + L($0) } ?? L("Выберите удобный способ поддержки"))
                    .font(.caption).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently)
                Spacer()
            }
            FeedbackContact().font(.caption)
        }.padding(24).frame(width: 590, height: 650)
    }
}

struct SupportSettingsCard: View {
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: L("Обратная связь и помощь"),
                               subtitle: L("Сообщите об ошибке, предложите улучшение или задайте вопрос разработчику."))
                FeedbackContact()
                DonationButton().buttonStyle(.bordered)
            }
        }
    }
}
