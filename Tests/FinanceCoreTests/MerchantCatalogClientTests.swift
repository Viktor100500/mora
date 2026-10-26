import XCTest
import os
@testable import FinanceCore

private final class CatalogStubProtocol: URLProtocol {
    private static let handlers = OSAllocatedUnfairLock<((URLRequest) throws -> (Int, Data))?>(uncheckedState: nil)
    static var handler: ((URLRequest) throws -> (Int, Data))? {
        get { handlers.withLockUnchecked { $0 } }
        set { handlers.withLockUnchecked { $0 = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handlers.withLockUnchecked { try $0!(request) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class MerchantCatalogClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_705_600)
    private let studio = Data(#"{"merchants":[{"canonicalName":"Example Grocery","aliases":[],"category":"groceries","defaultConfidence":0.99}]}"#.utf8)
    private let nsi = Data(#"{"nsi":{"brands/shop/clothes":{"items":[{"tags":{"brand":"Example Clothing","shop":"clothes"}}]}}}"#.utf8)
    private func client(directory: URL?) -> OpenMerchantCatalogClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogStubProtocol.self]
        return OpenMerchantCatalogClient(session: URLSession(configuration: configuration), cacheDirectory: directory)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoraCatalogCache-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    override func tearDown() { CatalogStubProtocol.handler = nil; super.tearDown() }
    private func successfulFeeds() {
        let studio = studio, nsi = nsi
        CatalogStubProtocol.handler = { request in
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.url?.query)
            XCTAssertTrue([OpenMerchantCatalogClient.studioURL, OpenMerchantCatalogClient.nsiURL].contains(request.url!))
            return (200, request.url == OpenMerchantCatalogClient.studioURL ? studio : nsi)
        }
    }
    func testValidFeedsSurviveRestartWithoutNetworkOrMerchantDisclosure() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        successfulFeeds()
        let initial = try await client(directory: directory).group(for: "Example Grocery #123", now: now)
        XCTAssertEqual(initial, .groceries)
        CatalogStubProtocol.handler = { _ in XCTFail("Fresh disk cache should avoid network"); throw URLError(.notConnectedToInternet) }
        let restarted = client(directory: directory)
        let grocery = try await restarted.group(for: "Example Grocery", now: now.addingTimeInterval(86400))
        let clothing = try await restarted.group(for: "Example Clothing", now: now.addingTimeInterval(86400))
        XCTAssertEqual(grocery, .groceries); XCTAssertEqual(clothing, .shopping)
    }
    func testOfflineAndMalformedRefreshKeepLastValidSources() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        successfulFeeds()
        _ = try await client(directory: directory).group(for: "Example Grocery", now: now)
        let previous = try Data(contentsOf: directory.appendingPathComponent("studio-v1.json"))
        CatalogStubProtocol.handler = { request in
            if request.url == OpenMerchantCatalogClient.studioURL { return (200, Data("<html>unavailable</html>".utf8)) }
            throw URLError(.notConnectedToInternet)
        }
        let restarted = client(directory: directory)
        let grocery = try await restarted.group(for: "Example Grocery", now: now.addingTimeInterval(8 * 86400))
        let clothing = try await restarted.group(for: "Example Clothing", now: now.addingTimeInterval(8 * 86400))
        XCTAssertEqual(grocery, .groceries); XCTAssertEqual(clothing, .shopping)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("studio-v1.json")), previous)
    }
    func testPartialOutageUsesTheHealthySource() async throws {
        let nsi = nsi
        CatalogStubProtocol.handler = { request in
            if request.url == OpenMerchantCatalogClient.studioURL { return (503, Data()) }
            return (200, nsi)
        }
        let group = try await client(directory: nil).group(for: "Example Clothing", now: now)
        XCTAssertEqual(group, .shopping)
    }
    func testBundledAliasesWorkWhenBothSourcesAreUnavailableAndUnknownsBackOff() async throws {
        var calls = 0
        CatalogStubProtocol.handler = { _ in calls += 1; throw URLError(.notConnectedToInternet) }
        let client = client(directory: nil)
        let local = try await client.group(for: "Siren47906", now: now)
        XCTAssertEqual(local, .dining); XCTAssertEqual(calls, 0)
        for name in ["Unknown Seller One", "Unknown Seller Two"] {
            do { _ = try await client.group(for: name, now: now); XCTFail("Unknown without usable sources should report the outage") }
            catch { }
        }
        XCTAssertEqual(calls, 2)
    }
    func testCorruptCacheDoesNotPreventAValidDownload() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        try Data("broken cache".utf8).write(to: directory.appendingPathComponent("studio-v1.json"))
        successfulFeeds()
        let result = try await client(directory: directory).group(for: "Example Grocery", now: now)
        XCTAssertEqual(result, .groceries)
    }
}
