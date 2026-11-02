import XCTest
@testable import FinanceCore

final class TransactionDraftTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testDateOnlyEditPreservesExactTimestampAndChronologicalOrder() throws {
        let date = ISO8601DateFormatter().date(from: "2026-10-21T19:45:23Z")!.addingTimeInterval(0.125)
        let account = Account(name: "Synthetic account")
        let original = Transaction(date: date, merchant: "Latest purchase", amount: -10, accountID: account.id)
        let earlier = Transaction(date: date.addingTimeInterval(-3600), merchant: "Earlier purchase", amount: -20, accountID: account.id)
        var edited = original
        edited.date = TransactionDateEditing.changingDay(of: date, to: utc.startOfDay(for: date), calendar: utc)
        edited.categoryID = UUID()
        let saved = try edited.mergingEditorChanges(from: original, into: original)
        XCTAssertEqual(saved.date, original.date)
        var ledger = Ledger.empty
        ledger.accounts = [account]; ledger.transactions = [earlier, saved]
        let search = TransactionSearch(startDate: date, endDate: date, accountID: nil, kind: "all", category: "all", text: "")
        XCTAssertEqual(try search.prepare(in: ledger).rows.map(\.id), [original.id, earlier.id])
    }

    func testChangingDateKeepsHoursMinutesSecondsAndFraction() {
        let original = ISO8601DateFormatter().date(from: "2026-10-21T19:45:23Z")!.addingTimeInterval(0.125)
        let target = ISO8601DateFormatter().date(from: "2026-10-18T00:00:00Z")!
        let result = TransactionDateEditing.changingDay(of: original, to: target, calendar: utc)
        XCTAssertEqual(result, original.addingTimeInterval(-3 * 86400))
        let copy = Transaction(date: target, merchant: "Template", amount: -1, accountID: UUID()).similarTransaction(date: original)
        XCTAssertEqual(copy.date, original)
    }

    func testChangingDayAcrossDaylightSavingPreservesLocalClockTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let source = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 19, minute: 45, second: 23))!
        let target = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let result = TransactionDateEditing.changingDay(of: source, to: target, calendar: calendar)
        let parts = calendar.dateComponents([.day, .hour, .minute, .second], from: result)
        XCTAssertEqual(parts.day, 8); XCTAssertEqual(parts.hour, 19)
        XCTAssertEqual(parts.minute, 45); XCTAssertEqual(parts.second, 23)
        XCTAssertEqual(result.timeIntervalSince(source), 23 * 3600)
    }

    func testClockEditKeepsSelectedDayAndClearsHiddenSeconds() throws {
        let original = ISO8601DateFormatter().date(from: "2026-10-21T19:45:23Z")!.addingTimeInterval(0.125)
        let pickerValue = ISO8601DateFormatter().date(from: "2026-11-01T09:15:00Z")!
        let edited = TransactionDateEditing.changingTime(of: original, to: pickerValue, calendar: utc)
        XCTAssertEqual(edited, ISO8601DateFormatter().date(from: "2026-10-21T09:15:00Z"))
        let nextDay = ISO8601DateFormatter().date(from: "2026-10-22T00:00:00Z")!
        XCTAssertEqual(TransactionDateEditing.changingDay(of: edited, to: nextDay, calendar: utc),
                       ISO8601DateFormatter().date(from: "2026-10-22T09:15:00Z"))
        let unchangedMinute = original.addingTimeInterval(-23.125)
        XCTAssertEqual(TransactionDateEditing.changingTime(of: original, to: unchangedMinute, calendar: utc), original)
    }

    func testBackdatedClockTimeSurvivesSaveAndReordersTransactions() throws {
        let account = Account(name: "Synthetic account")
        let created = ISO8601DateFormatter().date(from: "2026-10-21T22:30:45Z")!
        let original = Transaction(date: created, merchant: "Added last", amount: -10, accountID: account.id)
        var edited = original
        let morning = ISO8601DateFormatter().date(from: "2026-10-21T09:00:00Z")!
        edited.date = TransactionDateEditing.changingTime(of: original.date, to: morning, calendar: utc)
        let saved = try edited.mergingEditorChanges(from: original, into: original)
        let afternoon = Transaction(date: created.addingTimeInterval(-4 * 3600), merchant: "Afternoon purchase", amount: -20, accountID: account.id)
        var ledger = Ledger.empty
        ledger.accounts = [account]; ledger.transactions = [afternoon, saved]
        ledger = try LedgerFile.decode(LedgerFile.encode(ledger))
        let search = TransactionSearch(startDate: created, endDate: created)
        XCTAssertEqual(try search.prepare(in: ledger).rows.map(\.id), [afternoon.id, saved.id])
        XCTAssertEqual(ledger.transactions.last?.date, morning)

        // Midnight is a valid explicit time, not a missing value or the creation time.
        edited.date = TransactionDateEditing.changingTime(of: original.date, to: utc.startOfDay(for: created), calendar: utc)
        XCTAssertEqual(edited.date, utc.startOfDay(for: created))
    }

    func testClockEditAcrossDaylightSavingKeepsTheChosenLocalDay() {
        var calendar = utc
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let source = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 19, minute: 45))!
        let selected = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 9, minute: 15))!
        let result = TransactionDateEditing.changingTime(of: source, to: selected, calendar: calendar)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: result)
        XCTAssertEqual(parts, DateComponents(year: 2026, month: 11, day: 1, hour: 9, minute: 15))
    }

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
