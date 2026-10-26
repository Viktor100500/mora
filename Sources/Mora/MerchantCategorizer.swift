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
    private enum MissReason { case merchant, category }
    private struct Miss { let date: Date; let reason: MissReason }
    private var misses: [String: Miss] = [:]
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
    func process(store: FinanceStore, duringSync: Bool = false) async {
        if duringSync {
            while working { await withCheckedContinuation { finishWaiters.append($0) } }
        }
        guard !working, !store.isDemo, !stopping, !Task.isCancelled,
              duringSync || !store.isDeferringUpdates else { return }
        working = true
        defer {
            working = false
            let waiters = finishWaiters; finishWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        await configure(store)
        let snapshot = store.latestLedger.withoutChangeHistory()
        let useCatalogs = onlineEnabled
        let candidates = await BackgroundWork.shared.perform {
            snapshot.transactions.filter { $0.categoryID == nil && $0.kind != .transfer }.sorted { $0.date > $1.date }.map {
                let known = snapshot.suggestedCategory(merchant: $0.merchant, kind: $0.kind)
                let group = known == nil && useCatalogs && $0.kind == .expense ?
                    (MerchantCatalog.bundled.group(for: $0.merchant) ?? MerchantPlaces.bundled.group(for: $0.merchant)) : nil
                let place = group?.category(in: snapshot)
                return Candidate(transaction: $0, fingerprint: Self.signature($0), known: known ?? place)
            }
        }
        var assignments: [UUID: (fingerprint: String, categoryID: UUID)] = [:]
        var unknownMerchants: Set<String> = [], missingCategories: Set<String> = []
        for candidate in candidates {
            let transaction = candidate.transaction
            if Task.isCancelled || stopping || (!duringSync && store.isDeferringUpdates) { return }
            let key = transaction.id.uuidString, fingerprint = candidate.fingerprint
            // Clearing an automatically assigned category (including Undo) is a user choice.
            guard completed[key] != fingerprint else { continue }
            let known = candidate.known
            var categoryID = known
            if categoryID == nil, onlineEnabled, transaction.kind == .expense, Date() >= nextNetworkAttempt {
                let missKey = fingerprint + "|" + store.latestLedger.categories.map { $0.id.uuidString + $0.name }.joined(separator: "|")
                if let miss = misses[missKey], Date().timeIntervalSince(miss.date) < 86400 {
                    if miss.reason == .merchant { unknownMerchants.insert(fingerprint) }
                    else { missingCategories.insert(fingerprint) }
                    continue
                }
                do {
                    let group = try await lookup(transaction.merchant)
                    categoryID = group?.category(in: store.latestLedger)
                    guard onlineEnabled, !Task.isCancelled, !stopping else { return }
                    if categoryID == nil {
                        let reason: MissReason = group == nil ? .merchant : .category
                        misses[missKey] = Miss(date: Date(), reason: reason)
                        if reason == .merchant { unknownMerchants.insert(fingerprint) }
                        else { missingCategories.insert(fingerprint) }
                    }
                } catch is CancellationError { return }
                catch {
                    let message = L("Каталоги продавцов временно недоступны. Покупки сохраняются без категории.")
                    if status != message { status = message }
                    nextNetworkAttempt = Date().addingTimeInterval(900)
                    // Continue with history matches even while the public feeds are unavailable.
                }
            }
            guard let categoryID else { continue }
            assignments[transaction.id] = (fingerprint, categoryID)
        }
        let message: String?
        if onlineEnabled, Date() < nextNetworkAttempt, candidates.contains(where: { $0.known == nil }) {
            message = L("Каталоги продавцов временно недоступны. Покупки сохраняются без категории.")
        } else if !missingCategories.isEmpty {
            message = L("Для найденных продавцов нет подходящей категории расходов. Выберите категорию вручную — Mora запомнит выбор.")
        } else if !unknownMerchants.isEmpty {
            message = L("Продавцов без совпадения в справочниках: \(unknownMerchants.count). Выберите категорию вручную — Mora запомнит выбор.")
        } else { message = nil }
        if status != message { status = message }
        guard !assignments.isEmpty, duringSync || !store.isDeferringUpdates, !Task.isCancelled, !stopping else { return }
        let proposals = assignments
        let assigned = await store.change { ledger -> [String: String] in
            var assigned: [String: String] = [:]
            for (id, proposal) in proposals {
                guard let i = ledger.transactions.firstIndex(where: { $0.id == id }),
                      ledger.transactions[i].categoryID == nil,
                      Self.signature(ledger.transactions[i]) == proposal.fingerprint,
                      ledger.category(proposal.categoryID)?.kind == ledger.transactions[i].kind else { continue }
                // A manual rule/category added during the download wins over the catalog.
                ledger.transactions[i].categoryID = ledger.historicalCategory(merchant: ledger.transactions[i].merchant,
                    kind: ledger.transactions[i].kind) ?? proposal.categoryID
                assigned[id.uuidString] = proposal.fingerprint
            }
            return assigned
        }
        if let assigned, !assigned.isEmpty {
            completed.merge(assigned) { _, new in new }
            await persist()
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
                Text(L("Встроенная база заведений Нью-Йорка и окрестностей и продуктовых магазинов штата работает без интернета. Каталоги брендов обновляются в фоне. Названия покупок, суммы и счета никуда не отправляются."))
                    .font(.caption).foregroundStyle(.secondary)
                if let status = categorizer.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                Link("Enrichment from Merchant Studio by Jonathan Taveras", destination: URL(string: "https://github.com/jtvargas/merchant-studio")!).font(.caption)
                Link("OpenStreetMap Name Suggestion Index · BSD-3-Clause", destination: URL(string: "https://github.com/osmlab/name-suggestion-index")!).font(.caption)
                Link("Overture Places · CDLA Permissive 2.0 / Apache 2.0", destination: URL(string: "https://docs.overturemaps.org/guides/places/")!).font(.caption)
                Link("NYS Retail Food Stores · Open NY", destination: URL(string: "https://data.ny.gov/Economic-Development/Retail-Food-Stores/9a8c-vfzj")!).font(.caption)
            }
        }
    }
}
