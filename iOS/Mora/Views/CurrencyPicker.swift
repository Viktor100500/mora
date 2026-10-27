import SwiftUI

/// Currency choice with search: the region's currency and popular ones first,
/// then every ISO currency with its name. Without a title only the code is shown.
struct CurrencyPicker: View {
    var title: String?
    @Binding var selection: String
    var codes: [String] = Locale.commonISOCurrencyCodes
    @State private var choosing = false

    var body: some View {
        Button { choosing = true } label: {
            HStack(spacing: 6) {
                if let title { Text(title).foregroundStyle(.primary); Spacer() }
                Text(selection).foregroundStyle(title == nil ? Color.moraGreen : .secondary)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $choosing) { CurrencyList(selection: $selection, codes: codes) }
    }
}

private struct CurrencyList: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    let codes: [String]
    @State private var query = ""

    private var popular: [String] {
        var result: [String] = []
        for code in [Locale.current.currency?.identifier, selection].compactMap({ $0 }) + currencyList where codes.contains(code) && !result.contains(code) {
            result.append(code)
        }
        return result
    }

    private func name(_ code: String) -> String { L10n.locale.localizedString(forCurrencyCode: code) ?? code }

    private func matches(_ code: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        // Names are searched in both interface languages: "динар" and "dinar" both work.
        let names = [code, name(code)] + ["ru", "en"].compactMap { Locale(identifier: $0).localizedString(forCurrencyCode: code) }
        return names.contains { $0.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section(L("Популярные")) { ForEach(popular, id: \.self) { row($0) } }
                }
                Section(L("Все валюты")) { ForEach(codes.filter(matches).sorted(), id: \.self) { row($0) } }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L("Поиск валюты"))
            .navigationTitle(L("Валюта")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Отмена")) { dismiss() } } }
        }
    }

    private func row(_ code: String) -> some View {
        Button { selection = code; dismiss() } label: {
            HStack(spacing: 12) {
                Text(code).font(.body.weight(.semibold).monospaced()).frame(width: 48, alignment: .leading)
                Text(name(code)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if code == selection { Image(systemName: "checkmark").foregroundStyle(Color.moraGreen) }
            }.contentShape(Rectangle())
        }.foregroundStyle(.primary)
    }
}
