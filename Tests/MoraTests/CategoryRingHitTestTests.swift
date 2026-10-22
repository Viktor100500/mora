import XCTest
@testable import Mora

final class CategoryRingHitTestTests: XCTestCase {
    func testTooltipStaysOutsideCircleEvenWhenPlotIsWiderThanRing() {
        for frame in [CGRect(x: 40, y: 20, width: 300, height: 180), CGRect(x: 40, y: 20, width: 180, height: 180)] {
            let center = CategoryRingHitTest.tooltipCenter(in: frame, width: 210)
            let ringLeft = frame.midX - min(frame.width, frame.height) / 2
            XCTAssertEqual(center.x + 105, ringLeft - 12)
            XCTAssertEqual(center.y, frame.midY)
        }
    }

    func testSectorHoverUsesClockwiseAnglesStartingAtTop() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        XCTAssertEqual(CategoryRingHitTest.index(at: CGPoint(x: 190, y: 100), in: frame, amounts: [50, 25, 25]), 0)
        XCTAssertEqual(CategoryRingHitTest.index(at: CGPoint(x: 36, y: 164), in: frame, amounts: [50, 25, 25]), 1)
        XCTAssertEqual(CategoryRingHitTest.index(at: CGPoint(x: 36, y: 36), in: frame, amounts: [50, 25, 25]), 2)
    }

    func testHoleOutsideCircleAndEmptyDataDoNotShowATooltip() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        XCTAssertNil(CategoryRingHitTest.index(at: CGPoint(x: 100, y: 100), in: frame, amounts: [100]))
        XCTAssertNil(CategoryRingHitTest.index(at: CGPoint(x: 201, y: 100), in: frame, amounts: [100]))
        XCTAssertNil(CategoryRingHitTest.index(at: CGPoint(x: 190, y: 100), in: frame, amounts: []))
        XCTAssertNil(CategoryRingHitTest.index(at: CGPoint(x: 190, y: 100), in: frame, amounts: [0]))
    }
}
