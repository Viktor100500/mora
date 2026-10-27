import SwiftUI
import UIKit
import FinanceCore

extension Color {
    static let moraGreen = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.52, green: 0.73, blue: 0.60, alpha: 1)
            : UIColor(red: 0.20, green: 0.43, blue: 0.34, alpha: 1)
    })
    static let moraBackground = Color(uiColor: .systemGroupedBackground)
    static let moraCard = Color(uiColor: .secondarySystemGroupedBackground)

    /// Same palette tokens as the Mac app; custom categories may store #RRGGBB.
    static func token(_ value: String) -> Color {
        if let rgb = CategoryAppearance.rgb(value) { return Color(red: rgb.red, green: rgb.green, blue: rgb.blue) }
        return switch value {
        case "teal": Color(red: 0.20, green: 0.58, blue: 0.56)
        case "cyan": Color(red: 0.24, green: 0.64, blue: 0.76)
        case "indigo": Color(red: 0.36, green: 0.39, blue: 0.70)
        case "mint": Color(red: 0.38, green: 0.70, blue: 0.55)
        case "lime": Color(red: 0.58, green: 0.68, blue: 0.28)
        case "brown": Color(red: 0.57, green: 0.40, blue: 0.29)
        case "coral": Color(red: 0.91, green: 0.48, blue: 0.42)
        case "lavender": Color(red: 0.66, green: 0.57, blue: 0.81)
        case "green": .moraGreen
        case "orange": Color(red: 0.80, green: 0.48, blue: 0.28)
        case "blue": Color(red: 0.35, green: 0.53, blue: 0.72)
        case "purple": Color(red: 0.57, green: 0.48, blue: 0.70)
        case "pink": Color(red: 0.76, green: 0.46, blue: 0.57)
        case "red": Color(red: 0.78, green: 0.35, blue: 0.35)
        case "yellow": Color(red: 0.74, green: 0.62, blue: 0.30)
        default: .gray
        }
    }
}

enum Palette {
    static let tokens = ["green", "mint", "teal", "cyan", "blue", "indigo", "purple", "lavender", "pink", "coral", "red", "orange", "yellow", "lime", "brown", "gray"]
    static let names = ["green": "Зеленый", "mint": "Мятный", "teal": "Бирюзовый", "cyan": "Голубой", "blue": "Синий", "indigo": "Индиго", "purple": "Фиолетовый", "lavender": "Лавандовый", "pink": "Розовый", "coral": "Коралловый", "red": "Красный", "orange": "Оранжевый", "yellow": "Желтый", "lime": "Лаймовый", "brown": "Коричневый", "gray": "Серый"]
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color.moraCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct IconTile: View {
    var icon: String; var color: String = "green"; var size: CGFloat = 38
    var body: some View {
        Group {
            if CategoryAppearance.isEmoji(icon) {
                Text(icon).font(.system(size: size * 0.55))
            } else {
                Image(systemName: icon).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(Color.token(color))
            }
        }
        .frame(width: size, height: size)
        .background(Color.token(color).opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct SectionHeading: View {
    var title: String; var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L(title)).font(.headline)
            if let subtitle { Text(L(subtitle)).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct Meter: View {
    var progress: Double; var color: Color = .moraGreen
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.14))
                Capsule().fill(color).frame(width: proxy.size.width * min(max(progress.isFinite ? progress : 0, 0), 1))
            }
        }.frame(height: 7).accessibilityHidden(true)
    }
}

struct ChartLegend: View {
    var color: Color; var title: String
    var body: some View {
        HStack(spacing: 6) { Circle().fill(color).frame(width: 8, height: 8); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
}

struct LinkButton: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) { Text(L(title)); Image(systemName: "chevron.right").font(.caption.weight(.semibold)) }
                .font(.subheadline.weight(.medium)).foregroundStyle(Color.moraGreen)
        }.buttonStyle(.plain)
    }
}

/// Russian/English plural-free count lines reuse the Mac's "Label: N" convention.
func percent(_ part: Decimal, of total: Decimal) -> Int {
    total > 0 ? Int(((part / total).double * 100).rounded()) : 0
}

func replaceOrAppend<T: Identifiable>(_ value: T, in items: inout [T]) where T.ID == UUID {
    if let index = items.firstIndex(where: { $0.id == value.id }) { items[index] = value } else { items.append(value) }
}
