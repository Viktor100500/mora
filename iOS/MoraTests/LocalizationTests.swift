import XCTest
import FinanceCore
@testable import MoraiOS

/// Every Russian literal in the iPhone sources must have an English translation,
/// either shared with the Mac (`en.json`) or iPhone-only (`MobileStrings.json`).
final class LocalizationTests: XCTestCase {
    private var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Mora")
    }
    /// Names shown in their own language on purpose.
    private let untranslated: Set<String> = ["Русский"]

    override func setUp() { L10n.override = .english }
    override func tearDown() { L10n.override = nil }

    func testMobileTranslationsLoad() {
        XCTAssertEqual(L("Операции"), "Transactions")
        XCTAssertEqual(L("Ещё"), "More")
        XCTAssertEqual(L("Данные хранятся на этом iPhone"), "Data is stored on this iPhone")
        XCTAssertEqual(L("Дублировано операций: 3"), "Duplicated transactions: 3")
    }

    func testEveryRussianLiteralIsTranslated() throws {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "Sources are readable from the simulator")
        var missing = Set<String>()
        for file in files {
            for literal in Self.literals(in: try String(contentsOf: file, encoding: .utf8)) where Self.isRussian(literal) && !untranslated.contains(literal) {
                if Self.isRussian(L(literal)) { missing.insert("\(file.lastPathComponent): \(literal)") }
            }
        }
        XCTAssertTrue(missing.isEmpty, "Missing English translations:\n" + missing.sorted().joined(separator: "\n"))
    }

    private static func isRussian(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    /// Swift string literals with each interpolation replaced by a sample value.
    /// Literals nested inside interpolations are returned separately.
    static func literals(in source: String) -> [String] {
        let characters = Array(source)
        var result: [String] = []
        var index = 0
        func parseString() -> String {
            // `index` is just past the opening quote.
            var value = ""
            while index < characters.count {
                let c = characters[index]
                if c == "\"" { index += 1; return value }
                if c == "\\", index + 1 < characters.count {
                    let next = characters[index + 1]
                    if next == "(" {
                        index += 2
                        var depth = 1
                        while index < characters.count && depth > 0 {
                            let inner = characters[index]
                            if inner == "\"" { index += 1; result.append(parseString()); continue }
                            if inner == "(" { depth += 1 } else if inner == ")" { depth -= 1 }
                            index += 1
                        }
                        value += "7"
                        continue
                    }
                    value.append(next == "n" ? "\n" : next)
                    index += 2
                    continue
                }
                value.append(c); index += 1
            }
            return value
        }
        while index < characters.count {
            let c = characters[index]
            if c == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                while index < characters.count && characters[index] != "\n" { index += 1 }
                continue
            }
            if c == "\"" {
                if index + 2 < characters.count, characters[index + 1] == "\"", characters[index + 2] == "\"" {
                    index += 3
                    while index + 2 < characters.count && !(characters[index] == "\"" && characters[index + 1] == "\"" && characters[index + 2] == "\"") { index += 1 }
                    index += 3
                    continue
                }
                index += 1
                result.append(parseString())
                continue
            }
            index += 1
        }
        return result
    }

    func testLiteralScannerHandlesNestedInterpolation() {
        let source = #"Text(L("Код \(code) · \(enabled ? L("включена") : L("пауза"))")) // L("комментарий")"#
        XCTAssertEqual(Self.literals(in: source), ["включена", "пауза", "Код 7 · 7"])
    }
}
