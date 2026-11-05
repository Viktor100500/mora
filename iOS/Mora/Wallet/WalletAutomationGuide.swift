import SwiftUI

/// Step-by-step setup of the Wallet "Transaction" automation. iOS does not let an
/// app create automations, so each step shows what the Shortcuts screen looks
/// like, and the last step checks the next payment from the run journal.
struct WalletAutomationGuide: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var step = 0
    @State private var startedAt = Date()
    @State private var latest: WalletRun?

    private static let steps = 5

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
            .navigationTitle(L("Автоматизация Apple Pay"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Закрыть")) { dismiss() } }
            }
            .animation(.spring(duration: 0.35), value: step)
            .task(id: step) {
                // The last step watches the journal for the first payment after the setup.
                guard step == Self.steps else { return }
                while !Task.isCancelled {
                    latest = WalletRunLog.runs().first { $0.receivedAt >= startedAt.addingTimeInterval(-60) }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(1...Self.steps, id: \.self) { index in
                Capsule().fill(index <= step ? Color.moraGreen : Color.secondary.opacity(0.2)).frame(height: 5)
            }
        }
        .accessibilityLabel(L("Шаг \(step) из \(Self.steps)"))
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: intro
        case 1:
            header(1, "Создайте автоматизацию", "Всё делается в приложении «Быстрые команды». Возвращайтесь в Mora после каждого шага.")
            GuideMock { TriggerSearchMock() }
            instructions(["Откройте «Быстрые команды» и вкладку «Автоматизация».",
                          "Нажмите «+» или «Новая автоматизация».",
                          "Введите в поиске «Транзакция» и выберите её."])
            Button { if let url = URL(string: "shortcuts://") { openURL(url) } } label: {
                Label(L("Открыть «Быстрые команды»"), systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large).tint(.moraGreen)
        case 2:
            header(2, "Все карты и запуск сразу", "Так покупка записывается без вопросов, даже на заблокированном iPhone.")
            GuideMock { TriggerOptionsMock() }
            instructions(["Отметьте все карты, которыми платите.",
                          "Выберите «Запускать сразу» и выключите «Уведомлять о запуске».",
                          "Нажмите «Далее» → «Новая пустая автоматизация»."])
        case 3:
            header(3, "Первое действие — Start Wallet Payment", "Оно сохраняет покупку до того, как iOS прочитает сумму.")
            GuideMock {
                ActionMock(title: "Start Wallet Payment", parts: [.text("Start payment at "), .token("Продавец"), .text(" named "), .token("Имя"), .text(" with "), .token("Карта или пропуск")])
            }
            instructions(["Нажмите «Добавить действие» и найдите «Start Wallet Payment».",
                          "Нажмите на синее поле → «Входные данные команды».",
                          "Нажмите на неё ещё раз и выберите свойство, как на картинке. Так для всех трёх полей."])
        case 4:
            header(4, "Последнее действие — Finish Wallet Payment", "Одно поле, без выбора свойства: Mora сама достанет сумму из транзакции.")
            GuideMock {
                VStack(spacing: 10) {
                    ActionMock(title: "Start Wallet Payment", parts: [.text("Start payment at "), .token("Продавец"), .text(" …")], dimmed: true)
                    ActionMock(title: "Finish Wallet Payment", parts: [.text("Finish payment with "), .token("Входные данные команды")])
                }
            }
            instructions(["Добавьте «Finish Wallet Payment» под первым действием.",
                          "Нажмите на синее поле → «Входные данные команды». Свойство выбирать не нужно.",
                          "Нажмите «Готово»."])
        default:
            header(5, "Проверьте настройку", "Заплатите чем-нибудь Apple Pay — Mora покажет здесь, что передал Wallet.")
            WalletAutomationCheck(run: latest)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                Circle().fill(Color.moraGreen.opacity(0.12)).frame(width: 96, height: 96)
                Image(systemName: "wallet.pass.fill").font(.system(size: 40)).foregroundStyle(Color.moraGreen)
            }
            .frame(maxWidth: .infinity).padding(.top, 12)
            Text(L("Mora запишет каждую оплату Apple Pay")).font(.title2.weight(.bold)).frame(maxWidth: .infinity).multilineTextAlignment(.center)
            Text(L("iPhone сообщает о покупке через автоматизацию «Быстрых команд». Приложения не могут создать её сами, поэтому один раз настроим её вместе: 4 коротких шага и проверка, около двух минут."))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    benefit("checkmark.shield", "Покупки сохраняются даже без интернета и на заблокированном iPhone")
                    benefit("bolt", "Сумма, продавец, карта и счёт — без ручного ввода")
                    benefit("hand.tap", "Если Wallet что-то не передал, покупку можно дописать в Mora")
                }
            }
        }
    }

    private func benefit(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.moraGreen).frame(width: 22)
            Text(L(text)).font(.subheadline)
        }
    }

    private func header(_ number: Int, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Шаг \(number) из \(Self.steps)")).font(.caption.weight(.semibold)).foregroundStyle(Color.moraGreen)
            Text(L(title)).font(.title3.weight(.bold))
            Text(L(subtitle)).font(.subheadline).foregroundStyle(.secondary)
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

    @ViewBuilder private var buttons: some View {
        VStack(spacing: 10) {
            switch step {
            case 0:
                primary("Начать") { startedAt = Date(); step = 1 }
            case 1...4:
                HStack(spacing: 10) {
                    Button { step -= 1 } label: { Text(L("Назад")).frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large)
                    primary("Дальше") { step += 1 }
                }
            default:
                HStack(spacing: 10) {
                    Button { step -= 1 } label: { Text(L("Назад")).frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large)
                    primary(latest.map(WalletAutomationCheck.isReady) == true ? "Готово" : "Проверю позже") { dismiss() }
                }
            }
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(L(title)).fontWeight(.semibold).frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent).controlSize(.large).tint(.moraGreen)
    }
}

