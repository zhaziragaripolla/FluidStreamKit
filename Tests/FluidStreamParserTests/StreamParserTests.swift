import Testing
@testable import FluidStreamParser

// MARK: - Helpers

/// Events with adjacent text merged, so expectations don't depend on how input was chunked.
enum E: Equatable, CustomStringConvertible {
    case open(BlockKind)
    case text(String)
    case payload(String, complete: Bool)
    case close(BlockKind, recovered: Bool)

    var description: String {
        switch self {
        case .open(let k): "open(\(k))"
        case .text(let s): "text(\(s.debugDescription))"
        case .payload(let s, let c): "payload(\(s.debugDescription), complete: \(c))"
        case .close(let k, let r): "close(\(k)\(r ? ", recovered" : ""))"
        }
    }
}

func parse(_ chunks: [String], configuration: ParserConfiguration = ParserConfiguration()) -> [E] {
    var parser = StreamParser(configuration: configuration)
    var out: [E] = []
    let sink: (ParseEvent) -> Void = { event in
        switch event {
        case .text(let s):
            guard !s.isEmpty else { Issue.record("empty text event"); return }
            if case .text(let prev) = out.last { out[out.count - 1] = .text(prev + s) } else { out.append(.text(String(s))) }
        case .open(let k): out.append(.open(k))
        case .close(let k, let r): out.append(.close(k, recovered: r))
        case .toolCallPayload(let j, let c): out.append(.payload(j, complete: c))
        }
    }
    for chunk in chunks { parser.feed(chunk, emit: sink) }
    parser.finish(emit: sink)
    return out
}

func parse(_ text: String) -> [E] { parse([text]) }

/// Every way of cutting `text` into two chunks at a Unicode scalar boundary. RFC-001
/// guarantees chunks never split a scalar.
func everyTwoWaySplit(_ text: String) -> [[String]] {
    let scalars = Array(text.unicodeScalars)
    return (0...scalars.count).map { k in
        [String(String.UnicodeScalarView(scalars[..<k])), String(String.UnicodeScalarView(scalars[k...]))]
    }
}

func oneScalarPerChunk(_ text: String) -> [String] {
    text.unicodeScalars.map { String($0) }
}

