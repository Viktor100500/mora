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
}
