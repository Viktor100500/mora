import SwiftUI
import FinanceCore

/// Everything that collects purchases on this iPhone automatically: the Shortcuts
/// automations, where their purchases go, what waits for review and the journal.
struct AutomationScreen: View {
    @EnvironmentObject private var cloud: CloudSync
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var queue: WalletReviewQueue
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmClear = false
    @State private var sending = false
    @State private var openedBank: UUID?
    @State private var templates: [BankMessageTemplate] = []

    private var entries: [AutomationEntry] { AutomationJournal.entries(runs: queue.runs, alerts: queue.alerts) }
    private var waiting: Bool {
        queue.runs.contains { $0.delivery == .waiting || $0.delivery == .awaitingAmount } || queue.alerts.contains { $0.state == .waiting }
    }

    var body: some View {
        List {
            automationsSection
            reviewSection
            journalSection
            if !templates.isEmpty {
                Section {
                    NavigationLink { BankFormatsScreen() } label: {
                        LabeledContent { Text("\(templates.count)") } label: { Label(L("Запомненные форматы банков"), systemImage: "text.badge.checkmark") }
                    }
                } footer: { Text(L("Сообщения в этих форматах записываются без проверки.")) }
            }
        }
        .wrappingTitle(L("Автоматизация / Быстрые команды"))
        .toolbar { toolbar }
        .navigationDestination(item: $openedBank) { id in
            if let alert = queue.alerts.first(where: { $0.id == id }) {
                BankAlertDetailScreen(alert: alert, duplicate: AutomationJournal.duplicateNote(for: alert, alerts: queue.alerts))
            }
        }
        .confirmationDialog(L("Очистить журнал?"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(L("Очистить"), role: .destructive) { WalletRunLog.clear(); BankAlertLog.clear(); reload() }
        } message: { Text(L("Покупки, которые ждут отправки или проверки, останутся.")) }
        .refreshable { await deliver(); await cloud.refreshLists() }
        .onAppear(perform: reload)
        .onChange(of: router.sheet == nil) { _, closed in if closed { reload() } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
    }

    private func reload() { CaptureAutomation.resetOnceForFreshSetup(); queue.reload(); templates = BankAlertLog.templates() }

    private func deliver() async {
        sending = true
        await WalletBackgroundDelivery.run()
        await BankAlertDelivery.shared.deliverWaiting()
        reload(); sending = false
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if !entries.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if waiting {
                        Button { Task { await deliver() } } label: { Label(L("Отправить ожидающие"), systemImage: "paperplane") }.disabled(sending)
                    }
                    ShareLink(item: WalletRunLog.export(), preview: SharePreview(L("Журнал запусков Wallet"))) {
                        Label(L("Экспорт запусков Wallet"), systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) { confirmClear = true } label: { Label(L("Очистить журнал"), systemImage: "trash") }
                } label: { Label(L("Журнал"), systemImage: "ellipsis.circle") }
            }
        }
    }

    // MARK: Automations

    private var automationsSection: some View {
        Section {
            ForEach(CaptureAutomation.allCases) { automation in
                let state = automation.setupState(runs: queue.runs, alerts: queue.alerts)
                AutomationRow(automation: automation, state: state,
                              lastRun: automation.lastRun(runs: queue.runs, alerts: queue.alerts)) {
                    router.open(state == .notSet ? .automationGuide(automation) : .automationWaiting(automation))
                }
            }
        } header: { Text(L("Быстрые команды")) } footer: {
            Text(L("Каждая автоматизация — отдельная команда со своим действием Mora. Включите те, что подходят вашим картам: если одна покупка придёт из нескольких, Mora объединит их и покажет это в журнале."))
        }
    }

    // MARK: Review

