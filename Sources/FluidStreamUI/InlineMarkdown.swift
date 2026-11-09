/// Renders one line of Markdown (block prefix plus inline spans) into display text and style
/// spans.
///
/// This only ever runs on the **live tail line** of the document, so its cost is bounded by
/// the length of a line, not of the document. Pure Swift, with no Foundation, so it's
/// trivially testable.
///
/// While the line is still streaming (`isFinal == false`), rendering is **optimistic**:
/// - an unclosed `**bo` renders as bold "bo" with its marker hidden;
/// - a trailing undecided marker (`**`, `` ` ``, `\`) is hidden.
///
/// That way markers never flash on screen and then vanish. Once the line is final, only
/// markers that really closed are styled. Anything else shows literally.
enum InlineMarkdown {
    enum LineKind: Equatable, Sendable {
        case paragraph
        case heading(level: Int)
        case bullet
        case ordered
        case quote
    }

    enum Style: Equatable, Sendable {
        case bold, italic, code
        case link(String)
    }

    struct Span: Equatable, Sendable {
        /// UTF-16 offsets into `Line.text`, the unit `NSAttributedString` uses.
        var range: Range<Int>
        var style: Style
    }

    struct Line: Equatable, Sendable {
        var kind: LineKind
        var text: String
        var spans: [Span]
    }

    static func render(_ source: String, isFinal: Bool) -> Line {
        var renderer = Renderer(chars: Array(source), isFinal: isFinal)
        let kind = renderer.consumeLinePrefix()
        renderer.renderInline()
        return Line(kind: kind, text: renderer.out, spans: renderer.spans)
    }

    private struct Renderer {
        let chars: [Character]
        let isFinal: Bool
        var i = 0
        var out = ""
        var u16 = 0
        var spans: [Span] = []
        var boldStart: Int?
        var italicStart: Int?

        init(chars: [Character], isFinal: Bool) {
            self.chars = chars
            self.isFinal = isFinal
        }

        // MARK: Block prefix

        mutating func consumeLinePrefix() -> LineKind {
            let n = chars.count
            if n >= 1, chars[0] == ">", n == 1 || chars[1] == " " {
                i = min(2, n)
                return .quote
            }
            var hashes = 0
            while hashes < n, chars[hashes] == "#" { hashes += 1 }
            if (1...3).contains(hashes), hashes < n, chars[hashes] == " " {
                i = hashes + 1
                return .heading(level: hashes)
            }
            if n >= 2, chars[0] == "-" || chars[0] == "*" || chars[0] == "+", chars[1] == " " {
                i = 2
                emit("•")
                emit(" ")
                return .bullet
            }
            var digits = 0
            while digits < n, digits < 9, chars[digits].isASCII, chars[digits].isNumber { digits += 1 }
            if digits > 0, digits + 1 < n, chars[digits] == ".", chars[digits + 1] == " " {
                emit(chars[0..<(digits + 2)])
                i = digits + 2
                return .ordered
            }
            return .paragraph
        }

        // MARK: Inline

        mutating func renderInline() {
            while i < chars.count {
                switch chars[i] {
                case "\\": renderEscape()
                case "`": renderCodeSpan()
                case "*": renderEmphasis()
                case "[": renderLink()
                default:
                    emit(chars[i])
                    i += 1
                }
            }
            closeDanglingOpeners()
        }

        mutating func renderEscape() {
            let n = chars.count
            if i + 1 < n, chars[i + 1].isASCII, chars[i + 1].isPunctuation || chars[i + 1].isSymbol {
                emit(chars[i + 1])
                i += 2
            } else if i + 1 == n && !isFinal {
                i += 1                                   // trailing "\" on a live line: still undecided
            } else {
                emit("\\")
                i += 1
            }
        }

        /// A backtick run of length r opens a span that a later run of exactly r closes (CommonMark).
        mutating func renderCodeSpan() {
            let n = chars.count
            var run = 0
            while i + run < n, chars[i + run] == "`" { run += 1 }
            let contentStart = i + run
            var k = contentStart
            while k < n {
                guard chars[k] == "`" else { k += 1; continue }
                var closeRun = 0
                while k + closeRun < n, chars[k + closeRun] == "`" { closeRun += 1 }
                if closeRun == run {
                    appendStyled(chars[contentStart..<k], .code)
                    i = k + run
                    return
                }
                k += closeRun
            }
            if !isFinal {
                appendStyled(chars[contentStart..<n], .code)   // optimistic: still streaming
                i = n
            } else {
                emit(chars[i..<contentStart])                  // never closed: literal backticks
                i = contentStart
            }
        }

