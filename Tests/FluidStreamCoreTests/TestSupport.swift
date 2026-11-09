import Testing
import os

/// Polls `condition` until it holds, failing the test after `timeout`.
func waitUntil(
    isolation: isolated (any Actor)? = #isolation,
    timeout: Duration = .seconds(2),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while await !condition() {
        guard clock.now < deadline else {
            Issue.record("waitUntil timed out", sourceLocation: sourceLocation)
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

final class Counter: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: 0)
    var value: Int { storage.withLock { $0 } }
    func increment() { storage.withLock { $0 += 1 } }
}
