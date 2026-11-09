/// A block-level channel inside a streamed response. Text outside any block is prose.
public enum BlockKind: Sendable, Hashable {
    case thinking
    case toolCall
    case codeFence(language: String)
}

/// One step of the demuxed stream.
///
/// The `text` events between an `open` and its matching `close` belong to that block. All
/// other text is prose. Concatenating every `text` event reproduces the input, minus the
/// tags and fence lines themselves.
public enum ParseEvent: Sendable, Equatable {
    case open(BlockKind)
    /// A slice of the chunk passed to `feed`, or a small flushed holdback. Not copied.
    case text(Substring)
    /// Emitted right before `.close(.toolCall, …)`. Has the full JSON payload, plus a
    /// structural check (balanced brackets, no unterminated string). It doesn't fully
    /// validate the JSON. The consumer still decodes it.
    case toolCallPayload(json: String, isStructurallyComplete: Bool)
    /// `recovered == true` means the block was closed by error recovery, not by its own
    /// closing token: either at `finish()`, or for a fence left open when `</thinking>` arrives.
    case close(BlockKind, recovered: Bool)
}

public struct ParserConfiguration: Sendable, Equatable {
    /// Tag names for in-band blocks. They're matched literally as `<name>` and `</name>`.
    public var thinkingTag: String
    public var toolCallTag: String
    public var recognizesCodeFences: Bool
    /// If an opening fence's info line (e.g. "swift") grows past this, the line is treated as prose.
    public var maxFenceInfoBytes: Int

    public init(
        thinkingTag: String = "thinking",
        toolCallTag: String = "tool_call",
        recognizesCodeFences: Bool = true,
        maxFenceInfoBytes: Int = 64
    ) {
        precondition(thinkingTag != toolCallTag, "Tag names must differ")
        for name in [thinkingTag, toolCallTag] {
            precondition(!name.isEmpty && name.utf8.allSatisfy(Self.isTagNameByte), "Tag names must be ASCII [A-Za-z0-9_-]")
        }
        precondition(maxFenceInfoBytes > 0)
        self.thinkingTag = thinkingTag
        self.toolCallTag = toolCallTag
        self.recognizesCodeFences = recognizesCodeFences
        self.maxFenceInfoBytes = maxFenceInfoBytes
    }

    private static func isTagNameByte(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || b == 0x5F || b == 0x2D
    }
}

/// A single-pass, incremental demuxer for LLM text streams.
///
/// Feed it each frame's text delta, in order. It never re-scans earlier input. When a delta
/// ends partway through a tag or fence line, those bytes are held back until the next delta
/// resolves them. Holdback is capped at the longest tag or `maxFenceInfoBytes`.
///
/// It's a value type with no locks. Own it from one isolation domain, which is typically the
/// main actor inside `DisplayLinkCoordinator`'s flush handler.
public struct StreamParser: Sendable {

    // MARK: Public API

    public init(configuration: ParserConfiguration = ParserConfiguration()) {
        self.configuration = configuration
        let open = { (name: String) in Array("<\(name)>".utf8) }
        let close = { (name: String) in Array("</\(name)>".utf8) }
        tags = [
            open(configuration.thinkingTag), close(configuration.thinkingTag),
            open(configuration.toolCallTag), close(configuration.toolCallTag),
        ]
        stack.reserveCapacity(4)
        pending.reserveCapacity(16)
    }

    /// The innermost open block, or `nil` for prose.
    public var currentBlock: BlockKind? {
        switch stack.last! {
        case .prose: nil
        case .thinking: .thinking
        case .toolCall: .toolCall
        case .code(let fence): .codeFence(language: fence.language)
        }
    }

    /// Bytes currently held back, waiting for the next chunk to decide what they are.
    public var heldBackByteCount: Int { pending.count }

    /// Parses one delta and delivers events through `emit`. This path allocates nothing,
    /// apart from tool-call payload accumulation and fence language strings.
    public mutating func feed(_ chunk: String, emit: (ParseEvent) -> Void) {
        precondition(!isFinished, "feed(_:) after finish()")
        let utf8 = chunk.utf8
        var runStart: String.Index?
        var i = utf8.startIndex
        while i < utf8.endIndex {
            if process(utf8[i], at: i, in: chunk, runStart: &runStart, emit: emit) {
                utf8.formIndex(after: &i)
            }
        }
        emitRun(upTo: chunk.endIndex, in: chunk, runStart: &runStart, emit: emit)
    }

