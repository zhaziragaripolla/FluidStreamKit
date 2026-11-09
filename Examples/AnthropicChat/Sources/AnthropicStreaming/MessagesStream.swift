public import Foundation
public import FluidStreamUI

/// The Messages API streaming events this adapter acts on.
public enum MessagesStreamEvent: Sendable, Equatable {
    case messageStart(model: String?)
    /// `type` is the block's type: `text`, `thinking`, `tool_use`, `fallback`, …
    case contentBlockStart(index: Int, type: String)
    case textDelta(index: Int, text: String)
    case thinkingDelta(index: Int, thinking: String)
    case inputJSONDelta(index: Int, partialJSON: String)
    case contentBlockStop(index: Int)
    case messageDelta(stopReason: String?)
    case messageStop
    case ping
    case error(type: String, message: String)
    /// Event or delta types this adapter doesn't need (for example `signature_delta`).
    case ignored(String)

    public static func decode(_ event: ServerSentEvent) throws -> MessagesStreamEvent {
        let raw = try JSONDecoder().decode(Raw.self, from: Data(event.data.utf8))
        switch raw.type {
        case "message_start":
            return .messageStart(model: raw.message?.model)
        case "content_block_start":
            return .contentBlockStart(index: raw.index ?? 0, type: raw.content_block?.type ?? "unknown")
        case "content_block_delta":
            let index = raw.index ?? 0
            switch raw.delta?.type {
            case "text_delta": return .textDelta(index: index, text: raw.delta?.text ?? "")
            case "thinking_delta": return .thinkingDelta(index: index, thinking: raw.delta?.thinking ?? "")
            case "input_json_delta": return .inputJSONDelta(index: index, partialJSON: raw.delta?.partial_json ?? "")
            case let other: return .ignored(other ?? "content_block_delta")
            }
        case "content_block_stop":
            return .contentBlockStop(index: raw.index ?? 0)
        case "message_delta":
            return .messageDelta(stopReason: raw.delta?.stop_reason)
        case "message_stop":
            return .messageStop
        case "ping":
            return .ping
        case "error":
            return .error(type: raw.error?.type ?? "error", message: raw.error?.message ?? "")
        default:
            return .ignored(raw.type)
        }
    }

    private struct Raw: Decodable {
        let type: String
        let index: Int?
        let message: Message?
        let content_block: Block?
        let delta: Delta?
        let error: APIError?

        struct Message: Decodable { let model: String? }
        struct Block: Decodable { let type: String }
        struct Delta: Decodable {
            let type: String?
            let text: String?
            let thinking: String?
            let partial_json: String?
            let stop_reason: String?
        }
        struct APIError: Decodable { let type: String; let message: String }
    }
}

public enum MessagesStreamError: Error, Sendable, Equatable {
    /// A non-200 response. `body` is the API's error JSON, truncated.
    case http(status: Int, body: String)
    /// An `error` event mid-stream, for example `overloaded_error`.
    case api(type: String, message: String)
}

/// Turns Messages API events into the text `FluidStreamKit` parses.
///
/// Text deltas pass through unchanged. Thinking and tool-use blocks arrive as separate typed
/// blocks, not as in-band tags, so the bridge wraps them in tags the parser recognizes. The
/// tag names are deliberately unusual: a response that *talks about* `<thinking>` tags (for
/// example, an answer about prompting) renders as text and doesn't open a thinking block.
public struct MessagesTextBridge: Sendable {
    public static let thinkingTag = "anthropic-thinking"
    public static let toolCallTag = "anthropic-tool-use"

    /// Use this when creating the `StreamSession` that receives the bridged text.
    public static var parserConfiguration: ParserConfiguration {
        ParserConfiguration(thinkingTag: thinkingTag, toolCallTag: toolCallTag)
    }

    public private(set) var model: String?
    public private(set) var stopReason: String?
    private var blockTypes: [Int: String] = [:]

    public init() {}

