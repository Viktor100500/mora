import SwiftUI

struct TransactionFilterSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

struct TransactionToolbarButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? (scheme == .dark ? Color.black.opacity(0.85) : .white) : .primary)
            .padding(.horizontal, 14).frame(height: 40)
            .background(prominent ? Color.moraGreen : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct FilterChoice<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
}

/// The popover remains open while users build a selection of several values.
struct TransactionFilterChecklist<ID: Hashable>: View {
    let title: String
    let allTitle: String
    let width: CGFloat
    @Binding var selection: Set<ID>?
    let options: [FilterChoice<ID>]
    @State private var presented = false
    @State private var search = ""

    private var summary: String {
        guard let selection else { return allTitle }
        if selection.count == 1, let option = options.first(where: { selection.contains($0.id) }) { return option.title }
        return title + " · \(selection.count)"
    }

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 8) {
                Text(summary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
            .font(.body).foregroundStyle(selection == nil ? Color.primary : Color.moraGreen)
            .padding(.horizontal, 12).frame(width: width, height: 40)
            .modifier(TransactionFilterSurface())
        }
        .buttonStyle(.plain).help(summary)
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Button(L("Готово")) { presented = false }.buttonStyle(.plain).foregroundStyle(Color.moraGreen)
                }
                if options.count > 8 {
                    TextField(L("Поиск"), text: $search).textFieldStyle(.roundedBorder)
                }
                Toggle(allTitle, isOn: Binding(get: { selection == nil }, set: { selection = $0 ? nil : [] }))
                    .toggleStyle(.checkbox)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(options.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { option in
                            Toggle(option.title, isOn: Binding(get: { selection?.contains(option.id) ?? true }, set: { checked in
                                var next = selection ?? Set(options.map(\.id))
                                if checked { next.insert(option.id) } else { next.remove(option.id) }
                                selection = next == Set(options.map(\.id)) ? nil : next
                            })).toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.vertical, 2)
                }.frame(height: min(CGFloat(options.count) * 30, 280))
            }
            .padding(18).frame(width: 280)
        }
        .onChange(of: presented) { _, open in if !open { search = "" } }
    }
}
