import SwiftUI
import FinanceCore

@main
struct MoraApp: App {
    @StateObject private var store: FinanceStore
    @StateObject private var cloud = CloudSync()
    @StateObject private var router = AppRouter()
    @StateObject private var categorizer = MerchantCategorizer()
    @StateObject private var reviewQueue = WalletReviewQueue()

    init() {
        _store = StateObject(wrappedValue: FinanceStore())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(cloud)
                .environmentObject(router)
                .environmentObject(categorizer)
                .environmentObject(reviewQueue)
        }
        .backgroundTask(.appRefresh(WalletBackgroundDelivery.identifier)) { await WalletBackgroundDelivery.run() }
    }
}

enum AppTab: Hashable { case overview, transactions, analytics, accounts, more }

enum AppSheet: Identifiable {
    case welcome
    case transaction(Transaction?)
    case similar(Transaction)
    case split(Transaction)
    case account(Account?)
    case budget(Budget?)
    case goal(Goal?)
    case recurring(RecurringPayment?)
    case category(Category?, TransactionKind)
    case rule(CategoryRule?)
    case csv(CSVTable, String)
    case walletReview(CloudCapture)
    case walletRun(WalletRun, UUID?)
    case walletGuide

    var id: String {
        switch self {
        case .welcome: "welcome"
        case .transaction(let t): "transaction-\(t?.id.uuidString ?? "new")"
        case .similar(let t): "similar-\(t.id)"
        case .split(let t): "split-\(t.id)"
        case .account(let a): "account-\(a?.id.uuidString ?? "new")"
        case .budget(let b): "budget-\(b?.id.uuidString ?? "new")"
        case .goal(let g): "goal-\(g?.id.uuidString ?? "new")"
        case .recurring(let r): "recurring-\(r?.id.uuidString ?? "new")"
        case .category(let c, let kind): "category-\(c?.id.uuidString ?? "new-\(kind.rawValue)")"
        case .rule(let r): "rule-\(r?.id.uuidString ?? "new")"
        case .csv: "csv"
        case .walletReview(let capture): "wallet-\(capture.id)"
        case .walletRun(let run, _): "wallet-run-\(run.id)"
        case .walletGuide: "wallet-guide"
        }
    }
}

/// Navigation state shared by every tab, so any screen can open an editor or switch tabs.
@MainActor final class AppRouter: ObservableObject {
    @Published var tab: AppTab = .overview
    @Published var sheet: AppSheet?
    @Published var month = Dates.month(Date())
    /// Filters requested from another screen, e.g. "all transactions" for a category.
    @Published var transactionFilter: TransactionFilterRequest?
    /// A screen inside "More" requested by a debug launch argument.
    var debugMoreDestination: String?
    /// A screen inside "More" another tab asked to open.
    @Published var moreDestination: String?

    func openMore(_ screen: String) { tab = .more; moreDestination = screen }

    /// Bumped when a tab's bar item is tapped while that tab is already open,
    /// so screens built on a plain ScrollView can scroll back to the top.
    @Published private(set) var reselections: [AppTab: Int] = [:]

    func select(_ tab: AppTab) {
        if tab == self.tab { reselections[tab, default: 0] += 1 } else { self.tab = tab }
    }

    func open(_ sheet: AppSheet) {
        if self.sheet == nil { self.sheet = sheet; return }
        // Replace an open sheet only after it has been dismissed.
        self.sheet = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            self.sheet = sheet
        }
    }
}

struct TransactionFilterRequest: Equatable {
    var month: Date
    var categoryID: UUID?
    var accountID: UUID?
}
