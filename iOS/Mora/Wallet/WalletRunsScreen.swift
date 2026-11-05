import SwiftUI
import FinanceCore

/// Runs of the Wallet automation saved by Mora's actions and their delivery to the shared database.
struct WalletRunsScreen: View {
    @EnvironmentObject private var cloud: CloudSync
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
                    NavigationLink { WalletRunDetailScreen(id: run.id) } label: { Self.row(run, review: cloud.review(for: run)) }
                }
            } footer: {
                Text(L("Каждый запуск автоматизации сохраняется на iPhone до отправки и уходит сам, когда появится интернет. Покупки без суммы или продавца попадают на проверку в Mora. Если после оплаты здесь нет записи, автоматизация не дошла до Mora: проверьте, что первое действие в ней — «Start Wallet Payment»."))
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
        .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
    }

    private func reload() { runs = WalletRunLog.runs() }

    private func deliver() async {
        sending = true
        await WalletBackgroundDelivery.run()
        reload(); sending = false
    }

    static func row(_ run: WalletRun, review: CloudCapture?) -> some View {
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
            FinancialText(run.amount.isEmpty ? "без суммы" : run.amount).font(.subheadline.weight(.semibold))
        }
    }

    /// `review` is the server inbox entry of this run while it still needs the user.
    static func status(_ run: WalletRun, review: CloudCapture?) -> (text: String, icon: String, color: String) {
        switch run.delivery {
        case .logged: ("Только журнал: Apple Pay в Mora не включён", "list.bullet", "gray")
        case .incomplete: ("Не отправлено: нет суммы или продавца. Нажмите, чтобы отправить на проверку", "exclamationmark", "orange")
        case .awaitingAmount: ("Сохранено на iPhone, ждёт сумму от Wallet", "clock", "orange")
        case .waiting: ("Сохранено на iPhone, уйдёт при появлении интернета", "clock", "orange")
        case .late: ("Не отправлено: нажмите, чтобы решить", "hand.raised", "orange")
        case .delivered:
            if review != nil { ("Ждёт проверки в Mora: нажмите, чтобы проверить", "tray", "orange") }
            else if run.serverState == "recorded" { ("Расход записан", "checkmark", "green") }
            else { ("Доставлено в общую базу", "checkmark", "green") }
        case .failed: ("Сервер не принял покупку", "xmark", "orange")
        case .skipped: ("Не учитывается: записано вручную или исключено", "minus", "gray")
        case .duplicate: ("Пустой повтор запуска, не отправлен", "minus", "gray")
        }
    }
}

/// Everything Mora knows about one run: what Wallet passed, each delivery
/// attempt and what the user can do with it.
struct WalletRunDetailScreen: View {
    @EnvironmentObject private var cloud: CloudSync
    @EnvironmentObject private var router: AppRouter
    let id: UUID
    @State private var run: WalletRun?
    @State private var working = false

    var body: some View {
        Form {
            if let run {
                let review = cloud.review(for: run)
                let status = WalletRunsScreen.status(run, review: review)
                Section {
                    Label(L(status.text), systemImage: status.icon).foregroundStyle(status.color == "orange" ? Color.orange : Color.primary)
                    if let review {
                        Button { router.open(.walletReview(review)) } label: { Label(L("Проверить покупку"), systemImage: "square.and.pencil") }
                    }
                    if [.incomplete, .late, .failed, .skipped, .duplicate].contains(run.delivery) {
                        Button { act { await WalletDelivery.shared.confirm(run.id, with: WalletSender.current()) } } label: {
                            Label(L("Отправить на проверку в Mora"), systemImage: "paperplane")
                        }
                    }
                    if run.delivery == .waiting || run.delivery == .awaitingAmount {
                        Button { act { await WalletBackgroundDelivery.run() } } label: { Label(L("Отправить сейчас"), systemImage: "arrow.up.circle") }
                    }
                    if [.incomplete, .late, .failed, .waiting, .awaitingAmount].contains(run.delivery) {
                        Button(role: .destructive) { act { await WalletDelivery.shared.skip(run.id) } } label: {
                            Label(L("Не учитывать"), systemImage: "minus.circle")
                        }
                    }
                } footer: {
                    if let error = run.lastError, run.needsDelivery || run.delivery == .failed { Text(L(error)) }
                }
                Section {
                    LabeledContent(L("Время"), value: run.receivedAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().second().locale(L10n.locale)))
                    LabeledContent(L("Сумма"), value: run.amount.isEmpty ? "—" : run.amount)
                    LabeledContent(L("Продавец"), value: run.merchant.isEmpty ? "—" : run.merchant)
                    LabeledContent(L("Название"), value: run.name.isEmpty ? "—" : run.name)
                    LabeledContent(L("Карта"), value: run.card.isEmpty ? "—" : run.card)
                    if !run.action.isEmpty { LabeledContent(L("Действие"), value: run.action) }
                    LabeledContent(L("Попыток отправки"), value: "\(run.attempts)")
                } header: { Text(L("Что передал Wallet")) }
                Section {
                    if run.events.isEmpty { Text(L("Журнал событий появился в Mora 1.0.23")).foregroundStyle(.secondary) }
                    ForEach(Array(run.events.enumerated().reversed()), id: \.offset) { _, event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L(event.text)).font(.subheadline)
                            Text(event.date.formatted(.dateTime.hour().minute().second().locale(L10n.locale))).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text(L("События")) }
            }
        }
        .navigationTitle(L("Запуск Wallet"))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
        .onAppear(perform: reload)
    }

    private func reload() { run = WalletRunLog.runs().first { $0.id == id } }

    private func act(_ action: @escaping () async -> Void) {
        Task {
            working = true
            await action()
            await cloud.refreshLists()
            reload(); working = false
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
}
