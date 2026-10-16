import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable {
    case russian = "ru", english = "en"
    public var id: String { rawValue }
    public var locale: Locale { Locale(identifier: self == .english ? "en_US" : "ru_RU") }
}

/// UI translation only. Stored account/category/merchant names are never rewritten.
public final class UILocalization: @unchecked Sendable {
    public static let shared = UILocalization()
    private let exact: [String: String]
    private let templates: [(regex: NSRegularExpression, english: String)]
    private var cache: [String: String] = [:]
    private let lock = NSLock()
    public init(applicationResourcesURL: URL? = Bundle.main.resourceURL) {
        // SwiftPM's generated accessor looks beside the executable and in its
        // build directory. A distributed macOS app keeps resources in Contents/Resources.
        let executableResources = Bundle.main.executableURL?.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources")
        let resourceBundle = [applicationResourcesURL, executableResources].compactMap { root in
            root.flatMap { Bundle(url: $0.appendingPathComponent("Mora_FinanceCore.bundle")) }
        }.first ?? Bundle.module
        let data = resourceBundle.url(forResource: "en", withExtension: "json", subdirectory: "Localization")
            .flatMap { try? Data(contentsOf: $0) }
        exact = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        templates = exact.filter { $0.key.contains("{0}") }.sorted {
            // Prefer specific sentences over broad templates such as “{0} transactions”.
            $0.key.count > $1.key.count
        }.compactMap { key, english in
            let parts = key.components(separatedBy: try! NSRegularExpression(pattern: "\\{[0-9]+\\}"))
            let pattern = "^" + parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "([\\s\\S]*?)") + "$"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, english)
        }
    }
    public func text(_ value: String, language: AppLanguage) -> String {
        guard language == .english else { return value }
        if let translated = exact[value] { return translated }
        guard value.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) else { return value }
        lock.lock(); let previous = cache[value]; lock.unlock()
        if let previous { return previous }
        let range = NSRange(value.startIndex..., in: value)
        var result = value
        for template in templates {
            guard let match = template.regex.firstMatch(in: value, range: range) else { continue }
            result = template.english
            for index in (1..<match.numberOfRanges).reversed() {
                guard let range = Range(match.range(at: index), in: value) else { continue }
                var argument = String(value[range])
                if ["выше", "ниже", "Текущий месяц еще не завершен. ", "синхронизация включена", "синхронизация на паузе"].contains(argument) {
                    argument = exact[argument] ?? argument
                }
                result = result.replacingOccurrences(of: "{\(index - 1)}", with: argument)
            }
            break
        }
        lock.lock()
        if cache.count >= 2048 { cache.removeAll(keepingCapacity: true) }
        cache[value] = result
        lock.unlock()
        return result
    }
    public var translatedStringCount: Int { exact.count }
}

private extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        var parts: [String] = [], start = startIndex
        for match in regex.matches(in: self, range: NSRange(startIndex..., in: self)) {
            guard let range = Range(match.range, in: self) else { continue }
            parts.append(String(self[start..<range.lowerBound])); start = range.upperBound
        }
        parts.append(String(self[start...])); return parts
    }
}