    /// Ends the stream. Resolves any held-back bytes, then closes the blocks still open,
    /// innermost first, with `recovered: true`.
    public mutating func finish(emit: (ParseEvent) -> Void) {
        guard !isFinished else { return }
        isFinished = true

        switch scan {
        case .fenceCloseTail:
            closeFence(recovered: false, emit: emit)
        case .fenceRun(let marker, let count):
            if case .code(let fence) = stack.last!, marker == fence.marker, count >= fence.length {
                closeFence(recovered: false, emit: emit)   // closing fence with no trailing newline
            } else {
                flushPendingAsText(emit: emit)
            }
        default:
            flushPendingAsText(emit: emit)
        }

        while stack.count > 1 {
            closeInnermost(recovered: true, emit: emit)
        }
    }

    public mutating func feed(_ chunk: String) -> [ParseEvent] {
        var events: [ParseEvent] = []
        feed(chunk) { events.append($0) }
        return events
    }

    public mutating func finish() -> [ParseEvent] {
        var events: [ParseEvent] = []
        finish { events.append($0) }
        return events
    }

    // MARK: State

    private enum Context: Sendable {
        case prose, thinking, toolCall, code(Fence)
    }

    private struct Fence: Sendable {
        let marker: UInt8
        let length: Int
        let language: String
        let insideThinking: Bool
    }

    private enum Scan: Sendable {
        case normal
        /// At line start, consumed 1–3 spaces; a fence or a line-start tag may follow.
        case lineIndent(spaces: Int)
        /// Matching a tag prefix. `candidates` is a bitmask over `tags`.
        case tag(matched: Int, candidates: UInt8)
        case fenceRun(marker: UInt8, count: Int)
        /// Opening fence seen; accumulating its info string until newline.
        case fenceInfo(marker: UInt8, count: Int, infoStart: Int)
        /// Closing fence seen; only spaces or tabs may follow before the newline.
        case fenceCloseTail
    }

    private static let openThinking: UInt8 = 1 << 0
    private static let closeThinking: UInt8 = 1 << 1
    private static let openTool: UInt8 = 1 << 2
    private static let closeTool: UInt8 = 1 << 3

    private let configuration: ParserConfiguration
    private let tags: [[UInt8]]
    private var stack: [Context] = [.prose]
    private var scan = Scan.normal
    private var pending: [UInt8] = []
    private var atLineStart = true
    private var json = JSONStructureScanner()
    private var toolPayload = ""
    private var isFinished = false

    // MARK: Byte processing

