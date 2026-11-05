import SwiftUI
import FinanceCore

/// Runs of the Wallet automation saved by Mora's actions and their delivery to the shared database.
struct WalletRunsScreen: View {
    @EnvironmentObject private var cloud: CloudSync
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    @State private var runs: [WalletRun] = []
    @State private var confirmClear = false
    @State private var sending = false

    private var waiting: Bool { runs.contains { $0.delivery == .waiting || $0.delivery == .awaitingAmount } }

    var body: some View {
        List {
            Section {
                if runs.isEmpty { Text(L("Запусков пока нет")).foregroundStyle(.secondary) }
                ForEach(runs) { run in
                    let review = cloud.review(for: run)
                    Self.row(run, review: review) { router.open(cloud.processing(run, review: review)) }
                        .swipeActions {
                            if run.needsProcessing {
                                Button(role: .destructive) { Task { await WalletDelivery.shared.skip(run.id); reload() } } label: { Label(L("Не учитывать"), systemImage: "minus.circle") }
                            }
                        }
                }
            } footer: {
                Text(L("Каждый запуск автоматизации сохраняется на iPhone и уходит сам, когда появится интернет. Если Wallet не передал сумму или продавца, нажмите «Обработать» и допишите покупку. Если после оплаты здесь нет записи, автоматизация не дошла до Mora: проверьте, что первое действие в ней — «Start Wallet Payment»."))
            }
        }
        .navigationTitle(L("Запуски Wallet"))
        .toolbar {
            if waiting {
                Button(L("Отправить")) { Task { await deliver() } }.disabled(sending)
            } else if !runs.isEmpty {
                Button(L("Очистить"), role: .destructive) { confirmClear = true }
            }
        }
        .confirmationDialog(L("Очистить журнал запусков?"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(L("Очистить"), role: .destructive) { WalletRunLog.clear(); reload() }
        } message: { Text(L("Покупки, которые ждут отправки или решения, останутся.")) }
        .refreshable { await deliver(); await cloud.refreshLists() }
        .onAppear(perform: reload)
        .onChange(of: router.sheet == nil) { _, closed in if closed { reload() } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
    }

    private func reload() { runs = WalletRunLog.runs() }

    private func deliver() async {
        sending = true
        await WalletBackgroundDelivery.run()
        reload(); sending = false
    }

    /// `process` opens the transaction form of a purchase that needs the user.
    static func row(_ run: WalletRun, review: CloudCapture?, process: @escaping () -> Void) -> some View {
        let status = status(run, review: review)
        return HStack(spacing: 12) {
            IconTile(icon: status.icon, color: status.color, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.sentMerchant.isEmpty ? L("Без продавца") : run.sentMerchant).font(.body.weight(.medium))
                Text(L(status.text)).font(.caption).foregroundStyle(status.color == "orange" ? Color.orange : Color.secondary)
                Text([run.card.isEmpty ? L("Карта не передана") : run.card,
                      run.receivedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute().second().locale(L10n.locale))].joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                FinancialText(run.amount.isEmpty ? "без суммы" : run.amount).font(.subheadline.weight(.semibold))
                if run.needsProcessing || review != nil {
                    Button(L("Обработать"), action: process).buttonStyle(.borderedProminent).controlSize(.small).tint(.orange)
                }
            }
        }
    }

    /// `review` is the server inbox entry of this run while it still needs the user.
    static func status(_ run: WalletRun, review: CloudCapture?) -> (text: String, icon: String, color: String) {
        switch run.delivery {
        case .logged: ("Только журнал: Apple Pay в Mora не включён", "list.bullet", "gray")
        case .incomplete: ("Wallet не передал сумму или продавца", "exclamationmark", "orange")
        case .awaitingAmount: ("Сохранено на iPhone, ждёт сумму от Wallet", "clock", "orange")
        case .waiting: ("Сохранено на iPhone, уйдёт при появлении интернета", "clock", "orange")
        case .late: ("Не отправлено вовремя", "exclamationmark", "orange")
        case .delivered:
            if let review { (review.reason ?? "Нужно обработать", "exclamationmark", "orange") }
            else { ("Записано", "checkmark", "green") }
        case .failed: ("Сервер не принял покупку", "xmark", "orange")
        case .processed: ("Обработано", "checkmark", "green")
        case .skipped: ("Не учитывается", "minus", "gray")
        case .duplicate: ("Пустой повтор запуска", "minus", "gray")
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
