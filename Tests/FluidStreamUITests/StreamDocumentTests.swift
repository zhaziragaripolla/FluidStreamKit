import Testing
import AppKit
@testable import FluidStreamUI
import FluidStreamCore
import FluidStreamParser

// MARK: - Helpers

@MainActor
private func render(_ frames: [String], containerWidth: CGFloat = 0, check: (StreamDocument) -> Void = { _ in }) -> StreamRenderer {
    let renderer = StreamRenderer()
    if containerWidth > 0 { renderer.document.textContainer.size = CGSize(width: containerWidth, height: 0) }
    for frame in frames {
        renderer.apply(text: frame)
        check(renderer.document)
    }
    renderer.apply(text: "", isFinal: true)
    check(renderer.document)
    return renderer
}

@MainActor
private func assertFrozenRegionUntouched(_ document: StreamDocument, sourceLocation: SourceLocation = #_sourceLocation) {
    if let lowest = document.stats.lowestEditLocation {
        #expect(lowest >= document.stats.frozenLengthAtTransactionStart, "edited frozen text", sourceLocation: sourceLocation)
    }
}

private func randomFrames(_ text: String, seed: UInt64) -> [String] {
    var state = seed
    func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    let scalars = Array(text.unicodeScalars)
    var frames: [String] = []
    var i = 0
    while i < scalars.count {
        let end = min(scalars.count, i + Int(next() % 20) + 1)
        frames.append(String(String.UnicodeScalarView(scalars[i..<end])))
        i = end
    }
    return frames
}

private let richDocument = """
# Plan
Here is **bold**, *italic*, `code` and [a link](https://example.com).
<thinking>
Let me think about `x` and **y**.
```swift
let a = 1

let b = 2
```
</thinking>
- item one
- item **two**
12. numbered
<tool_call>{"name":"search","q":"</tool_call> trap"}</tool_call>
Final line with emoji 🧠 and é
"""

@MainActor
private func attribute(_ key: NSAttributedString.Key, of substring: String, in document: StreamDocument) -> Any? {
    let range = (document.string as NSString).range(of: substring)
    precondition(range.location != NSNotFound, "\(substring) not found")
    return document.attributedString.attribute(key, at: range.location, effectiveRange: nil)
}

// MARK: - Tests

@Suite("StreamDocument")
@MainActor
struct StreamDocumentTests {

