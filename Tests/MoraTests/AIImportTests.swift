import XCTest
import FinanceCore
@testable import Mora

final class AIImportTests: XCTestCase {
    func testChatGPTDeepLinkOpensNativeComposerAndPreservesEditablePrompt() throws {
        let prompt = "My request: 1 & 3 + fee? #literal %value\nСчет [запрос]"
        let chat = try XCTUnwrap(AIAgent.chatgpt.chatURL(prompt: prompt))
        XCTAssertEqual(chat.scheme, "codex")
        XCTAssertEqual(chat.host, "new")
        XCTAssertEqual(URLComponents(url: chat, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "prompt", value: prompt)])
        XCTAssertEqual(AIAgent.chatgpt.bundleIdentifier, "com.openai.codex")
        let claude = try XCTUnwrap(AIAgent.claude.chatURL(prompt: prompt))
        XCTAssertEqual(claude.scheme, "claude")
        XCTAssertEqual(URLComponents(url: claude, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, prompt)
        XCTAssertNil(AIAgent.claude.chatURL(prompt: String(repeating: "x", count: 14_001)))
    }

    func testTemporaryCodexPreferenceMigratesBackToChatGPT() throws {
        var saved = Preferences(); saved.aiAgent = "codex"
        let preferences = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(preferences.aiAgent, "chatgpt")
        XCTAssertEqual(Preferences().aiAgent, "chatgpt")
    }

    private func resources() throws -> (URL, Bundle) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoraPrompts-\(UUID()).bundle")
        let prompts = directory.appendingPathComponent("Contents/Resources/Prompts")
        try FileManager.default.createDirectory(at: prompts, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.mora.prompts", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("Contents/Info.plist"))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["mora-mcp", "mora-csv"] {
            try FileManager.default.copyItem(at: root.appendingPathComponent("Prompts/\(name).md"), to: prompts.appendingPathComponent("\(name).md"))
        }
        return (directory, try XCTUnwrap(Bundle(url: directory)))
    }

    func testPromptContainsNativeTransportAndEndsWithUserRequestWithoutDuplicateInstructions() throws {
        let (directory, bundle) = try resources(); defer { try? FileManager.default.removeItem(at: directory) }
        var ledger = try Ledger.personal(baseCurrency: "USD")
        ledger.accounts = [Account(name: "Test \"card\" $(literal)", currency: "USD")]
        let bridge = directory.appendingPathComponent("Bridge ' $(literal)")
        try Data().write(to: bridge)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
        let prompt = try AIPrompt.text("mora-mcp", ledger: ledger, includeContext: true,
                                       bundle: bundle, bridgeURL: bridge, dataDirectory: directory)
        XCTAssertLessThan(prompt.count, 9_000)
        XCTAssertTrue(prompt.contains(MoraAutomation.csvHeader))
        XCTAssertFalse(prompt.contains("# Mora: подготовка CSV из чата"))
        XCTAssertTrue(prompt.components(separatedBy: "\n\n").last?.hasPrefix("Мой запрос:\n[") == true)
        let transportLine = try XCTUnwrap(prompt.components(separatedBy: "\n").first { $0.hasPrefix("{\"arguments\"") })
        let transport = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(transportLine.utf8)) as? [String: Any])
        XCTAssertEqual(transport["executable"] as? String, bridge.path)
        XCTAssertEqual(transport["arguments"] as? [String], ["--data-dir", directory.path])
    }

    func testSnapshotDoesNotChooseAccountAndExcludesArchivedAccounts() throws {
        let (directory, bundle) = try resources(); defer { try? FileManager.default.removeItem(at: directory) }
        var ledger = Ledger.empty
        var account = Account(name: "Only account", currency: "USD")
        ledger.accounts = [account]
        let prompt = try AIPrompt.text("mora-csv", ledger: ledger, includeContext: true, bundle: bundle)
        XCTAssertFalse(prompt.contains("user_selected_account"))
        XCTAssertFalse(prompt.contains("source_file"))
        XCTAssertTrue(prompt.contains("Only account"))
        XCTAssertTrue(prompt.contains("Мой запрос:"))
        account.archived = true; ledger.accounts = [account]
        let archived = try AIPrompt.text("mora-csv", ledger: ledger, includeContext: true, bundle: bundle)
        XCTAssertFalse(archived.contains("Only account"))
    }
}
