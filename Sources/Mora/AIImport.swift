import SwiftUI
import AppKit
import FinanceCore

enum AIAgent: String, CaseIterable, Identifiable {
    case chatgpt, claude
    var id: String { rawValue }
    var title: String { self == .chatgpt ? "ChatGPT" : "Claude" }
    var website: URL { URL(string: self == .chatgpt ? "https://chatgpt.com/" : "https://claude.ai/new")! }
    func chatURL(prompt: String) -> URL? {
        var components = URLComponents(string: self == .chatgpt ? "codex://new" : "claude://claude.ai/new")!
        // Claude truncates prefilled prompts beyond approximately 14,000 characters.
        if self == .claude && prompt.count > 14_000 { return nil }
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=?#"))
        components.percentEncodedQuery = (self == .chatgpt ? "prompt=" : "q=") + (prompt.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        return components.url
    }
}

enum AIPrompt {
    static func text(_ name: String, ledger: Ledger, includeContext: Bool) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "md", subdirectory: "Prompts") else { throw LedgerError.invalid(L("Промпт не найден. Обновите сборку приложения.")) }
        var text = try String(contentsOf: url, encoding: .utf8)
        if includeContext {
            let context: [String: Any] = [
                "context_date": Dates.string(Date()), "time_zone": TimeZone.current.identifier,
                "base_currency": ledger.preferences.baseCurrency,
                "accounts": ledger.accounts.filter { !$0.archived }.map { ["name": $0.name, "currency": $0.currency] },
                "categories": ledger.categories.map { ["name": $0.name, "type": $0.kind.rawValue] }
            ]
            let data = try JSONSerialization.data(withJSONObject: context, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            text += L("\n\nАктуальный контекст Mora (названия счетов и категории):\n") + String(decoding: data, as: UTF8.self)
        }
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
    private var agent: AIAgent { AIAgent(rawValue: store.ledger.preferences.aiAgent) ?? .chatgpt }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeading(title: L("Импорт через AI-агента"), subtitle: L("Откройте промпт в новом чате и добавьте выписку или описание операций."))
            HStack {
                Text(L("AI-агент"))
                Spacer()
                Picker(L("AI-агент"), selection: Binding(get: { agent.rawValue }, set: { value in store.update { $0.preferences.aiAgent = value } })) {
                    ForEach(AIAgent.allCases) { Text(L($0.title)).tag($0.rawValue) }
                }.labelsHidden().frame(width: 180)
            }
            Picker(L("Способ импорта"), selection: $mode) { Text(L("Подготовить CSV")).tag("mora-csv"); Text(L("Записать через MCP")).tag("mora-mcp") }.pickerStyle(.segmented)
            Text(mode == "mora-csv" ? L("Агент подготовит CSV. Сохраните файл и импортируйте его в Mora.") : L("Агент добавит операции напрямую. В выбранном агенте должен быть подключен Mora MCP.")).font(.callout).foregroundStyle(.secondary)
            ScrollView { Text(prompt).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .padding(14).frame(height: 220).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)).financialField()
            Text(L("Промпт откроется в приложении, если оно поддерживает запуск нового чата. Иначе откроется сайт; промпт будет скопирован для вставки.")).font(.caption).foregroundStyle(.secondary)
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
        do { prompt = try AIPrompt.text(mode, ledger: store.ledger, includeContext: true) }
        catch { prompt = ""; store.error = error.localizedDescription }
    }
    private func openAgent() {
        AIPrompt.copy(prompt)
        if let url = agent.chatURL(prompt: prompt), NSWorkspace.shared.urlForApplication(toOpen: url) != nil, NSWorkspace.shared.open(url) {
            store.notice = L("\(agent.title): открыт новый чат с промптом. Промпт также скопирован.")
        } else if NSWorkspace.shared.open(agent.website) {
            store.notice = L("Промпт скопирован. Вставьте его в новый чат \(agent.title).")
        } else { store.error = L("Не удалось открыть \(agent.title). Промпт скопирован — вставьте его в чат вручную.") }
        dismiss()
    }
}
