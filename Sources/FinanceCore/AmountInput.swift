import Foundation

/// Manual entry is a decimal amount, never a localized number with grouping.
/// Keep malformed separator sequences visible and reject them on save rather
/// than silently changing the value of a pasted amount.
public enum AmountInput {
    public static func filtered(_ text: String) -> String {
        String(text.filter { ("0"..."9").contains($0) || $0 == "." || $0 == "," }.prefix(64))
    }

    public static func parse(_ text: String) -> Decimal? {
        guard !text.isEmpty, text.count <= 64, text == filtered(text),
              text.filter({ $0 == "." || $0 == "," }).count <= 1,
              text.contains(where: { ("0"..."9").contains($0) }),
              let value = Decimal(string: text.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN else { return nil }
        return value
    }
}
