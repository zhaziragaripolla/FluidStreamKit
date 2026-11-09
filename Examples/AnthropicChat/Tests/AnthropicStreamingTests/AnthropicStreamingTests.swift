import Testing
import Foundation
@testable import AnthropicStreaming
import FluidStreamUI

/// A recorded-shape stream: thinking (summarized), text with Markdown, a ping, a signature
/// delta, and a tool call whose JSON arrives in pieces.
private let fixture = """
event: message_start
data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","content":[]}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"The user wants a **short** answer."}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: ping
data: {"type":"ping"}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"# Answer\\nUse `task(id:)` — it's "}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"**cancelled** for you. Prompts often use <thinking> tags.\\n"}}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: content_block_start
data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"search","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\\"q\\":\\"swi"}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"ft\\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":2}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}

event: message_stop
data: {"type":"message_stop"}

"""

private func events(from text: String, dropBlankLines: Bool = false) -> [ServerSentEvent] {
    var parser = SSEParser()
    var out: [ServerSentEvent] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: dropBlankLines) {
        if let event = parser.consume(line: line) { out.append(event) }
    }
    if let last = parser.finish() { out.append(last) }
    return out
}

@Suite("SSEParser")
struct SSEParserTests {
    @Test func parsesEventsWithBlankLineSeparators() {
        let parsed = events(from: fixture)
        #expect(parsed.count == 16)
        #expect(parsed.first?.event == "message_start")
        #expect(parsed.last == ServerSentEvent(event: "message_stop", data: #"{"type":"message_stop"}"#))
    }

    @Test func blankLinesDroppedByTheLineReaderStillWork() {
        // URLSession.AsyncBytes.lines can skip empty lines; `event:` lines must still split events.
        #expect(events(from: fixture, dropBlankLines: true) == events(from: fixture))
    }

    @Test func multiLineDataCommentsAndSpacing() {
        let parsed = events(from: ": keep-alive\nevent:custom\ndata:first\ndata: second\nid: 7\n\n")
        #expect(parsed == [ServerSentEvent(event: "custom", data: "first\nsecond")])
    }
}

@Suite("Messages events and bridge")
struct BridgeTests {
    @Test func decodesEveryEventType() throws {
        let decoded = try events(from: fixture).map(MessagesStreamEvent.decode)
        #expect(decoded.contains(.messageStart(model: "claude-opus-5-5")))
        #expect(decoded.contains(.thinkingDelta(index: 0, thinking: "The user wants a **short** answer.")))
        #expect(decoded.contains(.ignored("signature_delta")))
        #expect(decoded.contains(.ping))
        #expect(decoded.contains(.inputJSONDelta(index: 2, partialJSON: #"{"q":"swi"#)))
        #expect(decoded.contains(.messageDelta(stopReason: "tool_use")))
    }

    @Test func errorEventThrows() throws {
        var bridge = MessagesTextBridge()
        let event = try MessagesStreamEvent.decode(ServerSentEvent(
            event: "error",
            data: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        ))
        #expect(throws: MessagesStreamError.api(type: "overloaded_error", message: "Overloaded")) {
            try bridge.text(for: event)
        }
    }

    @Test @MainActor func bridgedStreamRendersAsTypedBlocks() throws {
        var bridge = MessagesTextBridge()
        let text = try events(from: fixture).map(MessagesStreamEvent.decode).map { try bridge.text(for: $0) }.joined()
        #expect(bridge.stopReason == "tool_use")
        #expect(bridge.model == "claude-opus-5-5")

        let renderer = StreamRenderer(parserConfiguration: MessagesTextBridge.parserConfiguration)
        var toolCalls: [(String, Bool)] = []
        renderer.onToolCall = { toolCalls.append(($0, $1)) }
        renderer.apply(text: text, isFinal: true)

        let document = renderer.document
        let thinkingRange = (document.string as NSString).range(of: "The user wants a short answer.")
        #expect(thinkingRange.location != NSNotFound)
        #expect(document.attributedString.attribute(.fluidBlock, at: thinkingRange.location, effectiveRange: nil) as? String == "thinking")
        #expect(document.string.contains("Answer\nUse task(id:)"))          // heading + inline code rendered
        #expect(document.string.contains("<thinking> tags"))                // literal tag in prose is just text
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.0 == #"{"q":"swift"}"#)
        #expect(toolCalls.first?.1 == true)
    }

    @Test func outcomeNotices() {
        #expect(MessagesStreamOutcome(model: nil, stopReason: "refusal").notice != nil)
        #expect(MessagesStreamOutcome(model: nil, stopReason: "max_tokens").notice != nil)
        #expect(MessagesStreamOutcome(model: nil, stopReason: "end_turn").notice == nil)
    }
}

@Suite("Request")
struct RequestTests {
    @Test func bodyAndHeaders() throws {
        let request = try MessagesRequest(prompt: "Hi").urlRequest(apiKey: "test-key")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["stream"] as? Bool == true)
        #expect(body["fallbacks"] as? String == "default")
        #expect((body["thinking"] as? [String: String]) == ["type": "adaptive", "display": "summarized"])
        #expect((body["output_config"] as? [String: String]) == ["effort": "medium"])
    }
}
