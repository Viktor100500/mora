import XCTest
@testable import FinanceCore

final class WalletShortcutTemplateTests: XCTestCase {
    func testPublicTemplateConfiguresOneKeyAndEndpointWithoutDroppingCardOrGuards() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let template = try Data(contentsOf: root.appendingPathComponent("Resources/WalletSender.plist"))
        let configuration = try CloudConfiguration(projectURL: URL(string: "https://test-project.supabase.co")!, publicKey: "sb_publishable_test")
        let key = String(repeating: "a", count: 64)
        let data = try WalletShortcutTemplate.configured(template, configuration: configuration, phoneToken: key)
        let workflow = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let actions = try XCTUnwrap(workflow["WFWorkflowActions"] as? [[String: Any]])
        let parameters = actions.compactMap { $0["WFWorkflowActionParameters"] as? [String: Any] }
        XCTAssertEqual(parameters.filter { $0["WFTextActionText"] as? String == key }.count, 1)
        let request = try XCTUnwrap(parameters.first { $0["WFHTTPMethod"] as? String == "POST" })
        XCTAssertEqual(request["WFURL"] as? String, "https://test-project.supabase.co/rest/v1/rpc/mora_capture_payment")
        let output = String(describing: request)
        XCTAssertTrue(output.contains("p_card")); XCTAssertTrue(output.contains("sb_publishable_test"))
        XCTAssertFalse(String(describing: workflow).contains("sb_publishable_example"))
        XCTAssertFalse(actions.contains { $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.notification" })
        XCTAssertThrowsError(try WalletShortcutTemplate.configured(template, configuration: configuration, phoneToken: "invalid"))
    }
    func testRequiredCardNeverUsesThePhoneDefaultForAutomaticBooking() async throws {
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "Raiffeisen", currency: "USD")]
        let json: [String: Any] = ["id": UUID().uuidString, "merchant": "MTA", "amount": "$3.00", "currency": "USD",
            "account_id": ledger.accounts[0].id.uuidString, "date": "2026-11-01T22:25:00Z", "label": "iPhone", "card_required": true]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let capture = try decoder.decode(CloudCapture.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(capture.awaitsCardLink)
        let transaction = try await WalletReviewDraft.automaticTransaction(for: capture, in: ledger) { _, _, _, _ in
            XCTFail("Unidentified card must wait for review"); throw CancellationError()
        }
        XCTAssertNil(transaction)
    }
}
