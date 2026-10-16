import XCTest
@testable import FinanceCore

final class UILocalizationTests: XCTestCase {
    func testEnglishResourcesAndRussianRoundTrip() {
        let l = UILocalization.shared
        XCTAssertGreaterThan(l.translatedStringCount, 700)
        XCTAssertEqual(l.text("Операции", language: .english), "Transactions")
        XCTAssertEqual(l.text("История импортов", language: .english), "Import history")
        XCTAssertEqual(l.text("Настройки", language: .russian), "Настройки")
        XCTAssertEqual(l.text("Выбрано: 21", language: .english), "Selected: 21")
        XCTAssertEqual(l.text("Выбрано: 21", language: .russian), "Выбрано: 21")
    }
    func testInterpolatedTextPreservesValuesAndOrder() {
        XCTAssertEqual(UILocalization.shared.text("Добавлено: 7 из 10 · Исключено: 1 · Повторы: 2 · Ошибки: 0", language: .english), "Added: 7 of 10 · Excluded: 1 · Duplicates: 2 · Errors: 0")
        XCTAssertEqual(UILocalization.shared.text("Дата курсов: 12 октября 2026. Без интернета используются последние сохраненные значения.", language: .english), "Rate date: 12 октября 2026. The last saved rates are used offline.")
    }
    func testUnknownUserContentIsPreservedAndCacheIsThreadSafe() {
        let value = "Мой собственный магазин — Metropolitan Transportation Authority"
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            XCTAssertEqual(UILocalization.shared.text(value, language: .english), value)
            XCTAssertEqual(UILocalization.shared.text("Выбрано: 3", language: .english), "Selected: 3")
        }
        XCTAssertEqual(UILocalization.shared.text("Wholefoods Brooklyn #10220", language: .english), "Wholefoods Brooklyn #10220")
    }
}