func randomSplit(_ text: String, using rng: inout SplitMix64) -> [String] {
    let scalars = Array(text.unicodeScalars)
    var chunks: [String] = []
    var i = 0
    while i < scalars.count {
        let n = Int(rng.next() % 6) + 1
        let end = min(scalars.count, i + n)
        chunks.append(String(String.UnicodeScalarView(scalars[i..<end])))
        i = end
    }
    return chunks
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

let corpus: [String] = [
    "Hello <thinking>plan</thinking> world",
    "<thinking>\n```swift\nlet x = 1\n```\n</thinking>done",
    #"Call: <tool_call>{"q":"</tool_call> in a string","esc":"\"</tool_call>"}</tool_call> after"#,
    "```python\nprint('<thinking>')\n```\ntext",
    "a < b, <thin is not a tag, <thinkingX> neither, << either",
    "  ```js\ncode\n   ```  \nafter",
    "~~~\nhas ``` inside\n~~~\n",
    "````\n```\nnested-looking\n````\n",
    "🧠 <thinking>思考 é</thinking> ✅",
    "<thinking>\n```\nforgot to close\n</thinking>\nprose",
    "``inline`` and ```info with ` backtick\nstill prose",
    "<tool_call>\n```\nnot a fence in JSON\n```\n</tool_call>",
    "    ```\nfour spaces is not a fence\n",
    "```\nunclosed code at end",
    "```\ncode\n```",
    "<thinking>never closed",
]

// MARK: - Chunking invariance (the core property)

@Suite("Chunking invariance")
struct ChunkingInvarianceTests {
    @Test(arguments: corpus)
    func everyTwoWaySplitMatchesWholeParse(_ text: String) {
        let expected = parse(text)
        for chunks in everyTwoWaySplit(text) {
            #expect(parse(chunks) == expected, "split: \(chunks.map(\.debugDescription))")
        }
    }

    @Test(arguments: corpus)
    func oneScalarAtATimeMatchesWholeParse(_ text: String) {
        #expect(parse(oneScalarPerChunk(text)) == parse(text))
    }

    @Test func fuzzedDocumentsAreChunkingInvariant() {
        let fragments = ["<", ">", "/", "thinking", "tool_call", "`", "```", "~~~", "\n", " ", "a", "é", "🧠", "{", "}", "\"", "\\", "</thinking>", "<thinking>", "<tool_call>", "</tool_call>"]
        var rng = SplitMix64(state: 0xF1D)
        for _ in 0..<400 {
            let length = Int(rng.next() % 40)
            let doc = (0..<length).map { _ in fragments[Int(rng.next() % UInt64(fragments.count))] }.joined()
            let expected = parse(doc)
            #expect(parse(randomSplit(doc, using: &rng)) == expected, "doc: \(doc.debugDescription)")
            #expect(parse(oneScalarPerChunk(doc)) == expected, "doc: \(doc.debugDescription)")
        }
    }

    @Test func plainProseRoundTripsExactly() {
        var rng = SplitMix64(state: 42)
        let alphabet = Array("ab <>/`~ é\n{}\"")
        for _ in 0..<200 {
            let doc = String((0..<Int(rng.next() % 60)).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
            // Without tags or line-start fences, every byte must come back as prose, unchanged.
            guard !doc.contains("<thinking>"), !doc.contains("<tool_call>"),
                  !doc.split(separator: "\n", omittingEmptySubsequences: false).contains(where: {
                      let t = $0.drop(while: { $0 == " " }); return t.hasPrefix("```") || t.hasPrefix("~~~")
                  })
            else { continue }
            let events = parse(randomSplit(doc, using: &rng))
            #expect(events == (doc.isEmpty ? [] : [.text(doc)]), "doc: \(doc.debugDescription)")
        }
    }
}

// MARK: - Split tags

@Suite("Split tags")
struct SplitTagTests {
    @Test func tagSplitAcrossThreeChunksNeverLeaksPartialTag() {
        var parser = StreamParser()
        let first = parser.feed("Hello <thin")
        #expect(first == [.text("Hello ")])            // "<thin" held back, not shown
        #expect(parser.heldBackByteCount == 5)
        let second = parser.feed("king>plan</thi")
        #expect(second == [.open(.thinking), .text("plan")])
        let third = parser.feed("nking> world")
        #expect(third == [.close(.thinking, recovered: false), .text(" world")])
        #expect(parser.finish().isEmpty)
    }

    @Test func falseAlarmIsFlushedAsText() {
        #expect(parse(["a <thi", "nx"]) == [.text("a <thinx")])
    }

    @Test func truncatedTagAtEndOfStreamBecomesText() {
        #expect(parse(["x <thin"]) == [.text("x <thin")])
    }

    @Test func lessThanBeforeRealTag() {
        #expect(parse("<<thinking>a</thinking>") == [
            .text("<"), .open(.thinking), .text("a"), .close(.thinking, recovered: false),
        ])
    }

    @Test func toolCallTagIsLiteralInsideThinking() {
        #expect(parse("<thinking><tool_call>x</thinking>") == [
            .open(.thinking), .text("<tool_call>x"), .close(.thinking, recovered: false),
        ])
    }

    @Test func customTagNames() {
        let config = ParserConfiguration(thinkingTag: "reasoning", toolCallTag: "invoke")
        #expect(parse(["<reas", "oning>r</reasoning><thinking>"], configuration: config) == [
            .open(.thinking), .text("r"), .close(.thinking, recovered: false), .text("<thinking>"),
        ])
    }
}

// MARK: - Code fences

