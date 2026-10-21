import XCTest
@testable import FinanceCore

final class AmountInputTests: XCTestCase {
    func testTypingAndPastingKeepOnlyDecimalCharacters() {
        XCTAssertEqual(AmountInput.filtered("USD −1 234.56 €\n"), "1234.56")
        XCTAssertEqual(AmountInput.filtered("abc12,50xyz"), "12,50")
        XCTAssertEqual(AmountInput.filtered("١٢.٥"), ".")
    }
    func testBothSeparatorsMeanTheSameFractionAndNeverGrouping() {
        XCTAssertEqual(AmountInput.parse("12,50"), AmountInput.parse("12.50"))
        XCTAssertEqual(AmountInput.parse("1,234"), Decimal(string: "1.234"))
        XCTAssertEqual(AmountInput.parse(".5"), Decimal(string: "0.5"))
        for input in ["1,234.56", "1.2.3", "1,,2", "", ".", "1e3", "-12", "12 USD"] {
            XCTAssertNil(AmountInput.parse(input), input)
        }
    }
}
