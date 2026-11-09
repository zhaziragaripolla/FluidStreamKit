import Testing
@testable import FluidStreamCore

private let brain = Array("🧠".utf8)          // F0 9F A7 A0
private let loose = FlushPolicy(maxBytesPerFrame: 4096, catchUpFrames: 1_000)

@Suite("ByteRing")
struct ByteRingTests {
    @Test func roundsCapacityUpToPowerOfTwo() {
        #expect(ByteRing(capacity: 1).capacity == 4)
        #expect(ByteRing(capacity: 100).capacity == 128)
    }

    @Test func wrapsAroundWithoutCorruption() {
        var ring = ByteRing(capacity: 8)
        _ = Array("abcdef".utf8).withUnsafeBufferPointer { ring.write($0) }
        #expect(ring.consumeString(5) == "abcde")
        // head = 5, so the next 7 bytes span the physical end of storage
        let written = Array("ghijklm".utf8).withUnsafeBufferPointer { ring.write($0) }
        #expect(written == 7)
        #expect(ring.freeSpace == 0)
        #expect(ring.consumeString(8) == "fghijklm")
    }

    @Test func partialWriteWhenFull() {
        var ring = ByteRing(capacity: 4)
        let n = Array("abcdef".utf8).withUnsafeBufferPointer { ring.write($0) }
        #expect(n == 4)
    }

    @Test(arguments: [
        ([0x61, 0xF0, 0x9F], 3, 1),           // truncated 4-byte scalar → cut before lead
        ([0x61, 0xC3], 2, 1),                 // truncated 2-byte scalar
        ([0x61, 0xC3, 0xA9], 3, 3),           // complete "aé"
        ([0x80, 0x80, 0x80, 0x80, 0x80], 5, 5), // stray continuations → don't stall
        ([0x61, 0xFF], 2, 2),                 // invalid lead treated as standalone
    ] as [([UInt8], Int, Int)])
    func utf8Boundary(bytes: [UInt8], limit: Int, expected: Int) {
        var ring = ByteRing(capacity: 16)
        _ = bytes.withUnsafeBufferPointer { ring.write($0) }
        #expect(ring.utf8BoundaryLength(upTo: limit) == expected)
    }
}

@Suite("StreamBufferActor")
struct StreamBufferActorTests {

    // MARK: Coalescing

    @Test func coalescesManyAppendsIntoOneBatch() async throws {
        let buffer = StreamBufferActor()
        for i in 0..<100 { try await buffer.append("t\(i) ") }
        let batch = try #require(await buffer.drain(policy: loose))
        #expect(batch.text.hasPrefix("t0 t1 "))
        #expect(batch.text.hasSuffix("t99 "))
        #expect(batch.remainingBytes == 0)
        #expect(await buffer.drain(policy: loose) == nil)
        #expect(await buffer.metrics.flushes == 1)
    }

    @Test func acceptsDataAndSubstringUTF8() async throws {
        let buffer = StreamBufferActor()
        let s: Substring = "xxhelloxx".dropFirst(2).dropLast(2)
        try await buffer.append(s)
        try await buffer.append([UInt8](" world".utf8))
        #expect(await buffer.drain()?.text == "hello world")
    }

    // MARK: Split UTF-8 scalars

    @Test func holdsBackScalarSplitAcrossChunks() async throws {
        let buffer = StreamBufferActor()
        try await buffer.append([0x68, 0x69] + brain[0..<2])     // "hi" + first half of 🧠
        #expect(await buffer.drain()?.text == "hi")
        #expect(await buffer.drain() == nil)                    // only 2 dangling bytes
        #expect(await buffer.pendingByteCount == 2)
        try await buffer.append(Array(brain[2...]))
        #expect(await buffer.drain()?.text == "🧠")
    }

    @Test func scalarSplitAtEveryByteOffset() async throws {
        let text = "a€🧠é"
        let bytes = Array(text.utf8)
        for split in 0...bytes.count {
            let buffer = StreamBufferActor()
            var out = ""
            try await buffer.append(Array(bytes[..<split]))
            out += await buffer.drain()?.text ?? ""
            try await buffer.append(Array(bytes[split...]))
            out += await buffer.drain()?.text ?? ""
            #expect(out == text, "split at \(split)")
        }
    }

    @Test func scalarSplitAcrossPhysicalRingWrap() async throws {
        let buffer = StreamBufferActor(capacity: 8)
        try await buffer.append("abcdef")
        _ = await buffer.drain()                                // head at 6 (ring reset to 0 when empty)
        try await buffer.append("ab")
        _ = await buffer.drain()
        try await buffer.append("abcdef")
        #expect(await buffer.drain()?.text == "abcdef")         // head now mid-buffer
        try await buffer.append("é🧠")                           // 6 bytes straddling the wrap
        #expect(await buffer.drain()?.text == "é🧠")
    }

    @Test func budgetNeverCutsMidScalar() async throws {
        let buffer = StreamBufferActor()
        let policy = FlushPolicy(maxBytesPerFrame: 5, catchUpFrames: 1_000)
        try await buffer.append("ab🧠")                          // 6 bytes; budget 5 lands inside 🧠
        #expect(await buffer.drain(policy: policy)?.text == "ab")
        #expect(await buffer.drain(policy: policy)?.text == "🧠")
    }

    // MARK: Malformed input recovery

