import AppKit

/// Keep the process alive until already accepted asynchronous saves finish.
/// Closing an app must not cancel a financial commit halfway through its write.
@MainActor
final class MoraApplicationDelegate: NSObject, NSApplicationDelegate {
    var finishPendingWrites: (() async -> Void)?
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let finishPendingWrites else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { @MainActor in
            await finishPendingWrites()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
