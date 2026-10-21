import Foundation

public enum MerchantGroup: String, Codable, Sendable {
    case groceries, dining, transport, shopping, health, entertainment, subscriptions, travel, home, taxes, utilities, education, pets

    public func category(in ledger: Ledger) -> UUID? {
        let names: [String]
        switch self {
        case .groceries: names = ["продукты", "groceries"]
        case .dining: names = ["кафе и рестораны", "рестораны", "кафе", "restaurants", "dining", "food and drinks"]
        case .transport: names = ["транспорт", "transport", "transportation"]
        case .shopping: names = ["покупки", "shopping"]
        case .health: names = ["здоровье", "health", "healthcare"]
        case .entertainment: names = ["развлечения", "entertainment"]
        case .subscriptions: names = ["подписки", "subscriptions"]
        case .travel: names = ["путешествия", "travel"]
        case .home: names = ["дом", "home"]
        case .taxes: names = ["налоги", "taxes"]
        case .utilities: names = ["коммунальные платежи", "коммунальные услуги", "utilities"]
        case .education: names = ["образование", "education"]
        case .pets: names = ["питомцы", "животные", "pets"]
        }
        return ledger.categories.first { $0.kind == .expense && names.contains(MerchantName.normalized($0.name)) }?.id
    }
}

public enum MerchantName {
    public static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
}

/// Exact names and longest token-boundary prefixes. Conflicting types never win
/// by source order; negative aliases are checked before accepting an entry.
public struct MerchantCatalog: Sendable {
    private struct Candidate: Sendable { let group: MerchantGroup; let negatives: [String] }
    private var index: [String: [Candidate]] = [:]
    public init(applicationResourcesURL: URL? = Bundle.main.resourceURL) {
        let executableResources = Bundle.main.executableURL?.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources")
        let resourceBundle = [applicationResourcesURL, executableResources].compactMap { root in
            root.flatMap { Bundle(url: $0.appendingPathComponent("Mora_FinanceCore.bundle")) }
        }.first ?? Bundle.module
        struct Alias: Decodable { let alias: String; let group: MerchantGroup }
        if let url = resourceBundle.url(forResource: "MerchantAliases", withExtension: "json"),
           let data = try? Data(contentsOf: url), let aliases = try? JSONDecoder().decode([Alias].self, from: data) {
            for item in aliases { add(item.alias, group: item.group) }
        }
    }
    public mutating func add(_ alias: String, group: MerchantGroup, negatives: [String] = []) {
        let name = MerchantName.normalized(alias)
        guard name.count >= 3, name.count <= 200 else { return }
        index[name, default: []].append(Candidate(group: group, negatives: negatives.map(MerchantName.normalized)))
    }
    public func group(for merchant: String) -> MerchantGroup? {
        var name = MerchantName.normalized(merchant)
        guard !name.isEmpty, name.count <= 1000 else { return nil }
        for prefix in ["card purchase ", "purchase ", "sq ", "tst ", "pos "] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count)); break
        }
        let words = name.split(separator: " ")
        for length in stride(from: words.count, through: 1, by: -1) {
            let alias = words.prefix(length).joined(separator: " ")
            guard let candidates = index[alias], length == words.count || alias.count >= 4 else { continue }
            if candidates.contains(where: { entry in
                entry.negatives.contains { (" " + name + " ").contains(" " + $0 + " ") }
            }) { return nil }
            let groups = Set(candidates.map(\.group))
            if groups.count == 1 { return groups.first }
            // A known but ambiguous brand must not fall back to a shorter name.
            return nil
        }
        return nil
    }
    public mutating func addMerchantStudio(_ data: Data) throws {
        struct Feed: Decodable { let merchants: [Merchant] }
        struct Merchant: Decodable {
            let canonicalName: String; let aliases: [String]; let category: String
            let negativeAliases: [String]?; let defaultConfidence: Double?
        }
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        guard !feed.merchants.isEmpty, feed.merchants.count <= 20_000 else { throw CloudAPIError.invalidResponse }
        for merchant in feed.merchants where (merchant.defaultConfidence ?? 0) >= 0.9 {
            let group: MerchantGroup?
            switch merchant.category {
            case "food_dining": group = .dining
            case "auto_transport": group = .transport
            case "government_taxes", "taxes": group = .taxes
            case "bills_utilities": group = .utilities
            case "groceries": group = .groceries
            case "shopping", "office": group = .shopping
            case "health": group = .health
            case "entertainment": group = .entertainment
            case "subscriptions": group = .subscriptions
            case "travel": group = .travel
            case "home": group = .home
            case "education": group = .education
            case "pets": group = .pets
            default: group = nil
            }
            guard let group else { continue }
            for alias in ([merchant.canonicalName] + merchant.aliases).prefix(100) {
                add(alias, group: group, negatives: merchant.negativeAliases ?? [])
            }
        }
    }
    public mutating func addNSI(_ data: Data) throws {
        struct Feed: Decodable { let nsi: [String: Group] }
        struct Group: Decodable { let items: [Item] }
        struct Item: Decodable { let tags: [String: String] }
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        guard !feed.nsi.isEmpty, feed.nsi.count <= 2000 else { throw CloudAPIError.invalidResponse }
        for (path, value) in feed.nsi where path.hasPrefix("brands/") {
            for item in value.items {
                let group: MerchantGroup?
                let tags = item.tags
                if ["cafe", "restaurant", "fast_food", "bar", "pub", "ice_cream"].contains(tags["amenity"] ?? "") { group = .dining }
                else if tags["amenity"] == "pharmacy" { group = .health }
                else if tags["amenity"] == "cinema" { group = .entertainment }
                else if ["hotel", "motel", "hostel"].contains(tags["tourism"] ?? "") { group = .travel }
                else if ["supermarket", "convenience", "greengrocer", "butcher", "seafood"].contains(tags["shop"] ?? "") { group = .groceries }
                else if ["department_store", "variety_store", "stationery", "clothes", "shoes", "books", "electronics", "sports", "toys", "jewelry", "gift", "cosmetics"].contains(tags["shop"] ?? "") { group = .shopping }
                else if tags["shop"] == "pet" { group = .pets }
                else { group = nil }
                guard let group else { continue }
                for (key, name) in tags where key == "brand" || key == "name" || key.hasPrefix("brand:") || key.hasPrefix("name:") {
                    guard !key.contains("wikidata"), !key.contains("wikipedia") else { continue }
                    add(name, group: group)
                }
            }
        }
    }
}

