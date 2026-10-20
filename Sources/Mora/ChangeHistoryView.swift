import SwiftUI
import FinanceCore

struct ChangeHistoryCard: View {
    @EnvironmentObject private var store: FinanceStore
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeading(title: L("История изменений"), subtitle: L("Один клик отменяет или возвращает один шаг"))
                historyAction(description: store.undoDescription, title: L("Будет отменено"), empty: L("Нет изменений для отмены"),
                              button: L("Отменить"), icon: "arrow.uturn.backward", action: store.undo)
                Divider()
                historyAction(description: store.redoDescription, title: L("Будет возвращено"), empty: L("Нет изменений для возврата"),
                              button: L("Вернуть"), icon: "arrow.uturn.forward", action: store.redo)
                if store.undoCount + store.redoCount > 0 {
                    DisclosureGroup(L("Показать сохранённые шаги")) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                if store.undoCount > 0 {
                                    Text(L("Последние изменения · \(store.undoCount)")).font(.caption.weight(.semibold))
                                    ForEach(Array(store.undoDescriptions.enumerated()), id: \.offset) { index, description in
                                        historyEntry(description, index: index)
                                    }
                                }
                                if store.redoCount > 0 {
                                    Text(L("Отменённые шаги · \(store.redoCount)")).font(.caption.weight(.semibold))
                                    ForEach(Array(store.redoDescriptions.enumerated()), id: \.offset) { index, description in
                                        historyEntry(description, index: index)
                                    }
                                }
                            }.padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 280)
                    }.font(.callout)
                }
                Text(L("Хранятся последние 20 шагов, в том числе после перезапуска. Один шаг может включать несколько операций — например, импорт файла. Новое изменение после отмены очищает список возврата.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func historyAction(description: ChangeDescription?, title: String, empty: String,
                               button: String, icon: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).frame(width: 20).padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout.weight(.medium))
                if let description {
                    Text(description.title).font(.callout)
                    FinancialText(description.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else { Text(empty).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(button, action: action).disabled(description == nil)
        }
    }
    private func historyEntry(_ description: ChangeDescription, index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1).").font(.caption).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                Text(description.title).font(.caption.weight(.medium))
                FinancialText(description.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
