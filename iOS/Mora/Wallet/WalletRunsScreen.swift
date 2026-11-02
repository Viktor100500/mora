import SwiftUI

/// Runs of the Wallet automation saved by the "Log Wallet Payment" action and
/// their delivery to the shared database.
struct WalletRunsScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var runs: [WalletRun] = []
    @State private var confirmClear = false
    @State private var deciding: WalletRun?
    @State private var sending = false

    private var waiting: Bool { runs.contains { $0.delivery == .waiting } }

    var body: some View {
        List {
            Section {
                if runs.isEmpty { Text(L("Запусков пока нет")).foregroundStyle(.secondary) }
                ForEach(runs) { run in
                    Button { if run.delivery == .late { deciding = run } } label: { row(run) }.buttonStyle(.plain)
                }
            } footer: {
                Text(L("Каждый запуск автоматизации сохраняется на iPhone до отправки. Если после оплаты здесь нет записи, автоматизация не дошла до Mora. Покупка, не отправленная за 15 минут, ждёт решения: возможно, вы уже ввели её вручную."))
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
        .confirmationDialog(L("Покупка не отправилась вовремя"), isPresented: Binding(get: { deciding != nil }, set: { if !$0 { deciding = nil } }), titleVisibility: .visible, presenting: deciding) { run in
            Button(L("Отправить в Mora")) { Task { await WalletDelivery.shared.confirm(run.id, with: WalletSender.current()); reload() } }
            Button(L("Уже записал вручную")) { Task { await WalletDelivery.shared.skip(run.id); reload() } }
            Button(L("Не учитывать"), role: .destructive) { Task { await WalletDelivery.shared.skip(run.id); reload() } }
        } message: { run in
            Text(L("Проверьте, не вводили ли вы её вручную: \(run.merchant), \(run.amount)."))
        }
        .refreshable { await deliver() }
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
    }

    private func reload() { runs = WalletRunLog.runs() }

    private func deliver() async {
        sending = true
        if let sender = WalletSender.current() { await WalletDelivery.shared.deliverWaiting(with: sender) }
        reload(); sending = false
    }

    private func row(_ run: WalletRun) -> some View {
        let status = Self.status(run)
        return HStack(spacing: 12) {
            IconTile(icon: status.icon, color: status.color, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.merchant.isEmpty ? L("Без продавца") : run.merchant).font(.body.weight(.medium))
                Text(L(status.text)).font(.caption).foregroundStyle(status.color == "green" || status.color == "gray" ? Color.secondary : Color.orange)
                Text([run.card.isEmpty ? L("Карта не передана") : run.card,
                      run.receivedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute().second().locale(L10n.locale))].joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
                if let error = run.lastError, run.needsDelivery || run.delivery == .failed {
                    Text(L(error)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            FinancialText(run.amount.isEmpty ? "без суммы" : run.amount).font(.subheadline.weight(.semibold))
        }
    }

    static func status(_ run: WalletRun) -> (text: String, icon: String, color: String) {
        switch run.delivery {
        case .logged: ("Только журнал: Apple Pay в Mora не включён", "list.bullet", "gray")
        case .incomplete: ("Недостаточно данных Wallet: не отправлено", "exclamationmark", "orange")
        case .waiting: ("Сохранено на iPhone, ждёт отправки", "clock", "orange")
        case .late: ("Не отправлено за 15 минут: нажмите, чтобы решить", "hand.raised", "orange")
        case .delivered: run.serverState == "recorded" ? ("Расход записан", "checkmark", "green") : ("Доставлено, ждёт проверки в Mora", "tray", "orange")
        case .failed: ("Сервер не принял покупку", "xmark", "orange")
        case .skipped: ("Не отправлено: записано вручную или не учитывается", "minus", "gray")
        }
    }
}
