# RFC-002: Single-Pass Streaming Block Demuxer

| | |
|---|---|
| **Status** | Implemented in 1.0.0 |
| **Module** | `FluidStreamParser` |
| **Depends on** | RFC-001 (each input chunk is valid UTF-8 and never splits a scalar) |

## TL;DR

**Parse each frame's text delta once, byte by byte, with a small state machine. The machine holds back at most a tag's or a fence line's worth of bytes when a chunk ends mid-token.** The output is a flat stream of `open`, `text`, `close` events for four block kinds: prose, `<thinking>`, `<tool_call>` JSON, and fenced code. The cost per frame is O(new bytes), never O(document). Parsing happens at the **block level only**. Inline Markdown (bold, links, lists) is left to the renderer, which only ever styles the paragraph at the tail of the document. We rejected re-running regexes or a full Markdown parser over the accumulated text, because both repeat O(N) work every frame and turn a long answer into O(N²) main-thread time.

## Problem

- Each 8.33 ms frame delivers a delta of a few hundred bytes (RFC-001), and the delta can end anywhere: `…<thin` in one frame, `king>…` in the next, or `` `` `` followed by `` `swift\n``.
- The renderer has to know *which channel* each byte belongs to, as soon as possible. Thinking renders collapsed and dimmed, tool calls show as a card, code gets monospace styling, and prose renders as Markdown.
- Getting it wrong is visible. If a split tag is misread, `<thin` flashes on screen as literal text and then disappears. If a `</tool_call>` inside a JSON string is treated as a real tag, the rest of the answer gets swallowed.

### Before we build: do we need in-band tags at all?

The Anthropic Messages API already sends thinking and tool use as **separate, typed content blocks** (`thinking_delta`, `input_json_delta`, `text_delta`). For that path, the SSE layer maps block starts directly to `open` and `close` events, and no tag parsing is needed. The demuxer still earns its place for two reasons:

1. **Code fences are always in-band** inside `text_delta`. That case alone justifies a streaming parser.
2. Prompted, proxied or other-model streams put `<thinking>` and `<tool_call>` tags in the text itself.

So the event type is shared, and tag recognition is a configurable feature, not the core reason the module exists.

## Options & Trade-off Matrix

| Criterion | A. Regex over accumulated text each frame | B. Full Markdown AST re-parse (cmark / swift-markdown) each frame | **C. Single-pass byte state machine (chosen)** |
|---|---|---|---|
| **CPU per frame** | O(N) in document size, which grows through the response | O(N), plus building the AST | **O(Δ)**, the new bytes only |
| **Whole response** | O(N²) | O(N²) | **O(N)** |
| **Memory** | A copy of the whole document plus match objects | A full AST every frame, which churns the allocator | A fixed holdback of ≤ 64 bytes, plus the current tool-call JSON |
| **Split tokens across chunks** | Works by accident, because it re-scans everything | Same | **Explicit**: a bounded holdback buffer, tested at every split point |
| **Correctness traps** | `</tool_call>` inside a JSON string; tags inside code | Doesn't know our XML-style tags; needs pre-processing anyway | Depends on context: no tags inside code, and no tag close inside a JSON string |
| **Inline Markdown** | Possible, but fragile | ✅ Full CommonMark | ❌ Out of scope by design. The renderer styles the tail paragraph only |
| **Complexity** | Low code, but unbounded cost | Low code, plus a dependency | Medium: about 400 lines of state machine with exhaustive tests |

## Design

**Contexts** (a stack at most 3 deep):

| Context | Recognizes | Ignores |
|---|---|---|
| prose | `<thinking>`, `<tool_call>`, opening fence at line start | — |
| thinking | `</thinking>`, opening fence at line start | `<tool_call>` |
| tool call | `</tool_call>` **only outside JSON strings** | fences, other tags |
| code fence | its matching closing fence at line start (same character, at least as long). If the parent is thinking, also `</thinking>` at line start (recovery, see below) | all other tags |

**Holdback.** When a byte *might* start a token (`<`, or a space, `` ` `` or `~` at line start), the parser stops emitting and buffers bytes until the token either matches or can't match. A mismatch flushes the buffered bytes as ordinary text and re-processes the byte that broke the match. The holdback is bounded: tags are ≤ 12 bytes, and a fence's info line is capped at 64 bytes. Holdbacks of 15 bytes or fewer fit in Swift's inline small-string storage, so flushing one doesn't allocate on the heap.

**Output** goes through a non-escaping closure (`feed(_:emit:)`), so the parser creates no event arrays. Text events are `Substring` slices of the input chunk, with no copying on the common path.

**Malformed stream recovery:**

- **A truncated token at end of stream** (for example `<thin`) is flushed as text.
- **A block still open at `finish()`** is closed innermost-first with `recovered: true`.
- **An unterminated fence before `</thinking>`.** Models sometimes forget the closing fence. A `</thinking>` at line start inside a code block nested in thinking closes both blocks, and the fence close is marked recovered. Trade-off: a code sample that legitimately starts a line with `</thinking>` inside a thinking block gets cut. We judge that much rarer than the forgotten fence.
- **Tool-call JSON** is checked structurally as it streams (bracket depth and whether we're inside a string). The `toolCallPayload` event reports `isStructurallyComplete`. Full decoding stays with the consumer.

## Risks & Open Questions

- **Tags with attributes** (`<tool_call name="x">`) aren't supported in v1. Literal tags only. If needed, add them by extending the matcher with a bounded attribute scan.
- **Per-byte loop cost.** A Swift `UTF8View` loop should process well over 100 MB/s, which is ≥ 1000× the stream rate. *Validation:* measure throughput in `BenchmarkApp` with Time Profiler.
- **CommonMark edge cases** such as fences inside list items or block quotes are out of scope for v1, and they render as prose.

## Success Metrics

- **Chunking doesn't change the result.** Every test input produces identical events whether it's fed whole, split at every scalar boundary, or fed one scalar at a time (asserted in tests).
- 0 frames where a partial tag is shown as text.
- Parser main-thread time < 0.1 ms per frame at 150 tok/s.
