import SwiftUI
import Charts
import FinanceCore

struct TransactionRow: View {
    let transaction: Transaction
    private let category: Category?
    private let account: Account?
    private let destinationName: String
    var showsDate = true

    init(transaction: Transaction, ledger: Ledger, showsDate: Bool = true) {
        self.transaction = transaction
        category = ledger.category(transaction.categoryID)
        account = ledger.account(transaction.accountID)
        destinationName = transaction.destinationAccountID.flatMap { ledger.account($0)?.name } ?? ""
        self.showsDate = showsDate
    }

    private var subtitle: String {
        var parts = [transaction.kind == .transfer ? L("Перевод") : category?.name ?? L("Без категории")]
        if transaction.kind == .transfer {
            if let removed = transaction.removedTransferAccountName { parts.append(L("удаленный счет: \(removed)")) }
            else { parts.append("\(account?.name ?? "") → \(destinationName)") }
        } else if let account { parts.append(account.name) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            IconTile(icon: transaction.kind == .transfer ? "arrow.left.arrow.right" : category?.icon ?? "tag",
                     color: category?.color ?? (transaction.kind == .income ? "green" : "gray"), size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.merchant).font(.body.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let conversion = transaction.conversion {
                    FinancialText("\(DisplayMoney.string(abs(conversion.originalAmount), currency: conversion.originalCurrency)) · Visa \(Money.plain(conversion.rate))\(conversion.feePercent == 0 ? "" : " + " + Money.plain(conversion.feePercent) + "%")")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                FinancialText(DisplayMoney.signed(transaction, currency: account?.currency ?? "RUB"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(transaction.kind == .income ? Color.moraGreen : .primary)
                    .lineLimit(1)
                if showsDate {
                    Text(transaction.date.shortDay).font(.caption2).foregroundStyle(.secondary)
                }
            }.fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Month navigation shared by Overview, Analytics and Budgets.
struct MonthSwitcher: View {
    @Binding var month: Date
    var body: some View {
        HStack(spacing: 4) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
                .accessibilityLabel(L("Предыдущий месяц"))
            Menu {
                Button(L("Текущий месяц")) { set(Date()) }
                ForEach((-24...12).reversed(), id: \.self) { offset in
                    let date = Calendar.current.date(byAdding: .month, value: offset, to: Dates.month(Date()))!
                    Button(date.monthTitle) { set(date) }
                }
            } label: {
                Text(month.monthTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .frame(minWidth: 130).contentTransition(.numericText())
            }
            Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }
                .accessibilityLabel(L("Следующий месяц"))
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 4)
        .background(Color.moraCard, in: Capsule())
    }
    private func shift(_ months: Int) { set(Calendar.current.date(byAdding: .month, value: months, to: month)!) }
    private func set(_ date: Date) { withAnimation(.snappy) { month = Dates.month(date) } }
}

struct DemoBanner: View {
    @EnvironmentObject private var router: AppRouter
    var body: some View {
        Button { router.open(.welcome) } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Это демо: изучите приложение на примере")).font(.subheadline.weight(.medium))
                    Text(L("Начать свой учет")).font(.caption.weight(.semibold)).underline()
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
            .foregroundStyle(Color.moraGreen)
            .padding(14)
            .background(Color.moraGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }.buttonStyle(.plain)
    }
}

struct CurrencyWarning: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var router: AppRouter
    var body: some View {
        let missing = store.ledger.missingCurrencies
        if !missing.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(store.updatingRates ? L("Загружаем курсы валют…") : L("В итогах не учтены валюты без курса: \(missing.joined(separator: ", "))"))
                    .font(.footnote)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

extension TrendDetail {
    var title: String {
        switch self { case .months: L("Месяцы"); case .weeks: L("Недели"); case .days: L("Дни"); case .selectedDates: L("Выбранные даты") }
    }
    /// Fits a four-segment picker on a phone.
    var shortTitle: String { self == .selectedDates ? L("Даты") : title }
    var unit: Calendar.Component { switch self { case .months: .month; case .weeks: .weekOfYear; case .days, .selectedDates: .day } }
    func label(_ date: Date) -> String {
        switch self {
        case .months: date.formatted(.dateTime.month(.abbreviated).locale(L10n.locale))
        case .weeks, .days, .selectedDates: date.formatted(.dateTime.day().locale(L10n.locale))
        }
    }
}

/// Income and expense lines; bars when the period is split into days.
struct TrendChart: View {
    @AppStorage("mora.hideAmounts") private var hidden = false
    let trend: [MonthTotal]
    let detail: TrendDetail
    let currency: String
    var bars = false
    @State private var selected: Date?

    private var selectedItem: MonthTotal? {
        guard let selected else { return nil }
        return trend.min { abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected)) }
    }

    var body: some View {
        Chart {
            ForEach(trend) { item in
                if bars {
                    BarMark(x: .value(L("Период"), item.date, unit: detail.unit), y: .value(L("Сумма"), item.income.double))
                        .foregroundStyle(by: .value(L("Тип"), L("Доходы")))
                        .position(by: .value(L("Тип"), L("Доходы")))
                        .cornerRadius(3)
                    BarMark(x: .value(L("Период"), item.date, unit: detail.unit), y: .value(L("Сумма"), item.expense.double))
                        .foregroundStyle(by: .value(L("Тип"), L("Расходы")))
                        .position(by: .value(L("Тип"), L("Расходы")))
                        .cornerRadius(3)
                } else {
                    LineMark(x: .value(L("Период"), item.date, unit: detail.unit), y: .value(L("Сумма"), item.income.double), series: .value(L("Тип"), L("Доходы")))
                        .foregroundStyle(by: .value(L("Тип"), L("Доходы")))
                        .interpolationMethod(.monotone).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    LineMark(x: .value(L("Период"), item.date, unit: detail.unit), y: .value(L("Сумма"), item.expense.double), series: .value(L("Тип"), L("Расходы")))
                        .foregroundStyle(by: .value(L("Тип"), L("Расходы")))
                        .interpolationMethod(.monotone).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    if trend.count <= 12 {
                        PointMark(x: .value(L("Период"), item.date, unit: detail.unit), y: .value(L("Сумма"), item.income.double))
                            .foregroundStyle(by: .value(L("Тип"), L("Доходы"))).symbolSize(22)
                        PointMark(x: .value(L("Период"), item.date, unit: detail.unit), y: .value(L("Сумма"), item.expense.double))
                            .foregroundStyle(by: .value(L("Тип"), L("Расходы"))).symbolSize(22)
                    }
                }
            }
            if let item = selectedItem {
                RuleMark(x: .value(L("Период"), item.date, unit: detail.unit))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(detail == .months ? item.date.monthTitle : item.date.dayTitle).font(.caption2.weight(.semibold))
                            FinancialText("+" + DisplayMoney.string(item.income, currency: currency)).font(.caption2).foregroundStyle(Color.moraGreen)
                            FinancialText("−" + DisplayMoney.string(item.expense, currency: currency)).font(.caption2).foregroundStyle(Color.token("orange"))
                        }
                        .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
            }
        }
        .chartForegroundStyleScale([L("Доходы"): Color.moraGreen, L("Расходы"): Color.token("orange")])
        .chartLegend(.hidden)
        .chartXSelection(value: $selected)
        .chartXAxis {
            AxisMarks(values: axisDates) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) { Text(detail.label(date)).font(.caption2) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3])).foregroundStyle(Color.secondary.opacity(0.25))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(hidden ? "•••" : amount.formatted(.number.notation(.compactName).locale(L10n.locale))).font(.caption2)
                    }
                }
            }
        }
        .accessibilityHidden(hidden)
    }

    private var axisDates: [Date] {
        guard trend.count > 7 else { return trend.map(\.date) }
        let step = max(1, Int((Double(trend.count) / 6).rounded(.up)))
        return trend.enumerated().filter { $0.offset % step == 0 }.map(\.element.date)
    }
}

