import Testing
@testable import FluidStreamCore

@MainActor
private final class Harness {
    let buffer: StreamBufferActor
    let ticker = ManualFrameTicker()
    let coordinator: DisplayLinkCoordinator
    private(set) var batches: [FrameBatch] = []

    init(capacity: Int = 64 * 1024, policy: FlushPolicy = FlushPolicy(idleFramesBeforePause: 3)) {
        let buffer = StreamBufferActor(capacity: capacity)
        self.buffer = buffer
        var sink: ((FrameBatch) -> Void)?
        coordinator = DisplayLinkCoordinator(buffer: buffer, ticker: ticker, policy: policy) { sink?($0) }
        sink = { [unowned self] in self.batches.append($0) }
    }

    var text: String { batches.map(\.text).joined() }

    /// Fires one tick and waits for the coordinator to finish handling it.
    func frame() async throws {
        let before = coordinator.framesHandled
        guard ticker.fire() else { return }
        try await waitUntil { self.coordinator.framesHandled > before || self.coordinator.phase == .stopped }
    }
}

@Suite("DisplayLinkCoordinator")
@MainActor
struct DisplayLinkCoordinatorTests {

    @Test func burstIsDeliveredInOneFrame() async throws {
        let h = Harness()
        await h.coordinator.start()
        for i in 0..<50 { try await h.buffer.append("tok\(i) ") }
        try await h.frame()
        #expect(h.batches.count == 1)
        #expect(h.text.hasSuffix("tok49 "))
        h.coordinator.stop()
    }

    @Test func backToBackTicksCoalesceToAtMostOneExtraDrain() async throws {
        let h = Harness()
        await h.coordinator.start()
        try await h.buffer.append("hello")
        for _ in 0..<10 { h.ticker.fire() }            // main actor is "busy": no chance to drain between ticks
        try await waitUntil { h.coordinator.framesHandled >= 1 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.coordinator.framesHandled <= 2)      // bufferingNewest(1): 1 in-flight + 1 newest
        #expect(h.batches.count == 1)
        h.coordinator.stop()
    }

    @Test func pausesTickerAfterIdleFramesAndWakesOnData() async throws {
        let h = Harness()
        await h.coordinator.start()
        for _ in 0..<3 { try await h.frame() }
        #expect(h.coordinator.phase == .idlePaused)
        #expect(h.ticker.isPaused)

        try await h.buffer.append("wake")
        try await waitUntil { h.coordinator.phase == .running }
        #expect(!h.ticker.isPaused)
        try await h.frame()
        #expect(h.text == "wake")
        h.coordinator.stop()
    }

    @Test func splitScalarDoesNotStallPausedLink() async throws {
        let brain = Array("🧠".utf8)
        let h = Harness()
        await h.coordinator.start()
        try await h.buffer.append(Array(brain[0..<2]))
        for _ in 0..<3 { try await h.frame() }
        #expect(h.coordinator.phase == .idlePaused)
        try await h.buffer.append(Array(brain[2...]))
        try await waitUntil { h.coordinator.phase == .running }
        try await h.frame()
        #expect(h.text == "🧠")
        h.coordinator.stop()
    }

    @Test func backgroundingSuspendsFlushesAndForegroundCatchesUp() async throws {
        let h = Harness(policy: FlushPolicy(maxBytesPerFrame: 16, catchUpFrames: 4, idleFramesBeforePause: 3))
        await h.coordinator.start()
        h.coordinator.enterBackground()
        #expect(h.ticker.isPaused)

        try await h.buffer.append(String(repeating: "z", count: 400))
        try await Task.sleep(for: .milliseconds(10))
        #expect(h.coordinator.phase == .backgrounded)   // data must not wake us in background
        #expect(!h.ticker.fire())

        h.coordinator.enterForeground()
        var frames = 0
        while h.text.utf8.count < 400 && frames < 20 { try await h.frame(); frames += 1 }
        #expect(h.text.utf8.count == 400)
        #expect(frames == 4)                            // adaptive budget: 400 B / 4 frames
        h.coordinator.stop()
    }

    @Test func finalBatchStopsCoordinatorAndInvalidatesTicker() async throws {
        let h = Harness()
        await h.coordinator.start()
        try await h.buffer.append("bye")
        await h.buffer.finish()
        try await h.frame()
        #expect(h.batches.last?.completion == .finished)
        #expect(h.text == "bye")
        #expect(h.coordinator.phase == .stopped)
        #expect(h.ticker.isInvalidated)
    }

    @Test func finishWakesIdlePausedCoordinator() async throws {
        let h = Harness()
        await h.coordinator.start()
        for _ in 0..<3 { try await h.frame() }
        #expect(h.coordinator.phase == .idlePaused)
        await h.buffer.finish()
        try await waitUntil { h.coordinator.phase == .running }
        try await h.frame()
        #expect(h.coordinator.phase == .stopped)
    }

    @Test func cancelDeliversCancelledCompletion() async throws {
        let h = Harness()
        await h.coordinator.start()
        try await h.buffer.append("partial")
        await h.buffer.cancel()
        try await h.frame()
        #expect(h.batches.last?.completion == .cancelled)
        #expect(h.coordinator.phase == .stopped)
    }

    @Test func stopIsIdempotentAndIgnoresLaterTicks() async throws {
        let h = Harness()
        await h.coordinator.start()
        h.coordinator.stop()
        h.coordinator.stop()
        #expect(!h.ticker.fire())
        await h.coordinator.start()                      // no restart after stop
        #expect(h.coordinator.phase == .stopped)
    }

    @Test func endToEndJitteryProducerPreservesContentAndFrameCap() async throws {
        let h = Harness(capacity: 64)                    // small ring → exercises backpressure
        await h.coordinator.start()
        let tokens = (0..<300).map { i in i % 7 == 0 ? "🧠\(i) " : "tok\(i) " }
        let buffer = h.buffer
        let producer = Task.detached {
            for (i, t) in tokens.enumerated() {
                try await buffer.append(t)
                if i % 25 == 0 { try await Task.sleep(for: .milliseconds(2)) }   // network jitter
            }
            await buffer.finish()
        }
        var ticks = 0
        while h.coordinator.phase != .stopped && ticks < 5_000 {
            if h.ticker.isPaused {
                try await Task.sleep(for: .milliseconds(1))   // idle-paused: wait for wake
            } else {
                try await h.frame()
                ticks += 1
            }
        }
        try await producer.value
        #expect(h.text == tokens.joined())
        #expect(h.batches.count <= ticks)                // never more than one flush per frame
    }
}
