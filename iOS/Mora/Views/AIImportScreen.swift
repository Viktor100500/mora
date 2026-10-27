import SwiftUI
import UIKit
import FinanceCore

/// AI import through the shared database: Mora issues a connection URL for the
/// remote MCP function, the agent reads accounts and records transactions as one
/// import, and synchronization brings them into this iPhone.
struct AIImportScreen: View {
    @EnvironmentObject private var cloud: CloudSync
    @Environment(\.openURL) private var openURL
    @State private var revoking: CloudAgentConnection?
    @State private var promptCopied = false

    static var prompt: String {
        L("Импортируй операции в Mora через коннектор Mora. Сначала вызови get_mora_context, затем один раз add_transactions со всеми новыми операциями. Пропусти операции, которые уже есть в recent_transactions. Если непонятно, к какому счету относится операция, сначала спроси меня.\n\nМои операции:\n")
    }

    var body: some View {
        List {
            if let error = cloud.error {
                Section { Label(L(error), systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
            }
            if cloud.householdID == nil {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L("Нужна общая база"), systemImage: "cloud").font(.headline)
                        Text(L("AI-агент записывает операции в вашу общую базу Supabase, а Mora забирает их при синхронизации. Сначала подключите общую базу."))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                    NavigationLink { CloudScreen() } label: { Label(L("Подключить общую базу"), systemImage: "arrow.triangle.2.circlepath") }
                }
            } else {
                howItWorks
                connections
                promptSection
            }
        }
        .navigationTitle(L("Импорт через AI"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: cloud.householdID) { if cloud.householdID != nil { await cloud.loadAgents() } }
        .refreshable { await cloud.loadAgents() }
        .sheet(item: Binding(get: { cloud.newAgentURL.map(IdentifiedURL.init) }, set: { if $0 == nil { cloud.newAgentURL = nil } })) { item in
            AgentConnectionSheet(url: item.url)
        }
        .confirmationDialog(L("Отключить AI-агента?"), isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
            Button(L("Отключить"), role: .destructive) { if let agent = revoking { Task { await cloud.revokeAgent(agent) } } }
        } message: {
            Text(L("Адрес подключения перестанет работать. Записанные операции останутся в истории импортов."))
        }
    }

    private var howItWorks: some View {
        Section {
            step(1, "Подключите агента", "Mora выдаст адрес для Claude, ChatGPT или другого клиента MCP.")
            step(2, "Отправьте выписку", "Приложите в чате скриншот, PDF или опишите операции словами.")
            step(3, "Операции появятся в Mora", "Агент записывает их одним импортом. Его можно отменить в истории импортов.")
        }
    }

    private var connections: some View {
        Section {
            ForEach(cloud.agents) { agent in
                HStack(spacing: 12) {
                    IconTile(icon: "sparkles", color: "purple", size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.label).font(.body.weight(.medium))
                        Text(agent.last_used_at.map { L("Последний доступ: \($0.formatted(date: .abbreviated, time: .shortened))") } ?? L("Еще не подключался"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions { Button(L("Отключить"), role: .destructive) { revoking = agent } }
                .contextMenu { Button(L("Отключить"), systemImage: "xmark.circle", role: .destructive) { revoking = agent } }
            }
            Menu {
                ForEach(["Claude", "ChatGPT"], id: \.self) { name in
                    Button(name) { Task { await cloud.connectAgent(label: name) } }
                }
                Button(L("Другой клиент MCP")) { Task { await cloud.connectAgent(label: L("AI-агент")) } }
            } label: {
                Label(L("Подключить AI-агента"), systemImage: "plus.circle.fill")
            }.disabled(cloud.busy)
        } header: { Text(L("Подключения")) } footer: {
            Text(L("Агент видит названия счетов и категорий и операции за 60 дней, а добавлять может только новые операции. В проекте Supabase должны быть установлены миграция agent_import и функция mora-mcp."))
        }
    }

    private var promptSection: some View {
        Section {
            Text(Self.prompt).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Button { copyPrompt() } label: {
                Label(promptCopied ? L("Запрос скопирован") : L("Скопировать запрос"), systemImage: promptCopied ? "checkmark" : "doc.on.doc")
            }
            ForEach([("Claude", "claude://"), ("ChatGPT", "chatgpt://")], id: \.0) { name, scheme in
                Button {
                    copyPrompt()
                    if let url = URL(string: scheme) { openURL(url) { accepted in if !accepted { cloud.error = L("Приложение \(name) не установлено. Запрос скопирован.") } } }
                } label: { Label(L("Открыть \(name)"), systemImage: "arrow.up.forward.app") }
            }
        } header: { Text(L("Запрос для агента")) } footer: {
            Text(L("Вставьте запрос в новый чат, где включен коннектор Mora, и приложите выписку."))
        }
    }

    private func step(_ number: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(Color.moraGreen, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title)).font(.subheadline.weight(.semibold))
                Text(L(text)).font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 2)
    }

    private func copyPrompt() {
        UIPasteboard.general.string = Self.prompt
        promptCopied = true
        Task { @MainActor in try? await Task.sleep(for: .seconds(1.5)); promptCopied = false }
    }
}

private struct IdentifiedURL: Identifiable { let url: URL; var id: String { url.absoluteString } }

/// The connection URL is shown once, with where to paste it in each agent.
private struct AgentConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(url.absoluteString).font(.footnote.monospaced()).textSelection(.enabled)
                    Button { UIPasteboard.general.string = url.absoluteString; copied = true } label: {
                        Label(copied ? L("Адрес скопирован") : L("Скопировать адрес"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    ShareLink(item: url) { Label(L("Отправить на компьютер"), systemImage: "square.and.arrow.up") }
                } header: { Text(L("Адрес подключения")) } footer: {
                    Text(L("Адрес работает как пароль: с ним можно читать счета и добавлять операции. Mora показывает его один раз; отключить агента можно в любой момент."))
                }
                Section(L("Claude")) {
                    Text(L("На claude.ai откройте Настройки → Коннекторы → Добавить свой коннектор и вставьте адрес. Коннектор появится и в приложении Claude на iPhone."))
                        .font(.subheadline)
                }
                Section(L("ChatGPT")) {
                    Text(L("На chatgpt.com откройте Настройки → Приложения и коннекторы → Расширенные и включите режим разработчика. Затем создайте коннектор с этим адресом без авторизации."))
                        .font(.subheadline)
                }
            }
            .navigationTitle(L("AI-агент подключен")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Готово")) { dismiss() } } }
        }
        .interactiveDismissDisabled(!copied)
    }
}
