import XCTest
@testable import FinanceCore

final class MerchantPlacesTests: XCTestCase {
    func testDatasetTypesProcessorPrefixesAndAddressVariants() throws {
        let catalog = try MerchantPlaces(data: Data(#"{"schemaVersion":1,"region":"Test region","release":"test","places":[{"name":"Example Grocery Market","group":"groceries"},{"name":"Exampleburger","group":"dining"},{"name":"Example Cake","group":"dining"},{"name":"Otherbrandcake","group":"dining"},{"name":"Test Street Burger","group":"dining"}]}"#.utf8))
        XCTAssertEqual(catalog.group(for: "POS TST* Test Street Burger- W"), .dining)
        XCTAssertEqual(catalog.group(for: "Example Grocery 123 Main Street"), .groceries)
        XCTAssertEqual(catalog.group(for: "Example Burger"), .dining)
        XCTAssertEqual(catalog.group(for: "Example"), .dining)
        XCTAssertEqual(catalog.group(for: "Otherbrand"), .dining)
        XCTAssertNil(catalog.group(for: "Otherbrand Medical Center"))
        XCTAssertNil(catalog.group(for: "Example Medical Center"))
        XCTAssertNil(catalog.group(for: "Other Example Grocery Market"))
        XCTAssertNil(catalog.group(for: "Superexampleburgerology"))
    }
    func testConflictingAndUnknownTypesNeverFallBackToAShorterName() throws {
        let catalog = try MerchantPlaces(data: Data(#"{"schemaVersion":1,"region":"Test region","release":"test","places":[{"name":"Example Place","group":"dining"},{"name":"Example Place","group":"shopping"},{"name":"Unknown Types","group":null},{"name":"Unknown Types","group":"shopping"},{"name":"Example","group":"groceries"}]}"#.utf8))
        XCTAssertNil(catalog.group(for: "Example Place"))
        XCTAssertNil(catalog.group(for: "Example Place 42"))
        XCTAssertNil(catalog.group(for: "Unknown Types"))
    }
    func testIncompleteOrUnsupportedExtractIsRejected() {
        for fixture in [#"{"schemaVersion":2,"region":"test","release":"test","places":[]}"#,
                        #"{"schemaVersion":1,"region":"test","release":"test","places":[]}"#,
                        "<html>Unavailable</html>"] {
            XCTAssertThrowsError(try MerchantPlaces(data: Data(fixture.utf8)))
        }
    }
    func testShortenedNamesAcceptOnlyRecognizedLocationTails() throws {
        let catalog = try MerchantPlaces(data: Data(#"{"schemaVersion":1,"region":"Test region","release":"test","places":[{"name":"DÄN BAKERY & CAFÉ","group":"dining"},{"name":"Example Cake","group":"dining"},{"name":"Dan Bakery Brooklyn","group":"shopping"},{"name":"Dan Bakery Queens","group":null}]}"#.utf8))
        for name in ["Dan Bakery", "SQ * Dan Bakery Hoboken", "POS Dan Bakery Jersey City NJ USA",
                     "Dan Bakery New York NY"] {
            XCTAssertEqual(catalog.group(for: name), .dining, name)
        }
        XCTAssertEqual(catalog.group(for: "Dan Bakery Brooklyn"), .shopping)
        XCTAssertNil(catalog.group(for: "Dan Bakery Queens"))
        for name in ["Dan Bakery Medical Center", "Dan Bakery Unknownville", "Dan Bakery Hoboken Medical Center",
                     "Other Dan Bakery Hoboken", "Example Hoboken"] {
            XCTAssertNil(catalog.group(for: name), name)
        }
        let conflicting = try MerchantPlaces(data: Data(#"{"schemaVersion":1,"region":"Test region","release":"test","places":[{"name":"Dan Bakery Cafe","group":"dining"},{"name":"Dan Bakery","group":"shopping"}]}"#.utf8))
        XCTAssertNil(conflicting.group(for: "SQ * Dan Bakery Hoboken"))
    }
    func testBundledPublicDatasetLoadsAndCoversRegionalMerchantTypes() {
        let catalog = MerchantPlaces.bundled
        XCTAssertGreaterThan(catalog.placeCount, 100_000)
        XCTAssertEqual(catalog.group(for: "Laghman Express"), .dining)
        XCTAssertEqual(catalog.group(for: "TST* 7th Street Burger- W"), .dining)
        XCTAssertEqual(catalog.group(for: "Net Cost 3100 Ocean Ave"), .groceries)
        XCTAssertEqual(catalog.group(for: "Wildberry"), .dining)
        XCTAssertEqual(catalog.group(for: "Chapel Deli"), .groceries)
        XCTAssertEqual(catalog.group(for: "SQ * Dan Bakery Hoboken"), .dining)
        XCTAssertEqual(catalog.group(for: "SQ * Thisbowl Noho"), .dining)
        XCTAssertEqual(catalog.group(for: "The Wild-New"), .shopping)
        XCTAssertNil(catalog.group(for: "THISBOWL Medical Center"))
        XCTAssertNil(catalog.group(for: "Wildberry Medical Center"))
        XCTAssertEqual(MerchantCatalog.bundled.group(for: "Theperkhouse"), .dining)
        XCTAssertNil(MerchantCatalog.bundled.group(for: "Theperkhouse Medical Center"))
    }
}
