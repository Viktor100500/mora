import SwiftUI
import FinanceCore

/// Accounts of a multi-currency card in other currencies: for each currency, none or
/// one account. A purchase in that currency is booked there; any other currency goes
/// to the card's main account and is converted.
struct CardCurrencyAccounts: View {
    let accounts: [Account]
    let main: UUID?
    @Binding var selection: [UUID]

    private var mainCurrency: String? { accounts.first { $0.id == main }?.currency }
    private var currencies: [String] { Set(accounts.map(\.currency)).subtracting([mainCurrency ?? ""]).sorted() }
    private var chosen: [Account] { Self.valid(selection, main: main, in: accounts).compactMap { id in accounts.first { $0.id == id } } }

    var body: some View {
        if main != nil, !currencies.isEmpty {
            DisclosureGroup {
                ForEach(currencies, id: \.self) { currency in
                    Picker(currency, selection: binding(currency)) {
                        Text(L("Основной счёт")).tag(UUID?.none)
                        ForEach(accounts.filter { $0.currency == currency }) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                }
                Text(L("Покупка в валюте выбранного счёта спишется с него. Остальные валюты — с основного счёта с пересчётом."))
                    .font(.caption).foregroundStyle(.secondary)
            } label: {
                Text(chosen.isEmpty ? L("Счета в других валютах") : L("Другие валюты: \(chosen.map(\.currency).joined(separator: ", "))"))
                    .font(.subheadline)
            }
        }
    }

    private func binding(_ currency: String) -> Binding<UUID?> {
        Binding(get: { chosen.first { $0.currency == currency }?.id }, set: { value in
            selection = chosen.filter { $0.currency != currency }.map(\.id) + (value.map { [$0] } ?? [])
        })
    }

    /// Existing accounts, one per currency, none in the main account's currency.
    static func valid(_ ids: [UUID], main: UUID?, in accounts: [Account]) -> [UUID] {
        let mainCurrency = accounts.first { $0.id == main }?.currency
        var seen = Set<String>()
        return ids.compactMap { id in accounts.first { $0.id == id } }
            .filter { $0.id != main && $0.currency != mainCurrency && seen.insert($0.currency).inserted }
            .map(\.id)
    }
}
