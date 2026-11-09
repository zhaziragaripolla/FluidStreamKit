#if canImport(UIKit)
public import UIKit
#elseif canImport(AppKit)
public import AppKit
#endif
public import FluidStreamParser

/// The TextKit 2 document a streamed response renders into.
///
/// The text storage is split into two regions:
///
/// ```
/// [ frozen: never edited again ][ live tail: the line still being written ]
///                               ^ frozenLength
/// ```
///
/// - Prose and thinking text accumulates in `tailSource`, the raw Markdown of the current
///   line. Once per frame, the live tail is replaced by a fresh render of that line. A
///   newline or a block boundary finalizes the line and moves `frozenLength` forward.
/// - Code and tool-call text needs no inline rendering, so it's appended and frozen at once.
///
/// Every edit therefore lands at or after `frozenLength`. TextKit 2 re-lays-out only the
/// changed paragraph, and per-frame cost doesn't grow with the document.
///
/// **Don't** reach the layout through `UITextView.layoutManager`. That silently switches
/// the view to TextKit 1, and every edit would re-lay-out everything. Use `textLayoutManager`.
@MainActor
public final class StreamDocument {
    public struct EditStats: Sendable, Equatable {
        public var transactions = 0
        public var edits = 0
        /// The lowest storage location edited in the most recent transaction.
        public var lowestEditLocation: Int?
        /// `frozenLength` when the most recent transaction began.
        public var frozenLengthAtTransactionStart = 0
    }

    public let contentStorage: NSTextContentStorage
    public let textLayoutManager: NSTextLayoutManager
    public let textContainer: NSTextContainer
    public private(set) var theme: StreamTheme

    public private(set) var frozenLength = 0
    public private(set) var stats = EditStats()

    private let layoutDelegate: BlockBackgroundLayoutDelegate
    private var blocks: [BlockKind] = []
    private var tailSource = ""
    private var tailDirty = false
    private var trimLeadingAfterBoundary = false
    private var inTransaction = false

    public init(theme: StreamTheme = .standard(), containerWidth: CGFloat = 0) {
        self.theme = theme
        contentStorage = NSTextContentStorage()
        textLayoutManager = NSTextLayoutManager()
        textContainer = NSTextContainer(size: CGSize(width: containerWidth, height: 0))
        textContainer.lineFragmentPadding = 0
        textLayoutManager.textContainer = textContainer
        contentStorage.addTextLayoutManager(textLayoutManager)
        layoutDelegate = BlockBackgroundLayoutDelegate(codeBackground: theme.codeBackgroundColor)
        textLayoutManager.delegate = layoutDelegate
    }

    private var storage: NSTextStorage { contentStorage.textStorage! }

    // MARK: Accessibility

    /// Switches to `newTheme`, for example after a Dynamic Type change.
    ///
    /// Text already on screen is re-scaled once by the ratio of the two body font sizes. That
    /// is the one deliberate O(document) edit (RFC-003); it touches attributes only, never
    /// characters. Text that arrives afterwards uses `newTheme` directly.
    public func applyTheme(_ newTheme: StreamTheme) {
        precondition(!inTransaction, "applyTheme(_:) can't run inside performFrame")
        let ratio = newTheme.bodyFont.pointSize / theme.bodyFont.pointSize
        theme = newTheme
        guard ratio != 1, storage.length > 0 else { return }
        contentStorage.performEditingTransaction {
            let whole = NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(.font, in: whole) { value, range, _ in
                guard let font = value as? PlatformFont else { return }
                storage.addAttribute(.font, value: font.withSize(font.pointSize * ratio), range: range)
            }
        }
    }

    /// The finalized text from `location` up to `frozenLength`, split into runs by block kind.
    /// Text there will never change again, which makes it safe to announce to VoiceOver.
    public func finalizedSegments(from location: Int) -> [(text: String, block: StreamBlockAttribute?)] {
        guard location < frozenLength else { return [] }
        let range = NSRange(location: location, length: frozenLength - location)
        var segments: [(text: String, block: StreamBlockAttribute?)] = []
        storage.enumerateAttribute(.fluidBlock, in: range) { value, subrange, _ in
            let block = (value as? String).flatMap(StreamBlockAttribute.init(rawValue:))
            segments.append(((storage.string as NSString).substring(with: subrange), block))
        }
        return segments
    }

    public var string: String { storage.string }
    public var attributedString: NSAttributedString { NSAttributedString(attributedString: storage) }

    // MARK: Frame transactions

