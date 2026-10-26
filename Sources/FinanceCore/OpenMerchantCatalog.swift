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
    public static func descriptor(_ text: String) -> String {
        var name = normalized(text)
        let prefixes = ["card purchase ", "purchase ", "sq ", "tst ", "pos "]
        while let prefix = prefixes.first(where: { name.hasPrefix($0) }) {
            name = String(name.dropFirst(prefix.count))
        }
        return name
    }
}

/// Exact names and longest token-boundary prefixes. Conflicting types never win
/// by source order; negative aliases are checked before accepting an entry.
public struct MerchantCatalog: Sendable {
    public static let bundled = MerchantCatalog()
    private struct Candidate: Sendable { let group: MerchantGroup; let negatives: [String]; let prefixAllowed: Bool }
    private var index: [String: [Candidate]] = [:]
    public init(applicationResourcesURL: URL? = Bundle.main.resourceURL) {
        let executableResources = Bundle.main.executableURL?.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources")
        let resourceBundle = [applicationResourcesURL, executableResources].compactMap { root in
            root.flatMap { Bundle(url: $0.appendingPathComponent("Mora_FinanceCore.bundle")) }
        }.first ?? Bundle.module
        struct Alias: Decodable { let alias: String; let group: MerchantGroup; let prefixAllowed: Bool? }
        if let url = resourceBundle.url(forResource: "MerchantAliases", withExtension: "json"),
           let data = try? Data(contentsOf: url), let aliases = try? JSONDecoder().decode([Alias].self, from: data) {
            for item in aliases { add(item.alias, group: item.group, prefixAllowed: item.prefixAllowed ?? true) }
        }
    }
    public mutating func add(_ alias: String, group: MerchantGroup, negatives: [String] = [], prefixAllowed: Bool = true) {
        let name = MerchantName.normalized(alias)
        guard name.count >= 3, name.count <= 200 else { return }
        index[name, default: []].append(Candidate(group: group, negatives: negatives.map(MerchantName.normalized), prefixAllowed: prefixAllowed))
    }
    public func group(for merchant: String) -> MerchantGroup? {
        let name = MerchantName.descriptor(merchant)
        guard !name.isEmpty, name.count <= 1000 else { return nil }
        let words = name.split(separator: " ")
        // Contactless transit descriptions append the payment product to the
        // network name. Resolve the remaining name only against transit data.
        for suffix in [" tapp paygo cp", " tapp paygo"] where name.hasSuffix(suffix) {
            let network = String(name.dropLast(suffix.count))
            if let entries = index[network], Set(entries.map(\.group)) == [.transport] { return .transport }
        }
        for length in stride(from: words.count, through: 1, by: -1) {
            let alias = words.prefix(length).joined(separator: " ")
            guard let entries = index[alias], length == words.count || alias.count >= 4 else { continue }
            let candidates = entries.filter { length == words.count || $0.prefixAllowed }
            guard !candidates.isEmpty else { continue }
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
        for (path, value) in feed.nsi {
            for item in value.items {
                let group: MerchantGroup?
                let tags = item.tags
                let transit = path.hasPrefix("transit/") || (path.hasPrefix("operators/") &&
                    ["bus", "trolleybus", "train", "tram", "subway", "light_rail", "ferry", "monorail"].contains(tags["route"] ?? ""))
                guard path.hasPrefix("brands/") || transit else { continue }
                if transit { group = .transport }
                else if ["cafe", "restaurant", "fast_food", "bar", "pub", "ice_cream"].contains(tags["amenity"] ?? "") { group = .dining }
                else if tags["amenity"] == "pharmacy" { group = .health }
                else if tags["amenity"] == "cinema" { group = .entertainment }
                else if ["hotel", "motel", "hostel"].contains(tags["tourism"] ?? "") { group = .travel }
                else if ["supermarket", "convenience", "greengrocer", "butcher", "seafood"].contains(tags["shop"] ?? "") { group = .groceries }
                else if ["department_store", "variety_store", "stationery", "clothes", "shoes", "books", "electronics", "sports", "toys", "jewelry", "gift", "cosmetics"].contains(tags["shop"] ?? "") { group = .shopping }
                else if tags["shop"] == "pet" { group = .pets }
                else if ["fuel", "taxi", "car_rental", "car_sharing", "bicycle_rental", "charging_station"].contains(tags["amenity"] ?? "") { group = .transport }
                else { group = nil }
                guard let group else { continue }
                let keys = transit ? ["network", "operator", "name"] : ["brand", "name"]
                for (key, name) in tags where keys.contains(where: { key == $0 || key.hasPrefix($0 + ":") }) {
                    guard !key.contains("wikidata"), !key.contains("wikipedia") else { continue }
                    // A short network name such as PATH must not classify PATH Mental Health.
                    add(name, group: group, prefixAllowed: !transit || MerchantName.normalized(name).contains(" "))
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
    private let cacheDirectory: URL?
    private var catalog: MerchantCatalog?
    private var refreshAfter = Date.distantPast
    private var hasFeeds = false
    private var loading: Task<LoadedCatalog, Never>?
    public init(session: URLSession = .shared, cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("Mora/MerchantCatalogs")) {
        self.session = session; self.cacheDirectory = cacheDirectory
    }
    public func group(for merchant: String, now: Date = Date()) async throws -> MerchantGroup? {
        if let group = MerchantPlaces.bundled.group(for: merchant) { return group }
        if let group = MerchantCatalog.bundled.group(for: merchant) { return group }
        if let catalog, now < refreshAfter {
            if let group = catalog.group(for: merchant) { return group }
            guard hasFeeds else { throw Self.unavailable }
            return nil
        }
        if let loading { return try resolved(await loading.value, merchant: merchant) }
        let session = session, cacheDirectory = cacheDirectory
        let job = Task.detached(priority: .utility) { await Self.load(session: session, directory: cacheDirectory, now: now) }
        loading = job
        let value = await job.value
        catalog = value.catalog; refreshAfter = value.refreshAfter; hasFeeds = value.hasFeeds; loading = nil
        return try resolved(value, merchant: merchant)
    }
    private static var unavailable: LedgerError { .invalid("Каталоги продавцов временно недоступны. Покупки сохраняются без категории.") }
    private func resolved(_ value: LoadedCatalog, merchant: String) throws -> MerchantGroup? {
        if let group = value.catalog.group(for: merchant) { return group }
        guard value.hasFeeds else { throw Self.unavailable }
        return nil
    }
    private struct CachedFeed: Codable { let url: URL; let fetchedAt: Date; let data: Data }
    private struct Feed: Sendable { let data: Data?; let refreshAfter: Date }
    private struct LoadedCatalog: Sendable { let catalog: MerchantCatalog; let refreshAfter: Date; let hasFeeds: Bool }
    private static func apply(_ data: Data, studio: Bool, to catalog: inout MerchantCatalog) throws {
        if studio { try catalog.addMerchantStudio(data) } else { try catalog.addNSI(data) }
    }
    private static func loadFeed(studio: Bool, session: URLSession, directory: URL?, now: Date) async -> Feed {
        let url = studio ? studioURL : nsiURL
        let file = directory?.appendingPathComponent(studio ? "studio-v1.json" : "nsi-v1.json")
        var cached: CachedFeed?
        if let file, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 24_000_000,
           let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(CachedFeed.self, from: data),
           saved.url == url, saved.data.count <= 16_000_000, saved.fetchedAt.timeIntervalSince1970.isFinite,
           saved.fetchedAt <= now.addingTimeInterval(300) {
            var check = MerchantCatalog()
            if (try? apply(saved.data, studio: studio, to: &check)) != nil { cached = saved }
        }
        if let cached, now.timeIntervalSince(cached.fetchedAt) < 7 * 86400 {
            return Feed(data: cached.data, refreshAfter: cached.fetchedAt.addingTimeInterval(7 * 86400))
        }
        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("Mora (merchant catalogs)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 16_000_000 else { throw CloudAPIError.invalidResponse }
            var check = MerchantCatalog()
            try apply(data, studio: studio, to: &check)
            if let file, let directory {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if let encoded = try? JSONEncoder().encode(CachedFeed(url: url, fetchedAt: now, data: data)) {
                    try? encoded.write(to: file, options: .atomic)
                }
            }
            return Feed(data: data, refreshAfter: now.addingTimeInterval(7 * 86400))
        } catch {
            // A failed or malformed download never replaces the last valid feed.
            return Feed(data: cached?.data, refreshAfter: now.addingTimeInterval(900))
        }
    }
    private static func load(session: URLSession, directory: URL?, now: Date) async -> LoadedCatalog {
        async let studio = loadFeed(studio: true, session: session, directory: directory, now: now)
        async let nsi = loadFeed(studio: false, session: session, directory: directory, now: now)
        let feeds = await (studio, nsi)
        var catalog = MerchantCatalog(), loaded = false
        if let data = feeds.0.data, (try? apply(data, studio: true, to: &catalog)) != nil { loaded = true }
        if let data = feeds.1.data, (try? apply(data, studio: false, to: &catalog)) != nil { loaded = true }
        return LoadedCatalog(catalog: catalog, refreshAfter: min(feeds.0.refreshAfter, feeds.1.refreshAfter), hasFeeds: loaded)
    }
}
