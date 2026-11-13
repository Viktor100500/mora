import SwiftUI

/// Setup of one automation other than the Wallet "Transaction" one, which keeps its
/// own guide. On iOS 27 with a ready automation bundled in the app, the user adds it
/// and only turns its switch on; otherwise each step of building it is shown.
struct AutomationGuide: View {
    let automation: CaptureAutomation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var step = 0
    @State private var startedAt = Date()
    @State private var latest: AutomationEntry?
    @State private var manual: Bool

    init(automation: CaptureAutomation) {
        self.automation = automation
        _manual = State(initialValue: !automation.oneTapAvailable)
    }

    private struct Page {
        var title: String
        var subtitle: String
        var lines: [String]
        var mock: AnyView?
    }

    private var pages: [Page] { manual ? manualPages : oneTapPages }
    /// Pages plus the final check.
    private var steps: Int { pages.count + 1 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if step > 0 { progress.padding(.horizontal, 20).padding(.top, 4) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) { content }
                        .padding(20)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                }
                buttons.padding(.horizontal, 20).padding(.vertical, 12)
            }
            .background(Color.moraBackground)
            .wrappingTitle(automation.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Закрыть")) { dismiss() } }
            }
            .animation(.spring(duration: 0.35), value: step)
            .task(id: step) {
                // The last step watches the journal for the first entry from this automation.
                guard step == steps else { return }
                while !Task.isCancelled {
                    latest = AutomationJournal.entries().first { $0.source == automation && $0.date >= startedAt.addingTimeInterval(-60) }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(1...steps, id: \.self) { index in
                Capsule().fill(index <= step ? Color.moraGreen : Color.secondary.opacity(0.2)).frame(height: 5)
            }
        }
        .accessibilityLabel(L("Шаг \(step) из \(steps)"))
    }

    @ViewBuilder private var content: some View {
        if step == 0 { intro }
        else if step < steps {
            let page = pages[step - 1]
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Шаг \(step) из \(steps)")).font(.caption.weight(.semibold)).foregroundStyle(Color.moraGreen)
                Text(L(page.title)).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                Text(L(page.subtitle)).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let mock = page.mock { GuideMock { mock } }
            instructions(page.lines)
            if !manual && step == 1 {
                Button { withAnimation { manual = true; step = 1 } } label: {
                    Text(L("Собрать вручную")).font(.subheadline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain).foregroundStyle(Color.moraGreen)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Шаг \(step) из \(steps)")).font(.caption.weight(.semibold)).foregroundStyle(Color.moraGreen)
                Text(L("Проверьте настройку")).font(.title3.weight(.bold))
                Text(L(checkHint)).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            check
        }
    }

    // MARK: Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                Circle().fill(Color.token(automation.color).opacity(0.14)).frame(width: 96, height: 96)
                Image(systemName: automation.icon).font(.system(size: 40)).foregroundStyle(Color.token(automation.color))
            }
            .frame(maxWidth: .infinity).padding(.top, 12)
            Text(automation.title).font(.title2.weight(.bold)).frame(maxWidth: .infinity).multilineTextAlignment(.center)
            Text(automation.summary).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            if !automation.available {
                Card {
                    Label(L("Триггер «Уведомление» появился в iOS 27. Обновите iPhone, и эта автоматизация станет доступна."), systemImage: "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(.orange)
                }
            } else {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        benefit("square.stack.3d.up", manual ? L("Соберём вручную: \(pages.count) коротких шага и проверка, около двух минут.")
                                                             : L("Готовая автоматизация уже в Mora: добавьте её и включите переключатель."))
                        benefit("lock.shield", L("Работает на заблокированном iPhone и без интернета: покупка уйдёт позже."))
                        benefit("square.on.square", L("Если та же покупка придёт и из другой автоматизации, Mora объединит их и покажет это в журнале."))
                        if automation == .bankSMS || automation == .bankNotification {
                            benefit("hand.tap", L("Первое сообщение каждого банка Mora попросит проверить один раз, дальше такие сообщения записываются сами."))
                        }
                    }
                }
            }
        }
    }

    private func benefit(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.moraGreen).frame(width: 22)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func instructions(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(Color.moraGreen, in: Circle())
                    Text(L(line)).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Ready automation (iOS 27)

    private var oneTapPages: [Page] {
        let name = automation.templateName
        var enable = ["Нажмите «Открыть автоматизации»: откроется вкладка «Автоматизация» в «Быстрых командах»."]
        switch automation {
        case .bankNotification: enable.append("Нажмите на «\(name)» и в триггере «Уведомление» выберите приложение своего банка.")
        case .bankSMS: enable.append("Нажмите на «\(name)» и проверьте символ валюты в «Сообщение содержит»: он должен быть в SMS о ваших покупках.")
        default: break
        }
        enable += ["Включите переключатель справа от «\(name)» — он станет зелёным.",
                   "Если iOS спросит, выберите «Запускать сразу». Вернитесь в Mora."]
        return [
            Page(title: "Добавьте готовую автоматизацию", subtitle: "Триггер «\(automation.trigger)» и действие Mora в ней уже связаны.",
                 lines: ["Нажмите «Добавить в Быстрые команды» и выберите «Быстрые команды».",
                         "Нажмите «Добавить быструю команду».",
                         "Вернитесь в Mora и нажмите «Дальше»."],
                 mock: AnyView(VStack(spacing: 8) { TriggerMock(automation: automation); actionMock })),
            Page(title: "Включите автоматизацию",
                 subtitle: "iOS добавляет чужие автоматизации выключенными, и включить их может только владелец iPhone. Это единственное, что нужно сделать руками.",
                 lines: enable, mock: AnyView(EnableMock(automation: automation))),
        ]
    }

    // MARK: Building by hand

    private var runImmediately: Page {
        Page(title: "Запускать сразу", subtitle: "Так покупка записывается без вопросов, даже на заблокированном iPhone.",
             lines: ["Выберите «Запускать сразу» и выключите «Уведомлять о запуске».",
                     "Нажмите «Далее» → «Новая пустая автоматизация»."],
             mock: AnyView(RunOptionsMock()))
    }

    private var manualPages: [Page] {
        switch automation {
        case .walletNotification:
            [Page(title: "Создайте автоматизацию «Уведомление»", subtitle: "Всё делается в «Быстрых командах». Возвращайтесь в Mora после каждого шага.",
                  lines: ["Откройте «Быстрые команды», вкладку «Автоматизация» и нажмите «+».",
                          "Найдите триггер «Уведомление» и выберите приложение Wallet.",
                          "Фильтры по тексту не задавайте: Mora сама отличит покупку."],
                  mock: AnyView(TriggerMock(automation: automation))),
             runImmediately,
             Page(title: "Действие Log Wallet Notification", subtitle: "В нём три поля, и в каждое идёт свойство уведомления с тем же названием.",
                  lines: ["Найдите в действиях «Mora» → «Log Wallet Notification».",
                          "Нажмите на поле Title, выберите «Входные данные команды», затем нажмите на вставленную переменную и выберите свойство Title.",
                          "Так же заполните Subtitle и Body. Нажмите «Готово»."],
                  mock: AnyView(actionMock))]
        case .bankSMS:
            [Page(title: "Создайте автоматизацию «Сообщение»", subtitle: "Для каждой валюты покупок нужна своя такая автоматизация.",
                  lines: ["Откройте «Быстрые команды», вкладку «Автоматизация» и нажмите «+». На iOS 27 триггеры добавляются в новую команду как действия.",
                          "Выберите триггер «Сообщение».",
                          "В «Сообщение содержит» введите символ валюты ваших покупок, например «$», «€» или «₽». Отправителя можно не выбирать."],
                  mock: AnyView(TriggerMock(automation: automation))),
             runImmediately,
             Page(title: "Действие Log Bank Message", subtitle: "Mora получит текст SMS и отправителя. Коды подтверждения она сразу пропускает и не сохраняет.",
                  lines: ["Найдите в действиях «Mora» → «Log Bank Message».",
                          "В поле Text выберите «Входные данные команды», нажмите на вставленную переменную и выберите свойство «Содержимое».",
                          "В поле From так же выберите свойство «Отправитель». Нажмите «Готово»."],
                  mock: AnyView(actionMock))]
        case .bankNotification:
            [Page(title: "Создайте автоматизацию «Уведомление»", subtitle: "Для каждого приложения банка нужна своя автоматизация.",
                  lines: ["Откройте «Быстрые команды», вкладку «Автоматизация» и нажмите «+».",
                          "Найдите триггер «Уведомление» и выберите приложение банка или карты, например Chase или Bybit.",
                          "Фильтры по тексту можно не задавать. Уведомления этого приложения должны быть включены в настройках iPhone."],
                  mock: AnyView(TriggerMock(automation: automation))),
             runImmediately,
             Page(title: "Действие Log Bank Notification", subtitle: "Это отдельное действие для уведомлений, не для SMS: так журнал знает, откуда пришла покупка.",
                  lines: ["Найдите в действиях «Mora» → «Log Bank Notification».",
                          "В поле Title выберите «Входные данные команды», нажмите на вставленную переменную и выберите свойство Title. Так же для Body.",
                          "В поле App впишите название приложения банка, например Chase. Нажмите «Готово»."],
                  mock: AnyView(actionMock))]
        case .walletTransaction: []
        }
    }

    @ViewBuilder private var actionMock: some View {
        switch automation {
        case .walletNotification:
            ActionMock(title: "Log Wallet Notification", parts: [.text("Log Wallet notification "), .token("Title"), .text(", "), .token("Subtitle"), .text(", "), .token("Body")])
        case .bankSMS:
            ActionMock(title: "Log Bank Message", parts: [.text("Log "), .token("Содержимое"), .text(" from "), .token("Отправитель")])
        case .bankNotification:
            ActionMock(title: "Log Bank Notification", parts: [.text("Log notification "), .token("Title"), .text(", "), .token("Body"), .text(" from Chase")])
        case .walletTransaction:
            ActionMock(title: "Start Wallet Payment", parts: [.text("Start payment at "), .token("Продавец")])
        }
    }

    // MARK: Check

    private var checkHint: String {
        switch automation {
        case .walletNotification: "Заплатите Apple Pay, например за проезд. Когда Wallet покажет уведомление о покупке, Mora отметит его здесь."
        case .bankSMS: "Дождитесь SMS банка о покупке — Mora покажет здесь, что из него прочитала."
        case .bankNotification: "Дождитесь уведомления банка о покупке — Mora покажет здесь, что из него прочитала."
        case .walletTransaction: ""
        }
    }

    private var check: some View {
        Card {
            if let latest {
                VStack(alignment: .leading, spacing: 10) {
                    Label(L("Автоматизация работает"), systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(Color.moraGreen)
                    AutomationEntryRow(entry: latest)
                }
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Ждём первый запуск")).font(.headline)
                        Text(L("Можно закрыть помощника: результат будет виден в «Автоматизация / Быстрые команды» → «Журнал».")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Buttons

    @ViewBuilder private var buttons: some View {
        VStack(spacing: 10) {
            if step == 0 {
                if automation.available { primary(L("Начать")) { startedAt = Date(); step = 1 } }
                else { primary(L("Понятно")) { dismiss() } }
            } else if step < steps {
                if !manual && step == 1, let file = automation.templateFile {
                    ShareLink(item: file, preview: SharePreview(automation.templateName)) {
                        Text(L("Добавить в Быстрые команды")).fontWeight(.semibold).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(.moraGreen)
                } else if !manual && step == 2 {
                    primary(L("Открыть автоматизации")) { openURL(WalletAutomationGuide.automationsURL) }
                } else if manual && step == 1 {
                    Button { if let url = URL(string: "shortcuts://") { openURL(url) } } label: {
                        Label(L("Открыть «Быстрые команды»"), systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large).tint(.moraGreen)
                }
                HStack(spacing: 10) {
                    Button { step -= 1 } label: { Text(L("Назад")).frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large)
                    Button { step += 1 } label: { Text(L("Дальше")).frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large).tint(.moraGreen)
                }
            } else {
                HStack(spacing: 10) {
                    Button { step -= 1 } label: { Text(L("Назад")).frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large)
                    primary(latest == nil ? L("Проверю позже") : L("Готово")) { dismiss() }
                }
            }
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).fontWeight(.semibold).frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent).controlSize(.large).tint(.moraGreen)
    }
}

// MARK: Shortcuts screens drawn for the guide

/// The trigger of an automation as the Shortcuts Automation tab shows it.
private struct TriggerMock: View {
    let automation: CaptureAutomation

    var body: some View {
        HStack(spacing: 10) {
            appIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title)).font(.subheadline.weight(.semibold))
                Text(L(detail)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.moraCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder private var appIcon: some View {
        if automation == .walletNotification { WalletAppIcon() }
        else {
            Image(systemName: automation == .bankSMS ? "message.fill" : "building.columns.fill").font(.caption).foregroundStyle(.white)
                .frame(width: 30, height: 24)
                .background(automation == .bankSMS ? Color.green : Color.blue, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private var title: String {
        switch automation {
        case .walletNotification: "Когда я получаю уведомление от Wallet"
        case .bankSMS: "Когда я получаю сообщение, содержащее «$»"
        default: "Когда я получаю уведомление от приложения банка"
        }
    }

    private var detail: String {
        switch automation {
        case .bankSMS: "Триггер «Сообщение» · Запускать сразу"
        default: "Триггер «Уведомление» · Запускать сразу"
        }
    }
}

/// The run options shown after choosing a trigger.
private struct RunOptionsMock: View {
    var body: some View {
        VStack(spacing: 0) {
            row { Image(systemName: "checkmark").foregroundStyle(.blue); Text(L("Запускать сразу")); Spacer() }
            Divider()
            row {
                Text(L("Уведомлять о запуске")); Spacer()
                Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 44, height: 26)
                    .overlay(alignment: .leading) { Circle().fill(.white).padding(2).shadow(radius: 1) }
            }
        }
        .font(.subheadline)
        .background(Color.moraCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) { content() }.padding(.horizontal, 14).frame(height: 46)
    }
}

/// The added automation in the Automation tab, with its switch turned on.
private struct EnableMock: View {
    let automation: CaptureAutomation

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: automation.icon).font(.caption).foregroundStyle(.white)
                        .frame(width: 24, height: 24).background(Color.token(automation.color), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "leaf.fill").font(.caption).foregroundStyle(.white)
                        .frame(width: 24, height: 24).background(Color.moraGreen, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Text(automation.templateName).font(.subheadline.weight(.semibold))
                Text(L("Триггер «\(automation.trigger)»")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                Capsule().fill(Color.green).frame(width: 50, height: 30)
                    .overlay(alignment: .trailing) { Circle().fill(.white).padding(2) }
                Image(systemName: "arrow.up").font(.caption.weight(.bold)).foregroundStyle(Color.moraGreen)
            }
        }
        .padding(14)
        .background(Color.moraCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
