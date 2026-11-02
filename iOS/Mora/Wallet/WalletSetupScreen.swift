import SwiftUI
import FinanceCore

/// Turns on sending Wallet purchases from this iPhone: cards and accounts first,
/// then Mora creates its own phone key. Without Mora on the iPhone, the Mac
/// creates a shortcut instead.
struct WalletSetupScreen: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var cloud: CloudSync
    @State private var sender = WalletSender.current()
    @State private var label = UIDevice.current.name
    @State private var cards: [WalletCardAssignment] = []
    @State private var confirmDisable = false
    @State private var cardHelp: UUID?
    /// Exact "Card or Pass" values that Wallet already passed to the action on this iPhone.
    @State private var seenCards: [String] = []

    static let cardHelpText = "Это название, которое iPhone передаёт в автоматизацию в поле «Card or Pass». Обычно оно совпадает с подписью карты в приложении Wallet, например «Chase Freedom Unlimited» или «Raiffeisen Visa». Регистр и лишние пробелы не важны, остальное должно совпадать.\n\nНадёжнее всего: оплатите один раз этой картой — точное название появится в «Запусках Wallet» и в подсказках под списком карт."
    private var suggestions: [String] {
        let used = Set(cards.map { $0.card.trimmingCharacters(in: .whitespaces).lowercased() })
        return seenCards.filter { !used.contains($0.lowercased()) }
    }

    private var accounts: [Account] { store.ledger.accounts.filter { !$0.archived } }
    private static let unselected = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    private var ready: Bool {
        !cards.isEmpty && cards.allSatisfy { !$0.card.trimmingCharacters(in: .whitespaces).isEmpty && $0.account_id != Self.unselected }
    }

    var body: some View {
        Form {
            if let expiration = AppSignature.expiration {
                Section {
                    Label(L("Подпись Mora действует до \(expiration.formatted(date: .abbreviated, time: .omitted))"),
                          systemImage: AppSignature.expiresSoon() ? "exclamationmark.triangle" : "checkmark.seal")
                        .foregroundStyle(AppSignature.expiresSoon() ? .orange : .secondary)
                } footer: { Text(L("Когда подпись закончится, Mora не откроется и действие в автоматизации перестанет записывать покупки. Переустановите Mora с Mac заранее: данные сохранятся.")) }
            }
            if let sender { enabled(sender) } else { setup }
            Section {
                NavigationLink { WalletRunsScreen() } label: { Label(L("Запуски Wallet"), systemImage: "list.bullet.rectangle") }
            }
        }
        .navigationTitle(L("Apple Pay на iPhone"))
        .disabled(cloud.busy)
        .overlay { if cloud.busy { ProgressView().controlSize(.large) } }
        .onAppear {
            sender = WalletSender.current(); if cards.isEmpty { addCard() }
            var seen = Set<String>()
            seenCards = WalletRunLog.runs().map(\.card).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        }
        .confirmationDialog(L("Отключить Apple Pay на этом iPhone?"), isPresented: $confirmDisable, titleVisibility: .visible) {
            Button(L("Отключить"), role: .destructive) { Task { await cloud.disableWalletSender(); sender = WalletSender.current() } }
        } message: { Text(L("Ключ телефона будет отозван. Покупки, которые ещё ждут отправки, останутся на iPhone.")) }
    }

    @ViewBuilder private func enabled(_ sender: WalletSender) -> some View {
        Section {
            LabeledContent(L("Ключ телефона"), value: sender.label)
            if cloud.householdID != sender.householdID {
                Label(L("Ключ создан для другой общей базы. Отключите Apple Pay и включите заново."), systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
        } header: { Text(L("Apple Pay включён")) } footer: {
            Text(L("Счета карт меняются в разделе «Карты Apple Pay» общей базы. Новая карта появится там после первой покупки и будет ждать выбора счёта."))
        }
        Section {
            Text(L("1. Быстрые команды → Автоматизация → «Транзакция»: отметьте все карты и включите «Запускать сразу».\n2. Оставьте в автоматизации одно действие «Log Wallet Payment» (Mora): Amount, Merchant и Card or Pass из «Входных данных команды».\n3. Удалите из автоматизации прежнюю команду отправки, иначе покупка придёт дважды."))
                .font(.subheadline)
        } header: { Text(L("Автоматизация на iPhone")) }
        Section { Button(L("Отключить Apple Pay на этом iPhone"), role: .destructive) { confirmDisable = true } }
    }

    @ViewBuilder private var setup: some View {
        if cloud.householdID == nil {
            Section { Text(L("Сначала подключите iPhone к общей базе.")).foregroundStyle(.secondary) }
        } else {
            Section {
                TextField(L("Название iPhone"), text: $label)
            } footer: { Text(L("Под этим названием покупки iPhone видны в Mora.")) }
            Section {
                ForEach($cards) { $card in
                    VStack(alignment: .leading) {
                        HStack {
                            TextField(L("Название карты в Wallet"), text: $card.card).textInputAutocapitalization(.words)
                            Button { cardHelp = card.id } label: { Image(systemName: "questionmark.circle") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(L("Что такое название карты в Wallet"))
                                .popover(isPresented: Binding(get: { cardHelp == card.id }, set: { if !$0 { cardHelp = nil } })) {
                                    Text(L(Self.cardHelpText)).font(.callout).padding().frame(idealWidth: 320)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .presentationCompactAdaptation(.popover)
                                }
                        }
                        Picker(L("Счёт"), selection: $card.account_id) {
                            Text(L("Выберите счёт")).tag(Self.unselected)
                            ForEach(accounts) { Text("\($0.name) · \($0.currency)").tag($0.id) }
                        }
                    }
                }
                .onDelete { cards.remove(atOffsets: $0) }
                Button { addCard() } label: { Label(L("Добавить карту"), systemImage: "plus") }
                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Карты из последних оплат — нажмите, чтобы подставить:")).font(.footnote).foregroundStyle(.secondary)
                        ForEach(suggestions, id: \.self) { name in
                            Button { use(name) } label: { Label(name, systemImage: "creditcard") }.buttonStyle(.borderless)
                        }
                    }
                }
            } header: { Text(L("Карты и счета")) } footer: {
                Text(L("Название — как в поле «Card or Pass» оплаты: нажмите «?» рядом с полем. Покупки неизвестной карты или без карты будут ждать проверки и не спишутся с другого счёта."))
            }
            Section {
                Button(L("Включить Apple Pay на этом iPhone")) {
                    Task {
                        let assignments = cards.map { WalletCardAssignment(card: $0.card.trimmingCharacters(in: .whitespaces), accountID: $0.account_id) }
                        if await cloud.enableWalletSender(label: label.trimmingCharacters(in: .whitespaces), cards: assignments) {
                            sender = WalletSender.current()
                        }
                    }
                }
                .disabled(!ready || label.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: { Text(L("Mora создаст ключ этого iPhone и будет отправлять покупки сама. Команда с Mac не нужна.")) }
        }
    }

    private func addCard() { cards.append(WalletCardAssignment(accountID: Self.unselected)) }

    /// Fills the first empty card name, or adds a card with this name.
    private func use(_ name: String) {
        if let index = cards.firstIndex(where: { $0.card.trimmingCharacters(in: .whitespaces).isEmpty }) { cards[index].card = name }
        else { cards.append(WalletCardAssignment(card: name, accountID: Self.unselected)) }
    }
}
