import SwiftUI
import FinanceCore

struct CalendarPeriodSelection: Equatable {
    private(set) var start: Date
    private(set) var end: Date
    private(set) var anchor: Date?
    let calendar: Calendar

    init(start: Date, end: Date, calendar: Calendar = .current) {
        self.calendar = calendar
        let first = calendar.startOfDay(for: start), last = calendar.startOfDay(for: end)
        self.start = min(first, last); self.end = max(first, last)
    }

    mutating func select(_ date: Date) {
        let day = calendar.startOfDay(for: date)
        if let anchor {
            start = min(anchor, day); end = max(anchor, day); self.anchor = nil
        } else {
            start = day; end = day; anchor = day
        }
    }

    func preview(hovering day: Date?) -> ClosedRange<Date> {
        guard let anchor, let day else { return start...end }
        let normalized = calendar.startOfDay(for: day)
        return min(anchor, normalized)...max(anchor, normalized)
    }

    static func days(in month: Date, calendar: Calendar = .current) -> [Date] {
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month))!
        let offset = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -offset, to: first)!
        return (0..<42).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }
}

struct TransactionPeriodPicker: View {
    @Binding var startDate: Date
    @Binding var endDate: Date
    @State private var presented = false

    private var title: String {
        let calendar = Calendar.current
        let start: String
        if calendar.isDate(startDate, equalTo: endDate, toGranularity: .month) {
            start = startDate.formatted(.dateTime.day().locale(L10n.locale))
        } else {
            start = startDate.formatted(.dateTime.day().month(.abbreviated).year().locale(L10n.locale))
        }
        return start + " – " + endDate.formatted(.dateTime.day().month(.abbreviated).year().locale(L10n.locale))
    }

    var body: some View {
        Button { presented = true } label: {
            HStack(spacing: 9) {
                Image(systemName: "calendar").foregroundStyle(Color.moraGreen)
                Text(title).monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
            .font(.system(size: 13)).padding(.horizontal, 12).frame(height: 40)
            .modifier(TransactionFilterSurface())
        }
        .buttonStyle(.plain).fixedSize().help(L("Период операций"))
        .accessibilityLabel(L("Период операций") + ": " + title)
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            TransactionPeriodCalendar(start: startDate, end: endDate, cancel: { presented = false }) { start, end in
                startDate = start; endDate = end; presented = false
            }
        }
    }
}

/// Compact month grid inspired by Mini Calendar. Draft changes apply together.
struct TransactionPeriodCalendar: View {
    @State private var selection: CalendarPeriodSelection
    @State private var month: Date
    @State private var hoveredDay: Date?
    private let cancel: () -> Void
    private let apply: (Date, Date) -> Void
    private var calendar: Calendar { selection.calendar }