@Suite("Code fences")
struct CodeFenceTests {
    @Test func fenceWithLanguage() {
        #expect(parse("```swift\nlet a = 1\n```\nafter") == [
            .open(.codeFence(language: "swift")), .text("let a = 1\n"),
            .close(.codeFence(language: "swift"), recovered: false), .text("after"),
        ])
    }

    @Test func fenceSplitAcrossChunks() {
        #expect(parse(["``", "`sw", "ift extra\nx\n`", "``\n"]) == [
            .open(.codeFence(language: "swift")), .text("x\n"),
            .close(.codeFence(language: "swift"), recovered: false),
        ])
    }

    @Test func tagsAreLiteralInsideCode() {
        #expect(parse("```\n<thinking>not a block</thinking>\n```\n") == [
            .open(.codeFence(language: "")), .text("<thinking>not a block</thinking>\n"),
            .close(.codeFence(language: ""), recovered: false),
        ])
    }

    @Test func closerMustMatchMarkerAndLength() {
        #expect(parse("````\n```\n~~~~\n````\n") == [
            .open(.codeFence(language: "")), .text("```\n~~~~\n"),
            .close(.codeFence(language: ""), recovered: false),
        ])
    }

    @Test func fenceOnlyAtLineStart() {
        #expect(parse("text ```swift\nmore") == [.text("text ```swift\nmore")])
    }

    @Test func fourSpaceIndentIsNotAFence() {
        #expect(parse("    ```\nx") == [.text("    ```\nx")])
    }

    @Test func backtickInInfoStringIsNotAFence() {
        #expect(parse("```a`b\nx") == [.text("```a`b\nx")])
    }

    @Test func overlongInfoStringIsNotAFence() {
        let info = String(repeating: "x", count: 100)
        #expect(parse("```\(info)\ny") == [.text("```\(info)\ny")])
    }

    @Test func closingFenceAtEndOfStreamWithoutNewline() {
        #expect(parse(["```\ncode\n``", "`"]) == [
            .open(.codeFence(language: "")), .text("code\n"),
            .close(.codeFence(language: ""), recovered: false),
        ])
    }

    @Test func unclosedFenceIsRecoveredAtFinish() {
        #expect(parse("```py\nprint()") == [
            .open(.codeFence(language: "py")), .text("print()"),
            .close(.codeFence(language: "py"), recovered: true),
        ])
    }

    @Test func fenceInsideThinking() {
        #expect(parse("<thinking>\n```\nx\n```\n</thinking>") == [
            .open(.thinking), .text("\n"), .open(.codeFence(language: "")), .text("x\n"),
            .close(.codeFence(language: ""), recovered: false), .close(.thinking, recovered: false),
        ])
    }

    @Test func forgottenFenceIsClosedByThinkingEnd() {
        #expect(parse("<thinking>\n```\nx\n</thinking>\nprose") == [
            .open(.thinking), .text("\n"), .open(.codeFence(language: "")), .text("x\n"),
            .close(.codeFence(language: ""), recovered: true), .close(.thinking, recovered: false),
            .text("\nprose"),
        ])
    }

    @Test func thinkingCloseMidLineInCodeIsLiteral() {
        #expect(parse("<thinking>\n```\nlet s = \"</thinking>\"\n```\n</thinking>") == [
            .open(.thinking), .text("\n"), .open(.codeFence(language: "")),
            .text("let s = \"</thinking>\"\n"),
            .close(.codeFence(language: ""), recovered: false), .close(.thinking, recovered: false),
        ])
    }

    @Test func fencesCanBeDisabled() {
        let config = ParserConfiguration(recognizesCodeFences: false)
        #expect(parse(["```\nx\n```"], configuration: config) == [.text("```\nx\n```")])
    }
}

// MARK: - Tool calls

