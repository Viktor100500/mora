import SwiftUI
import FinanceCore

/// The automation journals saved on this iPhone. Purchases that need the user come
/// from them and from the server inbox, as one list.
@MainActor final class WalletReviewQueue: ObservableObject {
    @Published private(set) var runs: [WalletRun] = []
    @Published private(set) var alerts: [BankAlert] = []

    /// Wallet runs broken on the iPhone: the user books them in the transaction form.
    var broken: [WalletRun] { runs.filter(\.needsProcessing) }
    /// Bank messages in a new format or refused by the server.
    var bank: [BankAlert] { alerts.filter(\.needsUser) }

    func reload() {
        let runs = WalletRunLog.runs(), alerts = BankAlertLog.alerts()
        if runs != self.runs { self.runs = runs }
        if alerts != self.alerts { self.alerts = alerts }
    }

    func count(with cloud: CloudSync) -> Int { broken.count + bank.count + cloud.pending.count }

    /// Newest first, each with the automation it came from.
    func items(cloud: CloudSync) -> [ReviewItem] {
        let local = broken.map {
            ReviewItem(id: $0.id, merchant: $0.sentMerchant, amount: $0.amount, date: $0.receivedAt, card: $0.card,
                       reason: $0.amount.isEmpty ? "Wallet не передал сумму" : "Wallet не передал продавца",
                       origin: .iPhone($0), source: .walletTransaction)
        }
        let messages = bank.map {
            ReviewItem(id: $0.id, merchant: $0.merchant.isEmpty ? $0.source : $0.merchant,
                       amount: [$0.amount, $0.currency].filter { !$0.isEmpty }.joined(separator: " "), date: $0.receivedAt,
                       card: $0.source.isEmpty ? "" : $0.card,
                       reason: $0.state == .failed ? ($0.lastError ?? "Сервер не принял покупку") : "Новый формат: проверьте один раз",
                       origin: .bank($0), source: CaptureAutomation.source(of: $0))
        }
        let server = cloud.pending.map { capture in
            ReviewItem(id: capture.id, merchant: capture.merchant,
                       amount: capture.amount.isEmpty ? "" : capture.amount + (capture.currency.isEmpty ? "" : " " + capture.currency),
                       date: capture.date, card: capture.card ?? "", reason: capture.reason ?? "Нужна проверка",
                       origin: .server(capture), source: source(of: capture, cloud: cloud), fromServer: true)
        }
        return (local + messages + server).sorted { $0.date > $1.date }
    }

    /// The local run or message a server purchase was sent from, if it was this iPhone.
    private func source(of capture: CloudCapture, cloud: CloudSync) -> CaptureAutomation? {
        if runs.contains(where: { cloud.review(for: $0)?.id == capture.id }) { return .walletTransaction }
        let alert = alerts.first {
            $0.state == .delivered && abs($0.receivedAt.timeIntervalSince(capture.date)) < 1 && $0.merchant == capture.merchant
        }
        return alert.flatMap(CaptureAutomation.source(of:))
    }
}

/// A purchase that needs the user, from any automation.
struct ReviewItem: Identifiable {
    enum Origin { case iPhone(WalletRun), server(CloudCapture), bank(BankAlert) }
    let id: UUID
    let merchant: String
    let amount: String
    let date: Date
    let card: String
    let reason: String
    let origin: Origin
    let source: CaptureAutomation?
    /// Reached the shared database from another device or without a local record.
    var fromServer = false
}

struct ReviewRow: View {
    let item: ReviewItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(icon: "exclamationmark", color: "orange", size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.merchant.isEmpty ? L("Без продавца") : item.merchant).font(.body.weight(.medium)).lineLimit(2)
                    Spacer(minLength: 8)
                    FinancialText(item.amount.isEmpty ? "—" : item.amount).font(.subheadline.weight(.semibold))
                }
                if item.source == nil && item.fromServer {
                    SourceBadge(title: L("Общая база"), icon: "icloud", color: "gray")
                } else {
                    SourceBadge(item.source)
                }
                Text(L(item.reason)).font(.caption).foregroundStyle(.orange).lineLimit(3)
                Text([item.card, item.date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(L10n.locale))]
                    .filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 4)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Every purchase to review: opened from the overview notice and from "Automation".
struct WalletReviewScreen: View {
    @EnvironmentObject private var cloud: CloudSync
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var queue: WalletReviewQueue
    @State private var deleting: ReviewItem?
    @State private var openedBank: UUID?
    /// Deleted rows leave at once instead of coming back until the delete is saved.
    @State private var removed: Set<UUID> = []

    private var items: [ReviewItem] { queue.items(cloud: cloud).filter { !removed.contains($0.id) } }

    var body: some View {
        List {
            Section {
                if items.isEmpty {
                    Label(L("Все покупки обработаны"), systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    Button { open(item) } label: { ReviewRow(item: item) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { deleting = item } label: { Label(L("Удалить"), systemImage: "trash") }.tint(.red)
                        }
                }
            } footer: {
                Text(L("Автоматизации передали эти покупки не полностью, в новом формате банка или с новой карты. Нажмите, чтобы проверить: форма уже заполнена тем, что удалось получить."))
            }
        }
        .wrappingTitle(L("Покупки на проверку"))
        .navigationDestination(item: $openedBank) { id in
            if let alert = queue.alerts.first(where: { $0.id == id }) {
                BankAlertDetailScreen(alert: alert, duplicate: AutomationJournal.duplicateNote(for: alert, alerts: queue.alerts))
            }
        }
        .refreshable { queue.reload(); await cloud.refreshLists() }
        .onAppear(perform: queue.reload)
        .onChange(of: router.sheet == nil) { _, closed in if closed { queue.reload() } }
        .confirmationDialog(L("Удалить покупку?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { item in
            Button(L("Удалить"), role: .destructive) { delete(item) }
        } message: { _ in Text(L("Она не попадёт в расходы. Отменить удаление нельзя.")) }
    }

    private func open(_ item: ReviewItem) {
        switch item.origin {
        case .iPhone(let run): router.open(cloud.processing(run, review: nil))
        case .server(let capture): router.open(.walletReview(capture))
        case .bank(let alert): openedBank = alert.id
        }
    }

    private func delete(_ item: ReviewItem) {
        withAnimation { _ = removed.insert(item.id) }
        Task {
            switch item.origin {
            case .iPhone(let run): await WalletDelivery.shared.skip(run.id)
            case .server(let capture): await cloud.dismissCapture(capture)
            case .bank(let alert): await BankAlertDelivery.shared.skip(alert.id)
            }
            queue.reload()
            // Back in the list only if the delete failed.
            removed.remove(item.id)
        }
    }
}

extension CloudSync {
    /// The server inbox entry of a delivered run that still needs the user. The
    /// server keeps the run's time as the purchase time.
    func review(for run: WalletRun) -> CloudCapture? {
        guard run.delivery == .delivered else { return nil }
        return pending.first { abs($0.date.timeIntervalSince(run.receivedAt)) < 1 && $0.merchant == run.sentMerchant }
    }

    /// The transaction form for a purchase that needs the user: the server inbox entry
    /// when the purchase reached it, otherwise the purchase saved on this iPhone.
    func processing(_ run: WalletRun, review: CloudCapture?) -> AppSheet {
        if let review { return .walletReview(review) }
        let card = run.card.lowercased()
        return .walletRun(run, walletCards.first { !card.isEmpty && $0.card.lowercased() == card }?.account_id)
    }
}