    @ViewBuilder private var reviewSection: some View {
        let items = queue.items(cloud: cloud)
        Section {
            if items.isEmpty {
                Label(L("Все покупки проверены"), systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
            ForEach(items.prefix(5)) { item in
                Button { open(item) } label: { ReviewRow(item: item) }.buttonStyle(.plain)
            }
            if items.count > 5 {
                NavigationLink { WalletReviewScreen() } label: { Text(L("Все покупки на проверку: \(items.count)")) }
            }
        } header: { Text(L("На проверку")) } footer: {
            if !items.isEmpty { Text(L("Покупки, которые пришли не полностью, в новом формате банка или с новой карты. Нажмите, чтобы проверить.")) }
        }
    }

    private func open(_ item: ReviewItem) {
        switch item.origin {
        case .iPhone(let run): router.open(cloud.processing(run, review: nil))
        case .server(let capture): router.open(.walletReview(capture))
        case .bank(let alert): openedBank = alert.id
        }
    }

    // MARK: Journal

    private var journalSection: some View {
        Section {
            let all = entries
            if all.isEmpty { Text(L("Записей пока нет")).foregroundStyle(.secondary) }
            ForEach(all.prefix(100)) { entry in
                NavigationLink { AutomationEntryScreen(entry: entry) } label: { AutomationEntryRow(entry: entry) }
            }
        } header: { Text(L("Журнал")) } footer: {
            Text(L("Здесь каждый запуск автоматизаций за 14 дней: откуда пришла покупка, что с ней стало и где найден её дубль. Коды подтверждения и сообщения без покупки Mora не сохраняет — остаётся только строка о том, что сообщение пропущено."))
        }
    }
}

/// One automation: what it does, whether it works and its own setup button.
private struct AutomationRow: View {
    let automation: CaptureAutomation
    let state: CaptureAutomation.SetupState
    let lastRun: Date?
    let action: () -> Void

    /// A soft yellow that stays readable in light and dark mode.
    private static let waitingColor = Color(red: 0.86, green: 0.66, blue: 0.12)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(icon: automation.icon, color: automation.color, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(automation.title).font(.headline)
                    Text(automation.summary).font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(action: action) {
                    Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered).controlSize(.small).tint(tint)
                .disabled(!automation.available)
                // Only a counted purchase has a time worth showing: next to Set Up or Waiting,
                // an old journal entry would contradict the button.
                if let lastRun, automation.available, state == .working {
                    Text(lastRun.formatted(.relative(presentation: .named).locale(L10n.locale)))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.leading, 52)
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        guard automation.available else { return L("Нужна iOS 27") }
        return switch state {
        case .notSet: L("Настроить")
        case .waiting: L("Ждём покупку")
        case .working: L("Работает")
        }
    }

    private var icon: String {
        guard automation.available else { return "lock" }
        return switch state {
        case .notSet: "wand.and.stars"
        case .waiting: "hourglass"
        case .working: "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .notSet: .moraGreen
        case .waiting: Self.waitingColor
        case .working: .green
        }
    }
}

/// A journal line: source, outcome and duplicate handling of one run or message.
struct AutomationEntryRow: View {
    @EnvironmentObject private var cloud: CloudSync
    let entry: AutomationEntry

    var body: some View {
        let status = AutomationStatus.of(entry, cloud: cloud)
        HStack(alignment: .top, spacing: 12) {
            IconTile(icon: status.icon, color: status.color, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.body.weight(.medium)).lineLimit(2)
                    Spacer(minLength: 8)
                    if !amount.isEmpty { FinancialText(amount).font(.subheadline.weight(.semibold)) }
                }
                SourceBadge(entry.source)
                Text(L(status.text)).font(.caption).foregroundStyle(status.color == "orange" ? Color.orange : Color.secondary)
                if let duplicate = entry.duplicate {
                    Label(duplicate, systemImage: "square.on.square").font(.caption).foregroundStyle(.secondary)
                }
                Text(meta).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        switch entry.item {
        case .wallet(let run): run.sentMerchant.isEmpty ? L("Без продавца") : run.sentMerchant
        case .bank(let alert): alert.merchant.isEmpty ? (alert.source.isEmpty ? L("Сообщение") : alert.source) : alert.merchant
        }
    }

    private var amount: String {
        switch entry.item {
        case .wallet(let run): run.amount
        case .bank(let alert):
            alert.amount.isEmpty ? "" : [alert.income ? "+" + alert.amount : alert.amount, alert.currency].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    private var meta: String {
        let date = entry.date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(L10n.locale))
        switch entry.item {
        case .wallet(let run): return [run.card.isEmpty ? L("Карта не передана") : run.card, date].joined(separator: " · ")
        case .bank(let alert): return [alert.source.isEmpty ? nil : alert.card, date].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

/// Status texts of journal entries.
@MainActor enum AutomationStatus {
    static func of(_ entry: AutomationEntry, cloud: CloudSync) -> (text: String, icon: String, color: String) {
        switch entry.item {
        case .wallet(let run): wallet(run, review: cloud.review(for: run))
        case .bank(let alert): bank(alert)
        }
    }

    /// `review` is the server inbox entry of this run while it still needs the user.
    static func wallet(_ run: WalletRun, review: CloudCapture?) -> (text: String, icon: String, color: String) {
        switch run.delivery {
        case .logged: ("Только журнал: отправка в общую базу не включена", "list.bullet", "gray")
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
        case .duplicate: run.isEmpty ? ("Пустой повтор запуска", "minus", "gray") : ("Дубль: не отправлено", "square.on.square", "gray")
        }
    }

    static func bank(_ alert: BankAlert) -> (text: String, icon: String, color: String) {
        switch alert.state {
        case .ignored:
            switch alert.ignoredReason {
            case .oneTimeCode: ("Код подтверждения: пропущен, текст не сохранён", "lock", "gray")
            case .fraudCheck: ("Проверка операции банком: пропущена", "shield", "gray")
            case .declined: ("Отклонённая операция: пропущена", "xmark", "gray")
            default: alert.wallet == true ? ("Уведомление без покупки: пропущено", "minus", "gray")
                : ("Не покупка: пропущено, текст не сохранён", "minus", "gray")
            }
        case .review: ("Новый формат: проверьте один раз", "hand.tap", "orange")
        case .logged: ("Только журнал: отправка в общую базу не включена", "list.bullet", "gray")
        case .waiting: ("Сохранено на iPhone, уйдёт при появлении интернета", "clock", "orange")
        case .delivered: (alert.serverState == "recorded" ? "Расход записан" : "Доставлено, ждёт проверки в Mora", "checkmark", "green")
        case .failed: ("Сервер не принял покупку", "xmark", "orange")
        case .duplicate: alert.completedWallet == true ? ("Дополнило покупку Wallet", "square.on.square", "gray") : ("Дубль: не отправлено", "square.on.square", "gray")
        case .skipped: ("Не учитывается", "minus", "gray")
        }
    }
}

/// Details of a journal entry.
struct AutomationEntryScreen: View {
    let entry: AutomationEntry

    var body: some View {
        switch entry.item {
        case .wallet(let run): WalletRunDetailScreen(run: run, duplicate: entry.duplicate)
        case .bank(let alert): BankAlertDetailScreen(alert: alert, duplicate: entry.duplicate)
        }
    }
}

/// One run of the Wallet "Transaction" automation: what Wallet passed and its history.
struct WalletRunDetailScreen: View {
    @EnvironmentObject private var cloud: CloudSync
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    let run: WalletRun
    let duplicate: String?

    var body: some View {
        let review = cloud.review(for: run)
        let status = AutomationStatus.wallet(run, review: review)
        Form {
            Section {
                SourceBadge(.walletTransaction)
                Label(L(status.text), systemImage: status.icon)
                if let error = run.lastError { Text(L(error)).font(.caption).foregroundStyle(.secondary) }
                if run.needsProcessing || review != nil {
                    Button { router.open(cloud.processing(run, review: review)) } label: { Label(L("Обработать"), systemImage: "square.and.pencil") }
                }
            }
            if let duplicate {
                Section { Label(duplicate, systemImage: "square.on.square") } header: { Text(L("Дубли")) }
            }
            Section {
                LabeledContent(L("Сумма"), value: run.amount.isEmpty ? "—" : run.amount)
                LabeledContent(L("Продавец"), value: run.sentMerchant.isEmpty ? "—" : run.sentMerchant)
                LabeledContent(L("Карта"), value: run.card.isEmpty ? "—" : run.card)
                if !run.name.isEmpty { LabeledContent(L("Имя"), value: run.name) }
                if !run.action.isEmpty { LabeledContent(L("Действие"), value: run.action) }
            } header: { Text(L("Что передал Wallet")) }
            if !run.events.isEmpty {
                Section {
                    ForEach(Array(run.events.enumerated().reversed()), id: \.offset) { _, event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L(event.text)).font(.subheadline)
                            Text(event.date.formatted(.dateTime.day().month(.abbreviated).hour().minute().second().locale(L10n.locale)))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text(L("История")) }
            }
            if run.needsProcessing {
                Section {
                    Button(role: .destructive) { Task { await WalletDelivery.shared.skip(run.id); dismiss() } } label: {
                        Label(L("Не учитывать"), systemImage: "minus.circle")
                    }
                }
            }
        }
        .wrappingTitle(L("Запуск Wallet"))
    }
}

/// Bank wordings remembered after a check: messages in them are booked without review.
struct BankFormatsScreen: View {
    @State private var templates: [BankMessageTemplate] = []

    var body: some View {
        List {
            Section {
                if templates.isEmpty { Text(L("Форматов пока нет")).foregroundStyle(.secondary) }
                ForEach(templates) { template in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(template.sender.isEmpty ? L("Любой отправитель") : template.sender).font(.body.weight(.medium))
                        Text(template.pattern).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                .onDelete { offsets in
                    var all = templates; all.remove(atOffsets: offsets)
                    try? BankAlertLog.saveTemplates(all); templates = BankAlertLog.templates()
                }
            } footer: {
                Text(L("Сообщения в этих форматах записываются без проверки. Смахните формат, чтобы снова проверять такие сообщения."))
            }
        }
        .wrappingTitle(L("Запомненные форматы банков"))
        .onAppear { templates = BankAlertLog.templates() }
    }
}
