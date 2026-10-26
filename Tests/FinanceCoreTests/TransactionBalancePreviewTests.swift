import XCTest
@testable import FinanceCore

final class TransactionBalancePreviewTests: XCTestCase {
    func testPreviewReplacesLatestContributionAndIncludesBothTransferLegs() throws {
        let today = Dates.parse("2026-10-25")!
        let source = Account(name: "USD", currency: "USD", openingBalance: 1000)
        let destination = Account(name: "EUR", currency: "EUR", openingBalance: 500)
        var ledger = Ledger.empty
        ledger.accounts = [source, destination]
        let original = Transaction(date: today, merchant: "Old", amount: -10, accountID: source.id)
        ledger.transactions = [original]
        var edited = original
        edited.amount = -20
        XCTAssertEqual(ledger.projectedBalance(source, replacing: original.id, with: edited, through: today), 980)
        edited.kind = .transfer; edited.destinationAccountID = destination.id; edited.destinationAmount = 18
        XCTAssertEqual(ledger.projectedBalance(source, replacing: original.id, with: edited, through: today), 980)
        XCTAssertEqual(ledger.projectedBalance(destination, replacing: original.id, with: edited, through: today), 518)
        ledger.transactions = [edited]
        var changedAccount = edited
        changedAccount.accountID = destination.id; changedAccount.destinationAccountID = source.id
        changedAccount.amount = -30; changedAccount.destinationAmount = 33
        XCTAssertEqual(ledger.projectedBalance(source, replacing: edited.id, with: changedAccount, through: today), 1033)
        XCTAssertEqual(ledger.projectedBalance(destination, replacing: edited.id, with: changedAccount, through: today), 470)
        XCTAssertEqual(ledger.transactions, [edited], "Preview must never mutate the ledger")
    }

    func testIncomeConversionFeesAndFutureDayUseTheLedgerCutoff() throws {
        let today = Dates.parse("2026-10-25")!, tomorrow = Dates.parse("2026-10-26")!
        let account = Account(name: "EUR", currency: "EUR", openingBalance: 100, conversionFeePercent: 1)
        var ledger = Ledger.empty; ledger.accounts = [account]
        var draft = Transaction(date: tomorrow, merchant: "Foreign", amount: -10, accountID: account.id)
        let quote = CardConversion(originalAmount: -10, originalCurrency: "USD", accountCurrency: "EUR", rate: Decimal(string: "0.9")!, date: tomorrow).applyingFee(of: account)
        draft.amount = try quote.convertedAmount(); draft.conversion = quote
        XCTAssertEqual(ledger.projectedBalance(account, replacing: nil, with: draft, through: today), 100)
        XCTAssertEqual(ledger.projectedBalance(account, replacing: nil, with: draft, through: tomorrow), Decimal(string: "90.91"))
        draft.amount = 9; draft.kind = .income; draft.conversion = nil
        XCTAssertEqual(ledger.projectedBalance(account, replacing: nil, with: draft, through: tomorrow), 109)
    }
}
