import XCTest
@testable import FinanceCore

final class OpenMerchantCatalogTests: XCTestCase {
    func testPackagedAliasesLoadWithoutTheDeveloperBuildDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraCatalogResources-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("Mora_FinanceCore.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.mora.catalog", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
        try Data(#"[{"alias":"Packaged Merchant","group":"groceries"}]"#.utf8).write(to: bundle.appendingPathComponent("MerchantAliases.json"))
        XCTAssertEqual(MerchantCatalog(applicationResourcesURL: directory).group(for: "Packaged Merchant"), .groceries)
    }
    func testNSIBrandClassificationAndStoreSuffix() throws {
        var catalog = MerchantCatalog()
        try catalog.addNSI(Data(#"{"nsi":{"brands/shop/department_store":{"items":[{"tags":{"brand":"Muji","name":"MUJI","shop":"department_store"}}]}}}"#.utf8))
        XCTAssertEqual(catalog.group(for: "Muji - Chelsea Market"), .shopping)
        XCTAssertEqual(catalog.group(for: "SQ *MUJI #1024"), .shopping)
        XCTAssertNil(catalog.group(for: "Supermujiology"))
        XCTAssertEqual(catalog.group(for: "Siren47906"), .dining)
        XCTAssertNil(catalog.group(for: "Siren99999"))
        XCTAssertNil(catalog.group(for: "La Sirena"))
    }
    func testConflictsNegativeAliasesAndConfidenceDoNotGuess() throws {
        var catalog = MerchantCatalog()
        try catalog.addMerchantStudio(Data(#"{"merchants":[{"canonicalName":"Acme","aliases":["acme"],"negativeAliases":["acme cloud"],"category":"shopping","defaultConfidence":0.92},{"canonicalName":"Uncertain","aliases":[],"category":"groceries","defaultConfidence":0.5}]}"#.utf8))
        XCTAssertEqual(catalog.group(for: "Acme #102"), .shopping)
        catalog.add("Acme", group: .shopping)
        XCTAssertNil(catalog.group(for: "Acme Cloud"))
        XCTAssertNil(catalog.group(for: "Uncertain"))
        catalog.add("Acme", group: .dining)
        XCTAssertNil(catalog.group(for: "Acme"))
        XCTAssertNil(catalog.group(for: "Acme Store"))
        XCTAssertNil(catalog.group(for: " "))
    }
    func testMappingUsesExistingExpenseCategoryAndNeverCreatesOne() {
        var ledger = Ledger.empty
        XCTAssertEqual(MerchantGroup.dining.category(in: ledger), ledger.categories.first { $0.name == "Кафе и рестораны" }?.id)
        ledger.categories = [Category(name: "Shopping", kind: .income)]
        XCTAssertNil(MerchantGroup.shopping.category(in: ledger))
        XCTAssertNil(ledger.historicalCategory(merchant: "Starbucks", kind: .expense))
    }
    func testTransitNetworkAndOperatorNamesDoNotBecomeArbitraryPrefixes() throws {
        var catalog = MerchantCatalog()
        try catalog.addNSI(Data(#"{"nsi":{"transit/route/subway":{"items":[{"tags":{"network":"PATH","operator":"Example Metropolitan Transit Authority","route":"subway","owner":"Example City"}}]},"operators/route/bus":{"items":[{"tags":{"network":"Example Bus","operator":"Example Bus Company","route":"bus"}}]},"operators/office/company":{"items":[{"tags":{"operator":"Unrelated Company"}}]}}}"#.utf8))
        XCTAssertEqual(catalog.group(for: "Example Metropolitan Transit Authority"), .transport)
        XCTAssertEqual(catalog.group(for: "POS *Example Bus Company 123"), .transport)
        XCTAssertEqual(catalog.group(for: "PATH"), .transport)
        XCTAssertEqual(catalog.group(for: "Path Tapp Paygo Cp"), .transport)
        XCTAssertNil(catalog.group(for: "PATH Mental Health"))
        XCTAssertNil(catalog.group(for: "Example City"))
        XCTAssertNil(catalog.group(for: "Unrelated Company"))
    }
    func testNestedProcessorPrefixesAndConflictingTransitBrand() throws {
        var catalog = MerchantCatalog()
        catalog.add("Example Restaurant", group: .dining)
        XCTAssertEqual(catalog.group(for: "CARD PURCHASE POS TST* Example Restaurant #12"), .dining)
        try catalog.addNSI(Data(#"{"nsi":{"brands/shop/supermarket":{"items":[{"tags":{"name":"Metro","shop":"supermarket"}}]},"transit/route/subway":{"items":[{"tags":{"network":"Metro","route":"subway"}}]}}}"#.utf8))
        XCTAssertNil(catalog.group(for: "Metro"))
    }
}