@Suite("Tool calls")
struct ToolCallTests {
    @Test func payloadIsAccumulatedAndComplete() {
        let json = #"{"name":"search","input":{"q":"swift"}}"#
        #expect(parse(["<tool_call>", String(json.prefix(10)), String(json.dropFirst(10)), "</tool_call>"]) == [
            .open(.toolCall), .text(json), .payload(json, complete: true), .close(.toolCall, recovered: false),
        ])
    }

    @Test func closeTagInsideJSONStringDoesNotClose() {
        let json = #"{"q":"</tool_call>","e":"\"</tool_call>\\"}"#
        #expect(parse("<tool_call>\(json)</tool_call>x") == [
            .open(.toolCall), .text(json), .payload(json, complete: true),
            .close(.toolCall, recovered: false), .text("x"),
        ])
    }

    @Test func unbalancedPayloadIsFlaggedIncomplete() {
        #expect(parse(#"<tool_call>{"a":1</tool_call>"#) == [
            .open(.toolCall), .text(#"{"a":1"#), .payload(#"{"a":1"#, complete: false), .close(.toolCall, recovered: false),
        ])
    }

    @Test func emptyPayloadIsIncomplete() {
        #expect(parse("<tool_call> \n</tool_call>") == [
            .open(.toolCall), .text(" \n"), .payload(" \n", complete: false), .close(.toolCall, recovered: false),
        ])
    }

    @Test func truncatedToolCallIsRecoveredAtFinish() {
        #expect(parse(#"<tool_call>{"q":"unterminated"#) == [
            .open(.toolCall), .text(#"{"q":"unterminated"#),
            .payload(#"{"q":"unterminated"#, complete: false), .close(.toolCall, recovered: true),
        ])
    }

    @Test func secondToolCallStartsWithFreshState() {
        let events = parse(#"<tool_call>{"a":"</tool_call>"#)   // unterminated string swallows the close
        #expect(events.last == .close(.toolCall, recovered: true))
        #expect(parse(#"<tool_call>[1]</tool_call><tool_call>{}</tool_call>"#).filter {
            if case .payload = $0 { true } else { false }
        } == [.payload("[1]", complete: true), .payload("{}", complete: true)])
    }
}

// MARK: - Recovery & API

@Suite("Recovery and API")
struct RecoveryTests {
    @Test func unclosedBlocksCloseInnermostFirst() {
        #expect(parse("<thinking>\n```\nx") == [
            .open(.thinking), .text("\n"), .open(.codeFence(language: "")), .text("x"),
            .close(.codeFence(language: ""), recovered: true), .close(.thinking, recovered: true),
        ])
    }

    @Test func currentBlockTracksNesting() {
        var parser = StreamParser()
        #expect(parser.currentBlock == nil)
        _ = parser.feed("<thinking>\n```rust\n")
        #expect(parser.currentBlock == .codeFence(language: "rust"))
        _ = parser.feed("```\n")
        #expect(parser.currentBlock == .thinking)
        _ = parser.feed("</thinking>")
        #expect(parser.currentBlock == nil)
    }

    @Test func finishIsIdempotent() {
        var parser = StreamParser()
        _ = parser.feed("<thinking>")
        #expect(parser.finish() == [.close(.thinking, recovered: true)])
        #expect(parser.finish().isEmpty)
    }

    @Test func textEventsAreSlicesOfTheInputChunk() {
        var parser = StreamParser()
        let chunk = "before <thinking>inside</thinking> after"
        var slices: [Substring] = []
        parser.feed(chunk) { if case .text(let s) = $0 { slices.append(s) } }
        #expect(slices == ["before ", "inside", " after"])
        // Zero-copy: each slice shares the chunk's storage instead of copying it.
        #expect(slices.allSatisfy { $0.base == chunk })
    }

    @Test func largeStreamInFrameSizedChunks() {
        let unit = "Some prose. <thinking>reason ```not fence``` </thinking>\n```swift\nlet x = 1\n```\n"
        let doc = String(repeating: unit, count: 5_000)            // ~420 KB
        var parser = StreamParser()
        var proseBytes = 0, blocks = 0
        var index = doc.startIndex
        while index < doc.endIndex {
            let end = doc.index(index, offsetBy: 300, limitedBy: doc.endIndex) ?? doc.endIndex
            parser.feed(String(doc[index..<end])) { event in
                switch event {
                case .text(let s): proseBytes += s.utf8.count
                case .open: blocks += 1
                default: break
                }
            }
            index = end
        }
        _ = parser.finish()
        #expect(blocks == 10_000)
        #expect(parser.heldBackByteCount == 0)
        #expect(proseBytes > 0)
    }
}
