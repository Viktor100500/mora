import SwiftUI
import FinanceCore

struct TransactionDetailsView: View {
    var transaction: Transaction
    var ledger: Ledger
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Подробности операции")).font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(transaction.merchant).font(.title3.weight(.medium)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    LabeledContent(L("Дата"), value: transaction.date.formatted(.dateTime.day().month(.wide).year().locale(L10n.locale)))
                    LabeledContent(L("Тип"), value: L(transaction.kind.title))
                    LabeledContent(L("Счет"), value: ledger.account(transaction.accountID)?.name ?? "—")
                    if transaction.kind == .transfer {
                        LabeledContent(L("Счет назначения"), value: transaction.destinationAccountID.flatMap { ledger.account($0)?.name } ?? "—")
                    } else {
                        LabeledContent(L("Категория"), value: ledger.category(transaction.categoryID)?.name ?? L("Без категории"))
                    }
                    LabeledContent(L("Сумма")) {
                        FinancialText(DisplayMoney.string(transaction.amount, currency: ledger.account(transaction.accountID)?.currency ?? ledger.preferences.baseCurrency))
                    }
                    Divider()
                    Text(L("Описание")).font(.headline)
                    Text(transaction.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L("Нет заметки") : transaction.note)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if !transaction.tags.isEmpty {
                        Text(L("Теги")).font(.headline)
                        Text(transaction.tags.joined(separator: ", ")).textSelection(.enabled)
                    }
                }.font(.body).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button(L("Закрыть")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 600, height: 520)
    }
}
