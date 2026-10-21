import XCTest
@testable import FinanceCore

final class TransactionDraftTests: XCTestCase {
    func testEditorPreservesIndependentCategoryAndImportChanges() throws {
        let original = Transaction(date: Date(), merchant: "Test merchant", amount: -10, accountID: UUID())
        var edited = original, latest = original
        edited.note = "My note"
        latest.categoryID = UUID(); latest.importBatchID = UUID()
        let result = try edited.mergingEditorChanges(from: original, into: latest)
        XCTAssertEqual(result.note, "My note")
        XCTAssertEqual(result.categoryID, latest.categoryID)
        XCTAssertEqual(result.importBatchID, latest.importBatchID)
    }
    func testEditorRejectsAConflictingAmountButAllowsAnIdenticalEdit() throws {
        let original = Transaction(date: Date(), merchant: "Test merchant", amount: -10, accountID: UUID())
        var edited = original, latest = original
        edited.amount = -12; latest.amount = -15
        XCTAssertThrowsError(try edited.mergingEditorChanges(from: original, into: latest))
        latest.amount = -12
        XCTAssertEqual(try edited.mergingEditorChanges(from: original, into: latest).amount, -12)
    }
}
