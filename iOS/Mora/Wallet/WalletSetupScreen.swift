import SwiftUI
import FinanceCore

/// Turns on sending Wallet purchases from this iPhone: cards and accounts first,
/// then Mora creates its own phone key. Without Mora on the iPhone, the Mac
/// creates a shortcut instead.
struct WalletSetupScreen: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var cloud: CloudSync
    @EnvironmentObject private var router: AppRouter
    @State private var sender = WalletSender.current()
    @State private var label = UIDevice.current.name
    @State private var cards: [WalletCardAssignment] = []
    @State private var confirmDisable = false
    @State private var cardHelp: UUID?
    /// Accounts in other currencies per card row: a multi-currency card debits the account in the purchase currency.
    @State private var otherCurrencies: [UUID: [UUID]] = [:]
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
            } footer: { Text(L("Что передал Wallet при каждой оплате и как покупка дошла до Mora.")) }
        }
        .navigationTitle(L("Apple Pay на iPhone"))
        .disabled(cloud.busy)
        .overlay { if cloud.busy { ProgressView().controlSize(.large) } }
        .onAppear {
            sender = WalletSender.current()
            var seen = Set<String>()
            seenCards = WalletRunLog.runs().map(\.card).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            // Wallet passes the exact card name with every payment, so cards already used need no typing.
            if cards.isEmpty { cards = seenCards.map { WalletCardAssignment(card: $0, accountID: Self.unselected) } }
            if cards.isEmpty { addCard() }
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
        } header: { Text(L("Apple Pay включён")) }
        automationSection
        WalletCardsSection()
    }

    /// Whether the last payment came through the two-step automation.
    @ViewBuilder private var automationSection: some View {
        let last = WalletRunLog.runs().first { $0.delivery != .duplicate }
        let ready = last.map(WalletAutomationCheck.isReady) == true
        Section {
            HStack(spacing: 12) {
                IconTile(icon: ready ? "checkmark.seal" : "wand.and.stars", color: ready ? "green" : "orange", size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L(ready ? "Автоматизация работает" : last == nil ? "Автоматизация ещё не настроена" : "Автоматизацию нужно обновить")).font(.headline)
                    Text(L(ready ? "Последняя оплата пришла через «Start Wallet Payment» и «Finish Wallet Payment»." : "Пошаговый помощник, около двух минут."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button { router.open(.walletGuide) } label: {
                Label(L(ready ? "Открыть помощника" : "Настроить автоматизацию"), systemImage: "list.number")
            }
        } header: { Text(L("Автоматизация на iPhone")) }
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
                        Picker(L("Основной счёт"), selection: $card.account_id) {
                            Text(L("Выберите счёт")).tag(Self.unselected)
                            ForEach(accounts) { Text("\($0.name) · \($0.currency)").tag($0.id) }
                        }
                        CardCurrencyAccounts(accounts: accounts, main: card.account_id == Self.unselected ? nil : card.account_id,
                                             selection: Binding(get: { otherCurrencies[card.id] ?? [] }, set: { otherCurrencies[card.id] = $0 }))
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
                Text(L("Карты, которыми уже платили на этом iPhone, добавлены сами: выберите для них счета. Карта, которой ещё не платили, появится после первой покупки в «Карты Apple Pay». Покупки неизвестной карты или без карты ждут проверки и не спишутся с другого счёта."))
            }
            Section {
                Button(L("Включить Apple Pay на этом iPhone")) {
                    Task {
                        let assignments = cards.map { WalletCardAssignment(id: $0.id, card: $0.card.trimmingCharacters(in: .whitespaces), accountID: $0.account_id) }
                        let other = Dictionary(uniqueKeysWithValues: cards.map { card in
                            (card.id, CardCurrencyAccounts.valid(otherCurrencies[card.id] ?? [], main: card.account_id, in: accounts))
                        }).filter { !$0.value.isEmpty }
                        if await cloud.enableWalletSender(label: label.trimmingCharacters(in: .whitespaces), cards: assignments, otherCurrencies: other) {
                            sender = WalletSender.current()
                            router.open(.walletGuide)
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

/// Wallet cards of every phone key in the shared database and their accounts.
private struct WalletCardsSection: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var cloud: CloudSync

    var body: some View {
        Section {
            if cloud.walletCards.isEmpty {
                Text(L("Карт пока нет. Включите «Apple Pay на этом iPhone» и выберите счета для своих карт Wallet.")).foregroundStyle(.secondary)
            }
            ForEach(cloud.walletCards) { card in
                Picker(selection: Binding(get: { card.account_id }, set: { value in Task { await cloud.linkCard(card.id, account: value) } })) {
                    Text(L("Не выбран")).tag(UUID?.none)
                    ForEach(store.ledger.accounts.filter { !$0.archived }) { Text($0.name).tag(UUID?.some($0.id)) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.card.isEmpty ? L("без названия") : card.card)
                        Text(card.label + (card.pending_count > 0 ? " · " + L("ждут: \(card.pending_count)") : "")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                // Older databases without the multi-currency migration return no account_ids.
                if let other = card.account_ids {
                    CardCurrencyAccounts(accounts: store.ledger.accounts.filter { !$0.archived }, main: card.account_id,
                                         selection: Binding(get: { other }, set: { value in Task { await cloud.setCardAccounts(card.id, accounts: value) } }))
                }
            }
        } header: { Text(L("Карты Apple Pay")) } footer: {
            Text(L("Покупки картой записываются на выбранный счёт. Покупки новых карт ждут выбора счёта. Карта, которой ещё не платили, появится здесь после первой покупки."))
        }
    }
}