/// The result of the first payment after the setup: which parts of the automation work.
struct WalletAutomationCheck: View {
    let run: WalletRun?

    static func isReady(_ run: WalletRun) -> Bool {
        run.action == "Start Wallet Payment" && run.amountActionRan && !run.sentMerchant.isEmpty && !run.card.isEmpty
    }

    var body: some View {
        Card {
            if let run {
                VStack(alignment: .leading, spacing: 12) {
                    Label(L(Self.isReady(run) ? "Автоматизация работает" : "Почти готово: проверьте отмеченное"),
                          systemImage: Self.isReady(run) ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(Self.isReady(run) ? Color.moraGreen : .orange)
                    item(run.action == "Start Wallet Payment", "Первое действие — Start Wallet Payment",
                         fix: "Сейчас первым идёт «\(run.action.isEmpty ? "Log Wallet Payment" : run.action)». Замените его, шаг 3")
                    item(run.amountActionRan, "Последнее действие — Finish Wallet Payment", fix: "Добавьте его в конец автоматизации, шаг 4")
                    item(!run.merchant.isEmpty || !run.name.isEmpty, "Продавец", fix: "Поле Merchant: свойство «Продавец»")
                    item(!run.card.isEmpty, "Карта", fix: "Поле Card or Pass: свойство «Карта или пропуск»")
                    item(!run.amount.isEmpty, "Сумма", fix: "Транспорт и отложенные списания иногда приходят без суммы — это нормально, покупку можно обработать", optional: true)
                    item(!run.name.isEmpty, "Имя", fix: "Поле Name: свойство «Имя»", optional: true)
                    item(!run.transaction.isEmpty, "Транзакция целиком", fix: "Поле Transaction: «Входные данные команды»", optional: true)
                }
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Ждём первую оплату")).font(.headline)
                        Text(L("Mora покажет здесь, что передал Wallet. Можно закрыть помощника: проверка есть и в «Apple Pay на этом iPhone».")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func item(_ ok: Bool, _ title: String, fix: String, optional: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : optional ? "minus.circle" : "xmark.circle.fill")
                .foregroundStyle(ok ? Color.moraGreen : optional ? Color.secondary : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title)).font(.subheadline.weight(.medium))
                if !ok { Text(L(fix)).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: Shortcuts screens drawn for the guide

/// A rounded "phone screen" frame around a drawing of the Shortcuts interface.
private struct GuideMock<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

private struct TriggerSearchMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text(L("Транзакция")).foregroundStyle(.primary)
                Spacer()
            }
            .font(.subheadline).padding(10)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(spacing: 12) {
                WalletAppIcon()
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Транзакция")).font(.subheadline.weight(.semibold))
                    Text(L("Например, «Когда я прикладываю карту Wallet»")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color.moraCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.moraGreen, lineWidth: 2))
        }
    }
}

private struct TriggerOptionsMock: View {
    var body: some View {
        VStack(spacing: 0) {
            row { Text(L("Карты")); Spacer(); Text(L("Все")).foregroundStyle(.blue) }
            Divider()
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

/// A Shortcuts action block: plain words and blue variable fields.
private struct ActionMock: View {
    enum Part { case text(String), token(String) }
    let title: String
    let parts: [Part]
    var dimmed = false

    private var sentence: AttributedString {
        parts.reduce(into: AttributedString()) { result, part in
            switch part {
            case .text(let value): result += AttributedString(value)
            case .token(let value):
                var token = AttributedString("\u{00A0}" + L(value) + "\u{00A0}")
                token.foregroundColor = .blue
                token.backgroundColor = Color.blue.opacity(0.14)
                result += token
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "leaf.fill").font(.caption).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(Color.moraGreen, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(sentence).font(.body).lineSpacing(6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.moraCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(dimmed ? 0.5 : 1)
    }
}

/// The Wallet app icon as the Shortcuts trigger list shows it: stacked card stripes.
private struct WalletAppIcon: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color(red: 0.93, green: 0.91, blue: 0.86))
            .frame(width: 30, height: 24)
            .overlay(alignment: .top) {
                VStack(spacing: 1.5) {
                    stripe(Color(red: 0.28, green: 0.55, blue: 0.85))
                    stripe(Color(red: 0.98, green: 0.73, blue: 0.20))
                    stripe(Color(red: 0.38, green: 0.72, blue: 0.40))
                    stripe(Color(red: 0.92, green: 0.38, blue: 0.33))
                }
                .padding(.top, 5).padding(.horizontal, 3)
            }
    }

    private func stripe(_ color: Color) -> some View { Capsule().fill(color).frame(height: 2.5) }
}
