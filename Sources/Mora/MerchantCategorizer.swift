import SwiftUI
import FinanceCore
import CryptoKit

@MainActor
final class MerchantCategorizer: ObservableObject {
    @Published var onlineEnabled: Bool {
        didSet { preferences.set(onlineEnabled, forKey: "mora.merchantCategories.online") }
    }
    private var working = false
    @Published private(set) var status: String?
    private let preferences: UserDefaults
    private let lookup: (String) async throws -> MerchantGroup?
    private var completed: [String: String] = [:]
    private var misses: [String: Date] = [:]
    private var nextNetworkAttempt = Date.distantPast
    private var stateURL: URL?
    init(preferences: UserDefaults = .standard,
         lookup: @escaping (String) async throws -> MerchantGroup? = { try await OpenMerchantCatalogClient.shared.group(for: $0) }) {
        self.preferences = preferences; self.lookup = lookup
        onlineEnabled = preferences.object(forKey: "mora.merchantCategories.online") as? Bool ?? true
    }
    private func signature(_ transaction: FinanceCore.Transaction) -> String {
        SHA256.hash(data: Data((transaction.kind.rawValue + "|" + MerchantName.normalized(transaction.merchant)).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    private func configure(_ store: FinanceStore) {
        let url = store.fileURL.deletingLastPathComponent().appendingPathComponent("merchant-category-history.json")
        guard stateURL != url else { return }
        stateURL = url; completed = [:]; misses = [:]
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: String].self, from: data) { completed = saved }
    }
    private func persist() {
        guard let stateURL, let data = try? JSONEncoder().encode(completed) else { return }
        try? data.write(to: stateURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
    func run(store: FinanceStore) async {
        while !Task.isCancelled {
            await process(store: store)
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
        }
    }
    func process(store: FinanceStore) async {
        guard !working, !store.isDemo else { return }
        configure(store)
        working = true; defer { working = false }
        let candidates = store.ledger.transactions.filter { $0.categoryID == nil && $0.kind != .transfer }
            .sorted { $0.date > $1.date }
        for transaction in candidates {
            if Task.isCancelled { return }
            let key = transaction.id.uuidString, fingerprint = signature(transaction)
            // Clearing an automatically assigned category (including Undo) is a user choice.
            guard completed[key] != fingerprint else { continue }
            let known = store.ledger.historicalCategory(merchant: transaction.merchant, kind: transaction.kind)
            var categoryID = known
            if categoryID == nil, onlineEnabled, transaction.kind == .expense, Date() >= nextNetworkAttempt {
                let missKey = fingerprint + "|" + store.ledger.categories.map { $0.id.uuidString + $0.name }.joined(separator: "|")
                guard misses[missKey].map({ Date().timeIntervalSince($0) < 86400 }) != true else { continue }
                do {
                    categoryID = try await lookup(transaction.merchant)?.category(in: store.ledger)
                    guard onlineEnabled, !Task.isCancelled else { return }
                    if categoryID == nil { misses[missKey] = Date() }
                    if status != nil { status = nil }
                } catch is CancellationError { return }
                catch {
                    let message = L("Каталоги продавцов временно недоступны. Покупки сохраняются без категории.")
                    if status != message { status = message }
                    nextNetworkAttempt = Date().addingTimeInterval(900)
                    // Continue with history matches even while the public feeds are unavailable.
                }
            }
            guard let categoryID else { continue }
            let success = store.update { ledger in
                guard let i = ledger.transactions.firstIndex(where: { $0.id == transaction.id }),
                      ledger.transactions[i].categoryID == nil,
                      signature(ledger.transactions[i]) == fingerprint,
                      ledger.category(categoryID)?.kind == transaction.kind else { return }
                // A manual rule/category added during the download wins over the catalog.
                ledger.transactions[i].categoryID = ledger.historicalCategory(merchant: transaction.merchant, kind: transaction.kind) ?? categoryID
            }
            if success, store.ledger.transactions.first(where: { $0.id == transaction.id })?.categoryID != nil {
                completed[key] = fingerprint; persist()
            }
        }
    }
}

struct MerchantSettingsCard: View {
    @EnvironmentObject private var categorizer: MerchantCategorizer
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: L("Автоматические категории"), subtitle: L("Для знакомого продавца используется категория из истории"))
                Toggle(L("Определять категории новых продавцов"), isOn: $categorizer.onlineEnabled)
                Text(L("Бесплатные открытые каталоги обновляются в фоне. Операции, суммы и названия покупок никуда не отправляются. Неоднозначные совпадения остаются без категории."))
                    .font(.caption).foregroundStyle(.secondary)
                if let status = categorizer.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                Link("Enrichment from Merchant Studio by Jonathan Taveras", destination: URL(string: "https://github.com/jtvargas/merchant-studio")!).font(.caption)
                Link("OpenStreetMap Name Suggestion Index · BSD-3-Clause", destination: URL(string: "https://github.com/osmlab/name-suggestion-index")!).font(.caption)
            }
        }
    }
}
