import XCTest
@testable import FinanceCore

private final class CloudStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class CloudAPITests: XCTestCase {
    private func api() throws -> CloudAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CloudStubProtocol.self]
        return CloudAPI(configuration: try CloudConfiguration(projectURL: URL(string: "https://test-mora.supabase.co")!, publicKey: "sb_publishable_test"), transport: URLSession(configuration: config))
    }
    override func tearDown() { CloudStubProtocol.handler = nil; super.tearDown() }
    func testPasswordAndRefreshEndpointsAndSessionExpiry() async throws {
        let user = UUID()
        var requests = 0
        CloudStubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/auth/v1/token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.url?.query, requests == 0 ? "grant_type=password" : "grant_type=refresh_token")
            requests += 1
            return (200, Data("{\"access_token\":\"test-access\",\"refresh_token\":\"test-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(user)\",\"email\":\"test@example.test\"}}".utf8))
        }
        let api = try api()
        let session = try await api.signIn(email: "test@example.test", password: "test-only-password")
        XCTAssertEqual(session.user.id, user)
        XCTAssertGreaterThan(session.expires_at, Date().timeIntervalSince1970 + 3500)
        let refresh = try await api.refresh(session.refresh_token)
        XCTAssertEqual(refresh.refresh_token, "test-refresh")
        XCTAssertEqual(requests, 2)
        let stored = try JSONDecoder().decode(CloudSession.self, from: JSONEncoder().encode(refresh))
        XCTAssertEqual(stored.expires_at, refresh.expires_at)
    }
    func testRPCIncludesUserAuthenticationAndPreservesDatabaseDecimalPrecision() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let snapshot = try String(contentsOf: root.appendingPathComponent("cloud/tests/fixtures/backend-ledger.json"), encoding: .utf8)
        let id = UUID()
        CloudStubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/mora_get_household")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-access")
            return (200, Data("{\"household_id\":\"\(id)\",\"name\":\"Test\",\"version\":8,\"snapshot\":\(snapshot)}".utf8))
        }
        let envelope: CloudEnvelope = try await api().rpc("mora_get_household", ["p_household_id": id], accessToken: "user-access")
        XCTAssertEqual(envelope.household_id, id)
        XCTAssertEqual(envelope.version, 8)
        XCTAssertEqual(envelope.snapshot.transactions.first(where: { $0.amount < -1000 })?.amount, Decimal(string: "-123456789012.123456"))
        try envelope.snapshot.validate()
    }
    func testUnauthorizedResponseDoesNotDecodeAsData() async throws {
        CloudStubProtocol.handler = { _ in (401, Data("{\"message\":\"Expired JWT\"}".utf8)) }
        do {
            let _: Bool = try await api().rpc("mora_save_household", ["p_version": 1], accessToken: "expired-test-access")
            XCTFail("Expected unauthorized")
        } catch CloudAPIError.unauthorized { }
    }
}
