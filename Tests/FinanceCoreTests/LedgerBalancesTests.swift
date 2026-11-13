import XCTest
@testable import FinanceCore

final class LedgerBalancesTests: XCTestCase {
    func testBatchBalancesMatchPerAccountBalance() throws {
        var ledger = try Ledger.personal(baseCurrency: "USD")
        var archived = Account(name: "Old", currency: "EUR", openingBalance: 7)
        archived.archived = true
        ledger.accounts = [Account(name: "Main", currency: "USD", openingBalance: 100),
                           Account(name: "Euro", currency: "EUR", openingBalance: 50.5),
                           Account(name: "Empty", currency: "USD", openingBalance: 0), archived]
        let (main, euro, empty, old) = (ledger.accounts[0], ledger.accounts[1], ledger.accounts[2], ledger.accounts[3])
        let now = Date()
        let day: TimeInterval = 86_400
        ledger.transactions = [
            Transaction(date: now - 3 * day, merchant: "A", amount: -12.34, accountID: main.id),
            Transaction(date: now - day, merchant: "Pay", amount: 500, accountID: euro.id, kind: .income),
            Transaction(date: now - day, merchant: "Move", amount: -40, accountID: main.id, kind: .transfer, destinationAccountID: euro.id, destinationAmount: 36.5),
            Transaction(date: now, merchant: "Self", amount: -5, accountID: old.id, kind: .transfer, destinationAccountID: old.id, destinationAmount: 4),
            Transaction(date: now + 5 * day, merchant: "Future", amount: -99, accountID: main.id),
            Transaction(date: now + 6 * day, merchant: "Future move", amount: -10, accountID: euro.id, kind: .transfer, destinationAccountID: empty.id, destinationAmount: 9),
            Transaction(date: now, merchant: "Ghost", amount: -1, accountID: UUID(), kind: .transfer, destinationAccountID: UUID(), destinationAmount: 1)
        ]
        for date in [now, now + 5 * day, now + 10 * day, now - 5 * day] {
            let batch = ledger.balances(through: date)
            XCTAssertEqual(batch.count, ledger.accounts.count)
            for account in ledger.accounts {
                XCTAssertEqual(batch[account.id], ledger.balance(account, through: date))
            }
        }
    }
}
