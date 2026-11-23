import Foundation

enum LaunchTiming {
    static let minimumDuration: Duration = .seconds(3)

    static func waitForMinimum(since start: ContinuousClock.Instant,
                               minimum: Duration = minimumDuration) async throws {
        try await ContinuousClock().sleep(until: start.advanced(by: minimum))
    }
}
