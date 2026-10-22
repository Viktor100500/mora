import SwiftUI
import FinanceCore
import CryptoKit

@MainActor
final class MerchantCategorizer: ObservableObject {
    @Published var onlineEnabled: Bool {
        didSet { preferences.set(onlineEnabled, forKey: "mora.merchantCategories.online") }
    }
    private var working = false
    private var stopping = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    @Published private(set) var status: String?
    private let preferences: UserDefaults
    private let lookup: @MainActor (String) async throws -> MerchantGroup?
    private var completed: [String: String] = [:]
    private var misses: [String: Date] = [:]
    private var nextNetworkAttempt = Date.distantPast
    private var stateURL: URL?
    init(preferences: UserDefaults = .standard,
         lookup: (@MainActor (String) async throws -> MerchantGroup?)? = nil) {
        self.preferences = preferences; self.lookup = lookup ?? { try await OpenMerchantCatalogClient.shared.group(for: $0) }
        onlineEnabled = preferences.object(forKey: "mora.merchantCategories.online") as? Bool ?? true
    }
    nonisolated private static func signature(_ transaction: FinanceCore.Transaction) -> String {
        SHA256.hash(data: Data((transaction.kind.rawValue + "|" + MerchantName.normalized(transaction.merchant)).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    private func configure(_ store: FinanceStore) async {
        let url = store.fileURL.deletingLastPathComponent().appendingPathComponent("merchant-category-history.json")
        guard stateURL != url else { return }
        stateURL = url; completed = [:]; misses = [:]
        let saved = await BackgroundWork.shared.perform { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } }
        completed = saved ?? [:]
    }
    private func persist() async {
        guard let stateURL else { return }
        let saved = completed
        try? await BackgroundWork.shared.perform {
            try JSONEncoder().encode(saved).write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        }
    }
    private struct Candidate: Sendable {
        let transaction: Transaction
        let fingerprint: String
        let known: UUID?
    }
    func run(store: FinanceStore) async {
        await store.load()
        while !Task.isCancelled {
            await process(store: store)
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
        }
    }
    func finishPendingWrites() async {
        stopping = true
        while working { await withCheckedContinuation { finishWaiters.append($0) } }
    }
    func process(store: FinanceStore) async {
        guard !working, !store.isDemo, !stopping else { return }
        working = true
        defer {
            working = false
            let waiters = finishWaiters; finishWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        await configure(store)
        let snapshot = store.ledger.withoutChangeHistory()
        let candidates = await BackgroundWork.shared.perform {
            snapshot.transactions.filter { $0.categoryID == nil && $0.kind != .transfer }.sorted { $0.date > $1.date }.map {
                Candidate(transaction: $0, fingerprint: Self.signature($0), known: snapshot.suggestedCategory(merchant: $0.merchant, kind: $0.kind))
            }
        }
        for candidate in candidates {
            let transaction = candidate.transaction
            if Task.isCancelled || stopping { return }
            let key = transaction.id.uuidString, fingerprint = candidate.fingerprint
            // Clearing an automatically assigned category (including Undo) is a user choice.
            guard completed[key] != fingerprint else { continue }
            let known = candidate.known
            var categoryID = known
            if categoryID == nil, onlineEnabled, transaction.kind == .expense, Date() >= nextNetworkAttempt {
                let missKey = fingerprint + "|" + store.ledger.categories.map { $0.id.uuidString + $0.name }.joined(separator: "|")
                guard misses[missKey].map({ Date().timeIntervalSince($0) < 86400 }) != true else { continue }
                do {
                    categoryID = try await lookup(transaction.merchant)?.category(in: store.ledger)
                    guard onlineEnabled, !Task.isCancelled, !stopping else { return }
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
            let success = await store.update { ledger in
                guard let i = ledger.transactions.firstIndex(where: { $0.id == transaction.id }),
                      ledger.transactions[i].categoryID == nil,
                      Self.signature(ledger.transactions[i]) == fingerprint,
                      ledger.category(categoryID)?.kind == transaction.kind else { return }
                // A manual rule/category added during the download wins over the catalog.
                ledger.transactions[i].categoryID = ledger.historicalCategory(merchant: transaction.merchant, kind: transaction.kind) ?? categoryID
            }
            if success, store.ledger.transactions.first(where: { $0.id == transaction.id })?.categoryID != nil {
                completed[key] = fingerprint; await persist()
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
