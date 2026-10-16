import SwiftUI
import AppKit
import FinanceCore

struct ColorPickerRow: View {
    @Binding var color: String
    private let palette = ["green", "mint", "teal", "cyan", "blue", "indigo", "purple", "lavender", "pink", "coral", "red", "orange", "yellow", "lime", "brown", "gray"]
    private let names = ["green": "Зеленый", "mint": "Мятный", "teal": "Бирюзовый", "cyan": "Голубой", "blue": "Синий", "indigo": "Индиго", "purple": "Фиолетовый", "lavender": "Лавандовый", "pink": "Розовый", "coral": "Коралловый", "red": "Красный", "orange": "Оранжевый", "yellow": "Желтый", "lime": "Лаймовый", "brown": "Коричневый", "gray": "Серый"]

    private var customColor: Binding<Color> {
        Binding(get: { Color.token(color) }, set: { value in
            guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
            color = CategoryAppearance.hex(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Цвет")).font(.callout.weight(.medium))
                Spacer()
                ColorPicker(L("Свой цвет"), selection: customColor, supportsOpacity: false).fixedSize()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                ForEach(palette, id: \.self) { token in
                    Button { color = token } label: {
                        Circle().fill(Color.token(token)).frame(width: 24, height: 24)
                            .overlay {
                                if color == token { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white).shadow(radius: 1) }
                            }
                            .padding(4)
                            .overlay(Circle().stroke(Color.primary.opacity(color == token ? 0.6 : 0), lineWidth: 1.5))
                    }.buttonStyle(.plain).help(L(names[token] ?? token))
                        .accessibilityLabel(L(names[token] ?? token)).accessibilityAddTraits(color == token ? .isSelected : [])
                }
            }
        }
    }
}

struct CategoryIconPicker: View {
    @Binding var icon: String
    @Binding var useEmoji: Bool
    @State private var lastEmoji: String
    @State private var lastSymbol: String
    @State private var paletteRequest = 0
    @State private var showSymbols = false

    static let symbols = [
        "tag", "basket", "cart", "cup.and.saucer", "fork.knife", "carrot", "wineglass", "birthday.cake",
        "tram", "car", "bus", "bicycle", "fuelpump", "airplane", "ferry", "parkingsign.circle",
        "house", "building.2", "key", "bolt", "drop", "flame", "lightbulb", "sofa",
        "bag", "tshirt", "gift", "heart", "cross.case", "pills", "stethoscope", "pawprint",
        "sparkles", "gamecontroller", "film", "music.note", "book", "graduationcap", "figure.run", "dumbbell",
        "repeat", "phone", "iphone", "wifi", "antenna.radiowaves.left.and.right", "network", "desktopcomputer", "envelope",
        "building.columns", "doc.text", "percent", "banknote", "creditcard", "receipt", "chart.line.uptrend.xyaxis", "shield",
        "briefcase", "hammer", "wrench.and.screwdriver", "paintbrush", "leaf", "globe", "arrow.down.left", "ellipsis"
    ]
    private static let symbolNames = [
        "tag": "Метка", "basket": "Продукты", "cart": "Корзина", "cup.and.saucer": "Кофе",
        "fork.knife": "Рестораны", "carrot": "Овощи", "wineglass": "Напитки", "birthday.cake": "Праздники",
        "tram": "Трамвай", "car": "Автомобиль", "bus": "Автобус", "bicycle": "Велосипед",
        "fuelpump": "Топливо", "airplane": "Самолет", "ferry": "Паром", "parkingsign.circle": "Парковка",
        "house": "Дом", "building.2": "Недвижимость", "key": "Ключи", "bolt": "Электричество",
        "drop": "Вода", "flame": "Отопление", "lightbulb": "Освещение", "sofa": "Мебель",
        "bag": "Покупки", "tshirt": "Одежда", "gift": "Подарки", "heart": "Здоровье",
        "cross.case": "Медицина", "pills": "Лекарства", "stethoscope": "Врач", "pawprint": "Питомцы",
        "sparkles": "Развлечения", "gamecontroller": "Игры", "film": "Кино", "music.note": "Музыка",
        "book": "Книги", "graduationcap": "Образование", "figure.run": "Бег", "dumbbell": "Спорт",
        "repeat": "Подписки", "phone": "Телефон", "iphone": "Смартфон", "wifi": "Интернет",
        "antenna.radiowaves.left.and.right": "Связь", "network": "Сеть", "desktopcomputer": "Компьютер", "envelope": "Почта",
        "building.columns": "Налоги", "doc.text": "Документы", "percent": "Проценты", "banknote": "Деньги",
        "creditcard": "Банковская карта", "receipt": "Чеки", "chart.line.uptrend.xyaxis": "Инвестиции", "shield": "Страхование",
        "briefcase": "Работа", "hammer": "Ремонт", "wrench.and.screwdriver": "Инструменты", "paintbrush": "Творчество",
        "leaf": "Природа", "globe": "Мир", "arrow.down.left": "Доход", "ellipsis": "Другое",
    ]
    private let suggestions = [
        "🏛️", "🧾", "💰", "💳", "📱", "☎️", "📡", "🌐",
        "🛒", "🥑", "☕️", "🍽️", "🚗", "🚕", "⛽️", "✈️",
        "🏠", "🔑", "💡", "💧", "🛍️", "👕", "🎁", "💊",
        "🩺", "🐾", "🎮", "🎬", "🎵", "📚", "🎓", "🏋️",
        "🔁", "💻", "🛠️", "🌱", "🏖️", "👶", "❤️", "🏷️"
    ]

