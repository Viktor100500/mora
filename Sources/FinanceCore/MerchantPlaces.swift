import Foundation

/// A compact regional extract of Overture Places. Names are matched locally;
/// the public dataset, rather than a model or individual expense, supplies types.
public struct MerchantPlaces: Sendable {
    public static let bundled: MerchantPlaces = {
        let roots = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources")].compactMap { $0 }
        let bundle = roots.compactMap { Bundle(url: $0.appendingPathComponent("Mora_FinanceCore.bundle")) }.first ?? Bundle.module
        guard let url = bundle.url(forResource: "MerchantPlaces", withExtension: "deflate"),
              let compressed = try? Data(contentsOf: url),
              let data = try? (compressed as NSData).decompressed(using: .zlib) as Data,
              let catalog = try? MerchantPlaces(data: data) else { return MerchantPlaces() }
        return catalog
    }()
    private struct Match: Sendable { var groups: Set<MerchantGroup>; var unknown: Bool; var prefixAllowed: Bool }
    private var index: [String: Match] = [:]
    public private(set) var placeCount = 0
    public private(set) var region = ""
    public private(set) var release = ""
    public init() {}
    public init(data: Data) throws {
        struct Feed: Decodable {
            let schemaVersion: Int; let region: String; let release: String; let places: [Place]
        }
        struct Place: Decodable { let name: String; let group: MerchantGroup? }
        guard data.count <= 32_000_000 else { throw CloudAPIError.invalidResponse }
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        guard feed.schemaVersion == 1, !feed.places.isEmpty, feed.places.count <= 300_000 else { throw CloudAPIError.invalidResponse }
        region = feed.region; release = feed.release; placeCount = feed.places.count
        for place in feed.places {
            let name = MerchantName.normalized(place.name)
            guard name.count >= 4, name.count <= 200 else { continue }
            add(name, group: place.group, prefixAllowed: name.split(separator: " ").count >= 2)
            // These are type descriptors from the source name, not inferred
            // business types. Conflicting names still block all variants.
            var words = name.split(separator: " ").map(String.init)
            let descriptors: Set<String> = ["market", "markets", "supermarket", "restaurant", "cafe", "bakery", "cake", "inc", "llc"]
            while words.count > 1, let last = words.last, descriptors.contains(last) {
                words.removeLast()
                let shortened = words.joined(separator: " ")
                if shortened.filter(\.isLetter).count >= 6 { add(shortened, group: place.group, prefixAllowed: false) }
            }
            // Some source names join the business type to the brand (e.g.
            // Examplebrandcafe). Only accept long stems and compatible types.
            let attached = place.group == .dining ? ["restaurant", "bakery", "cafe", "cake"] :
                (place.group == .groceries ? ["supermarket", "market"] : [])
            for suffix in attached where name.hasSuffix(suffix) && !name.hasSuffix(" " + suffix) {
                let stem = String(name.dropLast(suffix.count))
                if stem.filter(\.isLetter).count >= 8 { add(stem, group: place.group, prefixAllowed: false) }
            }
        }
    }
    private mutating func add(_ name: String, group: MerchantGroup?, prefixAllowed: Bool) {
        let key = name.replacingOccurrences(of: " ", with: "")
        var match = index[key] ?? Match(groups: [], unknown: false, prefixAllowed: false)
        if let group { match.groups.insert(group) } else { match.unknown = true }
        match.prefixAllowed = match.prefixAllowed || prefixAllowed
        index[key] = match
    }
    public func group(for merchant: String) -> MerchantGroup? {
        let name = MerchantName.descriptor(merchant)
        guard !name.isEmpty, name.count <= 1000 else { return nil }
        let words = name.split(separator: " ")
        for length in stride(from: words.count, through: 1, by: -1) {
            let key = words.prefix(length).joined()
            guard let match = index[key] else { continue }
            let exact = length == words.count
            // A bank descriptor can append a street number to a one-word name.
            let address = !exact && words[length].first?.isNumber == true && key.count >= 6
            let prefix = match.prefixAllowed && words.prefix(length).joined(separator: " ").count >= 8
            guard exact || address || prefix else { continue }
            guard !match.unknown, match.groups.count == 1 else { return nil }
            return match.groups.first
        }
        return nil
    }
}