    @Test func repairsInvalidBytesInsteadOfStalling() async throws {
        let buffer = StreamBufferActor()
        try await buffer.append([0x61, 0xFF, 0x62] as [UInt8])
        #expect(await buffer.drain()?.text == "a\u{FFFD}b")
        try await buffer.append([0xE2, 0x41] as [UInt8])            // truncated lead then ASCII
        #expect(await buffer.drain()?.text == "\u{FFFD}A")
    }

    @Test func finishFlushesDanglingPartialAsReplacement() async throws {
        let buffer = StreamBufferActor()
        try await buffer.append(Array(brain[0..<2]))
        #expect(await buffer.drain() == nil)
        await buffer.finish()
        let batch = try #require(await buffer.drain())
        #expect(batch.text == "\u{FFFD}")
        #expect(batch.completion == .finished)
        #expect(await buffer.drain() == nil)
    }

    // MARK: Completion

    @Test func finishOnEmptyBufferYieldsEmptyFinalBatchOnce() async throws {
        let buffer = StreamBufferActor()
        try await buffer.append("done")
        #expect(await buffer.drain()?.isFinal == false)
        await buffer.finish()
        let final = try #require(await buffer.drain())
        #expect(final.text.isEmpty && final.completion == .finished)
        #expect(await buffer.drain() == nil)
    }

    @Test func appendAfterFinishThrows() async throws {
        let buffer = StreamBufferActor()
        await buffer.finish()
        await #expect(throws: StreamBufferError.finished) { try await buffer.append("late") }
    }

    @Test func cancelDiscardsAndYieldsCancelledBatch() async throws {
        let buffer = StreamBufferActor()
        try await buffer.append("discard me")
        await buffer.cancel()
        #expect(await buffer.drain()?.completion == .cancelled)
        #expect(await buffer.drain() == nil)
        await #expect(throws: CancellationError.self) { try await buffer.append("x") }
    }

    // MARK: Adaptive budget / backpressure spikes

    @Test func backlogDrainsWithinCatchUpFrames() async throws {
        let buffer = StreamBufferActor()
        let policy = FlushPolicy(maxBytesPerFrame: 4, catchUpFrames: 4)
        try await buffer.append(String(repeating: "x", count: 100))
        var frames = 0
        while await buffer.drain(policy: policy) != nil { frames += 1 }
        #expect(frames == 4)       // 100 bytes / 4 frames = 25 B/frame, held constant
        #expect(await buffer.pendingByteCount == 0)
    }

    @Test func producerSuspendsWhenFullAndResumesOnDrain() async throws {
        let buffer = StreamBufferActor(capacity: 16)
        let payload = (0..<200).map { "\($0 % 10)" }.joined()   // 200 bytes ≫ 16-byte ring
        let producer = Task { try await buffer.append(payload) }

        try await waitUntil { await buffer.metrics.producerSuspensions > 0 }
        #expect(await buffer.pendingByteCount == 16)

        var received = ""
        let policy = FlushPolicy(maxBytesPerFrame: 7, catchUpFrames: 1_000)
        while received.utf8.count < payload.utf8.count {
            if let batch = await buffer.drain(policy: policy) { received += batch.text }
            await Task.yield()
        }
        try await producer.value
        #expect(received == payload)
        #expect(await buffer.metrics.highWaterMark == 16)
    }

    @Test func cancellingSuspendedProducerThrowsCancellation() async throws {
        let buffer = StreamBufferActor(capacity: 4)
        let producer = Task { try await buffer.append("0123456789") }
        try await waitUntil { await buffer.metrics.producerSuspensions > 0 }
        producer.cancel()
        await #expect(throws: CancellationError.self) { try await producer.value }
        // Buffer is still usable for a fresh producer after draining.
        _ = await buffer.drain()
        try await buffer.append("ok")
        #expect(await buffer.drain()?.text == "ok")
    }

    @Test func bufferCancelWakesSuspendedProducer() async throws {
        let buffer = StreamBufferActor(capacity: 4)
        let producer = Task { try await buffer.append("0123456789") }
        try await waitUntil { await buffer.metrics.producerSuspensions > 0 }
        await buffer.cancel()
        await #expect(throws: CancellationError.self) { try await producer.value }
    }

    @Test func concurrentProducerIsRejected() async throws {
        let buffer = StreamBufferActor(capacity: 4)
        let first = Task { try await buffer.append("0123456789") }
        try await waitUntil { await buffer.metrics.producerSuspensions > 0 }
        await #expect(throws: StreamBufferError.concurrentProducer) { try await buffer.append("intruder") }
        first.cancel()
        _ = try? await first.value
    }

    // MARK: Wake signalling

    @Test func dataAvailableFiresOnceAfterIdleDrain() async throws {
        let buffer = StreamBufferActor()
        let counter = Counter()
        await buffer.setDataAvailableHandler { counter.increment() }

        try await buffer.append("a")                // consumer never idle yet → no signal
        #expect(counter.value == 0)
        _ = await buffer.drain()
        _ = await buffer.drain()                    // idle
        try await buffer.append("b")
        try await buffer.append("c")                // already signalled → no duplicate
        #expect(counter.value == 1)
    }

    @Test func dataAvailableFiresWhenPartialScalarCompletes() async throws {
        let buffer = StreamBufferActor()
        let counter = Counter()
        await buffer.setDataAvailableHandler { counter.increment() }
        try await buffer.append(Array(brain[0..<2]))
        #expect(await buffer.drain() == nil)        // non-empty, but nothing renderable → idle
        try await buffer.append(Array(brain[2...]))
        #expect(counter.value == 1)                 // regression: must not stall a paused display link
    }
}
