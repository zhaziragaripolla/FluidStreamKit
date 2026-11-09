# FluidStreamKit

[![CI](https://github.com/zhaziragaripolla/FluidStreamKit/actions/workflows/ci.yml/badge.svg)](https://github.com/zhaziragaripolla/FluidStreamKit/actions/workflows/ci.yml)

Render streaming LLM responses on iOS at 80–150+ tokens per second without dropped frames.

`FluidStreamKit` sits between your network stream and the screen:
- It buffers bursty token deltas and flushes them **once per display frame**, in sync with `CADisplayLink`.
- It splits the stream into prose, `<thinking>`, tool calls and code blocks with a **single-pass parser**.
- It renders into a **TextKit 2** text view, editing only the line being written.

SwiftUI never re-renders the whole answer per token, and the main thread never re-parses it.

- **Swift 6:** strict concurrency, actor-isolated, no data races (tests run clean under Thread Sanitizer).
- **Zero dependencies:** pure Swift Package Manager.
- **iOS 17+**, plus macOS 14+ for running the tests on your Mac.

## Installation

In Xcode, choose File ▸ Add Package Dependencies, or add it to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/zhaziragaripolla/FluidStreamKit.git", from: "1.0.0"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "FluidStreamUI", package: "FluidStreamKit"),
    ]),
]
```

**For 120 Hz on iPhone**, add this key to your app's Info.plist. Without it, iOS caps the display link at 60 Hz. That's still smooth, just not ProMotion.

```xml
<key>CADisableMinimumFrameDurationOnPhone</key>
<true/>
```

## Quickstart (SwiftUI)

```swift
import SwiftUI
import FluidStreamUI

struct AnswerView: View {
    let deltas: @Sendable () -> AsyncThrowingStream<String, any Error>   // your SSE text deltas
    @State private var session = StreamSession()

    var body: some View {
        FluidStreamView(renderer: session.renderer)
            .task {
                await session.start { buffer in
                    for try await delta in deltas() {
                        try await buffer.append(delta)
                    }
                }   // returning finishes the stream; throwing cancels it
            }
            .onDisappear { session.cancel() }
    }
}
```

That's the whole integration:
- `start` runs your producer off the main actor.
- `buffer.append` applies backpressure if the buffer fills.
- The view renders at most once per frame, and follows the newest text until the user scrolls up.

## How it works

```
your SSE producer ──append──▶ StreamBufferActor ──once per vsync──▶ StreamParser ──events──▶ StreamDocument (TextKit 2)
    (any isolation)           UTF-8 ring buffer   DisplayLinkCoordinator   single pass          frozen text + live tail
```

| Module | What it does |
|---|---|
| `FluidStreamCore` | `StreamBufferActor`, a fixed-capacity UTF-8 ring buffer that never splits a character, and `DisplayLinkCoordinator`, which drains it once per frame and pauses when idle or in the background |
| `FluidStreamParser` | `StreamParser`, which splits deltas into prose, `<thinking>`, `<tool_call>` JSON and code fences. It handles tags split across chunks (`<thin` + `king>`) |
| `FluidStreamUI` | `StreamSession` (the whole pipeline), `FluidStreamView` (SwiftUI), `StreamTextView` (UIKit) and `StreamTheme` |

Apps only need `import FluidStreamUI`. It re-exports the other two modules, so types such as `ParserConfiguration` and `FlushPolicy` are available without extra imports.

The design decisions and trade-offs are written up in [RFC-001](Docs/RFCs/RFC-001-display-synchronized-token-buffering.md) (buffering), [RFC-002](Docs/RFCs/RFC-002-streaming-block-demuxer.md) (parsing) and [RFC-003](Docs/RFCs/RFC-003-incremental-textkit2-rendering.md) (rendering).

## Common tasks

**React to tool calls.** You get the full JSON once the call closes, plus a structural check:
```swift
session.renderer.onToolCall = { json, isStructurallyComplete in
    // decode `json`; when isStructurallyComplete is false, the call was cut off or unbalanced
}
```

**Show a "Jump to latest" button** when the user scrolls away from the newest text:
```swift
FluidStreamView(renderer: session.renderer, onFollowingChanged: { following in showJumpButton = !following })
```

**Use your own tag names** if your model emits different ones:
```swift
StreamSession(parserConfiguration: ParserConfiguration(thinkingTag: "reasoning", toolCallTag: "invoke"))
```

**Style it** by passing your own fonts and colors: `StreamSession(theme: myTheme)`, starting from `StreamTheme.standard()`.

**Render text you already have**, for example a saved answer, without the buffer:
```swift
let renderer = StreamRenderer()
renderer.apply(text: savedAnswer, isFinal: true)
```

**Stream from Claude's Messages API:** see [Examples/AnthropicChat](Examples/AnthropicChat). It contains a small, tested adapter (SSE parsing plus event bridging) that you can copy into your app, and a runnable SwiftUI demo. Thinking and tool-use blocks render as their own blocks, and refusals and errors surface as a notice.

**Accessibility is on by default:**
- VoiceOver hears finished sentences as they stream, at most one announcement every ~1.5 s, never one per token. Code blocks are announced once as "Code block", and thinking and tool calls are skipped.
- Text re-scales when the user changes Dynamic Type.

Turn either off with `StreamTextView.announcesStreamingText` or `followsDynamicType`.

## Things to know

- **Append chunks, not single bytes.** Each `append` is an actor hop.
- **Call `cancel()` when the view goes away.** A session released without it also cleans up after itself.
- **Don't touch `StreamTextView.textView.layoutManager`.** Reading it silently switches the text view to TextKit 1, and every edit becomes a full re-layout. Use `textLayoutManager`.
- **Inline Markdown is styled on the line being written:** bold, italic, code, links, headings, lists and quotes. Underscores never mean italics, so `snake_case` is safe. Tables and nested block quotes aren't supported in v1.

## Performance

Measured with Instruments on an iPhone 16 Pro (iOS 26.6.1, 120 Hz), using the [FluidStreamBench](https://github.com/zhaziragaripolla/FluidStreamBench) harness: 6,000 tokens at 150 tok/s with network jitter, seed 42, Release build.

| | FluidStreamKit | Naive SwiftUI `Text(markdown)` |
|---|---|---|
| Hitch time per second of streaming (median of 3 runs) | **2.3 ms/s** (good: under 5) | 210 ms/s (critical: over 10) |
| Hitches per run | 4–14, almost all one frame | 435–458, up to 392 ms |
| Potential hangs per run | 0 | 6–22 |
| Main-thread time per text update | p50 5.9 ms · p99 8.0 ms (budget: 8.33 ms at 120 Hz) | n/a |

About 80% of each text update is TextKit laying out the visible text; parsing and editing take the rest.

## Development

```bash
swift test
```

The tests run on macOS: the rendering code builds against AppKit's TextKit 2 there and UIKit's on iOS. There are no dependencies to fetch.

## License

MIT. See [LICENSE](LICENSE).
