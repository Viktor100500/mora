import XCTest
@testable import FinanceCore

final class CategoryAppearanceTests: XCTestCase {
    func testEmojiSequencesAndLegacySymbols() {
        for emoji in ["🏛️", "📱", "☎", "❤️", "👨‍👩‍👧‍👦", "👩🏽‍💻", "🇷🇸", "1️⃣", "#️⃣", "🏳️‍🌈", "🏷️"] {
            XCTAssertTrue(CategoryAppearance.isEmoji(emoji), emoji)
        }
        for value in ["", "tag", "phone", "building.columns", "1", "#", "*", "a", "🏛️📱", "🏽", "🇷", "😀\u{0301}"] {
            XCTAssertFalse(CategoryAppearance.isEmoji(value), value)
        }
    }

    func testCustomColorEncodingAndInvalidValues() throws {
        let hex = CategoryAppearance.hex(red: 0.1, green: 0.5, blue: 1)
        XCTAssertEqual(hex, "#1A80FF")
        let rgb = try XCTUnwrap(CategoryAppearance.rgb(hex.lowercased()))
        XCTAssertEqual(rgb.red, 26.0 / 255)
        XCTAssertEqual(rgb.green, 128.0 / 255)
        XCTAssertEqual(rgb.blue, 1)
        XCTAssertEqual(CategoryAppearance.hex(red: -1, green: 2, blue: .nan), "#00FF00")
        for value in ["green", "#FFF", "FFFFFF", "#GGGGGG", "#-12345", "#1234567"] {
            XCTAssertNil(CategoryAppearance.rgb(value), value)
        }
    }

    func testEmojiAndCustomColorSurviveLedgerBackupAndHistory() throws {
        var ledger = Ledger()
        let category = Category(name: "Связь", icon: "👩🏽‍💻", color: "#1A80FF")
        ledger.categories.append(category)
        let restored = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored.categories.first, category)
        XCTAssertEqual(restored.categories.first?.icon.count, 1)
        var changed = restored
        changed.categories[0].icon = "🏛️"
        changed.categories[0].color = "teal"
        changed.recordChange(from: restored)
        try changed.undoLastChange()
        XCTAssertEqual(changed.categories.first, category)
        try changed.redoLastChange()
        XCTAssertEqual(changed.categories.first?.icon, "🏛️")
    }
}
