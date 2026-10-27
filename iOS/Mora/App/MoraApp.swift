import SwiftUI
import FinanceCore

@main
struct MoraApp: App {
    @StateObject private var store: FinanceStore
    @StateObject private var cloud = CloudSync()
    @StateObject private var router = AppRouter()

    init() {
        _store = StateObject(wrappedValue: FinanceStore())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(cloud)
                .environmentObject(router)
        }
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
