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

struct TransactionFilterMenu<Content: View>: View {
    var title: String
    var width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        Menu { content } label: {
            HStack(spacing: 8) {
                Text(title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
            .font(.body).foregroundStyle(.primary)
            .padding(.horizontal, 12).frame(width: width, height: 40)
            .modifier(TransactionFilterSurface())
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(title)
    }
}

struct TransactionFilterDate: View {
    var title: String
    @Binding var selection: Date

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            EuropeanDateField(title: title, selection: $selection, embedded: true)
                .frame(width: 104, height: 26)
        }
        .padding(.horizontal, 12).frame(height: 40)
        .modifier(TransactionFilterSurface())
        .fixedSize()
    }
}
