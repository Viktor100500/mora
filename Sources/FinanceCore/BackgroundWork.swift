import Foundation

/// CPU work and local I/O execute outside MainActor. Each operation is
/// synchronous inside this actor, so there is no suspension point between
/// checking a disk snapshot and committing it. LedgerFile also coordinates
/// other processes through its existing file lock and compare-and-swap checks.
public actor BackgroundWork {
    public static let shared = BackgroundWork()
    /// An OS authentication dialog must never hold up report or editor work.
    public static let credentials = BackgroundWork()
    public init() {}

    public func perform<Value: Sendable>(_ work: @Sendable () throws -> Value) rethrows -> Value {
        try work()
    }
}