    init(start: Date, end: Date, cancel: @escaping () -> Void, apply: @escaping (Date, Date) -> Void) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = L10n.locale
        _selection = State(initialValue: CalendarPeriodSelection(start: start, end: end, calendar: calendar))
        _month = State(initialValue: calendar.date(from: calendar.dateComponents([.year, .month], from: start))!)
        self.cancel = cancel; self.apply = apply
    }

    private var year: Int { calendar.component(.year, from: month) }
    private var monthNumber: Int { calendar.component(.month, from: month) }
    private var monthNames: [String] {
        let formatter = DateFormatter(); formatter.locale = L10n.locale
        return formatter.standaloneMonthSymbols
    }
    private var weekdays: [String] {
        let formatter = DateFormatter(); formatter.locale = L10n.locale
        let symbols = formatter.shortStandaloneWeekdaySymbols!
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(L("Период операций")).font(.headline)
                Spacer()
                Button(action: cancel) { Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel(L("Закрыть"))
            }
            HStack(spacing: 8) {
                endpoint(L("С"), date: selection.start)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                endpoint(L("По"), date: selection.end)
            }
            VStack(spacing: 12) {
                monthHeader
                VStack(spacing: 6) {
                    HStack(spacing: 0) {
                        ForEach(Array(weekdays.enumerated()), id: \.offset) { index, name in
                            let weekday = (calendar.firstWeekday - 1 + index) % 7
                            Text(name.uppercased()).font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(weekday == 0 || weekday == 6 ? Color.secondary.opacity(0.7) : Color.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 3) {
                        ForEach(CalendarPeriodSelection.days(in: month, calendar: calendar), id: \.self) { day in dayCell(day) }
                    }
                }
            }
            Text(selection.anchor == nil ? L("Выберите начало и конец периода") : L("Теперь выберите конец периода"))
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack(spacing: 6) {
                presetButton(L("Сегодня"), .today)
                presetButton(L("7 дней"), .week)
                presetButton(L("Этот месяц"), .month)
                Menu {
                    Button(L("30 дней")) { preset(.thirtyDays) }
                    Button(L("Прошлый месяц")) { preset(.previousMonth) }
                    Button(L("Этот год")) { preset(.year) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().frame(width: 24)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button(L("Отмена"), action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Применить")) { apply(selection.start, selection.end) }
                    .buttonStyle(.borderedProminent).tint(.moraGreen).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 342)
    }

    private func endpoint(_ title: String, date: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(date.formatted(.dateTime.day().month(.abbreviated).year().locale(L10n.locale)))
                .font(.system(size: 12, weight: .medium)).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    private var monthHeader: some View {
        HStack(spacing: 5) {
            Menu {
                ForEach(1...12, id: \.self) { value in
                    Button(monthNames[value - 1]) { show(year: year, month: value) }
                }
            } label: { Text(monthNames[monthNumber - 1].capitalized).font(.system(size: 14, weight: .semibold)) }
                .menuStyle(.borderlessButton).fixedSize()
            Menu {
                ForEach((year - 10)...(year + 10), id: \.self) { value in
                    Button(String(value)) { show(year: value, month: monthNumber) }
                }
            } label: { Text(String(year)).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary) }
                .menuStyle(.borderlessButton).fixedSize()
            Spacer(minLength: 0)
            Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }
                .help(L("Предыдущий месяц"))
            Button { month = Dates.month(Date()) } label: { Circle().fill(Color.moraGreen).frame(width: 6, height: 6) }
                .help(L("Текущий месяц"))
            Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }
                .help(L("Следующий месяц"))
        }
        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
    }

    private func dayCell(_ day: Date) -> some View {
        let range = selection.preview(hovering: hoveredDay)
        let endpoint = day == range.lowerBound || day == range.upperBound
        let included = range.contains(day)
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let today = calendar.isDateInToday(day)
        return Button {
            selection.select(day)
            if !inMonth { month = Dates.month(day) }
        } label: {
            Text(String(calendar.component(.day, from: day)))
                .font(.system(size: 12, weight: endpoint || today ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(endpoint ? Color.white : (inMonth ? Color.primary : Color.secondary.opacity(0.45)))
                .frame(width: 28, height: 28)
                .background { if endpoint { Circle().fill(Color.moraGreen) } }
                .overlay { if today && !endpoint { Circle().strokeBorder(Color.moraGreen, lineWidth: 1) } }
                .frame(maxWidth: .infinity).frame(height: 30)
                .background {
                    if included {
                        UnevenRoundedRectangle(topLeadingRadius: day == range.lowerBound ? 15 : 0,
                            bottomLeadingRadius: day == range.lowerBound ? 15 : 0,
                            bottomTrailingRadius: day == range.upperBound ? 15 : 0,
                            topTrailingRadius: day == range.upperBound ? 15 : 0)
                            .fill(Color.moraGreen.opacity(0.12))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { over in hoveredDay = over ? day : (hoveredDay == day ? nil : hoveredDay) }
        .accessibilityLabel(day.formatted(.dateTime.day().month(.wide).year().locale(L10n.locale)))
        .accessibilityAddTraits(included ? [.isSelected] : [])
    }

    private func moveMonth(_ delta: Int) { month = calendar.date(byAdding: .month, value: delta, to: month)!; hoveredDay = nil }
    private func show(year: Int, month: Int) { self.month = calendar.date(from: DateComponents(year: year, month: month, day: 1))!; hoveredDay = nil }
    private enum Preset { case today, week, thirtyDays, month, previousMonth, year }
    private func presetButton(_ title: String, _ value: Preset) -> some View {
        Button(title) { preset(value) }.buttonStyle(.bordered).controlSize(.small)
    }
    private func preset(_ value: Preset) {
        let today = calendar.startOfDay(for: Date())
        let start: Date, end: Date
        switch value {
        case .today: start = today; end = today
        case .week: start = calendar.date(byAdding: .day, value: -6, to: today)!; end = today
        case .thirtyDays: start = calendar.date(byAdding: .day, value: -29, to: today)!; end = today
        case .month, .previousMonth:
            start = value == .month ? Dates.month(today) : calendar.date(byAdding: .month, value: -1, to: Dates.month(today))!
            end = calendar.date(byAdding: .day, value: -1, to: calendar.date(byAdding: .month, value: 1, to: start)!)!
        case .year:
            start = calendar.date(from: DateComponents(year: calendar.component(.year, from: today), month: 1, day: 1))!
            end = calendar.date(byAdding: .day, value: -1, to: calendar.date(byAdding: .year, value: 1, to: start)!)!
        }
        selection = CalendarPeriodSelection(start: start, end: end, calendar: calendar)
        month = Dates.month(start); hoveredDay = nil
    }
}
