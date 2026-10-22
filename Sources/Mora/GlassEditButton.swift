import SwiftUI

struct GlassEditButton: View {
    var title = "Редактировать"
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "pencil")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .modifier(ToolbarGlassStyle(shape: Circle()))
        .help(L(title))
        .accessibilityLabel(L(title))
    }
}