    /// Applies one frame's events in a single editing transaction, so TextKit invalidates
    /// layout once per frame. The live tail is re-rendered at most once, at the end.
    public func performFrame(_ body: (StreamDocument) -> Void) {
        precondition(!inTransaction, "performFrame is not reentrant")
        inTransaction = true
        stats.transactions += 1
        stats.lowestEditLocation = nil
        stats.frozenLengthAtTransactionStart = frozenLength
        contentStorage.performEditingTransaction {
            body(self)
            if tailDirty { renderTail(isFinal: false) }
        }
        inTransaction = false
    }

    public func apply(_ event: ParseEvent) {
        precondition(inTransaction, "apply(_:) must run inside performFrame")
        switch event {
        case .open(let kind):
            finalizeTail(trimTrailingWhitespace: true)
            blocks.append(kind)
            beginBlockBoundary()
        case .close:
            finalizeTail(trimTrailingWhitespace: true)
            if !blocks.isEmpty { blocks.removeLast() }
            beginBlockBoundary()
        case .toolCallPayload:
            break                                   // surfaced by StreamRenderer.onToolCall
        case .text(let text):
            appendText(text)
        }
    }

    /// Finalizes the last line once the stream has ended.
    public func finish() {
        precondition(inTransaction, "finish() must run inside performFrame")
        finalizeTail(trimTrailingWhitespace: true)
    }

    // MARK: Text routing

    private var isRawBlock: Bool {
        switch blocks.last {
        case .codeFence, .toolCall: true
        case .thinking, nil: false
        }
    }

    private func appendText(_ incoming: Substring) {
        var text = incoming
        if trimLeadingAfterBoundary {
            // Indentation matters in code, so only drop newlines there.
            text = isRawBlock ? text.drop(while: \.isNewline) : text.drop(while: \.isWhitespace)
            guard !text.isEmpty else { return }
            trimLeadingAfterBoundary = false
        }

        if isRawBlock {
            append(NSAttributedString(string: String(text), attributes: rawAttributes()))
            frozenLength = storage.length
            return
        }

        var rest = text
        while let newline = rest.firstIndex(where: \.isNewline) {
            tailSource += rest[..<newline]
            finalizeLine()
            rest = rest[rest.index(after: newline)...]
        }
        if !rest.isEmpty {
            tailSource += rest
            tailDirty = true
        }
    }

    /// Ends the current line at a newline. Blank prose lines are dropped; paragraph spacing
    /// separates paragraphs instead.
    private func finalizeLine() {
        if tailSource.isEmpty {
            tailDirty = false
            return
        }
        renderTail(isFinal: true, terminator: "\n")
    }

    private func finalizeTail(trimTrailingWhitespace: Bool) {
        if trimTrailingWhitespace {
            while let last = tailSource.last, last.isWhitespace { tailSource.removeLast() }
        }
        if tailSource.isEmpty {
            tailDirty = false
            if storage.length > frozenLength {          // the live tail rendered only whitespace
                replace(NSRange(location: frozenLength, length: storage.length - frozenLength), with: NSAttributedString())
            }
            return
        }
        renderTail(isFinal: true)
    }

    private func renderTail(isFinal: Bool, terminator: String = "") {
        tailDirty = false
        let line = InlineMarkdown.render(tailSource, isFinal: isFinal)
        let rendered = makeAttributedLine(line, terminator: terminator)
        replace(NSRange(location: frozenLength, length: storage.length - frozenLength), with: rendered)
        if isFinal {
            frozenLength = storage.length
            tailSource = ""
        }
    }

    /// Blocks start on their own line: end the previous paragraph if it hasn't ended yet.
    private func beginBlockBoundary() {
        let length = storage.length
        if length > 0, (storage.string as NSString).character(at: length - 1) != 0x0A {
            let attributes = storage.attributes(at: length - 1, effectiveRange: nil)
            append(NSAttributedString(string: "\n", attributes: attributes))
        }
        frozenLength = storage.length
        trimLeadingAfterBoundary = true
    }

    // MARK: Edits (every mutation goes through these two)

    private func replace(_ range: NSRange, with string: NSAttributedString) {
        assert(range.location >= frozenLength, "edit inside the frozen region")
        noteEdit(at: range.location)
        storage.replaceCharacters(in: range, with: string)
    }

    private func append(_ string: NSAttributedString) {
        noteEdit(at: storage.length)
        storage.append(string)
    }

    private func noteEdit(at location: Int) {
        stats.edits += 1
        stats.lowestEditLocation = min(stats.lowestEditLocation ?? location, location)
    }

