/// Splits a byte stream into JSONL lines and decodes each one into an ``A2UIMessage``.
///
/// Feed it bytes in any chunking, for example straight from `URLSession.bytes(for:)`. A partial
/// last line is held until its newline arrives, so a message never applies half-received. A bad
/// line yields a failure and decoding continues with the next line.
public struct A2UILineDecoder: Sendable {
    public typealias Output = Result<A2UIMessage, A2UIDecodingError>

    /// Lines longer than this are dropped, which caps memory on a runaway stream.
    public let maxLineBytes: Int
    private var partial: [UInt8] = []
    private var discarding = false
    private var discardedBytes = 0

    public init(maxLineBytes: Int = 4 << 20) {
        self.maxLineBytes = maxLineBytes
    }

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [Output] {
        var out: [Output] = []
        for byte in bytes {
            if byte == UInt8(ascii: "\n") {
                if discarding {
                    out.append(.failure(.lineTooLong(bytes: discardedBytes)))
                    discarding = false
                    discardedBytes = 0
                } else {
                    emitLine(into: &out)
                }
                partial.removeAll(keepingCapacity: true)
            } else if discarding {
                discardedBytes += 1
            } else if partial.count >= maxLineBytes {
                discarding = true
                discardedBytes = partial.count + 1
                partial.removeAll()
            } else {
                partial.append(byte)
            }
        }
        return out
    }

    /// Decodes a final line that had no trailing newline.
    public mutating func finish() -> [Output] {
        var out: [Output] = []
        if discarding {
            out.append(.failure(.lineTooLong(bytes: discardedBytes)))
        } else {
            emitLine(into: &out)
        }
        partial.removeAll()
        discarding = false
        discardedBytes = 0
        return out
    }

    private func emitLine(into out: inout [Output]) {
        var line = partial[...]
        while let last = line.last, last == UInt8(ascii: "\r") || last == UInt8(ascii: " ") || last == UInt8(ascii: "\t") {
            line = line.dropLast()
        }
        while let first = line.first, first == UInt8(ascii: " ") || first == UInt8(ascii: "\t") {
            line = line.dropFirst()
        }
        guard !line.isEmpty else { return }
        do { out.append(.success(try A2UIMessage.decode(line: line))) } catch { out.append(.failure(error)) }
    }
}
