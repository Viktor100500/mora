import SwiftUI
import FinanceCore

struct CloudScreen: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var cloud: CloudSync
    @EnvironmentObject private var router: AppRouter
    @State private var url = ""
    @State private var key = ""
    @State private var email = ""
    @State private var password = ""
    @State private var joinCode = ""
    @State private var newHousehold = ""
    @State private var confirmOpen: CloudHousehold?
    @State private var confirmDisconnect = false

    var body: some View {
        Form {
            if let error = cloud.error {
                Section { Label(L(error), systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
            }
            if store.isDemo {
                Section {
                    Text(L("Сначала начните свой учет и создайте счет. Демо в облако не загружается.")).font(.subheadline)
                    Button(L("Начать свой учет")) { router.open(.welcome) }
                }
            } else if !cloud.signedIn {
                signInSection
            } else if cloud.householdID == nil {
                chooseHousehold
            } else {
                connected
            }
            Section {
                Text(L("Общая база работает с вашим собственным проектом Supabase: разработчик не предоставляет сервер и не получает доступ к данным. Покупки Apple Pay приходят через «Быстрые команды» — экспериментальная интеграция, не банковская синхронизация."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L("Общая база"))
        .disabled(cloud.busy)
        .overlay { if cloud.busy { ProgressView().controlSize(.large) } }
        .refreshable { await cloud.refreshLists(); await cloud.synchronize() }
        .onAppear {
            if url.isEmpty { url = cloud.projectURL }
            if key.isEmpty { key = cloud.publicKey }
            if email.isEmpty { email = cloud.email }
        }
        .confirmationDialog(L("Открыть общую базу «\(confirmOpen?.name ?? "")»?"), isPresented: Binding(get: { confirmOpen != nil }, set: { if !$0 { confirmOpen = nil } }), titleVisibility: .visible) {
            if let household = confirmOpen {
                Button(L("Заменить данные iPhone")) { Task { await cloud.openHousehold(household.id); confirmOpen = nil } }
            }
        } message: { Text(L("Данные на этом iPhone будут заменены общей базой. Перед заменой приложение сохранит резервную копию.")) }
        .confirmationDialog(L("Отключить общую базу?"), isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button(L("Отключить"), role: .destructive) { Task { await cloud.disconnect() } }
        } message: { Text(L("Локальная копия на iPhone сохранится. Сессия будет удалена из Связки ключей.")) }
    }

    private var signInSection: some View {
        Section {
            TextField(L("Адрес проекта (https://….supabase.co)"), text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField(L("Publishable key"), text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField(L("Email"), text: $email).keyboardType(.emailAddress).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField(L("Пароль"), text: $password).textContentType(.password)
            Button(L("Войти")) { Task { await cloud.signIn(url: url, key: key, email: email, password: password); password = "" } }
                .disabled(url.isEmpty || key.isEmpty || email.isEmpty || password.isEmpty)
        } header: { Text(L("Вход")) } footer: {
            Text(L("Используйте Project URL и Publishable key своего проекта и отдельного пользователя приложения. Secret и service_role ключи вводить нельзя."))
        }
    }

    @ViewBuilder private var chooseHousehold: some View {
        Section {
            if cloud.households.isEmpty { Text(L("Общих баз пока нет")).foregroundStyle(.secondary) }
            ForEach(cloud.households) { household in
                Button { confirmOpen = household } label: { Label(household.name, systemImage: "person.2") }
            }
            Button { Task { await cloud.refreshLists() } } label: { Label(L("Обновить список"), systemImage: "arrow.clockwise") }
        } header: { Text(L("Ваши общие базы")) } footer: { Text(L("Вошли как \(cloud.email)")) }
        Section {
            TextField(L("Код подключения"), text: $joinCode).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button(L("Подключиться по коду")) { Task { await cloud.join(code: joinCode); joinCode = "" } }.disabled(joinCode.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: { Text(L("Приглашение")) } footer: { Text(L("Код создается в Mora на Mac: «Общая база и Apple Pay» → «Пригласить».")) }
        Section {
            TextField(L("Название общей базы"), text: $newHousehold)
            Button(L("Создать из данных iPhone")) { Task { await cloud.createHousehold(name: newHousehold.trimmingCharacters(in: .whitespaces)) } }
                .disabled(newHousehold.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: { Text(L("Новая общая база")) }
        Section { Button(L("Выйти"), role: .destructive) { confirmDisconnect = true } }
    }

    @ViewBuilder private var connected: some View {
        Section {
            LabeledContent(L("Общая база"), value: cloud.householdName)
            LabeledContent(L("Пользователь"), value: cloud.email)
            LabeledContent(L("Синхронизация")) {
                if let date = cloud.lastSync { Text(date.formatted(.relative(presentation: .named).locale(L10n.locale))) } else { Text("—") }
            }
            Toggle(L("Синхронизировать автоматически"), isOn: Binding(get: { cloud.enabled }, set: { value in Task { await cloud.pause(!value) } }))
            Button { Task { await cloud.synchronize() } } label: { Label(L("Синхронизировать сейчас"), systemImage: "arrow.triangle.2.circlepath") }
        } footer: { Text(L("Открытая Mora проверяет изменения примерно каждые восемь секунд. Независимые изменения объединяются.")) }
        if cloud.conflict {
            Section {
                Text(L("Одна и та же запись изменена на двух устройствах. Выберите, какую версию сохранить.")).font(.subheadline)
                Button(L("Загрузить общую версию")) { Task { await cloud.useCloudVersion() } }
                Button(L("Оставить версию iPhone"), role: .destructive) { Task { await cloud.keepLocalVersion() } }
            } header: { Label(L("Конфликт синхронизации"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }
        Section {
            if cloud.pending.isEmpty { Text(L("Покупок на проверке нет")).foregroundStyle(.secondary) }
            ForEach(cloud.pending) { capture in
                Button { router.open(.walletReview(capture)) } label: { captureRow(capture) }.buttonStyle(.plain)
                    .swipeActions { Button(role: .destructive) { Task { await cloud.dismissCapture(capture) } } label: { Label(L("Скрыть"), systemImage: "eye.slash") } }
            }
        } header: { Text(L("Входящие Apple Pay")) } footer: {
            Text(L("Полные покупки записываются автоматически. Здесь остаются покупки без суммы, валюты или счета: нажмите, чтобы проверить."))
        }
        if !cloud.walletCards.isEmpty {
            Section {
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
                }
            } header: { Text(L("Карты Apple Pay")) } footer: { Text(L("Покупки картой записываются на выбранный счет.")) }
        }
        Section {
            Button { Task { await cloud.invite() } } label: { Label(L("Пригласить участника"), systemImage: "person.badge.plus") }
            if let code = cloud.invitation {
                HStack {
                    Text(code).font(.body.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button { UIPasteboard.general.string = code; store.showToast(L("Код скопирован")) } label: { Image(systemName: "doc.on.doc") }
                }
            }
            Button(L("Отключить общую базу"), role: .destructive) { confirmDisconnect = true }
        }
    }

    private func captureRow(_ capture: CloudCapture) -> some View {
        HStack(spacing: 12) {
            IconTile(icon: capture.awaitsCardLink ? "creditcard" : "wallet.pass", color: capture.awaitsCardLink ? "blue" : "orange", size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(capture.merchant.isEmpty ? L("Без описания") : capture.merchant).font(.body.weight(.medium))
                Text(capture.reason.map(L) ?? L("Нужна проверка")).font(.caption).foregroundStyle(.orange).lineLimit(2)
                Text([capture.card, capture.label, capture.date.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            FinancialText(capture.amount.isEmpty ? "—" : capture.amount + (capture.currency.isEmpty ? "" : " " + capture.currency)).font(.subheadline.weight(.semibold))
        }
    }
}
