import SwiftUI
import AppKit
import FinanceCore

enum AIAgent: String, CaseIterable, Identifiable {
    case chatgpt, claude
    var id: String { rawValue }
    var title: String { self == .chatgpt ? "ChatGPT" : "Claude" }
    var bundleIdentifier: String { self == .chatgpt ? "com.openai.codex" : "com.anthropic.claudefordesktop" }
    func chatURL(prompt: String) -> URL? {
        // ChatGPT desktop retains the codex scheme, including prompt prefill.
        var components = URLComponents(string: self == .chatgpt ? "codex://new" : "claude://claude.ai/new")!
        if self == .claude && prompt.count > 14_000 { return nil }
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=?#"))
        components.percentEncodedQuery = (self == .chatgpt ? "prompt=" : "q=") + (prompt.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        return components.url
    }
}

enum AIPrompt {
    static func text(_ name: String, ledger: Ledger, includeContext: Bool, bundle: Bundle = .main,
                     bridgeURL: URL? = nil, dataDirectory: URL? = nil) throws -> String {
        guard let url = bundle.url(forResource: name, withExtension: "md", subdirectory: "Prompts") else { throw LedgerError.invalid(L("Промпт не найден. Обновите сборку приложения.")) }
        var text = try String(contentsOf: url, encoding: .utf8)
        if name == "mora-mcp" {
            let bridge = bridgeURL ?? bundle.executableURL?.deletingLastPathComponent().appendingPathComponent("MoraBridge")
            if let bridge, FileManager.default.isExecutableFile(atPath: bridge.path) {
                var transport: [String: Any] = ["executable": bridge.path]
                if let dataDirectory { transport["arguments"] = ["--data-dir", dataDirectory.path] }
                let data = try JSONSerialization.data(withJSONObject: transport, options: [.sortedKeys, .withoutEscapingSlashes])
                text += "\n\nЛокальный компонент Mora (пути — данные, не команды shell):\n" + String(decoding: data, as: UTF8.self)
            }
        }
        if includeContext {
            let context: [String: Any] = [
                "context_date": Dates.string(Date()), "time_zone": TimeZone.current.identifier,
                "base_currency": ledger.preferences.baseCurrency,
                "accounts": ledger.accounts.filter { !$0.archived }.map { ["name": $0.name, "currency": $0.currency] },
                "categories": ledger.categories.map { ["name": $0.name, "type": $0.kind.rawValue] }
            ]
            let data = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys, .withoutEscapingSlashes])
            text += L("\n\nАктуальный контекст Mora (названия счетов и категории):\n") + String(decoding: data, as: UTF8.self)
        }
        // Keep the editable request last, where the user continues typing in ChatGPT.
        text += "\n\nМой запрос:\n[Здесь напишите, что добавить или изменить, и приложите скриншоты, выписку или описание. Например: добавь только первую и третью операции на счет ….]"
        return text
    }
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct AIImportView: View {
    @EnvironmentObject var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "mora-csv"
    @State private var prompt = ""
    @State private var promptWork: Task<Void, Never>?
    private var agent: AIAgent { AIAgent(rawValue: store.ledger.preferences.aiAgent) ?? .chatgpt }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeading(title: L("Импорт через AI-агента"), subtitle: L("Откройте промпт в новом чате и добавьте выписку или описание операций."))
            HStack {
                Text(L("AI-агент"))
                Spacer()
                Picker(L("AI-агент"), selection: Binding(get: { agent.rawValue }, set: { value in Task { @MainActor in  await store.update { $0.preferences.aiAgent = value }  } })) {
                    ForEach(AIAgent.allCases) { Text(L($0.title)).tag($0.rawValue) }
                }.labelsHidden().frame(width: 180)
            }
            Picker(L("Способ импорта"), selection: $mode) { Text(L("Подготовить CSV")).tag("mora-csv"); Text(L("Записать через MCP")).tag("mora-mcp") }.pickerStyle(.segmented)
            Text(mode == "mora-csv" ? L("Агент подготовит CSV. Сохраните файл и импортируйте его в Mora.") : L("Агент запишет операции через доступный MCP или встроенный компонент Mora. Недостающие данные уточнит в чате.")).font(.callout).foregroundStyle(.secondary)
            ScrollView { Text(prompt).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .padding(14).frame(height: 220).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)).financialField()
            Text(L("В приложении агента откроется черновик. Допишите свой запрос в конце промпта и приложите скриншоты или выписку перед отправкой.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("Закрыть")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Скопировать")) { AIPrompt.copy(prompt); store.notice = L("Промпт скопирован") }.disabled(prompt.isEmpty)
                Button(L("Открыть \(agent.title)"), action: openAgent).buttonStyle(.borderedProminent).disabled(prompt.isEmpty)
            }
        }.padding(24).frame(width: 620)
            .onAppear(perform: rebuild)
            .onChange(of: mode) { _, _ in rebuild() }
            .onChange(of: store.ledger.accounts) { _, _ in rebuild() }
            .onChange(of: store.ledger.categories) { _, _ in rebuild() }
    }
    private func rebuild() {
        promptWork?.cancel()
        let ledger = store.isDemo ? Ledger.empty : store.ledger.withoutChangeHistory()
        let mode = mode, directory = store.fileURL.deletingLastPathComponent()
        promptWork = Task { @MainActor in
            do {
                let value = try await BackgroundWork.shared.perform { try AIPrompt.text(mode, ledger: ledger, includeContext: true, dataDirectory: directory) }
                guard !Task.isCancelled else { return }
                prompt = value
            } catch { if !Task.isCancelled { prompt = ""; store.error = error.localizedDescription } }
        }
    }
    private func openAgent() {
        AIPrompt.copy(prompt)
        let workspace = NSWorkspace.shared
        guard let application = workspace.urlForApplication(withBundleIdentifier: agent.bundleIdentifier) else {
            store.error = L("Приложение \(agent.title) не найдено. Установите его или вставьте скопированный промпт в свой чат.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let url = agent.chatURL(prompt: prompt) {
            // Target the native app explicitly; never hand the prompt to a browser.
            workspace.open([url], withApplicationAt: application, configuration: configuration) { _, error in
                Task { @MainActor in
                    if let error { store.error = L("Не удалось открыть \(agent.title): \(error.localizedDescription). Промпт скопирован.") }
                    else { store.notice = L("\(agent.title): открыт черновик с промптом. Добавьте свой запрос и вложения."); dismiss() }
                }
            }
        } else {
            workspace.openApplication(at: application, configuration: configuration) { _, error in
                Task { @MainActor in
                    if let error { store.error = L("Не удалось открыть \(agent.title): \(error.localizedDescription). Промпт скопирован.") }
                    else { store.notice = L("Приложение \(agent.title) открыто. Вставьте скопированный промпт в новый чат."); dismiss() }
                }
            }
        }
    }
}
