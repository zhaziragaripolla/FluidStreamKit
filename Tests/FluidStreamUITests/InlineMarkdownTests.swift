import Testing
@testable import FluidStreamUI

typealias MD = InlineMarkdown

private func span(_ r: Range<Int>, _ s: MD.Style) -> MD.Span { MD.Span(range: r, style: s) }

@Suite("InlineMarkdown")
struct InlineMarkdownTests {

    // MARK: Final lines

    @Test func boldItalicCodeAndLink() {
        let line = MD.render("a **b** *c* `d` [e](https://x.y)", isFinal: true)
        #expect(line.text == "a b c d e")
        #expect(line.spans == [span(2..<3, .bold), span(4..<5, .italic), span(6..<7, .code), span(8..<9, .link("https://x.y"))])
    }

    @Test func flankingRuleKeepsArithmeticLiteral() {
        #expect(MD.render("2 * 3 * 4", isFinal: true) == MD.Line(kind: .paragraph, text: "2 * 3 * 4", spans: []))
        // On a live line there's no closer check to fall back on. Only the flanking rule
        // stops "2 * 3" from flickering into italics while it streams.
        #expect(MD.render("2 * 3", isFinal: false) == MD.Line(kind: .paragraph, text: "2 * 3", spans: []))
    }

    @Test func underscoresNeverEmphasize() {
        #expect(MD.render("use snake_case_names", isFinal: true).spans.isEmpty)
    }

    @Test func unclosedMarkersAreLiteralOnFinalLine() {
        #expect(MD.render("a **b", isFinal: true).text == "a **b")
        #expect(MD.render("`x", isFinal: true).text == "`x")
        #expect(MD.render("[x](y", isFinal: true).text == "[x](y")
    }

    @Test func multiBacktickCodeSpan() {
        let line = MD.render("``a`b`` end", isFinal: true)
        #expect(line.text == "a`b end")
        #expect(line.spans == [span(0..<3, .code)])
    }

    @Test func markdownInsideCodeSpanIsLiteral() {
        #expect(MD.render("`**x**`", isFinal: true).text == "**x**")
    }

    @Test func escapes() {
        #expect(MD.render(#"\*not\* \[x]"#, isFinal: true).text == "*not* [x]")
    }

    @Test func boldInsideItalic() {
        let line = MD.render("*a **b** c*", isFinal: true)
        #expect(line.text == "a b c")
        #expect(line.spans.contains(span(2..<3, .bold)))
        #expect(line.spans.contains(span(0..<5, .italic)))
    }

    @Test func utf16OffsetsAccountForEmoji() {
        let line = MD.render("🧠 **b**", isFinal: true)
        #expect(line.spans == [span(3..<4, .bold)])   // 🧠 is two UTF-16 units
    }

    // MARK: Block prefixes

    @Test(arguments: [
        ("# Title", MD.LineKind.heading(level: 1), "Title"),
        ("### Small", .heading(level: 3), "Small"),
        ("#### Too deep", .paragraph, "#### Too deep"),
        ("#NoSpace", .paragraph, "#NoSpace"),
        ("- item", .bullet, "• item"),
        ("* item", .bullet, "• item"),
        ("12. twelfth", .ordered, "12. twelfth"),
        ("3.14 is pi", .paragraph, "3.14 is pi"),
        ("> Tip: **x**", .quote, "Tip: x"),
        (">", .quote, ""),
        (">not a quote", .paragraph, ">not a quote"),
    ])
    func linePrefixes(source: String, kind: MD.LineKind, text: String) {
        let line = MD.render(source, isFinal: true)
        #expect(line.kind == kind)
        #expect(line.text == text)
    }

    // MARK: Live (optimistic) lines

    @Test func liveUnclosedBoldIsStyledWithMarkerHidden() {
        let line = MD.render("This is **bo", isFinal: false)
        #expect(line.text == "This is bo")
        #expect(line.spans == [span(8..<10, .bold)])
    }

    @Test func liveTrailingMarkerIsHidden() {
        #expect(MD.render("Hello **", isFinal: false).text == "Hello ")
        #expect(MD.render("Hello \\", isFinal: false).text == "Hello ")
    }

    @Test func liveUnclosedCodeAndLink() {
        #expect(MD.render("run `swift te", isFinal: false) == MD.Line(kind: .paragraph, text: "run swift te", spans: [span(4..<12, .code)]))
        #expect(MD.render("[Cl](https://cl", isFinal: false).spans == [span(0..<2, .link("https://cl"))])
    }

    @Test func liveRenderConvergesToFinalRender() {
        // Re-rendering a growing prefix must never crash, and the full line's live render
        // must match its final render once every marker is closed.
        let source = "Mix **bold**, *it*, `code` and [l](u) done"
        for end in source.indices {
            _ = MD.render(String(source[..<end]), isFinal: false)
        }
        #expect(MD.render(source, isFinal: false) == MD.render(source, isFinal: true))
    }
}
