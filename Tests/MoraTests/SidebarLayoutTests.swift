import XCTest
@testable import Mora
import FinanceCore
import AppKit

@MainActor
final class SidebarLayoutTests: XCTestCase {
    private let titles = ["Обзор", "Операции", "Счета", "Регулярные платежи", "Аналитика", "Категории и правила", "История импортов", "Настройки"]

    /// The amount must fit into the card at every width the sidebar allows.
    private func assertFits(_ amount: String, file: StaticString = #filePath, line: UInt = #line) {
        let limits = SidebarLayout.limits(netWorth: amount, navigationTitles: titles)
        XCTAssertLessThanOrEqual(limits.minimum, limits.ideal, file: file, line: line)
        XCTAssertLessThanOrEqual(limits.ideal, limits.maximum, file: file, line: line)
        for width in [limits.minimum, limits.ideal, limits.maximum] {
            let size = SidebarLayout.netWorthFontSize(for: amount, sidebarWidth: width)
            XCTAssertGreaterThanOrEqual(size, SidebarLayout.netWorthFontSize * SidebarLayout.netWorthMinimumScale - 0.5, file: file, line: line)
            let measured = max(SidebarLayout.textWidth(amount, font: SidebarLayout.netWorthFont(size: size)),
                               SidebarLayout.textWidth(FinancialPrivacy.mask(amount), font: SidebarLayout.netWorthFont(size: size)))
            XCTAssertLessThanOrEqual(measured, width - SidebarLayout.netWorthHorizontalInset, "\(amount) at \(width)", file: file, line: line)
        }
    }

    func testLongAmountsFitWithoutTruncation() {
        for amount in ["2 405 791,68 ₽", "12 345 678,90 ₽", "98 765 432,10 ₽", "$12,345,678.90", "€98,765,432.10", "CHF 98’765’432.10", "1 234 567 890,12 ₽"] {
            assertFits(amount)
        }
    }

    func testShortAmountKeepsFullSizeAtIdealWidth() {
        let limits = SidebarLayout.limits(netWorth: "12 000 ₽", navigationTitles: titles)
        XCTAssertEqual(SidebarLayout.netWorthFontSize(for: "12 000 ₽", sidebarWidth: limits.ideal), SidebarLayout.netWorthFontSize)
    }

    func testMinimumWidthGrowsForAmountsThatDoNotFitAtSmallestSize() {
        let normal = SidebarLayout.limits(netWorth: "12 345 678,90 ₽", navigationTitles: titles)
        let huge = SidebarLayout.limits(netWorth: "123 456 789 012 345 678,90 ₽", navigationTitles: titles)
        XCTAssertEqual(normal.minimum, SidebarLayout.preferredMinimumWidth)
        XCTAssertGreaterThan(huge.minimum, normal.minimum)
        XCTAssertGreaterThanOrEqual(huge.maximum, huge.minimum)
        assertFits("123 456 789 012 345 678,90 ₽")
    }

    func testMinimumWidthKeepsNavigationTitlesOnOneLine() {
        let limits = SidebarLayout.limits(netWorth: "0 ₽", navigationTitles: titles)
        let font = NSFont.systemFont(ofSize: SidebarLayout.navigationFontSize, weight: .semibold)
        for title in titles {
            XCTAssertLessThanOrEqual(SidebarLayout.textWidth(title, font: font) + SidebarLayout.navigationRowInset, limits.minimum, title)
        }
        XCTAssertLessThan(limits.minimum, limits.maximum)
    }
}
