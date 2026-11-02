import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FinanceCore

struct WalletShortcutSetupView: View {
    @EnvironmentObject private var cloud: CloudSync
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    @State private var label = "Мой iPhone"
    @State private var cards: [WalletCardAssignment] = []
    @State private var issued: CloudIssuedToken?
    @State private var working = false
    @State private var error: String?
    @State private var savedURL: URL?
    private let unselectedAccount = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    private var accounts: [Account] { store.ledger.accounts.filter { !$0.archived } }
    private var valid: Bool {
        let names = cards.map { $0.card.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
        return !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && label.count <= 100
            && !cards.isEmpty && cards.count <= 50 && names.allSatisfy { !$0.isEmpty && $0.count <= 200 }
            && Set(names).count == names.count && cards.allSatisfy { card in accounts.contains { $0.id == card.account_id } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Команда Apple Pay для iPhone")).font(.title2.bold())
            if let savedURL {
                Label(L("Команда сохранена"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(L("Передайте файл на iPhone через AirDrop и добавьте команду. В существующей автоматизации «Транзакция» выберите её вместо прежней и передайте исходную транзакцию целиком. Для каждой карты оставьте одну автоматизацию."))
                Text(L("При первой реальной оплате оставьте iPhone разблокированным, чтобы разрешить чтение Wallet, если iOS его запросит. Интернет нужен для отправки; очереди без сети пока нет.")).font(.callout).foregroundStyle(.secondary)
                Button(L("Показать файл")) { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
            } else {
                Text(L("Укажите названия карт так, как они отображаются в Wallet, и выберите счета. Mora не читает список карт iPhone. Если название не совпадёт или карта не определится, покупка останется на проверке."))
                    .font(.callout).foregroundStyle(.secondary)
                TextField(L("Название телефона"), text: $label).textFieldStyle(.roundedBorder).disabled(issued != nil)
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach($cards) { $card in
                            HStack {
                                TextField(L("Название карты в Wallet"), text: $card.card).textFieldStyle(.roundedBorder)
                                Picker(L("Счёт"), selection: $card.account_id) {
                                    Text(L("Выберите счёт")).tag(unselectedAccount)
                                    ForEach(accounts) { Text("\($0.name) · \($0.currency)").tag($0.id) }
                                }.frame(width: 240)
                                Button { cards.removeAll { $0.id == card.id } } label: { Image(systemName: "minus.circle") }
                                    .accessibilityLabel(L("Удалить карту"))
                            }
                        }
                    }
                }.frame(maxHeight: 220).disabled(issued != nil)
                Button(L("Добавить карту")) {
                    cards.append(WalletCardAssignment(accountID: unselectedAccount))
                }.disabled(cards.count >= 50 || issued != nil)
                Text(L("Команда тихая: читает сумму, продавца и карту сразу и через 5 секунд. Новые карты и покупки без определённой карты автоматически на основной счёт не записываются."))
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            }
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(savedURL == nil ? L("Отмена") : L("Готово")) { dismiss() }
                if savedURL == nil {
                    Button(issued == nil ? L("Создать и сохранить команду…") : L("Повторить сохранение…")) { save() }
                        .buttonStyle(.borderedProminent).disabled(!valid)
                }
            }
        }.padding(24).frame(width: 700).disabled(working)
            .interactiveDismissDisabled(working)
            .onAppear { if cards.isEmpty { cards = [WalletCardAssignment(accountID: unselectedAccount)] } }
    }
    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Mora-Wallet-5s.shortcut"
        panel.allowedContentTypes = [UTType(filenameExtension: "shortcut") ?? .data]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        working = true; error = nil
        Task { @MainActor in
            defer { working = false }
            do {
                guard let url = Bundle.main.url(forResource: "WalletSender", withExtension: "plist") else {
                    throw LedgerError.invalid(L("Не найден шаблон команды. Пересоберите приложение."))
                }
                let template = try Data(contentsOf: url)
                guard let projectURL = URL(string: cloud.projectURL) else { throw CloudAPIError.invalidResponse }
                let configuration = try CloudConfiguration(projectURL: projectURL, publicKey: cloud.publicKey)
                if issued == nil { issued = await cloud.createWalletSetup(label: label, cards: cards) }
                guard let issued else { throw LedgerError.invalid(cloud.error ?? L("Не удалось настроить карты.")) }
                let data = try WalletShortcutTemplate.configured(template, configuration: configuration, phoneToken: issued.token)
                try await BackgroundWork.shared.perform { try WalletShortcutFile.save(data, to: destination) }
                savedURL = destination
            } catch { self.error = error.localizedDescription }
        }
    }
}

private enum WalletShortcutFile {
    static func save(_ data: Data, to destination: URL) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mora-wallet-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("Wallet.unsigned.shortcut")
        let output = directory.appendingPathComponent("Wallet.shortcut")
        try data.write(to: input, options: .atomic)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["sign", "--mode", "people-who-know-me", "--input", input.path, "--output", output.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LedgerError.invalid("Apple не удалось подписать команду локально. Проверьте доступность приложения «Быстрые команды» на Mac и повторите сохранение. Ключ и настройки карт сохранены для повторной попытки.")
        }
        try Data(contentsOf: output).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
