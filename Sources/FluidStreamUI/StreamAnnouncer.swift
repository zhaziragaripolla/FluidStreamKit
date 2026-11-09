import Foundation

/// Decides what VoiceOver should say while an answer streams.
///
/// Announcing every token would be unusable: speech would queue up far behind the text. So
/// the announcer collects *finalized* text, which will never change again, and releases it in
/// whole sentences, at most once per `minimumInterval`. The rest comes out when the stream
/// ends. Prose is read aloud. A code block is announced once as "Code block.", and thinking
/// and tool-call text are skipped: the reader can explore them with VoiceOver afterwards.
///
/// Plain logic, no UIKit: `StreamTextView` feeds it and posts the announcements.
public struct StreamAnnouncer: Sendable {
    public var minimumInterval: Double
    private var pending = ""
    private var lastAnnouncement: Double?
    private var inCodeBlock = false

    public init(minimumInterval: Double = 1.5) {
        self.minimumInterval = minimumInterval
    }

    /// Adds newly finalized text of one block kind (`nil` = prose).
    public mutating func ingest(_ text: String, block: StreamBlockAttribute?) {
        switch block {
        case .code:
            if !inCodeBlock { pending += " Code block. " }
            inCodeBlock = true
        case .thinking, .toolCall:
            break
        case nil:
            inCodeBlock = false
            pending += text
        }
    }

    /// The text to announce now, if any. With `isFinal`, everything still pending comes out,
    /// whatever the interval and even without a sentence ending.
    public mutating func announcement(at time: Double, isFinal: Bool = false) -> String? {
        if isFinal { return take(upTo: pending.endIndex, at: time) }
        if let last = lastAnnouncement, time - last < minimumInterval { return nil }
        guard let end = pending.lastIndex(where: { ".!?\n".contains($0) }) else { return nil }
        return take(upTo: pending.index(after: end), at: time)
    }

    private mutating func take(upTo end: String.Index, at time: Double) -> String? {
        // Speech doesn't need layout: collapse every run of whitespace to one space.
        let text = pending[..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        pending.removeSubrange(..<end)
        guard !text.isEmpty else { return nil }
        lastAnnouncement = time
        return text
    }
}
