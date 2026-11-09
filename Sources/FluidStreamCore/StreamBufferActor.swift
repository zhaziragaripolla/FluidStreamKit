/// Tuning knobs shared by `StreamBufferActor.drain(policy:)` and `DisplayLinkCoordinator`.
public struct FlushPolicy: Sendable, Equatable {
    /// The normal per-frame drain budget. It's raised automatically while there's a backlog
    /// (see `catchUpFrames`).
    public var maxBytesPerFrame: Int
    /// The number of frames over which a backlog should clear. For example, a backlog that
    /// built up while the app was backgrounded drains over this many frames, instead of
    /// arriving as one huge layout pass or as a slow crawl.
    public var catchUpFrames: Int
    /// The number of consecutive empty frames the coordinator waits before it pauses the
    /// display link to save power.
    public var idleFramesBeforePause: Int

    public init(maxBytesPerFrame: Int = 4096, catchUpFrames: Int = 8, idleFramesBeforePause: Int = 6) {
        precondition(maxBytesPerFrame >= 4, "Budget must fit at least one UTF-8 scalar")
        precondition(catchUpFrames >= 1 && idleFramesBeforePause >= 1)
        self.maxBytesPerFrame = maxBytesPerFrame
        self.catchUpFrames = catchUpFrames
        self.idleFramesBeforePause = idleFramesBeforePause
    }
}

/// The text one frame should render: everything that became renderable since the last flush.
public struct FrameBatch: Sendable, Equatable {
    public enum Completion: Sendable, Equatable { case finished, cancelled }

    /// Always valid UTF-8. A batch never ends partway through a scalar.
    public let text: String
    public let byteCount: Int
    /// Bytes still buffered after this batch, for example a trailing partial scalar or the
    /// rest of a backlog.
    public let remainingBytes: Int
    /// Set only on the last batch the buffer will produce.
    public let completion: Completion?

    public var isFinal: Bool { completion != nil }
}

public struct BufferMetrics: Sendable, Equatable {
    public var bytesIn = 0
    public var bytesOut = 0
    public var flushes = 0
    public var producerSuspensions = 0
    public var highWaterMark = 0
}

public enum StreamBufferError: Error, Sendable, Equatable {
    /// `append` was called while another `append` was still suspended on backpressure.
    /// Allowing it would interleave the two chunks' bytes.
    case concurrentProducer
    /// `append` was called after `finish()`.
    case finished
}

