import Foundation

/// Comma-separated tag editing backed by the tags already saved in the ledger.
public enum TransactionTags {
    public static func normalized(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { value in
            let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, seen.insert(key(tag)).inserted else { return nil }
            return tag
        }
    }

    public static func parse(_ text: String) -> [String] {
        normalized(text.components(separatedBy: ","))
    }

    public static func suggestions(for text: String, available: [String]) -> [String] {
        let selected = Set(parse(text).map(key))
        let fragment = text.components(separatedBy: ",").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let query = available.contains { key($0) == key(fragment) } ? "" : fragment
        return normalized(available).filter {
            !selected.contains(key($0)) && (query.isEmpty || $0.localizedCaseInsensitiveContains(query))
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func selecting(_ tag: String, in text: String, available: [String]) -> String {
        var parts = text.components(separatedBy: ",")
        let fragment = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A complete existing tag is kept; a partially typed tag is completed.
        if !available.contains(where: { key($0) == key(fragment) }) { parts.removeLast() }
        return normalized(parts + [tag]).joined(separator: ", ") + ", "
    }

    private static func key(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
}

extension Ledger {
    public var availableTags: [String] {
        TransactionTags.normalized(transactions.flatMap(\.tags))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Use the only active account, or the source account most recently added to the ledger.
    public var suggestedTransactionAccountID: UUID? {
        let active = accounts.filter { !$0.archived }
        if active.count == 1 { return active[0].id }
        let ids = Set(active.map(\.id))
        return transactions.reversed().first { ids.contains($0.accountID) }?.accountID
    }
}
