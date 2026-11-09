import Testing
import AppKit
@testable import FluidStreamUI

@Suite("StreamAnnouncer")
struct StreamAnnouncerTests {
    @Test func announcesWholeSentencesNotTokens() {
        var announcer = StreamAnnouncer(minimumInterval: 1.5)
        announcer.ingest("Hello there. This is", block: nil)
        #expect(announcer.announcement(at: 0) == "Hello there.")       // the unfinished sentence waits
        announcer.ingest(" a test. And", block: nil)
        #expect(announcer.announcement(at: 0.5) == nil)                 // too soon after the last one
        #expect(announcer.announcement(at: 2.0) == "This is a test.")
    }

    @Test func finalFlushesTheRestImmediately() {
        var announcer = StreamAnnouncer()
        announcer.ingest("Ends without a period", block: nil)
        #expect(announcer.announcement(at: 0) == nil)
        #expect(announcer.announcement(at: 0.1, isFinal: true) == "Ends without a period")
        #expect(announcer.announcement(at: 9, isFinal: true) == nil)    // nothing twice
    }

    @Test func codeIsSummarizedAndThinkingSkipped() {
        var announcer = StreamAnnouncer()
        announcer.ingest("secret plan", block: .thinking)
        announcer.ingest("Here is code:\n", block: nil)
        announcer.ingest("let a = 1\n", block: .code)
        announcer.ingest("let b = 2\n", block: .code)                   // same block: no second notice
        announcer.ingest("{\"q\":1}", block: .toolCall)
        announcer.ingest("Done.", block: nil)
        #expect(announcer.announcement(at: 0, isFinal: true) == "Here is code: Code block. Done.")
    }
}

@Suite("Dynamic Type and finalized text")
@MainActor
struct DocumentAccessibilityTests {
    @Test func applyThemeRescalesExistingTextAndUsesTheNewSizeAfterwards() throws {
        let renderer = StreamRenderer()
        let base = renderer.document.theme.bodyFont.pointSize
        renderer.apply(text: "# Title\nBody **bold** `code`\n")
        let headingBefore = try #require(font(of: "Title", in: renderer.document)).pointSize

        renderer.document.applyTheme(renderer.document.theme.scaled(by: 1.5))

        #expect(abs(font(of: "Body", in: renderer.document)!.pointSize - base * 1.5) < 0.01)
        #expect(abs(font(of: "Title", in: renderer.document)!.pointSize - headingBefore * 1.5) < 0.01)
        #expect(font(of: "bold", in: renderer.document)!.fontDescriptor.symbolicTraits.contains(.bold))  // traits kept
        renderer.apply(text: "New line", isFinal: true)
        #expect(abs(font(of: "New line", in: renderer.document)!.pointSize - base * 1.5) < 0.01)
    }

    @Test func finalizedSegmentsCoverOnlyFrozenTextSplitByBlock() {
        let renderer = StreamRenderer()
        renderer.apply(text: "Intro\n<thinking>plan</thinking>\n```\ncode\n```\nlive tail")
        let segments = renderer.document.finalizedSegments(from: 0)
        #expect(segments.map(\.block) == [nil, .thinking, .code])
        #expect(segments.map(\.text).joined().contains("live tail") == false)   // still being written
        #expect(renderer.document.finalizedSegments(from: renderer.document.frozenLength).isEmpty)
    }

    private func font(of text: String, in document: StreamDocument) -> NSFont? {
        let range = (document.string as NSString).range(of: text)
        guard range.location != NSNotFound else { return nil }
        return document.attributedString.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
    }
}