    /// The text to append to the stream buffer for `event` (often empty).
    /// - Throws: `MessagesStreamError.api` for an `error` event.
    public mutating func text(for event: MessagesStreamEvent) throws -> String {
        switch event {
        case .messageStart(let model):
            if let model { self.model = model }
            return ""
        case .contentBlockStart(let index, let type):
            blockTypes[index] = type
            switch type {
            case "thinking": return "\n<\(Self.thinkingTag)>\n"
            case "tool_use": return "\n<\(Self.toolCallTag)>"
            default: return ""
            }
        case .textDelta(_, let text):
            return text
        case .thinkingDelta(_, let thinking):
            return thinking
        case .inputJSONDelta(_, let json):
            return json
        case .contentBlockStop(let index):
            switch blockTypes.removeValue(forKey: index) {
            case "thinking": return "\n</\(Self.thinkingTag)>\n"
            case "tool_use": return "</\(Self.toolCallTag)>\n"
            default: return ""
            }
        case .messageDelta(let stopReason):
            if let stopReason { self.stopReason = stopReason }
            return ""
        case .messageStop, .ping, .ignored:
            return ""
        case .error(let type, let message):
            throw MessagesStreamError.api(type: type, message: message)
        }
    }
}

/// What a finished stream reported.
public struct MessagesStreamOutcome: Sendable, Equatable {
    public let model: String?
    /// `end_turn`, `max_tokens`, `refusal`, `tool_use`, …
    public let stopReason: String?

    /// A one-line notice for the UI when the answer didn't end normally, else `nil`.
    public var notice: String? {
        switch stopReason {
        case "refusal": "Claude declined to continue this response."
        case "max_tokens": "The response hit the max_tokens limit and was cut off."
        default: nil
        }
    }
}

/// A Messages API request, streamed.
public struct MessagesRequest: Sendable, Equatable {
    public var model = "claude-opus-5-5"
    public var maxTokens = 64_000
    /// `low` suits quick chat; Claude Opus 5.5 defaults to `medium`.
    public var effort = "medium"
    public var prompt: String

    public init(prompt: String) {
        self.prompt = prompt
    }

    /// The JSON body. Thinking is adaptive with summarized display, so its text streams into
    /// the thinking block. `fallbacks: "default"` re-runs a declined request on a recommended
    /// model server-side; a fallback mid-answer continues on the same stream.
    public func body() throws -> Data {
        let json: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "thinking": ["type": "adaptive", "display": "summarized"],
            "output_config": ["effort": effort],
            "fallbacks": "default",
            "messages": [["role": "user", "content": prompt]],
        ]
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    public func urlRequest(apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try body()
        return request
    }
}

/// Streams one Messages API response into a `StreamBufferActor`.
///
/// Call it from `StreamSession.start`. When it returns, the session finishes; when it throws,
/// the session cancels and keeps the text already shown.
public struct MessagesStreamer: Sendable {
    public let apiKey: String
    public let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func stream(_ request: MessagesRequest, into buffer: StreamBufferActor) async throws -> MessagesStreamOutcome {
        let (bytes, response) = try await session.bytes(for: try request.urlRequest(apiKey: apiKey))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.utf8.count > 2_000 { break }
            }
            throw MessagesStreamError.http(status: http.statusCode, body: body)
        }

        var parser = SSEParser()
        var bridge = MessagesTextBridge()
        for try await line in bytes.lines {
            guard let event = parser.consume(line: line) else { continue }
            let text = try bridge.text(for: try MessagesStreamEvent.decode(event))
            if !text.isEmpty { try await buffer.append(text) }   // ~1 append per token: cheap at stream rates
        }
        if let last = parser.finish() {
            let text = try bridge.text(for: try MessagesStreamEvent.decode(last))
            if !text.isEmpty { try await buffer.append(text) }
        }
        return MessagesStreamOutcome(model: bridge.model, stopReason: bridge.stopReason)
    }
}
