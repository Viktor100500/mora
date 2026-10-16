import SwiftUI
import FinanceCore

struct WelcomeView: View {
    @AppStorage("mora.language") private var language = "ru"
    @State private var baseCurrency = "USD"
    var start: (String) -> Void
    var explore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                IconTile(icon: "leaf.fill", color: "green", size: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("Добро пожаловать в Mora")).font(.title2.weight(.semibold))
                    Text(L("Личные финансы на вашем Mac")).foregroundStyle(.secondary)
                }
            }
            Picker(L("Язык интерфейса"), selection: $language) {
                Text("Русский").tag("ru")
                Text("English").tag("en")
            }.pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 18) {
                step("lock.shield", "Без регистрации", "Счета и операции хранятся на вашем Mac. Облако подключается отдельно по вашему выбору.")
                step("wallet.bifold", "Начните с одного счета", "Укажите валюту и остаток перед первой операцией. Затем добавьте расход или импортируйте CSV.")
                step("chart.pie", "Смотрите общую картину", "Обзор и аналитика покажут расходы по категориям. Демо поможет сначала познакомиться с приложением.")
            }
            Divider()
            HStack {
                Text(L("Валюта отчетов")).font(.callout.weight(.medium))
                Spacer()
                Picker(L("Валюта отчетов"), selection: $baseCurrency) {
                    ForEach(currencyList, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 150, alignment: .leading)
            }
            Text(L("Валюта отчетов объединяет итоги. У каждого счета может быть своя валюта."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("Посмотреть демо"), action: explore)
                Spacer()
                Button(L("Создать первый счет")) { start(baseCurrency) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 560).environment(\.locale, L10n.locale)
    }

    private func step(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.moraGreen).frame(width: 26)
            VStack(alignment: .leading, spacing: 5) {
                Text(L(title)).font(.callout.weight(.semibold))
                Text(L(detail)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
