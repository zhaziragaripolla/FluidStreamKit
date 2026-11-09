import Testing
import os
@testable import FluidStreamUI
import FluidStreamCore

// Stress tests for StreamSession and display-link frame coalescing under standard token
// burst patterns. Invariants checked throughout:
//   1. Content: the rendered document equals rendering the whole text in one go.
//   2. Coalescing: at most one render (onContentChange) per handled frame.
//   3. Liveness: every burst is eventually rendered, the run completes, and no producer hangs.

private final class Flag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: 0)
    var value: Int { state.withLock { $0 } }
    func increment() { state.withLock { $0 += 1 } }
}

@MainActor
private final class BurstHarness {
    let ticker = ManualFrameTicker()
    let session: StreamSession
    private(set) var renders = 0

    init(capacity: Int = 1024, policy: FlushPolicy = FlushPolicy(maxBytesPerFrame: 256, catchUpFrames: 4, idleFramesBeforePause: 3)) {
        session = StreamSession(ticker: ticker, flushPolicy: policy, bufferCapacity: capacity)
        session.renderer.onContentChange = { [unowned self] in renders += 1 }
    }

    var coordinator: DisplayLinkCoordinator { session.coordinator }
    var text: String { session.renderer.document.string }

    /// Fires one frame and waits until the coordinator has handled it (or there was no frame to fire).
    func frame() async throws {
        let before = coordinator.framesHandled
        guard ticker.fire() else {
            try await Task.sleep(for: .milliseconds(1))
            return
        }
        try await poll { self.coordinator.framesHandled > before || self.coordinator.phase == .stopped }
    }

    /// Drives frames until the run stops. Returns the number of frames fired.
    @discardableResult
    func runToCompletion(limit: Int = 50_000) async throws -> Int {
        var frames = 0
        while coordinator.phase != .stopped && frames < limit {
            try await frame()
            frames += 1
        }
        #expect(coordinator.phase == .stopped, "run never completed")
        return frames
    }

    func assertInvariants(expected: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let reference = StreamRenderer()
        reference.apply(text: expected, isFinal: true)
        #expect(session.renderer.document.attributedString.isEqual(to: reference.document.attributedString),
                "rendered text differs", sourceLocation: sourceLocation)
        #expect(renders <= coordinator.framesHandled, "more renders than frames", sourceLocation: sourceLocation)
    }
}

private func poll(
    isolation: isolated (any Actor)? = #isolation,
    timeout: Duration = .seconds(3),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out")
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private let markdownUnit = "Para **bold** `code` é🧠 <thinking>t</thinking>\n```swift\nlet x = 1\n```\n- item\n"

@Suite("StreamSession bursts")
@MainActor
struct StreamSessionBurstTests {

    @Test func singleBurstMuchLargerThanTheRing() async throws {
        let h = BurstHarness(capacity: 1024)
        let text = String(repeating: markdownUnit, count: 300)          // ~21 KB through a 1 KB ring
        await h.session.start { try await $0.append(text) }
        try await h.runToCompletion()
        h.assertInvariants(expected: text)
        #expect(await h.session.buffer.metrics.producerSuspensions > 0)  // backpressure was exercised
    }

    @Test func thousandsOfTinyAppendsIncludingSplitScalars() async throws {
        let h = BurstHarness()
        let text = String(repeating: markdownUnit, count: 20)
        let bytes = Array(text.utf8)
        await h.session.start { buffer in
            for byte in bytes { try await buffer.append([byte]) }       // splits every multi-byte scalar
        }
        try await h.runToCompletion()
        h.assertInvariants(expected: text)
    }

    @Test func burstIdleBurstWakesThePausedDisplayLink() async throws {
        let h = BurstHarness()
        let gate = Flag()
        await h.session.start { buffer in
            try await buffer.append("first burst\n")
            while gate.value == 0 { try await Task.sleep(for: .milliseconds(1)) }   // network stall
            try await buffer.append("second burst")
        }
        try await poll { h.text.contains("first") || h.ticker.fire() == false }
        while h.coordinator.phase != .idlePaused { try await h.frame() }
        #expect(h.ticker.isPaused)                                       // idle: link paused
        gate.increment()                                                 // network resumes
        try await h.runToCompletion()
        h.assertInvariants(expected: "first burst\nsecond burst")
    }

    @Test func tickStormCoalescesToAtMostTwoDrains() async throws {
        let h = BurstHarness()
        await h.session.start { try await $0.append("hello") }
        try await poll { true }
        for _ in 0..<1_000 { h.ticker.fire() }                           // main actor busy, no yielding
        try await Task.sleep(for: .milliseconds(30))
        #expect(h.coordinator.framesHandled <= 2)
        #expect(h.renders <= 2)
    }

    @Test func backlogBuiltInBackgroundClearsWithinCatchUpFrames() async throws {
        let policy = FlushPolicy(maxBytesPerFrame: 64, catchUpFrames: 4, idleFramesBeforePause: 3)
        let h = BurstHarness(capacity: 64 * 1024, policy: policy)
        let text = String(repeating: "x", count: 8_000)
        let appended = Flag()
        h.coordinator.enterBackground()
        await h.session.start { buffer in
            try await buffer.append(text)
            appended.increment()
            try await Task.sleep(for: .seconds(60))                      // keep the stream open
        }
        try await poll { appended.value == 1 }
        #expect(!h.ticker.fire())                                        // no frames in background
        h.coordinator.enterForeground()
        var frames = 0
        while h.text.utf8.count < text.utf8.count && frames < 100 { try await h.frame(); frames += 1 }
        #expect(h.text.utf8.count == 8_000)
        #expect(frames <= policy.catchUpFrames + 1, "catch-up took \(frames) frames")
        h.session.cancel()
    }

    @Test func cancelWhileProducerIsBlockedOnBackpressure() async throws {
        let h = BurstHarness(capacity: 64)
        let exited = Flag()
        await h.session.start { buffer in
            defer { exited.increment() }
            while true { try await buffer.append(String(repeating: "y", count: 100)) }
        }
        try await poll { true }
        h.session.cancel()
        try await h.runToCompletion()
        try await poll { exited.value == 1 }
        #expect(h.session.renderer.completion == .cancelled)
    }

    @Test func concurrentStartCallsRunOneProducer() async throws {
        let h = BurstHarness()
        let runs = Flag()
        async let a: Void = h.session.start { buffer in runs.increment(); try await buffer.append("once") }
        async let b: Void = h.session.start { buffer in runs.increment(); try await buffer.append("once") }
        _ = await (a, b)
        try await h.runToCompletion()
        #expect(runs.value == 1)
        #expect(h.session.renderer.completion == .finished)
        h.assertInvariants(expected: "once")
    }

    @Test func abandonedSessionDoesNotLeakItsProducer() async throws {
        let exited = Flag()
        weak var weakSession: StreamSession?
        do {
            let h = BurstHarness(capacity: 64)
            weakSession = h.session
            await h.session.start { buffer in
                defer { exited.increment() }
                // An endless response into a tiny ring: blocks on backpressure almost immediately.
                while true { try await buffer.append(String(repeating: "z", count: 100)) }
            }
            for _ in 0..<5 { try await h.frame() }
        }   // view dismissed mid-answer: nobody calls cancel()
        try await poll { exited.value == 1 }
        #expect(exited.value == 1, "producer is still suspended after its session was released")
        try await poll { weakSession == nil }
        #expect(weakSession == nil, "session leaked")
    }
}