        mutating func renderEmphasis() {
            let n = chars.count
            let length = (i + 1 < n && chars[i + 1] == "*") ? 2 : 1
            let bold = length == 2
            let previous: Character? = i > 0 ? chars[i - 1] : nil
            let next: Character? = i + length < n ? chars[i + length] : nil
            let openStart = bold ? boldStart : italicStart

            // Closer: needs an open delimiter, and must be right-flanking (no whitespace before it).
            if let start = openStart, let previous, !previous.isWhitespace {
                spans.append(Span(range: start..<u16, style: bold ? .bold : .italic))
                if bold { boldStart = nil } else { italicStart = nil }
                i += length
                return
            }
            // A marker at the very end of a live line can't be decided yet. Hide it.
            if next == nil && !isFinal {
                i += length
                return
            }
            // Opener: must be left-flanking (so "2 * 3" stays literal). On a final line it
            // also needs a closer further on.
            if openStart == nil, let next, !next.isWhitespace,
               !isFinal || hasCloser(from: i + length, length: length) {
                if bold { boldStart = u16 } else { italicStart = u16 }
                i += length
                return
            }
            emit(chars[i..<(i + length)])
            i += length
        }

        func hasCloser(from start: Int, length: Int) -> Bool {
            var k = start
            while k < chars.count {
                if chars[k] == "*" {
                    let run = (k + 1 < chars.count && chars[k + 1] == "*") ? 2 : 1
                    if run == length, !chars[k - 1].isWhitespace { return true }
                    k += run
                } else {
                    k += 1
                }
            }
            return false
        }

        /// `[label](url)`. The bracket stays literal until `](` appears (see RFC-003 risks).
        mutating func renderLink() {
            let n = chars.count
            var k = i + 1
            while k + 1 < n, !(chars[k] == "]" && chars[k + 1] == "(") { k += 1 }
            guard k + 1 < n else {
                emit("[")
                i += 1
                return
            }
            let label = chars[(i + 1)..<k]
            if let close = chars[(k + 2)...].firstIndex(of: ")") {
                appendStyled(label, .link(String(chars[(k + 2)..<close])))
                i = close + 1
            } else if !isFinal {
                appendStyled(label, .link(String(chars[(k + 2)...])))
                i = n
            } else {
                emit("[")
                i += 1
            }
        }

        /// A live line keeps its optimistic styles. On a final line, an opener that was never
        /// closed gets its literal marker put back where it was hidden.
        mutating func closeDanglingOpeners() {
            if !isFinal {
                if let start = boldStart { spans.append(Span(range: start..<u16, style: .bold)) }
                if let start = italicStart { spans.append(Span(range: start..<u16, style: .italic)) }
            } else {
                let restores = [(boldStart, "**"), (italicStart, "*")]
                    .compactMap { position, marker in position.map { ($0, marker) } }
                    .sorted { $0.0 > $1.0 }
                for (position, marker) in restores { insertLiteral(marker, atUTF16: position) }
            }
            boldStart = nil
            italicStart = nil
        }

        mutating func insertLiteral(_ marker: String, atUTF16 position: Int) {
            let index = out.utf16.index(out.utf16.startIndex, offsetBy: position)
            out.insert(contentsOf: marker, at: index)
            let delta = marker.utf16.count
            u16 += delta
            for s in spans.indices {
                let r = spans[s].range
                let lower = r.lowerBound >= position ? r.lowerBound + delta : r.lowerBound
                let upper = r.upperBound > position ? r.upperBound + delta : r.upperBound
                spans[s].range = lower..<upper
            }
        }

        // MARK: Output

        mutating func emit(_ c: Character) {
            out.append(c)
            u16 += c.utf16.count
        }

        mutating func emit(_ s: ArraySlice<Character>) {
            for c in s { emit(c) }
        }

        mutating func appendStyled(_ s: ArraySlice<Character>, _ style: Style) {
            let start = u16
            emit(s)
            if u16 > start { spans.append(Span(range: start..<u16, style: style)) }
        }
    }
}
