import SwiftUI
import UIKit

/// The same support address as the Mac app.
enum SupportContact {
    static let email = "yar.thedeveloper@proton.me"

    /// A new mail with the app and iOS versions in the subject, so replies need fewer questions.
    static var mailURL: URL {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [URLQueryItem(name: "subject", value: "Mora iPhone \(version), iOS \(UIDevice.current.systemVersion)")]
        return components.url ?? URL(string: "mailto:\(email)")!
    }
}

struct SupportSection: View {
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        Section {
            Button {
                // Without a configured mail app the address is copied instead.
                openURL(SupportContact.mailURL) { accepted in if !accepted { copy() } }
            } label: { Label(L("Написать в поддержку"), systemImage: "envelope") }
            Button(action: copy) {
                HStack {
                    Label(copied ? L("Почта скопирована") : SupportContact.email, systemImage: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? Color.moraGreen : .primary)
                    Spacer()
                }.contentShape(Rectangle())
            }
            .accessibilityHint(L("Скопировать адрес почты"))
        } header: { Text(L("Обратная связь и помощь")) } footer: {
            Text(L("Сообщите об ошибке, предложите улучшение или задайте вопрос разработчику."))
        }
        .animation(.easeInOut(duration: 0.15), value: copied)
    }

    private func copy() {
        UIPasteboard.general.string = SupportContact.email
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
