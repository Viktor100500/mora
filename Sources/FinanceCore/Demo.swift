import Foundation

public extension Ledger {
    static func demo(now: Date = Date()) -> Ledger {
        var ledger = Ledger.empty
        let main = Account(name: "Основной счет", openingBalance: 285_000, color: "green")
        let savings = Account(name: "Накопления", kind: .savings, openingBalance: 640_000, color: "purple")
        let usd = Account(name: "Валютный счет", currency: "USD", openingBalance: 3_200, color: "blue")
        let cash = Account(name: "Наличные", kind: .cash, openingBalance: 18_000, color: "orange")
        ledger.accounts = [main, savings, usd, cash]
        ledger.preferences.rates = ["RUB": 1, "USD": 90, "EUR": 100]
        let month = Dates.month(now)
        let currentDay = Calendar.current.component(.day, from: now)
        func add(_ merchant: String, _ amount: Decimal, _ category: String, _ date: Date, account: Account = main) {
            let kind: TransactionKind = amount < 0 ? .expense : .income
            ledger.transactions.append(Transaction(date: date, merchant: merchant, amount: amount, accountID: account.id, categoryID: ledger.categories.first { $0.name == category }?.id, kind: kind))
        }
        for offset in (0..<6).reversed() {
            let start = Calendar.current.date(byAdding: .month, value: -offset, to: month)!
            func date(_ day: Int) -> Date { Calendar.current.date(byAdding: .day, value: day - 1, to: start)! }
            func include(_ day: Int) -> Bool { offset != 0 || day <= currentDay }
            if include(1) { add("Зарплата", 245_000, "Зарплата", date(1)) }
            if include(2) { add("Аренда квартиры", -65_000, "Дом", date(2)) }
            if include(3) { add("Перекресток", Decimal(-5_280 - offset * 120), "Продукты", date(3)) }
            if include(4) { add("Яндекс Go", -1_280, "Транспорт", date(4)) }
            if include(5) { add("Работа над проектом", 95_000, "Другой доход", date(5)) }
            if include(6) { add("Кофемания", -3_650, "Кафе и рестораны", date(6)) }
            if include(7) { add("ВкусВилл", -4_720, "Продукты", date(7)) }
            if include(8) { add("Ozon", -12_490, "Покупки", date(8)) }
            if include(9) { add("Яндекс Плюс", -399, "Подписки", date(9)) }
            if include(10) { add("Клиника", -6_200, "Здоровье", date(10)) }
            if include(11) { add("Супермаркет", -2_870, "Продукты", date(11)) }
            if include(12) { add("Кино", -1_800, "Развлечения", date(12)) }
            if include(15) { add("Ресторан", -4_600, "Кафе и рестораны", date(15)) }
            if include(19) { add("Продукты на неделю", -8_900, "Продукты", date(19)) }
            if include(22) { add("Билеты", Decimal(-18_000 - offset * 3_400), "Путешествия", date(22)) }
            if include(25) { add("Маркетплейс", -5_990, "Покупки", date(25)) }
        }
        ledger.budgets = [Budget(categoryID: ledger.categories[0].id, limit: 30_000), Budget(categoryID: ledger.categories[1].id, limit: 15_000), Budget(categoryID: ledger.categories[2].id, limit: 8_000), Budget(categoryID: ledger.categories[3].id, limit: 70_000), Budget(categoryID: ledger.categories[4].id, limit: 12_000)]
        ledger.goals = [Goal(name: "Подушка безопасности", target: 900_000, saved: 640_000, deadline: Calendar.current.date(byAdding: .month, value: 8, to: now)!, icon: "shield.lefthalf.filled"), Goal(name: "Путешествие в Японию", target: 350_000, saved: 145_000, deadline: Calendar.current.date(byAdding: .month, value: 6, to: now)!, icon: "airplane")]
        func next(_ day: Int) -> Date { Calendar.current.date(byAdding: .day, value: day - 1, to: month)! }
        let followingMonth = Calendar.current.date(byAdding: .month, value: 1, to: month)!
        ledger.recurring = [RecurringPayment(name: "Яндекс Плюс", amount: 399, accountID: main.id, categoryID: ledger.categories[7].id, nextDate: next(9) > now ? next(9) : Calendar.current.date(byAdding: .day, value: 8, to: followingMonth)!), RecurringPayment(name: "iCloud+", amount: 199, accountID: main.id, categoryID: ledger.categories[7].id, nextDate: next(18)), RecurringPayment(name: "Аренда квартиры", amount: 65_000, accountID: main.id, categoryID: ledger.categories[3].id, nextDate: Calendar.current.date(byAdding: .day, value: 1, to: followingMonth)!)]
        ledger.rules = [CategoryRule(keyword: "ВкусВилл", categoryID: ledger.categories[0].id), CategoryRule(keyword: "Яндекс Go", categoryID: ledger.categories[2].id), CategoryRule(keyword: "Ozon", categoryID: ledger.categories[4].id)]
        return ledger
    }
}
