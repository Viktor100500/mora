import SwiftUI
import FinanceCore

struct WelcomeView: View {
    @State private var baseCurrency = Locale.current.currency?.identifier ?? "USD"
    var start: (String) -> Void
    var explore: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "leaf.fill").font(.system(size: 30)).foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(LinearGradient(colors: [Color(red: 0.25, green: 0.51, blue: 0.41), Color(red: 0.11, green: 0.31, blue: 0.23)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        Text(L("Добро пожаловать в Mora")).font(.largeTitle.weight(.bold))
                        Text(L("Личные финансы на вашем iPhone")).font(.title3).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        step("lock.shield", "Без регистрации", "Счета и операции хранятся на iPhone. Облако подключается отдельно по вашему выбору.")
                        step("wallet.bifold", "Начните с одного счета", "Укажите валюту и остаток перед первой операцией. Затем добавьте расход или импортируйте CSV.")
                        step("chart.pie", "Смотрите общую картину", "Обзор и аналитика покажут расходы по категориям. Демо поможет сначала познакомиться с приложением.")
                        step("arrow.triangle.2.circlepath", "Вместе с Mac", "Подключите общую базу Mora или перенесите резервную копию JSON с Mac.")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("Валюта отчетов")).font(.headline)
                            Spacer()
                            CurrencyPicker(selection: $baseCurrency).font(.headline)
                        }
                        Text(L("Валюта отчетов объединяет итоги. У каждого счета может быть своя валюта.")).font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(Color.moraCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(24)
            }
            .background(Color.moraBackground)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button { start(baseCurrency) } label: { Text(L("Создать первый счет")).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6) }
                        .buttonStyle(.borderedProminent)
                    Button(L("Посмотреть демо"), action: explore).font(.headline)
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
                .background(.bar)
            }
            .environment(\.locale, L10n.locale)
        }
    }

    private func step(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.moraGreen).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(L(title)).font(.headline)
                Text(L(detail)).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
