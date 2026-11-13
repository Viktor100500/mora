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
    @State private var latestRun: WalletRun?
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
        // The Wallet "Transaction" automation keeps its own drawn guide for building by hand.
        if automation == .walletTransaction && manual {
            WalletAutomationGuide(exitManual: automation.oneTapAvailable ? { manual = false; step = 0 } : nil)
        } else {
            guide
        }
    }

    private var guide: some View {
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
            // Back on the intro offers the ready automation again after "Build it by hand".
            .onChange(of: step) { _, value in if value == 0 { manual = !automation.oneTapAvailable } }
            .task(id: step) {
                // The last step watches the journal for the first entry from this automation.
                // The manual Wallet Transaction guide is a separate view that marks its own end;
                // here it leaves no pages, so step 1 would wrongly count as the last one.
                guard step == steps, !(automation == .walletTransaction && manual) else { return }
                automation.setupFinishedAt = startedAt
                while !Task.isCancelled {
                    let since = startedAt.addingTimeInterval(-60)
                    latest = AutomationJournal.entries().first { $0.source == automation && $0.date >= since }
                    if automation == .walletTransaction { latestRun = WalletRunLog.runs().first { $0.receivedAt >= since } }
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
                    Text(L("Настроить вручную")).font(.subheadline).frame(maxWidth: .infinity)
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
                        benefit("square.stack.3d.up", manual ? L("Настроим вручную: \(pages.count) коротких шага и проверка, около двух минут.")
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

    /// The steps as Shortcuts shows them on iOS 27: share sheet, the shared shortcut,
    /// its editor with "Automation is turned off", then the switch in the Automation tab.
    private var oneTapPages: [Page] {
        let name = automation.templateName
        let edit: [String] = switch automation {
        case .bankSMS: ["Нажмите на «Отправитель» в триггере и выберите номера и названия всех банков, от которых приходят SMS о покупках. Можно выбрать несколько — одной автоматизации хватит на все банки. Остальное не меняйте.",
                        "Нажмите «‹» в левом верхнем углу."]
        case .bankNotification: ["Нажмите на приложение в триггере и выберите приложения всех своих банков и карт. Можно выбрать несколько — одной автоматизации хватит на все. Остальное не меняйте.",
                                 "Нажмите «‹» в левом верхнем углу."]
        default: ["Здесь ничего менять не нужно.", "Нажмите «‹» в левом верхнем углу."]
        }
        return [
            Page(title: "Отправьте в «Быстрые команды»", subtitle: "Mora откроет меню «Поделиться» с готовой автоматизацией.",
                 lines: ["Нажмите «Добавить в Быстрые команды» внизу.",
                         "В строке приложений выберите «Быстрые команды»."],
                 mock: AnyView(ShareSheetMock(name: name))),
            Page(title: "Нажмите «Добавить быструю команду»", subtitle: "«Быстрые команды» покажут карточку «\(name)».",
                 lines: ["Нажмите синюю кнопку «Добавить быструю команду» внизу экрана."],
                 mock: AnyView(AddShortcutMock(name: name))),
            Page(title: "Вернитесь назад",
                 subtitle: automation == .bankSMS || automation == .bankNotification
                    ? "Откроется готовая команда: действие Mora уже связано с триггером. Осталось выбрать банки — пока они не выбраны, над триггером написано, что автоматизацию нельзя включить."
                    : "Откроется готовая команда: триггер и действия Mora уже связаны. Надпись «Автоматизация выключена» над триггером — это нормально, её включают на следующем шаге.",
                 lines: edit, mock: AnyView(EditorMock(automation: automation))),
            Page(title: "Включите переключатель",
                 subtitle: "iOS добавляет чужие автоматизации выключенными, и включить их может только владелец iPhone. Это единственное, что нужно сделать руками.",
                 lines: ["Вы на вкладке «Автоматизация». Найдите строку с подписью «\(name)». Если команду добавляли раньше, в конце будет номер, например «\(name) 1».",
                         "Включите переключатель справа от неё — он станет зелёным.",
                         "Вернитесь в Mora: «◀ Mora» в левом верхнем углу экрана."],
                 mock: AnyView(EnableMock(automation: automation))),
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
            [Page(title: "Создайте автоматизацию «Сообщение»", subtitle: "Одной автоматизации хватит на все банки: отправителей можно выбрать несколько.",
                  lines: ["Откройте «Быстрые команды», вкладку «Автоматизация» и нажмите «+». На iOS 27 триггеры добавляются в новую команду как действия.",
                          "Выберите триггер «Сообщение».",
                          "Нажмите на «Отправитель» и выберите номера и названия всех банков, от которых приходят SMS о покупках. Без отправителя автоматизацию нельзя включить."],
                  mock: AnyView(TriggerMock(automation: automation))),
             runImmediately,
             Page(title: "Действие Log Bank Message", subtitle: "Mora получит текст SMS и отправителя. Коды подтверждения она сразу пропускает и не сохраняет.",
                  lines: ["Найдите в действиях «Mora» → «Log Bank Message».",
                          "В поле Text выберите «Входные данные команды», нажмите на вставленную переменную и выберите свойство «Содержимое».",
                          "В поле From так же выберите свойство «Отправитель». Нажмите «Готово»."],
                  mock: AnyView(actionMock))]
        case .bankNotification:
            [Page(title: "Создайте автоматизацию «Уведомление»", subtitle: "Одной автоматизации хватит на все банки: приложений можно выбрать несколько.",
                  lines: ["Откройте «Быстрые команды», вкладку «Автоматизация» и нажмите «+».",
                          "Найдите триггер «Уведомление» и выберите приложения всех своих банков и карт, например Chase и Bybit.",
                          "Фильтры по тексту можно не задавать. Уведомления этого приложения должны быть включены в настройках iPhone."],
                  mock: AnyView(TriggerMock(automation: automation))),
             runImmediately,
             Page(title: "Действие Log Bank Notification", subtitle: "Это отдельное действие для уведомлений, не для SMS: так журнал знает, откуда пришла покупка.",
                  lines: ["Найдите в действиях «Mora» → «Log Bank Notification».",
                          "В поле Title выберите «Входные данные команды», нажмите на вставленную переменную и выберите свойство Title. Так же для Body.",
                          "В поле App так же выберите свойство с названием приложения: так Mora узнает, какой банк прислал уведомление. Нажмите «Готово»."],
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
            ActionMock(title: "Log Bank Notification", parts: [.text("Log notification "), .token("Title"), .text(", "), .token("Body"), .text(" from "), .token("App")])
        case .walletTransaction:
            VStack(spacing: 8) {
                ActionMock(title: "Start Wallet Payment", parts: [.text("Start payment at "), .token("Merchant"), .text(" named "), .token("Name"), .text(" with "), .token("Card or Pass")])
                ActionMock(title: "Finish Wallet Payment", parts: [.text("Finish payment of "), .token("Amount")])
            }
        }
    }

    // MARK: Check

    private var checkHint: String {
        switch automation {
        case .walletNotification: "Заплатите Apple Pay, например за проезд. Когда Wallet покажет уведомление о покупке, Mora отметит его здесь."
        case .bankSMS: "Дождитесь SMS банка о покупке — Mora покажет здесь, что из него прочитала."
        case .bankNotification: "Дождитесь уведомления банка о покупке — Mora покажет здесь, что из него прочитала."
        case .walletTransaction: "Заплатите чем-нибудь Apple Pay — Mora покажет здесь, что передал Wallet."
        }
    }

    @ViewBuilder private var check: some View {
        if automation == .walletTransaction { WalletAutomationCheck(run: latestRun) } else { entryCheck }
    }

    private var entryCheck: some View {
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
                } else if !manual && step == 4 {
                    Button { openURL(WalletAutomationGuide.automationsURL) } label: {
                        Label(L("Открыть автоматизации"), systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large).tint(.moraGreen)
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
                    primary(latest == nil && latestRun == nil ? L("Проверю позже") : L("Готово")) { dismiss() }
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
    /// The trigger sentence of the Automation tab.
    static func sentence(_ automation: CaptureAutomation) -> String { TriggerMock(automation: automation).title }

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
        if automation == .walletNotification || automation == .walletTransaction { WalletAppIcon() }
        else {
            Image(systemName: automation == .bankSMS ? "message.fill" : "building.columns.fill").font(.caption).foregroundStyle(.white)
                .frame(width: 30, height: 24)
                .background(automation == .bankSMS ? Color.green : Color.blue, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    var title: String {
        switch automation {
        case .walletTransaction: "Когда я прикладываю пропуск или карту Wallet"
        case .walletNotification: "Когда я получаю уведомление от Wallet"
        case .bankSMS: "Когда я получаю сообщение от банка"
        default: "Когда я получаю уведомление от приложения банка"
        }
    }

    private var detail: String {
        switch automation {
        case .bankSMS: "Отправители: ваши банки · Запускать сразу"
        case .walletTransaction: "Триггер «Транзакция» · Запускать сразу"
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

/// The share sheet: the Shortcuts app in the row of apps.
private struct ShareSheetMock: View {
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "leaf.fill").font(.title3).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(Color.moraGreen, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(name).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            Divider()
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 5) {
                    ShortcutsAppIcon(size: 50)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.moraGreen, lineWidth: 3).padding(-4))
                    Text(L("Быстрые команды")).font(.caption2.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                }
                .frame(width: 70)
                ForEach(0..<3, id: \.self) { _ in
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.18)).frame(width: 50, height: 50)
                        Capsule().fill(Color.secondary.opacity(0.18)).frame(width: 40, height: 6)
                    }
                    .frame(width: 56)
                }
            }
        }
        .padding(14)
        .background(Color.moraCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// The shared shortcut as Shortcuts presents it before adding.
private struct AddShortcutMock: View {
    let name: String

    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading) {
                Image(systemName: "square.2.layers.3d.fill").foregroundStyle(.white)
                Spacer(minLength: 18)
                Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            }
            .padding(12).frame(width: 170, height: 96, alignment: .leading)
            .background(Color(red: 0.93, green: 0.38, blue: 0.40), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Label(L("Добавить быструю команду"), systemImage: "plus.circle.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(Color.blue, in: Capsule())
                .overlay(Capsule().stroke(Color.moraGreen, lineWidth: 3).padding(-4))
        }
    }
}

/// The added shortcut's editor: turned-off automation above the trigger; only Back is needed.
private struct EditorMock: View {
    let automation: CaptureAutomation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left").font(.headline).foregroundStyle(.primary)
                    .frame(width: 38, height: 38).background(Color.secondary.opacity(0.18), in: Circle())
                    .overlay(Circle().stroke(Color.moraGreen, lineWidth: 3).padding(-3))
                Text(automation.templateName).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(L(automation == .bankSMS ? "Укажите «Отправителя», чтобы включить автоматизацию" : "Автоматизация выключена"), systemImage: "clock.badge.xmark")
                    .font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                Text(L(TriggerMock.sentence(automation))).font(.subheadline.weight(.semibold))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            ForEach(automation.actions, id: \.self) { action in
                HStack(spacing: 8) {
                    Image(systemName: "leaf.fill").font(.caption).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(Color.moraGreen, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(action).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Color.moraCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

/// The Shortcuts app icon, drawn.
private struct ShortcutsAppIcon: View {
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: "square.2.layers.3d.fill").font(.system(size: size * 0.48)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color(red: 0.95, green: 0.35, blue: 0.55), Color(red: 0.35, green: 0.30, blue: 0.85)],
                                       startPoint: .topTrailing, endPoint: .bottomLeading),
                        in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

/// The added automation in the Automation tab: turn its switch on.
private struct EnableMock: View {
    let automation: CaptureAutomation

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: automation.icon).font(.caption).foregroundStyle(.white)
                        .frame(width: 26, height: 22).background(Color.blue, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    ShortcutsAppIcon(size: 24)
                }
                Text(L(TriggerMock.sentence(automation))).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(automation.templateName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Capsule().fill(Color.green).frame(width: 50, height: 30)
                .overlay(alignment: .trailing) { Circle().fill(.white).padding(2) }
                .overlay(Capsule().stroke(Color.moraGreen, lineWidth: 3).padding(-4))
        }
        .padding(14)
        .background(Color.moraCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// After the setup guide: the automation is set up, Mora waits for one purchase from it
/// to confirm that it works. The guide can be shown again from here.
struct AutomationWaitingView: View {
    let automation: CaptureAutomation
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var router: AppRouter
    @State private var latest: AutomationEntry?
    @State private var latestRun: WalletRun?

    private var since: Date { (automation.setupFinishedAt ?? .distantPast).addingTimeInterval(-60) }
    private var confirmed: Bool { latest != nil || latestRun != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ZStack {
                        Circle().fill(Color.orange.opacity(0.14)).frame(width: 96, height: 96)
                        Image(systemName: confirmed ? "checkmark.seal.fill" : "hourglass").font(.system(size: 40))
                            .foregroundStyle(confirmed ? Color.moraGreen : .orange)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 12)
                    Text(L(confirmed ? "Автоматизация работает" : "Ждём первую покупку"))
                        .font(.title2.weight(.bold)).frame(maxWidth: .infinity).multilineTextAlignment(.center)
                    Text(L(hint)).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    if automation == .walletTransaction {
                        WalletAutomationCheck(run: latestRun)
                    } else {
                        Card {
                            if let latest {
                                AutomationEntryRow(entry: latest)
                            } else {
                                HStack(spacing: 12) {
                                    ProgressView()
                                    Text(L("Mora покажет здесь первую покупку из этой автоматизации.")).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(L("Покупки нет?"), systemImage: "questionmark.circle").font(.headline)
                            Text(L("Проверьте, что переключатель автоматизации в «Быстрых командах» на вкладке «Автоматизация» включён. Если не помогло, пройдите настройку ещё раз.")).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button { router.sheet = .automationGuide(automation) } label: {
                        Label(L("Показать инструкцию снова"), systemImage: "list.number").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large).tint(.moraGreen)
                    Button { dismiss() } label: { Text(L("Готово")).fontWeight(.semibold).frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large).tint(.moraGreen)
                }
                .padding(.horizontal, 20).padding(.vertical, 12).background(Color.moraBackground)
            }
            .background(Color.moraBackground)
            .wrappingTitle(automation.title)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Закрыть")) { dismiss() } } }
            .task {
                while !Task.isCancelled {
                    latest = AutomationJournal.entries().first { $0.source == automation && $0.date >= since }
                    if automation == .walletTransaction { latestRun = WalletRunLog.runs().first { $0.receivedAt >= since } }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
        }
    }

    private var hint: String {
        if confirmed { return "Первая покупка пришла — дальше Mora записывает покупки сама." }
        return switch automation {
        case .walletTransaction: "Вы настроили автоматизацию. Заплатите чем-нибудь Apple Pay: как только Mora получит хотя бы одну покупку, настройка подтвердится."
        case .walletNotification: "Вы настроили автоматизацию. Как только Wallet покажет уведомление о покупке и Mora его получит, настройка подтвердится."
        case .bankSMS: "Вы настроили автоматизацию. Как только придёт SMS банка о покупке и Mora его прочитает, настройка подтвердится."
        case .bankNotification: "Вы настроили автоматизацию. Как только придёт уведомление банка о покупке и Mora его прочитает, настройка подтвердится."
        }
    }
}
