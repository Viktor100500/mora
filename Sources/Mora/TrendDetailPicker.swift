import SwiftUI
import AppKit
import FinanceCore

extension TrendDetail {
    var title: String {
        switch self {
        case .months: return L("Месяцы")
        case .weeks: return L("Недели")
        case .days: return L("Дни")
        case .selectedDates: return L("Выбранные даты")
        }
    }

    func axisLabel(_ date: Date) -> String {
        self == .months
            ? date.formatted(.dateTime.month(.abbreviated).locale(L10n.locale))
            : date.formatted(.dateTime.day().month(.abbreviated).locale(L10n.locale))
    }

    func axisDates(_ trend: [MonthTotal]) -> [Date] {
        let step = self == .days || self == .selectedDates ? max(1, (trend.count + 7) / 8) : 1
        return trend.enumerated().compactMap { $0.offset.isMultiple(of: step) ? $0.element.date : nil }
    }
}

struct TrendDetailPicker: View {
    @Binding var selection: TrendDetail
    var includesSelectedDates = false
    var body: some View {
        NativeTrendDetailPicker(selection: $selection, details: TrendDetail.allCases.filter { includesSelectedDates || $0 != .selectedDates })
            .fixedSize()
    }
}

private struct NativeTrendDetailPicker: NSViewRepresentable {
    @Binding var selection: TrendDetail
    var details: [TrendDetail]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: details.map(\.title), trackingMode: .selectOne,
            target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fit
        control.font = .systemFont(ofSize: 13)
        control.selectedSegmentBezelColor = NSColor(Color.moraGreen)
        control.setAccessibilityLabel(L("Детализация графика"))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.segmentCount = details.count
        for (index, detail) in details.enumerated() { control.setLabel(detail.title, forSegment: index) }
        control.selectedSegment = details.firstIndex(of: selection) ?? 0
        control.isEnabled = context.environment.isEnabled
    }

    @MainActor final class Coordinator: NSObject {
        var parent: NativeTrendDetailPicker
        init(_ parent: NativeTrendDetailPicker) { self.parent = parent }
        @objc func changed(_ control: NSSegmentedControl) {
            guard parent.details.indices.contains(control.selectedSegment) else { return }
            parent.selection = parent.details[control.selectedSegment]
        }
    }
}