    @Test func inlineMarkdownIsRenderedAndMarkersRemoved() {
        let document = render(["Hello **world**\nNext"]).document
        #expect(document.string == "Hello world\nNext")
        let font = attribute(.font, of: "world", in: document) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test func liveTailIsOptimisticThenSettles() {
        let renderer = StreamRenderer()
        renderer.apply(text: "This is **bo")
        #expect(renderer.document.string == "This is bo")
        let font = attribute(.font, of: "bo", in: renderer.document) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        renderer.apply(text: "ld** end")
        #expect(renderer.document.string == "This is bold end")
    }

    @Test func blocksStartOnTheirOwnLine() {
        let document = render(["Hello <thinking>plan</thinking> world"]).document
        #expect(document.string == "Hello\nplan\nworld")
        #expect(attribute(.fluidBlock, of: "plan", in: document) as? String == "thinking")
        #expect(attribute(.fluidBlock, of: "world", in: document) == nil)
    }

    @Test func codeIsRawMonospaceAndTagged() {
        let document = render(["Intro\n```swift\nlet **x** = 1\n\n  indented\n```\nAfter"]).document
        #expect(document.string == "Intro\nlet **x** = 1\n\n  indented\nAfter")
        #expect(attribute(.fluidBlock, of: "let", in: document) as? String == "code")
        #expect(attribute(.fluidCodeLanguage, of: "let", in: document) as? String == "swift")
        #expect((attribute(.font, of: "let", in: document) as? NSFont)?.isFixedPitch == true)
    }

    @Test func blankProseLinesCollapse() {
        #expect(render(["a\n\n\nb"]).document.string == "a\nb")
    }

    @Test func toolCallIsReportedOnce() {
        let renderer = StreamRenderer()
        var calls: [(String, Bool)] = []
        renderer.onToolCall = { calls.append(($0, $1)) }
        renderer.apply(text: #"<tool_call>{"a":"#)
        renderer.apply(text: #""</tool_call>"}</tool_call>done"#)
        #expect(calls.count == 1)
        #expect(calls.first?.0 == #"{"a":"</tool_call>"}"#)
        #expect(calls.first?.1 == true)
        #expect(renderer.document.string.hasSuffix("\ndone"))
    }

    @Test func frozenRegionIsNeverEditedAndChunkingDoesNotMatter() {
        let reference = render([richDocument]).document.attributedString
        #expect(reference.string.hasPrefix("Plan\nHere is bold, italic, code and a link."))
        for seed in 1...40 as ClosedRange<UInt64> {
            let document = render(randomFrames(richDocument, seed: seed)) { assertFrozenRegionUntouched($0) }.document
            #expect(document.attributedString.isEqual(to: reference), "seed \(seed): \(document.string.debugDescription)")
        }
    }

    @Test func oneTransactionPerFrame() {
        let renderer = StreamRenderer()
        for frame in ["a ", "**b", "**\n", "c"] { renderer.apply(text: frame) }
        #expect(renderer.document.stats.transactions == 4)
    }

    @Test func contentChangeFiresOncePerFrame() {
        let renderer = StreamRenderer()
        var notifications = 0
        renderer.onContentChange = { notifications += 1 }
        renderer.apply(text: "one\ntwo\nthree")
        #expect(notifications == 1)
    }

    @Test func nothingIsAppliedAfterCompletion() {
        let renderer = render(["done"])
        renderer.apply(text: "late")
        #expect(renderer.document.string == "done")
        #expect(renderer.completion == .finished)
    }

    @Test func codeParagraphsGetBackgroundFragments() {
        let document = render(["Text\n```\ncode line\n```\nMore"], containerWidth: 320).document
        let layout = document.textLayoutManager
        layout.ensureLayout(for: layout.documentRange)
        var kinds: [(String, Bool)] = []
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
            let text = (fragment.textElement as? NSTextParagraph)?.attributedString.string ?? ""
            kinds.append((text.trimmingCharacters(in: .newlines), fragment is BlockBackgroundFragment))
            return true
        }
        #expect(kinds.map(\.0) == ["Text", "code line", "More"])
        #expect(kinds.map(\.1) == [false, true, false])
    }
}

@Suite("StreamSession end-to-end")
@MainActor
struct StreamSessionTests {
    @Test func bytesFlowThroughEveryLayer() async throws {
        let ticker = ManualFrameTicker()
        let session = StreamSession(ticker: ticker, bufferCapacity: 64)   // tiny ring → backpressure
        let frames = randomFrames(richDocument, seed: 99)
        await session.start { buffer in
            for frame in frames { try await buffer.append(frame) }
        }
        var ticks = 0
        while session.coordinator.phase != .stopped && ticks < 10_000 {
            if !ticker.fire() { try await Task.sleep(for: .milliseconds(1)) }
            await Task.yield()
            ticks += 1
        }
        #expect(session.coordinator.phase == .stopped)
        #expect(session.renderer.completion == .finished)
        #expect(session.renderer.document.attributedString.isEqual(to: render([richDocument]).document.attributedString))
    }

    @Test func cancellationKeepsRenderedText() async throws {
        let ticker = ManualFrameTicker()
        let session = StreamSession(ticker: ticker)
        await session.start { buffer in
            try await buffer.append("partial **answer")
            try await Task.sleep(for: .seconds(60))     // a stalled network
        }
        var ticks = 0
        while session.renderer.document.string.isEmpty && ticks < 2_000 {
            if !ticker.fire() { try await Task.sleep(for: .milliseconds(1)) }
            await Task.yield()
            ticks += 1
        }
        session.cancel()
        ticks = 0
        while session.coordinator.phase != .stopped && ticks < 2_000 {
            if !ticker.fire() { try await Task.sleep(for: .milliseconds(1)) }
            await Task.yield()
            ticks += 1
        }
        #expect(session.renderer.completion == .cancelled)
        #expect(session.renderer.document.string == "partial **answer")   // finalized: unclosed marker shown literally
    }
}
