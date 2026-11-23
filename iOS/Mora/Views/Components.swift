import SwiftUI
import Charts
import FinanceCore

struct TransactionRow: View {
    @EnvironmentObject private var categorizer: MerchantCategorizer
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var iconDimension = 44
    @AppStorage("mora.hideAmounts") private var amountsHidden = false
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

    private var conversionText: String? {
        transaction.conversion.map { conversion in
            DisplayMoney.string(abs(conversion.originalAmount), currency: conversion.originalCurrency)
        }
    }
    private var amountLabel: some View {
        FinancialText(DisplayMoney.signed(transaction, currency: account?.currency ?? "RUB"))
            .font(.body.weight(.semibold))
            .foregroundStyle(transaction.kind == .income ? Color.moraGreen : .primary)
            .monospacedDigit()
            .lineLimit(1)
    }
    private var time: some View {
        Text(showsDate ? transaction.date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(L10n.locale))
                       : transaction.date.formatted(.dateTime.hour().minute().locale(L10n.locale)))
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
    }
    private var subtitleText: some View {
        Group {
            if transaction.categoryID == nil && categorizer.pendingTransactionIDs.contains(transaction.id) {
                TransactionCategoryProgress()
            } else {
                Text(subtitle).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
        }.font(.caption).foregroundStyle(.secondary)
    }
    private var merchant: some View {
        Text(transaction.merchant).font(.body.weight(.medium))
            .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(icon: transaction.kind == .transfer ? "arrow.left.arrow.right" : category?.icon ?? "tag",
                     color: category?.color ?? (transaction.kind == .income ? "green" : "gray"), size: min(iconDimension, 60))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                TransactionHeadingLayout(stacked: typeSize.isAccessibilitySize) {
                    merchant
                    amountLabel.minimumScaleFactor(0.65)
                }
                subtitleText
                    .frame(maxWidth: .infinity, alignment: .leading)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        originalAmount
                        Spacer(minLength: 0)
                        time
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        originalAmount
                        time
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .alignmentGuide(.listRowSeparatorLeading) { _ in min(iconDimension, 60) + 12 }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var originalAmount: some View {
        if let conversionText {
            FinancialText(conversionText).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
                .accessibilityLabel(L("Исходная сумма: \(amountsHidden ? FinancialPrivacy.mask(conversionText) : conversionText)"))
        }
    }

}

/// Measure the amount first, then wrap the merchant into its remaining column.
/// ViewThatFits uses an unwrapped title's ideal width and needlessly stacks it.
private struct TransactionHeadingLayout: Layout {
    var stacked: Bool

    private func sizes(width: CGFloat, subviews: Subviews) -> (CGSize, CGSize, Bool) {
        let amount = subviews[1].sizeThatFits(.unspecified)
        let vertical = stacked || amount.width + 12 + min(96, width * 0.4) > width
        let titleWidth = vertical ? width : max(0, width - amount.width - 12)
        return (subviews[0].sizeThatFits(ProposedViewSize(width: titleWidth, height: nil)),
                subviews[1].sizeThatFits(ProposedViewSize(width: min(amount.width, width), height: nil)), vertical)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(12) { $0 + $1.sizeThatFits(.unspecified).width }
        let (title, amount, vertical) = sizes(width: width, subviews: subviews)
        return CGSize(width: width, height: vertical ? title.height + 4 + amount.height : max(title.height, amount.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (title, amount, vertical) = sizes(width: bounds.width, subviews: subviews)
        let titleProposal = ProposedViewSize(width: vertical ? bounds.width : bounds.width - amount.width - 12, height: title.height)
        subviews[0].place(at: bounds.origin, proposal: titleProposal)
        let amountProposal = ProposedViewSize(width: amount.width, height: amount.height)
        let baselineOffset = subviews[0].dimensions(in: titleProposal)[.firstTextBaseline]
            - subviews[1].dimensions(in: amountProposal)[.firstTextBaseline]
        subviews[1].place(at: CGPoint(x: bounds.maxX - amount.width,
            y: bounds.minY + (vertical ? title.height + 4 : baselineOffset)), proposal: amountProposal)
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

/// Like the Mac notice: how many automatically captured purchases need the user.
/// The list itself lives in "More" → "Automation".
struct WalletReviewBanner: View {
    @EnvironmentObject private var cloud: CloudSync
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var queue: WalletReviewQueue

    var body: some View {
        let count = queue.count(with: cloud)
        if count > 0 {
            Button { router.openMore("wallet-review") } label: {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle.fill").font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Покупки на проверку: \(count)")).font(.subheadline.weight(.semibold))
                        Text(L("Автоматизации передали не всё — проверьте")).font(.caption)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .foregroundStyle(.orange)
                .padding(14)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
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

/// Category share ring. Tapping a sector shows that category in the center;
/// categories under 5% share one "Other" sector.
struct CategoryDonut: View {
    let totals: [CategoryTotal]
    let expense: Decimal
    let currency: String

    private struct SliceIdentity: Hashable {
        let id: UUID?
        let amount: Decimal
    }

    var body: some View {
        let slices = totals.filter { $0.amount > 0 && $0.amount.double.isFinite }
            .groupingSmallShares(name: L("Другое"))
        CategoryDonutContent(slices: slices, expense: expense, currency: currency)
            // A new dataset gets fresh selection and sector geometry. In particular,
            // do not interpolate disappearing sectors with MonthSwitcher's spring:
            // Charts can produce NaN angles and trap while drawing rounded arcs.
            .id(slices.map { SliceIdentity(id: $0.id, amount: $0.amount) })
            .transaction {
                $0.animation = nil
                $0.disablesAnimations = true
            }
    }
}

private struct CategoryDonutContent: View {
    @AppStorage("mora.hideAmounts") private var hidden = false
    let slices: [CategoryTotal]
    let expense: Decimal
    let currency: String
    @State private var angle: Double?

    private var selected: CategoryTotal? {
        guard let angle else { return nil }
        var running = 0.0
        for total in slices {
            running += total.amount.double
            if angle <= running { return total }
        }
        return nil
    }

    var body: some View {
        Chart(slices) { total in
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

    private var labelOffset: CGFloat {
        // Move only the caption; extra padding changes the whole scroll layout.
        if #available(iOS 26, *), UIDevice.current.userInterfaceIdiom == .phone { return -12 }
        return 0
    }


    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Mora \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "lock.shield")
                Text(store.isDemo ? L("Демонстрационный режим · изменения не сохраняются")
                     : cloud.householdID == nil ? L("Данные хранятся на этом iPhone")
                     : L("Локальная копия общей базы · \(cloud.enabled ? L("синхронизация включена") : L("синхронизация на паузе"))"))
            }
            // Always visible, so the installed build can be checked at a glance.
            Text(verbatim: Self.version).monospacedDigit()
        }
        .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .offset(y: labelOffset)
    }
}

extension View {
    /// Applied to a tab's ScrollView content: tapping the open tab again scrolls back
    /// to the very top, with the large title expanded, the way Lists do by themselves.
    func scrollsToTopOnReselect(_ tab: AppTab) -> some View { modifier(ScrollToTopOnReselect(tab: tab)) }
}

private struct ScrollToTopOnReselect: ViewModifier {
    @EnvironmentObject private var router: AppRouter
    @State private var finder = ScrollViewFinder.Box()
    let tab: AppTab

    func body(content: Content) -> some View {
        content
            .background(ScrollViewFinder(box: finder))
            .onChange(of: router.reselections[tab]) {
                guard let scrollView = finder.scrollView else { return }
                // A collapsed large title shrinks the inset, so go back to the expanded one.
                let top = max(finder.expandedTop, scrollView.adjustedContentInset.top)
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: -top), animated: true)
            }
    }
}

private struct ScrollViewFinder: UIViewRepresentable {
    final class Box {
        weak var scrollView: UIScrollView?
        /// The top inset seen while the large title was expanded.
        var expandedTop: CGFloat = 0
    }
    let box: Box

    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        Task { @MainActor in
            var parent = view.superview
            while let current = parent, !(current is UIScrollView) { parent = current.superview }
            box.scrollView = parent as? UIScrollView
            if let scrollView = box.scrollView { box.expandedTop = max(box.expandedTop, scrollView.adjustedContentInset.top) }
        }
    }
}

extension View {
    /// UIKit owns one refresh gesture and its settling animation. SwiftUI data
    /// updates do not replace the control or animate the navigation/search layout.
    func settledRefreshable(action: @escaping @MainActor () async -> Void) -> some View {
        modifier(SettledRefreshModifier(action: action))
    }
}

private struct SettledRefreshModifier: ViewModifier {
    let action: @MainActor () async -> Void
    @State private var refreshing = false

    func body(content: Content) -> some View {
        content
            .transaction { transaction in
                if refreshing { transaction.animation = nil; transaction.disablesAnimations = true }
            }
            .background(RefreshScrollAnchor {
                refreshing = true
                await action()
                refreshing = false
            })
    }
}

private struct RefreshScrollAnchor: UIViewRepresentable {
    let action: @MainActor () async -> Void

    func makeCoordinator() -> ScrollRefreshCoordinator { ScrollRefreshCoordinator(action: action) }
    func makeUIView(context: Context) -> RefreshScrollProbe {
        let view = RefreshScrollProbe()
        view.isUserInteractionEnabled = false
        view.attach = { [weak coordinator = context.coordinator] view in coordinator?.attach(from: view) }
        return view
    }
    func updateUIView(_ view: RefreshScrollProbe, context: Context) {
        context.coordinator.action = action
        view.scheduleAttachment()
    }
    static func dismantleUIView(_ view: RefreshScrollProbe, coordinator: ScrollRefreshCoordinator) { coordinator.detach() }
}

private final class RefreshScrollProbe: UIView {
    var attach: ((UIView) -> Void)?
    override func didMoveToWindow() { super.didMoveToWindow(); scheduleAttachment() }
    override func layoutSubviews() { super.layoutSubviews(); scheduleAttachment() }
    func scheduleAttachment() {
        Task { @MainActor [weak self] in
            guard let self, window != nil else { return }
            attach?(self)
        }
    }
}

@MainActor
final class ScrollRefreshCoordinator: NSObject {
    var action: @MainActor () async -> Void
    private(set) weak var scrollView: UIScrollView?
    let control = UIRefreshControl()
    private var task: Task<Void, Never>?

    init(action: @escaping @MainActor () async -> Void) {
        self.action = action
        super.init()
        control.addTarget(self, action: #selector(refresh), for: .valueChanged)
    }
    func attach(from probe: UIView) {
        guard scrollView == nil else { return }
        var parent = probe.superview
        while let current = parent {
            if let scroll = current as? UIScrollView ?? Self.findScroll(in: current) {
                scrollView = scroll
                scroll.refreshControl = control
                return
            }
            parent = current.superview
        }
    }
    private static func findScroll(in view: UIView) -> UIScrollView? {
        for child in view.subviews {
            if let scroll = child as? UIScrollView { return scroll }
            if let scroll = findScroll(in: child) { return scroll }
        }
        return nil
    }
    @objc private func refresh() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await action()
            guard !Task.isCancelled else { return }
            finish()
            task = nil
        }
    }
    private func finish() {
        control.endRefreshing()
        guard let scrollView else { return }
        scrollView.layoutIfNeeded()
        // Only repair the overscroll left by this gesture. If the user scrolled
        // into the list while loading, keep that position and their search focus.
        guard !scrollView.isDragging, !scrollView.isDecelerating,
              scrollView.contentOffset.y < -scrollView.adjustedContentInset.top else { return }
        UIView.animate(withDuration: 0.28, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top), animated: false)
            scrollView.superview?.layoutIfNeeded()
        }
    }
    func detach() {
        task?.cancel(); task = nil
        control.endRefreshing()
        if scrollView?.refreshControl === control { scrollView?.refreshControl = nil }
        scrollView = nil
    }
}
