import XCTest
@testable import FinanceCore

final class CloudTests: XCTestCase {
    private func ledger() -> Ledger {
        var ledger = Ledger.empty
        ledger.accounts = [Account(name: "Общий счет", currency: "USD")]
        return ledger
    }
    private func purchase(_ ledger: Ledger, merchant: String, amount: Decimal = -10) -> Transaction {
        Transaction(date: Dates.parse("2026-10-12")!, merchant: merchant, amount: amount, accountID: ledger.accounts[0].id)
    }
    func testTwoPhonesAndOfflineDesktopEditsAreCombined() throws {
        let base = ledger()
        var local = base, remote = base
        local.transactions.append(purchase(base, merchant: "Local offline"))
        remote.transactions.append(purchase(base, merchant: "Member iPhone"))
        remote.transactions.append(purchase(base, merchant: "Owner iPhone"))
        let merged = try CloudMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(Set(merged.transactions.map(\.merchant)), ["Local offline", "Member iPhone", "Owner iPhone"])
        XCTAssertEqual(merged.balance(merged.accounts[0]), -30)
    }
    func testOfflineDeletionSurvivesRemoteNewPayment() throws {
        var base = ledger(); base.transactions.append(purchase(base, merchant: "Old"))
        var local = base, remote = base
        local.transactions = []
        remote.transactions.append(purchase(base, merchant: "New"))
        let merged = try CloudMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.transactions.map(\.merchant), ["New"])
    }
    func testConflictingEditsAndDeleteVersusEditAreNeverOverwritten() throws {
        var base = ledger(); base.transactions.append(purchase(base, merchant: "Purchase"))
        var local = base, remote = base
        local.transactions[0].amount = -20; remote.transactions[0].amount = -30
        XCTAssertThrowsError(try CloudMerge.merge(base: base, local: local, remote: remote))
        local.transactions = []
        XCTAssertThrowsError(try CloudMerge.merge(base: base, local: local, remote: remote))
    }
    func testAccountDeletionCannotOrphanOtherPersonsPayment() {
        let base = ledger(); var local = base, remote = base
        local.accounts = []; remote.transactions.append(purchase(base, merchant: "New"))
        XCTAssertThrowsError(try CloudMerge.merge(base: base, local: local, remote: remote))
    }
    func testLocalDisplayChoicesAreNotUploadedOrOverwritten() throws {
        let base = ledger(); var local = base, remote = base
        local.preferences.appearance = "dark"; local.preferences.showGoals = true; local.preferences.aiAgent = "claude"
        remote.preferences.appearance = "light"; remote.preferences.showBudgets = true
        remote.transactions.append(purchase(base, merchant: "Remote"))
        let merged = try CloudMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.preferences.appearance, "dark")
        XCTAssertTrue(merged.preferences.showGoals)
        XCTAssertFalse(merged.preferences.showBudgets)
        XCTAssertEqual(merged.preferences.aiAgent, "claude")
        let shared = CloudMerge.shared(merged)
        XCTAssertNil(shared.changeHistory)
        XCTAssertEqual(shared.preferences.appearance, "system")
        XCTAssertFalse(shared.preferences.showGoals)
        XCTAssertEqual(shared.schemaVersion, 4)
    }
    func testDecimalPrecisionAndDatesSurviveCanonicalMerge() throws {
        let base = ledger(); var local = base
        let value = Decimal(string: "-123456789012.123456")!
        local.transactions.append(purchase(base, merchant: "Decimal", amount: value))
        let merged = try CloudMerge.merge(base: base, local: local, remote: base)
        XCTAssertEqual(merged.transactions[0].amount, value)
        XCTAssertTrue(try CloudMerge.same(merged, local))
    }
    func testRuleReorderingIsPreservedAndConcurrentReorderConflicts() throws {
        var base = ledger()
        let category = base.categories[0].id
        base.rules = [CategoryRule(keyword: "a", categoryID: category), CategoryRule(keyword: "b", categoryID: category), CategoryRule(keyword: "c", categoryID: category)]
        var local = base, remote = base
        local.rules.swapAt(0, 1)
        remote.rules.append(CategoryRule(keyword: "d", categoryID: category))
        let merged = try CloudMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.rules.map(\.keyword), ["b", "a", "c", "d"])
        remote.rules.swapAt(1, 2)
        XCTAssertThrowsError(try CloudMerge.merge(base: base, local: local, remote: remote))
    }
    func testEditDuringNetworkRequestAndUndoPreserveIndependentRemotePayment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ledger.json")
        let sent = ledger()
        try LedgerFile.save(sent, to: file)
        var later = sent; later.transactions.append(purchase(sent, merchant: "Edited during upload"))
        try LedgerFile.save(later, to: file, expected: sent)
        var remote = sent; remote.transactions.append(purchase(sent, merchant: "Phone"))
        let applied = try LedgerFile.applyCloud(remote, at: file, mergeAgainst: sent)
        XCTAssertEqual(Set(applied.transactions.map(\.merchant)), ["Edited during upload", "Phone"])
        XCTAssertEqual(applied.undoCount, 1)
        XCTAssertEqual(try LedgerFile.decode(Data(contentsOf: file)), applied)
        XCTAssertTrue(try CloudMerge.same(CloudMerge.merge(base: remote, local: applied, remote: remote), applied))
        let undone = try LedgerFile.undo(at: file, expected: applied)
        XCTAssertEqual(undone.transactions.map(\.merchant), ["Phone"])
        let redone = try LedgerFile.redo(at: file, expected: undone)
        XCTAssertEqual(Set(redone.transactions.map(\.merchant)), ["Edited during upload", "Phone"])
    }
    func testExplicitCloudAdoptionArchivesExistingLedger() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ledger.json")
        var local = ledger(); local.transactions.append(purchase(local, merchant: "Private old data"))
        try LedgerFile.save(local, to: file)
        let remote = ledger()
        let adopted = try LedgerFile.adoptCloud(remote, at: file)
        XCTAssertEqual(adopted.accounts, remote.accounts)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("before-cloud-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try LedgerFile.decode(Data(contentsOf: backups[0])), local)
    }
    func testRejectsBackendSecretsAndUntrustedCloudURLs() throws {
        let url = URL(string: "https://example-project.supabase.co")!
        XCTAssertNoThrow(try CloudConfiguration(projectURL: url, publicKey: "sb_publishable_example"))
        XCTAssertThrowsError(try CloudConfiguration(projectURL: url, publicKey: "sb_secret_example"))
        let jwt = "e30." + Data("{\"role\":\"service_role\"}".utf8).base64EncodedString() + ".signature"
        XCTAssertThrowsError(try CloudConfiguration(projectURL: url, publicKey: jwt))
        let anon = "e30." + Data("{\"role\":\"anon\"}".utf8).base64EncodedString() + ".signature"
        XCTAssertNoThrow(try CloudConfiguration(projectURL: url, publicKey: anon))
        for bad in ["http://example-project.supabase.co", "https://evil.example", "https://example-project.supabase.co.evil.example", "https://user:pass@example-project.supabase.co", "https://example-project.supabase.co/path"] {
            XCTAssertThrowsError(try CloudConfiguration(projectURL: URL(string: bad)!, publicKey: "sb_publishable_example"))
        }
    }
    func testRealPostgreSQLSnapshotCanBeReadByMora() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("cloud/tests/fixtures/backend-ledger.json"))
        let ledger = try LedgerFile.decode(data)
        XCTAssertEqual(ledger.transactions.count, 4)
        XCTAssertTrue(ledger.transactions.allSatisfy { $0.kind == .expense && $0.tags.contains("Предварительно") && $0.externalID?.hasPrefix("wallet:") == true })
        XCTAssertEqual(ledger.transactions.first(where: { $0.amount < -1000 })?.amount, Decimal(string: "-123456789012.123456"))
        XCTAssertTrue(ledger.transactions.allSatisfy { ledger.account($0.accountID) != nil })
        XCTAssertTrue(ledger.transactions.filter { $0.merchant == "Test cafe" }.allSatisfy { $0.categoryID == ledger.categories[0].id })
    }
}
