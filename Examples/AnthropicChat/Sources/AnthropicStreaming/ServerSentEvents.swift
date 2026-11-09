/// One Server-Sent Event: an optional `event:` name and its `data:` payload.
public struct ServerSentEvent: Sendable, Equatable {
    public var event: String?
    public var data: String

    public init(event: String?, data: String) {
        self.event = event
        self.data = data
    }
}

/// A line-oriented Server-Sent Events parser (the WHATWG event-stream format).
///
/// Feed it one line at a time, without the line terminator. An event is complete at a blank
/// line. Some line readers drop blank lines (for example `URLSession.AsyncBytes.lines`), so a
/// new `event:` line also completes the pending event, and so does `finish()` at the end of
/// the stream. Comment lines (`:` keep-alives) and `id:` / `retry:` fields are ignored.
public struct SSEParser: Sendable {
    private var event: String?
    private var data: [String] = []

    public init() {}

    public mutating func consume(line: some StringProtocol) -> ServerSentEvent? {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = Substring(line[..<colon])
            value = Substring(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }

        switch field {
        case "event":
            let completed = flush()
            event = String(value)
            return completed
        case "data":
            data.append(String(value))
            return nil
        default:
            return nil
        }
    }

    /// Completes a final event that wasn't followed by a blank line.
    public mutating func finish() -> ServerSentEvent? {
        flush()
    }

    private mutating func flush() -> ServerSentEvent? {
        defer {
            event = nil
            data = []
        }
        guard !data.isEmpty else { return nil }
        return ServerSentEvent(event: event, data: data.joined(separator: "\n"))
    }
}
