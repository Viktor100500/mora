import Foundation

extension Ledger {
    /// Explicit rules win, then the user's own merchant history, then a small
    /// offline vocabulary. An unknown merchant stays uncategorized.
    public func historicalCategory(merchant: String, kind: TransactionKind) -> UUID? {
        guard kind != .transfer else { return nil }
        if let rule = matchingCategory(merchant: merchant, kind: kind) { return rule }
        let normalized = MerchantName.normalized
        let name = normalized(merchant)
        guard !name.isEmpty else { return nil }
        if let previous = transactions.filter({
            $0.kind == kind && normalized($0.merchant) == name && category($0.categoryID)?.kind == kind
        }).max(by: { $0.date < $1.date }) { return previous.categoryID }
        return nil
    }

    public func suggestedCategory(merchant: String, kind: TransactionKind) -> UUID? {
        if let known = historicalCategory(merchant: merchant, kind: kind) { return known }
        let normalized = MerchantName.normalized
        let name = normalized(merchant)
        guard kind == .expense else { return nil }
        let vocabulary: [(merchants: [String], categories: [String])] = [
            (["raising canes", "raising cane s", "starbucks", "mcdonalds", "mcdonald s", "kfc", "burger king", "restaurant", "cafe", "coffee", "pizza", "ресторан", "кафе", "кофе"],
             ["кафе и рестораны", "рестораны", "кафе", "restaurants", "dining", "food and drinks"]),
            (["lidl", "aldi", "walmart", "whole foods", "trader joe s", "grocery", "supermarket", "пятерочка", "перекресток", "магнит"],
             ["продукты", "groceries"]),
            (["uber", "lyft", "taxi", "такси", "транспорт"], ["транспорт", "transport", "transportation"]),
            (["netflix", "spotify", "youtube premium", "icloud"], ["подписки", "subscriptions"]),
            (["pharmacy", "аптека"], ["здоровье", "health", "healthcare"])
        ]
        let padded = " " + name + " "
        for entry in vocabulary where entry.merchants.contains(where: { padded.contains(" " + $0 + " ") }) {
            if let match = categories.first(where: { $0.kind == kind && entry.categories.contains(normalized($0.name)) }) { return match.id }
        }
        return nil
    }
}