    init(icon: Binding<String>, useEmoji: Binding<Bool>) {
        _icon = icon
        let emoji = CategoryAppearance.isEmoji(icon.wrappedValue)
        _useEmoji = useEmoji
        _lastEmoji = State(initialValue: emoji ? icon.wrappedValue : "🏷️")
        _lastSymbol = State(initialValue: emoji ? "tag" : icon.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Значок")).font(.callout.weight(.medium))
                Spacer()
                Picker(L("Вид значка"), selection: $useEmoji) {
                    Text(L("Эмоджи")).tag(true)
                    Text(L("Символы")).tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
            }
            if useEmoji {
                HStack(spacing: 10) {
                    EmojiInput(text: $icon, paletteRequest: paletteRequest).frame(width: 72, height: 34)
                    Button(L("Все эмоджи Apple…")) { paletteRequest += 1 }
                    Spacer()
                }
                Text(L("Выберите эмоджи в системной панели или вставьте свой.")).font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 4) {
                    ForEach(suggestions, id: \.self) { emoji in
                        Button { icon = emoji } label: {
                            Text(emoji).font(.system(size: 22)).frame(maxWidth: .infinity).frame(height: 30)
                                .background(Color.primary.opacity(icon == emoji ? 0.09 : 0.025))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.moraGreen.opacity(icon == emoji ? 0.7 : 0), lineWidth: 1.5))
                        }.buttonStyle(.plain).accessibilityLabel(emoji).accessibilityAddTraits(icon == emoji ? .isSelected : [])
                    }
                }
                if !CategoryAppearance.isEmoji(icon) {
                    Text(L("Для значка нужен один эмоджи.")).font(.caption).foregroundStyle(Color.token("red"))
                }
            } else {
                Button { showSymbols = true } label: {
                    HStack { Image(systemName: icon).font(.title3).frame(width: 28); Text(L("Выбрать символ…")); Spacer(); Image(systemName: "chevron.down").foregroundStyle(.secondary) }.padding(8)
                }.buttonStyle(.bordered)
                    .popover(isPresented: $showSymbols) {
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40)), count: 8), spacing: 8) {
                                ForEach(Self.symbols, id: \.self) { symbol in
                                    Button { icon = symbol; showSymbols = false } label: {
                                        Image(systemName: symbol).font(.system(size: 20)).frame(width: 40, height: 36)
                                            .background(Color.primary.opacity(icon == symbol ? 0.1 : 0.025)).clipShape(RoundedRectangle(cornerRadius: 7))
                                    }.buttonStyle(.plain).help(L(Self.symbolNames[symbol] ?? symbol)).accessibilityLabel(L(Self.symbolNames[symbol] ?? symbol))
                                }
                            }.padding(16)
                        }.frame(width: 410, height: 300)
                    }
            }
        }
        .onChange(of: useEmoji) { _, emoji in icon = emoji ? lastEmoji : lastSymbol }
        .onChange(of: icon) { _, value in
            if CategoryAppearance.isEmoji(value) { lastEmoji = value }
            else if !useEmoji { lastSymbol = value }
        }
    }
}

/// An explicit native first responder sends Character Viewer insertion to the icon,
/// even when the category name was the most recently edited field.
private struct EmojiInput: NSViewRepresentable {
    @Binding var text: String
    var paletteRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.font = .systemFont(ofSize: 22)
        field.alignment = .center
        field.delegate = context.coordinator
        field.setAccessibilityLabel(L("Эмоджи категории"))
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.string = text
        }
        if context.coordinator.paletteRequest != paletteRequest {
            context.coordinator.paletteRequest = paletteRequest
            DispatchQueue.main.async {
                guard let window = field.window, window.makeFirstResponder(field) else { return }
                field.selectText(nil)
                NSApp.orderFrontCharacterPalette(nil)
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: EmojiInput
        var paletteRequest = 0
        init(_ parent: EmojiInput) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}
