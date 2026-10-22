import SwiftUI

private struct FilteredTransactionExportKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

extension FocusedValues {
    var exportFilteredTransactions: (@MainActor () -> Void)? {
        get { self[FilteredTransactionExportKey.self] }
        set { self[FilteredTransactionExportKey.self] = newValue }
    }
}