    /// Returns `false` when `byte` must be processed again, because it broke a holdback
    /// match and now has to be read in the `.normal` state.
    private mutating func process(
        _ byte: UInt8,
        at index: String.Index,
        in chunk: String,
        runStart: inout String.Index?,
        emit: (ParseEvent) -> Void
    ) -> Bool {
        switch scan {
        case .normal:
            if atLineStart && fencesAllowed {
                if byte == .space {
                    beginHoldback(byte, at: index, in: chunk, runStart: &runStart, emit: emit)
                    scan = .lineIndent(spaces: 1)
                    return true
                }
                if byte == .backtick || byte == .tilde {
                    beginHoldback(byte, at: index, in: chunk, runStart: &runStart, emit: emit)
                    scan = .fenceRun(marker: byte, count: 1)
                    return true
                }
            }
            if byte == .lessThan {
                let mask = tagCandidates(atLineStart: atLineStart)
                if mask != 0 {
                    beginHoldback(byte, at: index, in: chunk, runStart: &runStart, emit: emit)
                    scan = .tag(matched: 1, candidates: mask)
                    return true
                }
            }
            // An ordinary byte. It extends the current zero-copy text run.
            if runStart == nil { runStart = index }
            if case .toolCall = stack.last! { json.consume(byte) }
            atLineStart = byte == .newline
            return true

        case .lineIndent(let spaces):
            if byte == .space && spaces < 3 {
                pending.append(byte)
                scan = .lineIndent(spaces: spaces + 1)
                return true
            }
            if byte == .backtick || byte == .tilde {
                pending.append(byte)
                scan = .fenceRun(marker: byte, count: 1)
                return true
            }
            if byte == .lessThan {
                let mask = tagCandidates(atLineStart: true)
                if mask != 0 {
                    pending.append(byte)
                    scan = .tag(matched: 1, candidates: mask)
                    return true
                }
            }
            flushPendingAsText(emit: emit)
            return false

        case .tag(let matched, let candidates):
            var next: UInt8 = 0
            for t in 0..<tags.count where candidates & (1 << t) != 0 {
                let literal = tags[t]
                if matched < literal.count && literal[matched] == byte { next |= 1 << t }
            }
            guard next != 0 else {
                flushPendingAsText(emit: emit)
                return false
            }
            pending.append(byte)
            for t in 0..<tags.count where next & (1 << t) != 0 && tags[t].count == matched + 1 {
                pending.removeAll(keepingCapacity: true)
                scan = .normal
                atLineStart = false
                performTag(UInt8(1) << t, emit: emit)
                return true
            }
            scan = .tag(matched: matched + 1, candidates: next)
            return true

        case .fenceRun(let marker, let count):
            if byte == marker {
                pending.append(byte)
                scan = .fenceRun(marker: marker, count: count + 1)
                return true
            }
            guard count >= 3 else {
                flushPendingAsText(emit: emit)
                return false
            }
            if case .code(let fence) = stack.last! {
                // Inside code, the only fence that counts is a matching closer.
                guard marker == fence.marker, count >= fence.length else {
                    flushPendingAsText(emit: emit)
                    return false
                }
                if byte == .space || byte == .tab {
                    pending.append(byte)
                    scan = .fenceCloseTail
                    return true
                }
                if byte == .newline {
                    closeFence(recovered: false, emit: emit)
                    return true
                }
                flushPendingAsText(emit: emit)
                return false
            }
            if byte == .newline {
                openFence(marker: marker, length: count, language: "", emit: emit)
                return true
            }
            pending.append(byte)
            scan = .fenceInfo(marker: marker, count: count, infoStart: pending.count - 1)
            return true

        case .fenceInfo(let marker, let count, let infoStart):
            if byte == .newline {
                let language = Self.firstWord(of: pending[infoStart...])
                openFence(marker: marker, length: count, language: language, emit: emit)
                return true
            }
            // CommonMark: a backtick fence's info string can't contain backticks.
            if (marker == .backtick && byte == .backtick) || pending.count - infoStart >= configuration.maxFenceInfoBytes {
                flushPendingAsText(emit: emit)
                return false
            }
            pending.append(byte)
            return true

        case .fenceCloseTail:
            if byte == .space || byte == .tab {
                pending.append(byte)
                return true
            }
            if byte == .newline {
                closeFence(recovered: false, emit: emit)
                return true
            }
            flushPendingAsText(emit: emit)
            return false
        }
    }

    private var fencesAllowed: Bool {
        guard configuration.recognizesCodeFences else { return false }
        if case .toolCall = stack.last! { return false }
        return true
    }

    /// The tags that can be recognized in the current context.
    private func tagCandidates(atLineStart: Bool) -> UInt8 {
        switch stack.last! {
        case .prose: Self.openThinking | Self.openTool
        case .thinking: Self.closeThinking
        case .toolCall: json.inString ? 0 : Self.closeTool
        case .code(let fence): (fence.insideThinking && atLineStart) ? Self.closeThinking : 0
        }
    }

    // MARK: Actions

    private mutating func performTag(_ tag: UInt8, emit: (ParseEvent) -> Void) {
        switch tag {
        case Self.openThinking:
            stack.append(.thinking)
            emit(.open(.thinking))
        case Self.closeThinking:
            if case .code = stack.last! {
                closeInnermost(recovered: true, emit: emit)   // the model forgot to close the fence
            }
            closeInnermost(recovered: false, emit: emit)
        case Self.openTool:
            stack.append(.toolCall)
            json = JSONStructureScanner()
            toolPayload = ""
            emit(.open(.toolCall))
        case Self.closeTool:
            closeInnermost(recovered: false, emit: emit)
        default:
            preconditionFailure("unknown tag bit \(tag)")
        }
    }

    private mutating func openFence(marker: UInt8, length: Int, language: String, emit: (ParseEvent) -> Void) {
        pending.removeAll(keepingCapacity: true)
        scan = .normal
        var insideThinking = false
        if case .thinking = stack.last! { insideThinking = true }
        stack.append(.code(Fence(marker: marker, length: length, language: language, insideThinking: insideThinking)))
        atLineStart = true
        emit(.open(.codeFence(language: language)))
    }

