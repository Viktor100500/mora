import SwiftUI
import FinanceCore

/// One message: its text, the fields Mora read and, for a new format, the check
/// that teaches Mora the format. The merchant is picked by tapping words of the text.
struct BankAlertDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var cloud: CloudSync
    @State var alert: BankAlert
    /// Where the same purchase was found again, from the journal.
    var duplicate: String?
    @State private var selection: ClosedRange<Int>?
    @State private var working = false
    @State private var result: String?

    private var editable: Bool { alert.needsUser || (alert.state == .duplicate && !alert.text.isEmpty) }
    /// Only the format is remembered: the purchase itself already came another way.
    private var learnOnly: Bool { alert.state == .duplicate }
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
                SourceBadge(CaptureAutomation.source(of: alert))
                Label(L(AutomationStatus.bank(alert).text), systemImage: AutomationStatus.bank(alert).icon)
                if let error = alert.lastError { Text(L(error)).font(.caption).foregroundStyle(.secondary) }
                if let result { Text(L(result)).font(.caption).foregroundStyle(.green) }
            }
            if let duplicate {
                Section { Label(duplicate, systemImage: "square.on.square") } header: { Text(L("Дубли")) }
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
            Section {
                Button(role: .destructive) { BankAlertLog.remove(alert.id); dismiss() } label: { Label(L("Удалить из журнала"), systemImage: "trash") }
            }
        }
        .wrappingTitle(L(alert.wallet == true ? "Уведомление Wallet" : "Сообщение банка"))
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
            let learned = await BankAlertDelivery.shared.confirm(alert, sending: WalletSender.current() != nil)
            await cloud.refreshLists()
            if learned { dismiss() } else { result = "Покупка отправлена, но формат не запомнен: выберите продавца из текста." }
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
