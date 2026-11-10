import SwiftUI
import FinanceCore

/// Bank SMS and app notifications: how to connect them, messages waiting for a
/// first check, the journal and the remembered formats.
struct BankAlertsScreen: View {
    @EnvironmentObject private var cloud: CloudSync
    @Environment(\.scenePhase) private var scenePhase
    @State private var alerts: [BankAlert] = []
    @State private var templates: [BankMessageTemplate] = []

    private var review: [BankAlert] { alerts.filter(\.needsUser) }
    private var journal: [BankAlert] { alerts.filter { !$0.needsUser } }

    var body: some View {
        List {
            if WalletSender.current() == nil {
                Section {
                    NavigationLink { WalletSetupScreen() } label: { Label(L("Включить Apple Pay на iPhone"), systemImage: "wallet.pass") }
                } footer: { Text(L("Покупки из SMS и уведомлений уходят в общую базу тем же ключом телефона, что и Apple Pay. Пока он не включён, Mora только показывает сообщения здесь.")) }
            }
            if !review.isEmpty {
                Section {
                    ForEach(review) { alert in
                        NavigationLink { BankAlertDetailScreen(alert: alert) } label: { Self.row(alert) }
                    }
                } header: { Text(L("Проверьте один раз")) } footer: {
                    Text(L("Проверьте сумму и продавца в первом сообщении нового формата. Mora запомнит формат, и следующие такие сообщения запишутся сами."))
                }
            }
            Section {
                NavigationLink { BankAlertSetupScreen(kind: .sms) } label: { Label(L("Банковские SMS"), systemImage: "message") }
                NavigationLink { BankAlertSetupScreen(kind: .notification) } label: { Label(L("Уведомления приложений банков"), systemImage: "bell.badge") }
                NavigationLink { BankAlertSampleScreen() } label: { Label(L("Проверить на примере"), systemImage: "text.magnifyingglass") }
            } header: { Text(L("Подключение")) }
            if !templates.isEmpty {
                Section {
                    ForEach(templates) { template in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(template.sender.isEmpty ? L("Любой отправитель") : template.sender).font(.body.weight(.medium))
                            Text(template.pattern).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    .onDelete { offsets in
                        var all = templates; all.remove(atOffsets: offsets)
                        try? BankAlertLog.saveTemplates(all); reload()
                    }
                } header: { Text(L("Запомненные форматы")) } footer: {
                    Text(L("Сообщения в этих форматах записываются без проверки. Смахните формат, чтобы снова проверять такие сообщения."))
                }
            }
            Section {
                if journal.isEmpty { Text(L("Сообщений пока нет")).foregroundStyle(.secondary) }
                ForEach(journal.prefix(50)) { alert in
                    NavigationLink { BankAlertDetailScreen(alert: alert) } label: { Self.row(alert) }
                }
            } header: { Text(L("Журнал")) } footer: {
                Text(L("Коды подтверждения и сообщения без покупки Mora не сохраняет: в журнале остаётся только строка о том, что сообщение пропущено."))
            }
        }
        .navigationTitle(L("SMS и уведомления"))
        .refreshable { await BankAlertDelivery.shared.deliverWaiting(); await cloud.refreshLists(); reload() }
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
    }

    private func reload() { alerts = BankAlertLog.alerts(); templates = BankAlertLog.templates() }

    static func row(_ alert: BankAlert) -> some View {
        let status = status(alert)
        return HStack(spacing: 12) {
            IconTile(icon: status.icon, color: status.color, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.merchant.isEmpty ? (alert.source.isEmpty ? L("Сообщение") : alert.source) : alert.merchant).font(.body.weight(.medium))
                Text(L(status.text)).font(.caption).foregroundStyle(status.color == "orange" ? Color.orange : Color.secondary)
                Text([alert.source.isEmpty ? nil : alert.card,
                      alert.receivedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(L10n.locale))]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if !alert.amount.isEmpty {
                FinancialText([alert.income ? "+" + alert.amount : alert.amount, alert.currency].filter { !$0.isEmpty }.joined(separator: " "))
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    static func status(_ alert: BankAlert) -> (text: String, icon: String, color: String) {
        switch alert.state {
        case .ignored:
            switch alert.ignoredReason {
            case .oneTimeCode: ("Код подтверждения: пропущен, текст не сохранён", "lock", "gray")
            case .fraudCheck: ("Проверка операции банком: пропущена", "shield", "gray")
            case .declined: ("Отклонённая операция: пропущена", "xmark", "gray")
            default: ("Не покупка: пропущено, текст не сохранён", "minus", "gray")
            }
        case .review: ("Новый формат: проверьте один раз", "hand.tap", "orange")
        case .logged: ("Только журнал: Apple Pay в Mora не включён", "list.bullet", "gray")
        case .waiting: ("Сохранено на iPhone, уйдёт при появлении интернета", "clock", "orange")
        case .delivered: (alert.serverState == "recorded" ? "Расход записан" : "Доставлено, ждёт проверки в Mora", "checkmark", "green")
        case .failed: ("Сервер не принял покупку", "xmark", "orange")
        case .duplicate: ("Уже пришло из Wallet: не отправлено", "square.on.square", "gray")
        case .skipped: ("Не учитывается", "minus", "gray")
        }
    }
}

/// Step-by-step automation setup. Mora cannot create automations itself, so the
/// user builds one with a single Mora action.
struct BankAlertSetupScreen: View {
    enum Kind { case sms, notification }
    let kind: Kind

    var body: some View {
        Form {
            switch kind {
            case .sms:
                Section {
                    step(1, "Откройте «Быстрые команды» → «Автоматизация» → «+» → «Сообщение».")
                    step(2, "В поле «Сообщение содержит» введите символ валюты ваших покупок, например «$», «€» или «USD». Отправителя можно не выбирать.")
                    step(3, "Выберите «Запускать сразу» и «Далее».")
                    step(4, "Добавьте действие Mora «Log Bank Message». В «Text» выберите «Входные данные команды» → «Содержимое», в «From» — «Входные данные команды» → «Отправитель».")
                    step(5, "Для других валют добавьте такие же автоматизации с другим символом.")
                } header: { Text(L("Автоматизация «Сообщение»")) } footer: {
                    Text(L("Символ валюты есть почти в каждом сообщении о покупке, поэтому подбирать слова для каждого банка не нужно. Сообщения без покупки и коды подтверждения Mora сразу пропускает и не сохраняет."))
                }
            case .notification:
                Section {
                    step(1, "Нужна iOS 27. Откройте «Быстрые команды» → «Автоматизация» → «+» → «Уведомление».")
                    step(2, "Выберите приложение банка или карты, например Bybit или Chase. Фильтры по тексту можно не задавать.")
                    step(3, "Выберите «Запускать сразу» и «Далее».")
                    step(4, "Добавьте действие Mora «Log Bank Message». В «Text» выберите «Уведомление» → «Текст», в «Title» — «Уведомление» → «Заголовок», в «From» впишите название приложения.")
                    step(5, "Для каждого приложения банка сделайте свою автоматизацию. Добавьте такую же для Wallet: его уведомление приносит сумму и продавца проезда в транспорте, которых ещё нет в момент оплаты.")
                } header: { Text(L("Автоматизация «Уведомление»")) } footer: {
                    Text(L("Так ловятся карты без SMS: Mora получает текст уведомления о покупке. Уведомления приложения должны быть включены в настройках iPhone."))
                }
            }
            Section {
                Text(L("Первое сообщение каждого банка появится в «Проверьте один раз». Проверьте сумму и продавца — следующие сообщения в том же формате запишутся сами. Если карта новая, Mora один раз спросит, к какому счёту её относить."))
                    .font(.subheadline)
            } header: { Text(L("Что будет дальше")) }
        }
        .navigationTitle(L(kind == .sms ? "Банковские SMS" : "Уведомления банков"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.subheadline.weight(.bold)).foregroundStyle(.tint).frame(width: 18)
            Text(L(text)).font(.subheadline)
        }
    }
}

/// Pasting a real message shows what Mora understands before any automation runs.
struct BankAlertSampleScreen: View {
    @State private var text = ""
    @State private var source = ""
    @State private var alert: BankAlert?

    var body: some View {
        Form {
            Section {
                TextField(L("Отправитель или приложение, например Raiffeisen"), text: $source)
                    .textInputAutocapitalization(.never)
                TextEditor(text: $text).frame(minHeight: 140)
                Button { check() } label: { Label(L("Проверить"), systemImage: "text.magnifyingglass") }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: { Text(L("Вставьте сообщение о покупке")) } footer: {
                Text(L("Скопируйте SMS или текст уведомления банка. Цифры карты и суммы можно не менять: пример остаётся на iPhone."))
            }
            if let alert {
                if alert.state == .ignored {
                    Section { Label(L(BankAlertsScreen.status(alert).text), systemImage: "minus.circle") }
                } else {
                    Section {
                        NavigationLink { BankAlertDetailScreen(alert: alert, sample: true) } label: { BankAlertsScreen.row(alert) }
                    } footer: { Text(L("Откройте, чтобы поправить поля и запомнить формат.")) }
                }
            }
        }
        .navigationTitle(L("Проверить на примере"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func check() {
        var value = BankAlert(receivedAt: .now, source: source.trimmingCharacters(in: .whitespaces), text: BankMessage.normalized(text), state: .review)
        switch BankMessage.parse(text, sender: value.source, templates: BankAlertLog.templates()) {
        case .ignored(let reason): value.state = .ignored; value.ignoredReason = reason; value.text = ""
        case .parsed(let parsed): value.apply(parsed)
        }
        alert = value
    }
}

/// One message: its text, the fields Mora read and, for a new format, the check
/// that teaches Mora the format. The merchant is picked by tapping words of the text.
struct BankAlertDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var cloud: CloudSync
    @State var alert: BankAlert
    var sample = false
    @State private var selection: ClosedRange<Int>?
    @State private var working = false
    @State private var result: String?

    private var editable: Bool { sample || alert.needsUser || (alert.state == .duplicate && !alert.text.isEmpty) }
    /// Only the format is remembered: the purchase itself already came from Wallet.
    private var learnOnly: Bool { sample || alert.state == .duplicate }
    private var words: [(text: String, range: Range<String.Index>)] {
        var result: [(String, Range<String.Index>)] = []
        var start: String.Index?
        for index in alert.text.indices {
            if alert.text[index].isWhitespace {
                if let begin = start { result.append((String(alert.text[begin..<index]), begin..<index)); start = nil }
            } else if start == nil { start = index }
        }
        if let begin = start { result.append((String(alert.text[begin...]), begin..<alert.text.endIndex)) }
        return result
    }

    var body: some View {
        Form {
            Section {
                Label(L(BankAlertsScreen.status(alert).text), systemImage: BankAlertsScreen.status(alert).icon)
                if let error = alert.lastError { Text(L(error)).font(.caption).foregroundStyle(.secondary) }
                if let result { Text(L(result)).font(.caption).foregroundStyle(.green) }
            }
            if !alert.text.isEmpty {
                Section {
                    if editable {
                        WordFlow(words: words.map(\.text), selection: selection) { tap($0) }
                    } else {
                        Text(alert.text).font(.callout).textSelection(.enabled)
                    }
                } header: { Text(L(alert.source.isEmpty ? "Текст" : alert.source)) } footer: {
                    if editable { Text(L("Нажмите первое и последнее слово продавца, чтобы выбрать его из текста.")) }
                }
            }
            Section {
                if editable {
                    TextField(L("Сумма"), text: $alert.amount).keyboardType(.decimalPad)
                    TextField(L("Валюта, например USD"), text: $alert.currency).textInputAutocapitalization(.characters)
                    TextField(L("Продавец"), text: $alert.merchant)
                    TextField(L("Последние 4 цифры карты"), text: $alert.cardLast4).keyboardType(.numberPad)
                    Toggle(L("Возврат или зачисление"), isOn: $alert.income)
                } else {
                    LabeledContent(L("Сумма"), value: alert.amount.isEmpty ? "—" : alert.amount)
                    LabeledContent(L("Валюта"), value: alert.currency.isEmpty ? "—" : alert.currency)
                    LabeledContent(L("Продавец"), value: alert.merchant.isEmpty ? "—" : alert.merchant)
                    LabeledContent(L("Карта"), value: alert.card)
                }
            } header: { Text(L("Что прочитала Mora")) }
            if editable {
                Section {
                    Button { confirm() } label: {
                        Label(L(learnOnly ? "Запомнить формат" : "Записать и запомнить формат"), systemImage: "checkmark.circle")
                    }.disabled(alert.parsed == nil || alert.merchant.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !learnOnly {
                        Button(role: .destructive) { Task { await BankAlertDelivery.shared.skip(alert.id); dismiss() } } label: {
                            Label(L("Не учитывать"), systemImage: "minus.circle")
                        }
                    }
                } footer: {
                    Text(L("Формат запоминается, только если сумма и продавец взяты из текста сообщения."))
                }
            }
            if !sample {
                Section {
                    Button(role: .destructive) { BankAlertLog.remove(alert.id); dismiss() } label: { Label(L("Удалить из журнала"), systemImage: "trash") }
                }
            }
        }
        .navigationTitle(L("Сообщение банка"))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
    }

    private func tap(_ index: Int) {
        if let current = selection, current.count == 1, index > current.lowerBound { selection = current.lowerBound...index }
        else { selection = index...index }
        guard let range = selection else { return }
        let all = words
        let text = String(alert.text[all[range.lowerBound].range.lowerBound..<all[range.upperBound].range.upperBound])
        alert.merchantText = text
        alert.merchant = text.trimmingCharacters(in: CharacterSet(charactersIn: " .,:-\"'«»"))
    }

    private func confirm() {
        // An amount typed by hand is not part of the text, so the format keeps the one Mora found.
        if let parsed = alert.parsed, !alert.amountText.isEmpty, case .parsed(let found) = BankMessage.parse(alert.text),
           found.amount != parsed.amount { alert.amountText = "" }
        working = true
        Task {
            if sample {
                let learned = alert.parsed.flatMap { try? BankAlertLog.learn(from: alert.text, source: alert.source, parsed: $0) } != nil
                result = learned ? "Формат запомнен: такие сообщения будут записываться сами." : "Формат не запомнен: выберите продавца из текста."
            } else {
                let learned = await BankAlertDelivery.shared.confirm(alert, sending: WalletSender.current() != nil)
                await cloud.refreshLists()
                if learned { dismiss() } else { result = "Покупка отправлена, но формат не запомнен: выберите продавца из текста." }
            }
            working = false
        }
    }
}

/// Words of a message as tappable chips that wrap like text.
private struct WordFlow: View {
    let words: [String]
    let selection: ClosedRange<Int>?
    let tap: (Int) -> Void

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                let selected = selection?.contains(index) == true
                Text(word).font(.callout)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    .onTapGesture { tap(index) }
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var items: [Int] = [], x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append((items, y, x - spacing, height)); y += height + spacing
                items = []; x = 0; height = 0
            }
            items.append(index); x += size.width + spacing; height = max(height, size.height)
        }
        if !items.isEmpty { rows.append((items, y, x - spacing, height)) }
        return rows
    }
}