    private mutating func closeFence(recovered: Bool, emit: (ParseEvent) -> Void) {
        pending.removeAll(keepingCapacity: true)
        scan = .normal
        atLineStart = true
        closeInnermost(recovered: recovered, emit: emit)
    }

    private mutating func closeInnermost(recovered: Bool, emit: (ParseEvent) -> Void) {
        precondition(stack.count > 1, "cannot close the prose root")
        switch stack.removeLast() {
        case .prose:
            preconditionFailure("unreachable")
        case .thinking:
            emit(.close(.thinking, recovered: recovered))
        case .toolCall:
            emit(.toolCallPayload(json: toolPayload, isStructurallyComplete: json.isStructurallyComplete))
            toolPayload = ""
            emit(.close(.toolCall, recovered: recovered))
        case .code(let fence):
            emit(.close(.codeFence(language: fence.language), recovered: recovered))
        }
    }

    // MARK: Text emission

    private mutating func beginHoldback(
        _ byte: UInt8,
        at index: String.Index,
        in chunk: String,
        runStart: inout String.Index?,
        emit: (ParseEvent) -> Void
    ) {
        emitRun(upTo: index, in: chunk, runStart: &runStart, emit: emit)
        pending.removeAll(keepingCapacity: true)
        pending.append(byte)
    }

    /// Run boundaries always sit on ASCII bytes or chunk edges, so they're valid scalar
    /// boundaries and slicing is safe.
    private mutating func emitRun(
        upTo end: String.Index,
        in chunk: String,
        runStart: inout String.Index?,
        emit: (ParseEvent) -> Void
    ) {
        guard let start = runStart else { return }
        runStart = nil
        if start < end { emitText(chunk[start..<end], emit: emit) }
    }

    /// A false alarm. The held-back bytes were ordinary text after all.
    private mutating func flushPendingAsText(emit: (ParseEvent) -> Void) {
        scan = .normal
        guard !pending.isEmpty else { return }
        if case .toolCall = stack.last! {
            for byte in pending { json.consume(byte) }
        }
        // Holdbacks of 15 bytes or fewer (every tag literal) fit in Swift's inline
        // small-string storage, so this doesn't allocate on the heap.
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        atLineStart = false
        emitText(text[...], emit: emit)
    }

    private mutating func emitText(_ text: Substring, emit: (ParseEvent) -> Void) {
        if case .toolCall = stack.last! { toolPayload.append(contentsOf: text) }
        emit(.text(text))
    }

    private static func firstWord(of info: ArraySlice<UInt8>) -> String {
        let trimmed = info.drop(while: { $0 == .space || $0 == .tab })
        let word = trimmed.prefix(while: { $0 != .space && $0 != .tab && $0 != .carriageReturn })
        return String(decoding: word, as: UTF8.self)
    }
}

/// Tracks enough JSON structure to know (a) whether `</tool_call>` is inside a string
/// literal, and (b) whether the payload looks complete.
struct JSONStructureScanner: Sendable {
    private(set) var depth = 0
    private(set) var inString = false
    private var escaped = false
    private var malformed = false
    private var sawValue = false

    mutating func consume(_ byte: UInt8) {
        if inString {
            if escaped { escaped = false }
            else if byte == .backslash { escaped = true }
            else if byte == .quote { inString = false }
            return
        }
        switch byte {
        case .quote:
            inString = true
            sawValue = true
        case .openBrace, .openBracket:
            depth += 1
            sawValue = true
        case .closeBrace, .closeBracket:
            depth -= 1
            if depth < 0 { malformed = true; depth = 0 }
        case .space, .tab, .newline, .carriageReturn:
            break
        default:
            sawValue = true
        }
    }

    var isStructurallyComplete: Bool { sawValue && depth == 0 && !inString && !malformed }
}

private extension UInt8 {
    static let tab: UInt8 = 0x09
    static let newline: UInt8 = 0x0A
    static let carriageReturn: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let quote: UInt8 = 0x22
    static let lessThan: UInt8 = 0x3C
    static let openBracket: UInt8 = 0x5B
    static let backslash: UInt8 = 0x5C
    static let closeBracket: UInt8 = 0x5D
    static let backtick: UInt8 = 0x60
    static let openBrace: UInt8 = 0x7B
    static let closeBrace: UInt8 = 0x7D
    static let tilde: UInt8 = 0x7E
}
