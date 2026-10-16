import Foundation

public enum FinancialPrivacy {
    private static let numbers = try! NSRegularExpression(pattern: #"[+−-]?\d(?:[\d\s\u00A0\u202F.,]*\d)?"#)
    private static let dates = try! NSRegularExpression(pattern: #"\b\d{4}-\d{2}-\d{2}\b"#)
    public static func mask(_ value: String) -> String {
        let original = value as NSString
        let fullRange = NSRange(location: 0, length: original.length)
        let dateRanges = dates.matches(in: value, range: fullRange).map(\.range)
        let masked = NSMutableString(string: value)
        for match in numbers.matches(in: value, range: fullRange).reversed() {
            let end = NSMaxRange(match.range)
            if end < original.length, original.substring(from: end).trimmingCharacters(in: .whitespaces).hasPrefix("%") { continue }
            if dateRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
            masked.replaceCharacters(in: match.range, with: "•••")
        }
        return masked as String
    }
}
