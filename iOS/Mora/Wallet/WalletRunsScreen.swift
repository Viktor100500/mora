import SwiftUI

/// Runs of the Wallet automation saved by the "Log Wallet Payment" action.
struct WalletRunsScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var runs: [WalletRun] = []
    @State private var confirmClear = false

    var body: some View {
        List {
            Section {
                if runs.isEmpty { Text(L("Запусков пока нет")).foregroundStyle(.secondary) }
                ForEach(runs) { run in row(run) }
            } footer: {
                Text(L("Добавьте действие «Log Wallet Payment» первым шагом в автоматизацию «Транзакция» и передайте в него сумму, продавца и карту. Каждый запуск сохраняется только на этом iPhone и ничего не отправляет. Если после оплаты здесь нет записи, автоматизация не дошла до Mora."))
            }
        }
        .navigationTitle(L("Запуски Wallet"))
        .toolbar {
            if !runs.isEmpty {
                Button(L("Очистить"), role: .destructive) { confirmClear = true }
            }
        }
        .confirmationDialog(L("Очистить журнал запусков?"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(L("Очистить"), role: .destructive) { WalletRunLog.clear(); reload() }
        }
        .refreshable { reload() }
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
    }

    private func reload() { runs = WalletRunLog.runs() }

    private func row(_ run: WalletRun) -> some View {
        HStack(spacing: 12) {
            IconTile(icon: run.isComplete ? "checkmark" : "exclamationmark", color: run.isComplete ? "green" : "orange", size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.merchant.isEmpty ? L("Без продавца") : run.merchant).font(.body.weight(.medium))
                Text([run.card.isEmpty ? L("Карта не передана") : run.card,
                      run.receivedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute().second().locale(L10n.locale))].joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            FinancialText(run.amount.isEmpty ? "без суммы" : run.amount).font(.subheadline.weight(.semibold))
        }
    }
}
