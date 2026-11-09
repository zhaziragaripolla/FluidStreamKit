/// A fixed-capacity FIFO of raw UTF-8 bytes.
///
/// - Storage is allocated once, at init. It never grows or reallocates while streaming.
/// - Writes and reads copy with `memcpy`, using at most two segments to cover wraparound.
/// - Not thread-safe by design. `StreamBufferActor` owns the only instance, and actor
///   isolation provides the exclusion.
struct ByteRing: Sendable {
    private var storage: [UInt8]
    private var head = 0
    private(set) var count = 0
    private let mask: Int

    var capacity: Int { storage.count }
    var freeSpace: Int { capacity - count }
    var isEmpty: Bool { count == 0 }

    /// Rounds `requestedCapacity` up to a power of two, so indexing can use a bit mask.
    /// The minimum is 4 bytes, enough to hold the longest UTF-8 scalar.
    init(capacity requestedCapacity: Int) {
        precondition(requestedCapacity > 0, "ByteRing capacity must be positive")
        var cap = 4
        while cap < requestedCapacity { cap <<= 1 }
        storage = [UInt8](repeating: 0, count: cap)
        mask = cap - 1
    }

    /// Copies up to `freeSpace` bytes from `source`. Returns how many bytes were written.
    mutating func write(_ source: UnsafeBufferPointer<UInt8>) -> Int {
        let n = Swift.min(source.count, freeSpace)
        guard n > 0, let src = source.baseAddress else { return 0 }
        let tail = (head + count) & mask
        let firstSegment = Swift.min(n, capacity - tail)
        storage.withUnsafeMutableBufferPointer { dst in
            let base = dst.baseAddress!
            (base + tail).update(from: src, count: firstSegment)
            if n > firstSegment {
                base.update(from: src + firstSegment, count: n - firstSegment)
            }
        }
        count += n
        return n
    }

    /// Returns the byte at logical `offset` from the read head, without consuming it.
    subscript(offset: Int) -> UInt8 {
        storage[(head + offset) & mask]
    }

    /// Returns the largest length `<= limit` that doesn't end partway through a UTF-8 scalar.
    ///
    /// It looks back at most 3 bytes to find the last lead byte. If that lead byte's sequence
    /// would extend past `limit`, the cut moves to just before the lead byte. A run of stray
    /// continuation bytes with no lead byte is malformed input. In that case the method
    /// returns `limit` unchanged, so decoding repairs the bytes to U+FFFD rather than stalling.
    func utf8BoundaryLength(upTo limit: Int) -> Int {
        precondition(limit <= count)
        guard limit > 0 else { return 0 }
        var i = limit - 1
        let lowestScan = Swift.max(0, limit - 4)
        while i >= lowestScan {
            let byte = self[i]
            if byte & 0b1100_0000 != 0b1000_0000 {           // not a continuation byte
                let expected = Self.sequenceLength(lead: byte)
                return i + expected > limit ? i : limit
            }
            i -= 1
        }
        return limit
    }

    /// Removes the first `n` bytes and decodes them as a `String`.
    ///
    /// `String(unsafeUninitializedCapacity:initializingUTF8With:)` validates the bytes and
    /// replaces invalid sequences with U+FFFD. Strings of 15 bytes or fewer are stored inline
    /// and don't allocate on the heap.
    mutating func consumeString(_ n: Int) -> String {
        precondition(n >= 0 && n <= count)
        guard n > 0 else { return "" }
        let start = head
        let firstSegment = Swift.min(n, capacity - start)
        let text = storage.withUnsafeBufferPointer { src in
            String(unsafeUninitializedCapacity: n) { out in
                let o = out.baseAddress!, s = src.baseAddress!
                o.update(from: s + start, count: firstSegment)
                if n > firstSegment {
                    (o + firstSegment).update(from: s, count: n - firstSegment)
                }
                return n
            }
        }
        head = (head + n) & mask
        count -= n
        if count == 0 { head = 0 }   // keeps later writes contiguous, so they copy in one segment
        return text
    }

    mutating func removeAll() {
        head = 0
        count = 0
    }

    @inline(__always)
    static func sequenceLength(lead: UInt8) -> Int {
        switch lead {
        case 0x00...0x7F: 1
        case 0xC2...0xDF: 2
        case 0xE0...0xEF: 3
        case 0xF0...0xF4: 4
        default: 1  // invalid lead byte (0x80–0xC1, 0xF5–0xFF): treat as standalone; decoding will repair it
        }
    }
}
