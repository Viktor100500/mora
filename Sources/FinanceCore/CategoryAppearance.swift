import Foundation

/// Emoji and RGB colors fit the existing string fields, including backups and sync.
public enum CategoryAppearance {
    public static func isEmoji(_ value: String) -> Bool {
        guard value.count == 1, let first = value.unicodeScalars.first else { return false }
        let scalars = value.unicodeScalars
        // Digits, # and * have the Emoji property only as part of a keycap.
        if scalars.contains(where: { $0.value == 0x20E3 }) {
            return "0123456789#*".unicodeScalars.contains(first)
        }
        guard first.properties.isEmoji, !first.properties.isEmojiModifier,
              !(0x30...0x39).contains(first.value), first.value != 0x23, first.value != 0x2A else { return false }
        if (0x1F1E6...0x1F1FF).contains(first.value) {
            return scalars.count == 2 && scalars.allSatisfy { (0x1F1E6...0x1F1FF).contains($0.value) }
        }
        return scalars.allSatisfy {
            $0.properties.isEmoji || $0.value == 0xFE0F || $0.value == 0x200D || (0xE0020...0xE007F).contains($0.value)
        }
    }

    public static func rgb(_ value: String) -> (red: Double, green: Double, blue: Double)? {
        guard value.count == 7, value.first == "#",
              value.dropFirst().unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value) }),
              let rgb = UInt32(value.dropFirst(), radix: 16) else { return nil }
        return (Double((rgb >> 16) & 255) / 255, Double((rgb >> 8) & 255) / 255, Double(rgb & 255) / 255)
    }

    public static func hex(red: Double, green: Double, blue: Double) -> String {
        func channel(_ value: Double) -> Int { Int((min(max(value.isFinite ? value : 0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(red), channel(green), channel(blue))
    }
}
