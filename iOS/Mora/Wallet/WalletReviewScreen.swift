import SwiftUI
import FinanceCore

/// Wallet purchases saved on this iPhone that Wallet passed incompletely. Together
/// with the server inbox they make one list of purchases that need the user.
@MainActor final class WalletReviewQueue: ObservableObject {
    @Published private(set) var broken: [WalletRun] = []

    func reload() {
        let runs = WalletRunLog.runs().filter(\.needsProcessing)
        if runs != broken { broken = runs }
    }

    func count(with cloud: CloudSync) -> Int { broken.count + cloud.pending.count }
}

/// One list of purchases to process: opened from the overview notice and from the shared database screen.
struct WalletReviewScreen: View {
    @EnvironmentObject private var cloud: CloudSync
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var queue: WalletReviewQueue
    @State private var deleting: Item?

    struct Item: Identifiable {
        enum Source { case iPhone(WalletRun), server(CloudCapture) }
        let id: UUID
        let merchant: String
        let amount: String
        let date: Date
        let card: String
        let reason: String
        let source: Source
    }

    private var items: [Item] {
        let local = queue.broken.map {
            Item(id: $0.id, merchant: $0.sentMerchant, amount: $0.amount, date: $0.receivedAt, card: $0.card,
                 reason: $0.amount.isEmpty ? "Wallet не передал сумму" : "Wallet не передал продавца", source: .iPhone($0))
        }
        let server = cloud.pending.map {
            Item(id: $0.id, merchant: $0.merchant, amount: $0.amount.isEmpty ? "" : $0.amount + ($0.currency.isEmpty ? "" : " " + $0.currency),
                 date: $0.date, card: $0.card ?? "", reason: $0.reason ?? "Нужна проверка", source: .server($0))
        }
        return (local + server).sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            Section {
                if items.isEmpty {
                    Label(L("Все покупки обработаны"), systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    Button { open(item) } label: { row(item) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { deleting = item } label: { Label(L("Удалить"), systemImage: "trash") }.tint(.red)
                        }
                }
            } footer: {
                Text(L("Wallet передал эти покупки не полностью. Нажмите, чтобы дописать сумму или продавца: форма уже заполнена тем, что удалось получить."))
            }
        }
        .navigationTitle(L("Покупки на проверку"))
        .refreshable { queue.reload(); await cloud.refreshLists() }
        .onAppear(perform: queue.reload)
        .onChange(of: router.sheet == nil) { _, closed in if closed { queue.reload() } }
        .confirmationDialog(L("Удалить покупку?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { item in
            Button(L("Удалить"), role: .destructive) { delete(item) }
        } message: { _ in Text(L("Она не попадёт в расходы. Отменить удаление нельзя.")) }
    }

    private func open(_ item: Item) {
        switch item.source {
        case .iPhone(let run): router.open(cloud.processing(run, review: nil))
        case .server(let capture): router.open(.walletReview(capture))
        }
    }

    private func delete(_ item: Item) {
        Task {
            switch item.source {
            case .iPhone(let run): await WalletDelivery.shared.skip(run.id)
            case .server(let capture): await cloud.dismissCapture(capture)
            }
            queue.reload()
        }
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 12) {
            IconTile(icon: "exclamationmark", color: "orange", size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.merchant.isEmpty ? L("Без продавца") : item.merchant).font(.body.weight(.medium))
                Text(L(item.reason)).font(.caption).foregroundStyle(.orange).lineLimit(2)
                Text([item.card, item.date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(L10n.locale))]
                    .filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            FinancialText(item.amount.isEmpty ? "—" : item.amount).font(.subheadline.weight(.semibold))
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