/// Owns the ingestion ring buffer for a single streamed response.
///
/// **Producer side (any isolation):** `append(_:)` copies bytes in. When the ring is full,
/// the call suspends until a drain frees space. This is the backpressure. Contract: one
/// producer, which matches an SSE connection's single read loop.
///
/// **Consumer side (main actor, once per frame):** `drain(policy:)` returns at most one
/// `FrameBatch`, cut on a UTF-8 scalar boundary.
public actor StreamBufferActor {
    private enum State: Equatable { case open, finished, cancelled }

    private var ring: ByteRing
    private var state = State.open
    private var isProducing = false
    private var deliveredFinal = false
    private var catchUpBytesPerFrame = 0

    private var spaceWaiter: (id: UInt64, continuation: CheckedContinuation<Void, any Error>)?
    private var nextWaiterID: UInt64 = 0

    /// True after a drain finds nothing renderable. The next state change (new bytes,
    /// finish, cancel) fires `dataAvailableHandler` exactly once, which lets the coordinator
    /// pause its display link while idle with no risk of missing a wake-up.
    private var consumerIsIdle = false
    private var dataAvailableHandler: (@Sendable () -> Void)?

    public private(set) var metrics = BufferMetrics()

    public init(capacity: Int = 64 * 1024) {
        ring = ByteRing(capacity: capacity)
    }

    public var capacity: Int { ring.capacity }
    public var pendingByteCount: Int { ring.count }

    /// Installs a hook that fires when renderable state appears after the consumer went idle.
    /// It must be cheap, and must not call back into this actor synchronously.
    public func setDataAvailableHandler(_ handler: (@Sendable () -> Void)?) {
        dataAvailableHandler = handler
    }

    // MARK: Producer

    /// Appends raw UTF-8 bytes, suspending while the ring is full.
    ///
    /// `Data`, `[UInt8]`, `String.UTF8View` and `Substring.UTF8View` are copied straight from
    /// contiguous storage. Any other collection is copied into a contiguous array once first.
    ///
    /// - Throws: `CancellationError` if the calling task is cancelled while suspended, or if
    ///   the buffer is cancelled. `StreamBufferError` if the producer contract is violated.
    public func append<Bytes: Collection<UInt8> & Sendable>(_ bytes: Bytes) async throws {
        guard bytes.withContiguousStorageIfAvailable({ _ in () }) != nil else {
            try await append(ContiguousArray(bytes))
            return
        }
        try beginProducing()
        defer { isProducing = false }

        let total = bytes.count
        var written = 0
        while written < total {
            try Task.checkCancellation()
            guard state != .cancelled else { throw CancellationError() }

            let n = bytes.withContiguousStorageIfAvailable { buffer in
                ring.write(UnsafeBufferPointer(rebasing: buffer[written...]))
            } ?? 0
            if n > 0 {
                written += n
                metrics.bytesIn += n
                metrics.highWaterMark = max(metrics.highWaterMark, ring.count)
                signalConsumerIfIdle()
            }
            if written < total {
                try await waitForSpace()
            }
        }
    }

    /// Convenience for text deltas, such as already-decoded SSE `data:` payloads.
    public func append(_ text: String) async throws {
        try await append(text.utf8)
    }

    public func append(_ text: Substring) async throws {
        try await append(text.utf8)
    }

    /// Marks the end of the stream. Remaining bytes are flushed, including a dangling partial
    /// scalar, which is repaired to U+FFFD, and then a final batch is produced.
    public func finish() {
        guard state == .open else { return }
        state = .finished
        signalConsumerIfIdle(force: true)
    }

    /// Abandons the stream. Buffered bytes are discarded, a suspended producer resumes with
    /// `CancellationError`, and the next drain returns a `.cancelled` final batch.
    public func cancel() {
        guard state != .cancelled else { return }
        state = .cancelled
        ring.removeAll()
        if let waiter = spaceWaiter {
            spaceWaiter = nil
            waiter.continuation.resume(throwing: CancellationError())
        }
        signalConsumerIfIdle(force: true)
    }

    // MARK: Consumer

    /// Returns the next frame's text, or `nil` if there's nothing renderable yet.
    ///
    /// The budget is `max(policy.maxBytesPerFrame, ceil(pending / policy.catchUpFrames))`, so
    /// steady-state flushes stay small and backlogs still clear in bounded time.
    public func drain(policy: FlushPolicy = FlushPolicy()) -> FrameBatch? {
        if deliveredFinal { return nil }

        if state == .cancelled {
            deliveredFinal = true
            return FrameBatch(text: "", byteCount: 0, remainingBytes: 0, completion: .cancelled)
        }

        let pending = ring.count
        let producerDone = state == .finished && !isProducing
        if pending == 0 {
            if producerDone {
                deliveredFinal = true
                return FrameBatch(text: "", byteCount: 0, remainingBytes: 0, completion: .finished)
            }
            consumerIsIdle = true
            return nil
        }

        // The catch-up rate is set when a backlog appears and held until the backlog clears.
        // If it were recomputed from the shrinking backlog every frame, it would decay
        // geometrically and take far more than `catchUpFrames` frames.
        if pending > policy.maxBytesPerFrame {
            let rate = (pending + policy.catchUpFrames - 1) / policy.catchUpFrames
            catchUpBytesPerFrame = max(catchUpBytesPerFrame, rate)
        } else {
            catchUpBytesPerFrame = 0
        }
        let budget = min(pending, max(policy.maxBytesPerFrame, catchUpBytesPerFrame))
        // Once the producer is done, the trailing bytes will never be completed, so flush
        // them as they are and let decoding repair any partial scalar.
        let length = (producerDone && budget == pending) ? budget : ring.utf8BoundaryLength(upTo: budget)
        guard length > 0 else {
            consumerIsIdle = true      // only a partial scalar is buffered; wait for its tail
            return nil
        }

        let text = ring.consumeString(length)
        metrics.bytesOut += length
        metrics.flushes += 1
        resumeProducerIfWaiting()

        let isFinal = producerDone && ring.isEmpty
        if isFinal { deliveredFinal = true }
        return FrameBatch(
            text: text,
            byteCount: length,
            remainingBytes: ring.count,
            completion: isFinal ? .finished : nil
        )
    }

    // MARK: Private

    private func beginProducing() throws {
        switch state {
        case .cancelled: throw CancellationError()
        case .finished: throw StreamBufferError.finished
        case .open: break
        }
        guard !isProducing else { throw StreamBufferError.concurrentProducer }
        isProducing = true
    }

    private func waitForSpace() async throws {
        metrics.producerSuspensions += 1
        let id = nextWaiterID
        nextWaiterID &+= 1
        try await withTaskCancellationHandler {
            // The body runs synchronously on this actor, so the cancellation check and the
            // store can't interleave with `cancelWaiter`. That removes the lost-wake-up race.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled || state == .cancelled {
                    continuation.resume(throwing: CancellationError())
                } else if ring.freeSpace > 0 {
                    continuation.resume()
                } else {
                    spaceWaiter = (id, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UInt64) {
        guard let waiter = spaceWaiter, waiter.id == id else { return }
        spaceWaiter = nil
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeProducerIfWaiting() {
        guard ring.freeSpace > 0, let waiter = spaceWaiter else { return }
        spaceWaiter = nil
        waiter.continuation.resume()
    }

    private func signalConsumerIfIdle(force: Bool = false) {
        guard consumerIsIdle || force else { return }
        consumerIsIdle = false
        dataAvailableHandler?()
    }
}
