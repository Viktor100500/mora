import Foundation

extension Ledger {
    /// Explicit rules and exact history win. Descriptor variants are reused only
    /// when every matching historical name agrees on an existing category.
    public func historicalCategory(merchant: String, kind: TransactionKind) -> UUID? {
        guard kind != .transfer else { return nil }
        if let rule = matchingCategory(merchant: merchant, kind: kind) { return rule }
        let normalized = MerchantName.normalized
        let name = normalized(merchant)
        guard !name.isEmpty else { return nil }
        if let previous = transactions.filter({
            $0.kind == kind && normalized($0.merchant) == name && category($0.categoryID)?.kind == kind
        }).max(by: { $0.date < $1.date }) { return previous.categoryID }
        guard let key = merchantHistoryKey(merchant) else { return nil }
        let matches = Set(transactions.compactMap { previous -> UUID? in
            guard previous.kind == kind, category(previous.categoryID)?.kind == kind,
                  merchantHistoryKey(previous.merchant) == key else { return nil }
            return previous.categoryID
        })
        return matches.count == 1 ? matches.first : nil
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

/// Wallet and bank statements can omit a generic store descriptor or add a
/// payment processor prefix. Keep brand words intact: arbitrary prefixes,
/// locations and single-word names are not enough evidence of the same seller.
private func merchantHistoryKey(_ merchant: String) -> String? {
    var name = MerchantName.normalized(merchant)
    for prefix in ["card purchase ", "purchase ", "sq ", "tst ", "pos "] where name.hasPrefix(prefix) {
        name = String(name.dropFirst(prefix.count)); break
    }
    var words = name.split(separator: " ").map(String.init)
    let descriptors: Set<String> = ["market", "store", "shop", "supermarket"]
    while words.count > 2, let last = words.last, descriptors.contains(last) { words.removeLast() }
    let key = words.joined(separator: " ")
    guard words.count >= 2, key.count >= 8 else { return nil }
    return key
}
