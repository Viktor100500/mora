import SwiftUI
import FinanceCore

struct TransactionTagsField: View {
    @Binding var text: String
    let available: [String]
    @FocusState private var focused: Bool
    @State private var dismissed = false

    private var suggestions: [String] {
        TransactionTags.suggestions(for: text, available: available)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(L("Теги через запятую"), text: $text)
                .focused($focused)
                .onTapGesture { dismissed = false }
                .onChange(of: focused) { _, value in if value { dismissed = false } }
                .onChange(of: text) { _, _ in dismissed = false }
            if focused && !dismissed && !suggestions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions, id: \.self) { tag in
                            Button {
                                text = TransactionTags.selecting(tag, in: text, available: available)
                                focused = true
                            } label: {
                                Label(tag, systemImage: "tag")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                        }
                    }
                }
                .frame(height: CGFloat(min(suggestions.count, 4)) * 30)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(L("Существующие теги"))
            }
        }
        .onKeyPress(.escape) {
            guard focused && !dismissed && !suggestions.isEmpty else { return .ignored }
            dismissed = true
            return .handled
        }
    }
}