public actor OpenMerchantCatalogClient {
    public static let shared = OpenMerchantCatalogClient()
    public static let studioURL = URL(string: "https://raw.githubusercontent.com/jtvargas/merchant-studio/main/data/merchant_aliases.json")!
    public static let nsiURL = URL(string: "https://cdn.jsdelivr.net/npm/name-suggestion-index@8.0.20260918/dist/json/nsi.min.json")!
    private let session: URLSession
    private var catalog: MerchantCatalog?
    private var loadedAt: Date?
    private var loading: Task<MerchantCatalog, Error>?
    public init(session: URLSession = .shared) { self.session = session }
    public func group(for merchant: String) async throws -> MerchantGroup? {
        if let catalog, let loadedAt, Date().timeIntervalSince(loadedAt) < 7 * 86400 { return catalog.group(for: merchant) }
        if let loading { return try await loading.value.group(for: merchant) }
        let session = self.session
        let job = Task.detached(priority: .utility) { () throws -> MerchantCatalog in
            @Sendable func download(_ url: URL) async throws -> Data {
                var request = URLRequest(url: url, timeoutInterval: 8)
                request.setValue("Mora/1.5.8 (merchant catalog)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 16_000_000 else { throw CloudAPIError.invalidResponse }
                return data
            }
            async let studio = try? download(Self.studioURL)
            async let nsi = try? download(Self.nsiURL)
            let sources = await (studio, nsi)
            var result = MerchantCatalog(), loaded = false
            if let data = sources.0, (try? result.addMerchantStudio(data)) != nil { loaded = true }
            if let data = sources.1, (try? result.addNSI(data)) != nil { loaded = true }
            guard loaded else { throw LedgerError.invalid("Каталоги продавцов временно недоступны. Покупки сохраняются без категории.") }
            return result
        }
        loading = job
        do {
            let value = try await job.value
            catalog = value; loadedAt = Date(); loading = nil
            return value.group(for: merchant)
        } catch { loading = nil; throw error }
    }
}