/// Category share ring. Tapping a sector shows that category in the center.
struct CategoryDonut: View {
    @AppStorage("mora.hideAmounts") private var hidden = false
    let totals: [CategoryTotal]
    let expense: Decimal
    let currency: String
    @State private var angle: Double?

    private var selected: CategoryTotal? {
        guard let angle else { return nil }
        var running = 0.0
        for total in totals {
            running += total.amount.double
            if angle <= running { return total }
        }
        return nil
    }

    var body: some View {
        Chart(totals) { total in
            SectorMark(angle: .value(L("Сумма"), total.amount.double), innerRadius: .ratio(0.68), angularInset: 1.5)
                .cornerRadius(4)
                .foregroundStyle(Color.token(total.color))
                .opacity(selected == nil || selected?.id == total.id ? 1 : 0.3)
        }
        .chartAngleSelection(value: $angle)
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    VStack(spacing: 3) {
                        if let selected {
                            Text(selected.name).font(.caption.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                            FinancialText(DisplayMoney.string(selected.amount, currency: currency)).font(.subheadline.weight(.semibold))
                            Text("\(percent(selected.amount, of: expense))%").font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text(L("Расходы")).font(.caption).foregroundStyle(.secondary)
                            FinancialText(DisplayMoney.string(expense, currency: currency)).font(.headline).minimumScaleFactor(0.6).lineLimit(1)
                        }
                    }
                    .frame(width: frame.width * 0.58)
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .accessibilityHidden(hidden)
        .animation(.easeInOut(duration: 0.2), value: selected?.id)
    }
}

struct CategoryShareRow: View {
    let total: CategoryTotal
    let expense: Decimal
    let currency: String
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                IconTile(icon: total.icon, color: total.color, size: 30)
                Text(total.name).font(.subheadline).lineLimit(1)
                Spacer(minLength: 6)
                FinancialText(DisplayMoney.string(total.amount, currency: currency)).font(.subheadline.weight(.medium))
                Text("\(percent(total.amount, of: expense))%").font(.caption).foregroundStyle(.secondary).frame(minWidth: 34, alignment: .trailing)
            }
            Meter(progress: expense > 0 ? (total.amount / expense).double : 0, color: .token(total.color)).padding(.leading, 40)
        }
    }
}

struct EmptyCard: View {
    var icon: String; var title: String; var text: String
    var button: String? = nil; var action: () -> Void = {}
    var body: some View {
        VStack(spacing: 12) {
            IconTile(icon: icon, size: 56)
            Text(L(title)).font(.headline)
            Text(L(text)).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let button { Button(L(button), action: action).buttonStyle(.borderedProminent) }
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}

struct StorageFooter: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var cloud: CloudSync
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.shield")
            Text(store.isDemo ? L("Демонстрационный режим · изменения не сохраняются")
                 : cloud.householdID == nil ? L("Данные хранятся на этом iPhone")
                 : L("Локальная копия общей базы · \(cloud.enabled ? L("синхронизация включена") : L("синхронизация на паузе"))"))
        }
        .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        .frame(maxWidth: .infinity).padding(.vertical, 8)
    }
}