    // MARK: Attributes

    private func rawAttributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        switch blocks.last {
        case .codeFence(let language):
            var attributes: [NSAttributedString.Key: Any] = [
                .font: theme.codeFont,
                .foregroundColor: theme.textColor,
                .paragraphStyle: paragraph,
                .fluidBlock: StreamBlockAttribute.code.rawValue,
            ]
            if !language.isEmpty { attributes[.fluidCodeLanguage] = language }
            return attributes
        default:
            return [
                .font: theme.toolCallFont,
                .foregroundColor: theme.secondaryTextColor,
                .paragraphStyle: paragraph,
                .fluidBlock: StreamBlockAttribute.toolCall.rawValue,
            ]
        }
    }

    private func lineAttributes(for kind: InlineMarkdown.LineKind) -> [NSAttributedString.Key: Any] {
        var font = theme.bodyFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = theme.paragraphSpacing
        switch kind {
        case .paragraph:
            break
        case .heading(let level):
            font = theme.bodyFont.scaled(by: theme.headingScales[level - 1]).adding(bold: true, italic: false)
            paragraph.paragraphSpacingBefore = theme.paragraphSpacing
        case .bullet, .ordered:
            paragraph.headIndent = theme.listIndent       // hanging indent for wrapped lines
            paragraph.paragraphSpacing = theme.paragraphSpacing / 2
        case .quote:
            paragraph.firstLineHeadIndent = theme.listIndent
            paragraph.headIndent = theme.listIndent
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: kind == .quote ? theme.secondaryTextColor : theme.textColor,
            .paragraphStyle: paragraph,
        ]
        if blocks.last == .thinking {
            attributes[.foregroundColor] = theme.secondaryTextColor
            attributes[.fluidBlock] = StreamBlockAttribute.thinking.rawValue
        }
        return attributes
    }

    private func makeAttributedLine(_ line: InlineMarkdown.Line, terminator: String) -> NSAttributedString {
        let base = lineAttributes(for: line.kind)
        let baseFont = base[.font] as! PlatformFont
        let result = NSMutableAttributedString(string: line.text + terminator, attributes: base)
        for span in line.spans {
            let range = NSRange(location: span.range.lowerBound, length: span.range.count)
            switch span.style {
            case .bold, .italic:
                let bold = span.style == .bold
                // Combine with whatever is already there, so bold inside italic stays both.
                result.enumerateAttribute(.font, in: range) { value, subrange, _ in
                    let font = (value as? PlatformFont) ?? baseFont
                    result.addAttribute(.font, value: font.adding(bold: bold, italic: !bold), range: subrange)
                }
            case .code:
                result.addAttributes([.font: theme.codeFont, .backgroundColor: theme.inlineCodeBackgroundColor], range: range)
            case .link(let destination):
                result.addAttribute(.foregroundColor, value: theme.linkColor, range: range)
                if let url = URL(string: destination) { result.addAttribute(.link, value: url, range: range) }
            }
        }
        return result
    }
}

// MARK: - Code block backgrounds

/// Supplies a custom fragment for code paragraphs, so their background spans the full
/// container width. A `.backgroundColor` attribute would only paint behind the glyphs.
final class BlockBackgroundLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    let codeBackground: PlatformColor

    init(codeBackground: PlatformColor) {
        self.codeBackground = codeBackground
    }

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph,
           paragraph.attributedString.length > 0,
           paragraph.attributedString.attribute(.fluidBlock, at: 0, effectiveRange: nil) as? String == StreamBlockAttribute.code.rawValue {
            return BlockBackgroundFragment(textElement: textElement, range: textElement.elementRange, fill: codeBackground)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

final class BlockBackgroundFragment: NSTextLayoutFragment {
    let fill: PlatformColor

    init(textElement: NSTextElement, range: NSTextRange?, fill: PlatformColor) {
        self.fill = fill
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) { nil }

    /// In fragment-local coordinates: from the container's leading edge across its full width.
    private var backgroundRect: CGRect {
        let containerWidth = textLayoutManager?.textContainer?.size.width ?? 0
        let width = max(containerWidth, layoutFragmentFrame.maxX)
        return CGRect(x: -layoutFragmentFrame.minX, y: 0, width: width, height: layoutFragmentFrame.height)
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(backgroundRect)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setFillColor(fill.cgColor)
        context.fill(backgroundRect.offsetBy(dx: point.x, dy: point.y))
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}
