import SwiftUI
import FinanceCore
import AppKit

struct CloudSettingsCard: View {
    @EnvironmentObject private var cloud: CloudSync
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "Общая база и Apple Pay", subtitle: "Совместный учет на нескольких Mac и расходы из «Быстрых команд»")
                HStack {
                    Label(cloud.householdID == nil ? "Облако не подключено" : "\(cloud.householdName) · \(cloud.enabled ? "синхронизация включена" : "на паузе")", systemImage: "icloud")
                    Spacer()
                    Button("Настроить…") { openWindow(id: "cloud") }
                }
                if let error = cloud.error { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }
    }
}

struct CloudSettingsView: View {
    @EnvironmentObject private var cloud: CloudSync
    @EnvironmentObject private var store: FinanceStore
    @State private var url = ""
    @State private var key = ""
    @State private var email = ""
    @State private var password = ""
    @State private var showConnectionSettings = true
    @State private var name = "Семейный учет"
    @State private var code = ""
    @State private var account: UUID?
    @State private var phoneLabel = "Мой iPhone"
    @State private var adoptID: UUID?
    @State private var confirmJoin = false
    @State private var confirmLocal = false
    @State private var confirmDisconnect = false
    @State private var selectedCapture: CloudCapture?
    @State private var handledNotification: UUID?
    private var accounts: [Account] { store.ledger.accounts.filter { !$0.archived } }
    var body: some View {
        ScrollViewReader { scrollProxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Общая база и Apple Pay").font(.title2.bold())
                    Spacer()
                    // Keep the scroll content's geometry stable during periodic syncs.
                    ProgressView("Подключаемся к облаку…")
                        .labelsHidden().controlSize(.small)
                        .frame(width: 16, height: 16)
                        .opacity(cloud.busy ? 1 : 0)
                        .accessibilityHidden(!cloud.busy)
                }
                Text("У каждого свой вход. Счета, операции, категории и планы доступны участникам одной общей базы. На этом Mac остается копия для работы без интернета.").font(.callout).foregroundStyle(.secondary)
                if store.isDemo {
                    Label("Сначала начните свой учет в главном окне и создайте счет. Демо нельзя подключить к облаку.", systemImage: "info.circle").foregroundStyle(.orange)
                }
                if let error = cloud.error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                if !cloud.signedIn { signInCard }
                else {
                    HStack { Label(cloud.email, systemImage: "person.crop.circle"); Spacer(); Button("Отключить облако…") { confirmDisconnect = true } }
                    if cloud.householdID == nil { householdCard }
                    else { syncCard; inviteCard; phoneCard; inboxCard.id("wallet-inbox") }
                }
                Text("Первое подключение требует бесплатного проекта Supabase и установки схемы Mora. Оплата iPhone передает доступные сведения о покупке; это не банковская выписка. Автоматизация настраивается отдельно на каждом телефоне.").font(.caption).foregroundStyle(.secondary)
                Link("Настройка автоматизации Apple", destination: URL(string: "https://support.apple.com/en-ng/guide/shortcuts/apd65c67538a/ios")!).font(.caption)
                FeedbackContact().font(.caption).padding(.top, 8)
            }.padding(24).frame(maxWidth: 780).frame(maxWidth: .infinity)
        }
        .frame(minWidth: 660, minHeight: 580)
        .disclosureGroupStyle(OutlinedDisclosureGroupStyle())
        .onAppear {
            url = cloud.projectURL
            key = cloud.publicKey
            email = cloud.email
            showConnectionSettings = url.isEmpty || key.isEmpty
            if account == nil { account = accounts.first?.id }
            if cloud.signedIn { Task { await cloud.refreshLists() } }
        }
        .onReceive(store.notifications.$navigation) { request in navigate(request, scrollProxy: scrollProxy) }
        .onChange(of: cloud.pending) { _, _ in navigate(store.notifications.navigation, scrollProxy: scrollProxy) }
        .confirmationDialog("Открыть общую базу вместо текущей?", isPresented: $confirmJoin, titleVisibility: .visible) {
            Button("Сохранить копию и подключиться") { Task { await cloud.join(code: code); code = "" } }
        } message: { Text("Текущие данные этого Mac сохранятся в отдельный файл before-cloud. После подключения будут открыты счета и операции общей базы. Автоматического объединения двух независимых баз нет.") }
        .confirmationDialog("Открыть выбранную общую базу?", isPresented: Binding(get: { adoptID != nil }, set: { if !$0 { adoptID = nil } }), titleVisibility: .visible) {
            if let id = adoptID { Button("Сохранить копию и открыть") { adoptID = nil; Task { await cloud.openHousehold(id) } } }
        } message: { Text("Текущая база этого Mac будет сохранена отдельно. При конфликте эта команда выбирает облачную версию.") }
        .confirmationDialog("Заменить облачную базу версией этого Mac?", isPresented: $confirmLocal, titleVisibility: .visible) {
            Button("Сохранить копию и заменить") { Task { await cloud.keepLocalVersion() } }
        } message: { Text("Сначала облачная версия сохранится в отдельный файл на этом Mac. Затем версия этого Mac станет общей для всех участников. При новых облачных правках замена будет остановлена.") }
        .confirmationDialog("Отключить облако на этом Mac?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Отключить") { password = ""; Task { await cloud.disconnect() } }
        } message: { Text("Локальные данные останутся на Mac. Ключи телефонов продолжат работать до отзыва в общей базе. Другие участники сохранят доступ.") }
        .sheet(item: $selectedCapture) { capture in WalletReviewForm(capture: capture).modifier(FeedbackFooter()).modifier(FinanceErrorAlert()).environmentObject(cloud).environmentObject(store) }
        }
    }
    private func navigate(_ request: NotificationNavigation?, scrollProxy: ScrollViewProxy) {
        guard let request, request.id != handledNotification else { return }
        switch request.destination {
        case .page: return
        case .inbox: break
        case .capture(let id):
            guard let capture = cloud.pending.first(where: { $0.id == id }) else { return }
            selectedCapture = capture
        }
        handledNotification = request.id
        Task { @MainActor in
            await Task.yield()
            scrollProxy.scrollTo("wallet-inbox", anchor: .top)
        }
    }
    private var signInCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "Вход", subtitle: "Email и пароль, которые вы создали для Mora")
                DisclosureGroup("Параметры подключения", isExpanded: $showConnectionSettings) {
                    TextField("Адрес облака: https://проект.supabase.co", text: $url).textFieldStyle(.roundedBorder)
                    TextField("Публичный ключ проекта (Publishable key)", text: $key).textFieldStyle(.roundedBorder)
                }
                TextField("Email", text: $email).textFieldStyle(.roundedBorder)
                SecureField("Пароль пользователя Mora", text: $password).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Войти") {
                        let enteredPassword = password; password = ""
                        Task { await cloud.signIn(url: url, key: key, email: email, password: enteredPassword) }
                    }.buttonStyle(.borderedProminent).disabled(cloud.busy || store.isDemo || url.isEmpty || key.isEmpty || email.isEmpty || password.isEmpty)
                    Spacer()
                    Link("Открыть Supabase", destination: URL(string: "https://supabase.com/dashboard")!)
                }
                Text("Это учетная запись пользователя приложения, созданная в разделе Authentication вашего проекта, а не пароль от панели Supabase. Сессия хранится в Связке ключей macOS. Secret key и service_role не нужны.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var householdCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "Подключение", subtitle: "Создайте общую базу или подключитесь к существующей")
                TextField("Название общей базы", text: $name).textFieldStyle(.roundedBorder)
                Button("Создать общую базу из данных этого Mac") { Task { await cloud.createHousehold(name: name) } }
                    .disabled(cloud.busy || store.isDemo || name.trimmingCharacters(in: .whitespaces).isEmpty || accounts.isEmpty)
                Text("Счета, операции и планы этого Mac будут загружены в ваш проект Supabase. Перед первым подключением можно сохранить резервную копию в главном окне.").font(.caption).foregroundStyle(.secondary)
                Divider()
                TextField("Код подключения от владельца базы", text: $code).textFieldStyle(.roundedBorder)
                Button("Подключиться по коду…") { confirmJoin = true }.disabled(cloud.busy || store.isDemo || code.isEmpty)
                ForEach(cloud.households) { household in
                    HStack { Text(household.name); Spacer(); Button("Открыть…") { adoptID = household.id } }.disabled(cloud.busy || store.isDemo)
                }
                Button("Обновить список") { Task { await cloud.refreshLists() } }.disabled(cloud.busy)
            }
        }
    }
    private var syncCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: cloud.householdName, subtitle: "Изменения проверяются каждые 8 секунд, пока Mora открыта и Mac не спит")
                Toggle("Синхронизация включена", isOn: Binding(get: { cloud.enabled }, set: { value in Task { await cloud.pause(!value) } })).disabled(cloud.busy)
                HStack {
                    if let last = cloud.lastSync { Text("Последняя синхронизация: \(last.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Синхронизировать") { Task { await cloud.synchronize() } }.disabled(cloud.busy || !cloud.enabled)
                }
                Text(L("Без интернета изменения остаются на Mac и отправляются после восстановления соединения. Независимые облачные изменения сохраняются при отмене. История отмены сокращается только при конфликте, чтобы не перезаписать чужие изменения.")).font(.caption).foregroundStyle(.secondary)
                if cloud.conflict {
                    Divider()
                    Text("Выберите версию для всей общей базы. Текущие версии будут сохранены отдельно на этом Mac.").font(.callout)
                    HStack {
                        Button("Использовать облачную версию…") { adoptID = cloud.householdID }
                        Button("Использовать версию этого Mac…") { confirmLocal = true }
                        Button("Сохранить JSON…") { Task { @MainActor in  await store.backup()  } }
                    }.disabled(cloud.busy)
                }
            }
        }
    }
    private var inviteCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "Второй участник", subtitle: "Владелец базы создает одноразовый код подключения на 7 дней")
                Button("Создать код подключения") { Task { await cloud.invite() } }.disabled(cloud.busy)
                if let invitation = cloud.invitation {
                    Text(invitation).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button("Скопировать код") { copy(invitation) }
                    Text("Передайте код участнику лично. Он дает доступ ко всем данным этой базы. Новый код отменяет предыдущий.").font(.caption).foregroundStyle(.secondary)
                }
                Text("На втором Mac: войдите отдельным пользователем того же проекта и выберите «Подключиться по коду». Общий Apple Account не требуется.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var phoneCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "Apple Pay → расход", subtitle: "Один ключ для одной карты и счета. Настройте автоматизацию отдельно на каждом iPhone.")
                TextField("Название телефона или карты", text: $phoneLabel).textFieldStyle(.roundedBorder)
                Picker("Счет для расходов", selection: $account) {
                    Text("Выберите счет").tag(Optional<UUID>.none)
                    ForEach(accounts) { Text("\($0.name) · \($0.currency)").tag(Optional($0.id)) }
                }
                Button("Создать ключ для «Быстрых команд»") {
                    if let account { Task { await cloud.issueToken(account: account, label: phoneLabel) } }
                }.disabled(cloud.busy || !cloud.enabled || account == nil || phoneLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                if let token = cloud.issuedToken {
                    Text("Ключ показан только сейчас. Скопируйте его в команду; восстановить его позднее нельзя.").font(.caption).foregroundStyle(.secondary)
                    Text(token).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button("Скопировать параметры подключения") {
                        copy("URL: \(cloud.captureURL)\napikey: \(cloud.publicKey)\np_token: \(token)")
                    }
                }
                DisclosureGroup("Как настроить команду") {
                    Text("1. В «Быстрых командах» создайте автоматизацию Wallet / «Транзакция» для выбранной карты и включите немедленный запуск.\n2. Получите сумму, валюту и продавца из входной транзакции. Не вводите фиксированную валюту для покупок в разных валютах.\n3. Создайте UUID события и текущую дату в ISO 8601.\n4. Добавьте «Получить содержимое URL»: POST, заголовок apikey и JSON с полями ниже.\n5. Проверьте ответ: recorded — расход записан; pending — покупка доставлена и ожидает обработки Mora или ручной проверки.")
                        .font(.callout).textSelection(.enabled).padding(.top, 8)
                    Text("p_token · p_event_id · p_amount · p_currency · p_merchant · p_occurred_at")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.top, 8)
                    Text("Сумма передается текстом, без разделителей тысяч (например 12.50). При повторной отправке используйте прежний UUID и дату. Все данные и ответ сохраняйте до подтверждения сервера; простой HTTP-запрос не обеспечивает очередь без интернета.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }
                ForEach(cloud.phoneTokens) { token in
                    HStack {
                        Text("\(token.label) · \(token.revoked ? "отозван" : "действует")")
                        Spacer()
                        if !token.revoked { Button("Отозвать") { Task { await cloud.revokeToken(token.id) } }.disabled(cloud.busy) }
                    }.font(.callout)
                }
                Text("Ключ может только добавлять расходы в выбранный счет. Он не позволяет читать операции или менять другие счета. При потере телефона отзовите ключ.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var inboxCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "Покупки из Wallet на проверке", subtitle: "Полные покупки добавляются автоматически. Неполные данные можно исправить здесь.")
                if cloud.pending.isEmpty { Text("Нет покупок для проверки").foregroundStyle(.secondary) }
                ForEach(cloud.pending) { capture in
                    let currency = WalletReviewDraft(capture: capture, ledger: store.ledger).currency
                    let knownCurrency = currency != WalletReviewDraft.unknownCurrency
                    let waiting = knownCurrency && ["Не получена валюта покупки", "Валюта покупки отличается от валюты счета"].contains(capture.reason ?? "")
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(capture.merchant.isEmpty ? "Продавец не получен" : capture.merchant)
                            FinancialText("\(capture.amount) \(knownCurrency ? currency : "")").font(.caption).foregroundStyle(.secondary)
                            if !knownCurrency {
                                Text("Валюта покупки не передана").font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Источник: \(capture.label)").font(.caption).foregroundStyle(.secondary)
                            Text(L(waiting ? "Ожидает автоматической записи" : capture.reason ?? "Проверьте покупку")).font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Button("Проверить…") { selectedCapture = capture }
                            Button(role: .destructive) {
                                Task {
                                    await cloud.resolve(capture, account: capture.account_id,
                                                        amount: "", merchant: capture.merchant, dismiss: true)
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.red.opacity(0.8))
                                    .frame(width: 28, height: 28)
                                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain)
                                .help(L("Удалить покупку без возможности восстановления"))
                                .accessibilityLabel(L("Удалить покупку из Wallet"))
                        }.disabled(cloud.busy)
                    }
                }
            }
        }
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }

}
