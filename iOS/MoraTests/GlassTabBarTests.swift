import XCTest
import UIKit
@testable import MoraiOS

@available(iOS 26, *)
@MainActor
final class GlassTabBarTests: XCTestCase {
    private let symbols = ["square.grid.2x2", "arrow.left.arrow.right", "chart.xyaxis.line", "wallet.bifold", "ellipsis.circle"]
    private let english = ["Overview", "Transactions", "Analytics", "Accounts", "More"]
    private let russian = ["Обзор", "Операции", "Аналитика", "Счета", "Ещё"]

    func testAllTitlesAndIconsShareOneScaleAcrossWidthsAndLanguages() throws {
        for titles in [english, russian] {
            let bar = makeBar(titles: titles)
            for width: CGFloat in [320, 375, 393, 430, 768] {
                bar.frame.size.width = width
                bar.layoutIfNeeded()
                let labels = titleLabels(in: bar, titles: titles)
                XCTAssertGreaterThanOrEqual(labels.count, titles.count)
                let fontSize = try XCTUnwrap(labels.first?.font.pointSize)
                for label in labels {
                    XCTAssertEqual(label.font.pointSize, fontSize, accuracy: 0.001)
                    XCTAssertFalse(label.adjustsFontSizeToFitWidth)
                    let textWidth = (label.text ?? "").size(withAttributes: [.font: label.font!]).width
                    XCTAssertLessThanOrEqual(textWidth, label.bounds.width + 0.01)
                    // Include magnification, not just the resting state.
                    XCTAssertLessThanOrEqual(textWidth * 1.15, (label.superview?.bounds.width ?? 0) - 4 + 0.01)
                    let index = try XCTUnwrap(titles.firstIndex(of: label.text ?? ""))
                    let icon = try XCTUnwrap(label.superview?.subviews.compactMap { $0 as? UIImageView }.first)
                    let config = UIImage.SymbolConfiguration(pointSize: 19 * fontSize / 10, weight: .medium)
                    let expected = UIImage(systemName: symbols[index] + ".fill", withConfiguration: config)
                        ?? UIImage(systemName: symbols[index], withConfiguration: config)
                    XCTAssertEqual(icon.image?.size, expected?.size)
                }
                print("Tab bar: \(width) pt, \(titles[1]), common font \(fontSize) pt")
                if [375, 393, 430].contains(width) {
                    bar.backgroundColor = .systemBackground
                    let image = UIGraphicsImageRenderer(bounds: bar.bounds).image { bar.layer.render(in: $0.cgContext) }
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "tab-bar-\(titles == english ? "en" : "ru")-\(Int(width))"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    func testSizingUpdatesForLanguageAndWidthChangesWithoutChangingSelectionGeometry() throws {
        let bar = makeBar(titles: english)
        let narrowFont = try XCTUnwrap(titleLabels(in: bar, titles: english).first?.font.pointSize)
        for index in symbols.indices {
            bar.setSelectedIndex(index, animated: false)
            bar.layoutIfNeeded()
            XCTAssertTrue(titleLabels(in: bar, titles: english).allSatisfy { abs($0.font.pointSize - narrowFont) < 0.001 })
        }
        bar.frame.size.width = 768
        bar.layoutIfNeeded()
        XCTAssertTrue(titleLabels(in: bar, titles: english).allSatisfy { $0.font.pointSize == 10 })
        bar.frame.size.width = 375
        bar.setTitles(russian)
        bar.layoutIfNeeded()
        let russianFont = try XCTUnwrap(titleLabels(in: bar, titles: russian).first?.font.pointSize)
        XCTAssertGreaterThan(russianFont, narrowFont)
        XCTAssertTrue(titleLabels(in: bar, titles: russian).allSatisfy { abs($0.font.pointSize - russianFont) < 0.001 })
        bar.setTitles(english)
        bar.layoutIfNeeded()
        XCTAssertEqual(try XCTUnwrap(titleLabels(in: bar, titles: english).first?.font.pointSize), narrowFont, accuracy: 0.001)
    }

    func testLiftedLensKeepsClearOfNeighbourTitles() throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        for titles in [english, russian] {
            for width: CGFloat in [320, 375, 393, 430, 768] {
                let bar = makeBar(titles: titles, width: width)
                let lens = try XCTUnwrap(descendants(of: bar).first { String(describing: type(of: $0)).contains("LiquidLens") })
                for index in symbols.indices {
                    bar.setSelectedIndex(index, animated: false)
                    bar.setLensLifted(true)
                    let lensFrame = lens.convert(lens.bounds, to: bar)
                    for label in titleLabels(in: bar, titles: titles) where label.text != titles[index] && label.superview?.transform.isIdentity == true {
                        let textSize = (label.text ?? "").size(withAttributes: [.font: label.font!])
                        let frame = label.convert(CGRect(x: (label.bounds.width - textSize.width) / 2, y: 0, width: textSize.width, height: label.bounds.height), to: bar)
                        XCTAssertFalse(lensFrame.intersects(frame), "\(titles[index]) lens touches \(label.text ?? "") at \(width) pt")
                    }
                    bar.setLensLifted(false)
                }
            }
        }
    }

    private func makeBar(titles: [String], width: CGFloat = 375) -> GlassTabBar {
        let bar = GlassTabBar(symbols: symbols)
        bar.setTitles(titles)
        bar.frame = CGRect(x: 0, y: 0, width: width, height: GlassTabBar.height)
        bar.layoutIfNeeded()
        return bar
    }

    private func titleLabels(in bar: UIView, titles: [String]) -> [UILabel] {
        descendants(of: bar).compactMap { $0 as? UILabel }.filter { titles.contains($0.text ?? "") }
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
