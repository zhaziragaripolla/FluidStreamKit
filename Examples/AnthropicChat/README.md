# AnthropicChat example

Streams a Claude Messages API response into `FluidStreamKit`.

- **`Sources/AnthropicStreaming/`**: a small, dependency-free adapter you can copy into your app:
  - `SSEParser`: Server-Sent Events parsing. It also works with line readers that drop blank lines, such as `URLSession.AsyncBytes.lines`.
  - `MessagesStreamEvent`: decodes the stream's events (`message_start`, `content_block_*`, `text_delta`, `thinking_delta`, `input_json_delta`, `message_delta`, `ping`, `error`).
  - `MessagesTextBridge`: turns those events into text for `StreamSession`. Text passes through as-is. Thinking and tool-use blocks are wrapped in tags the parser recognizes, so they render as dimmed thinking and tool-call blocks.
  - `MessagesStreamer`: sends the request with `URLSession` and appends each delta to the session's buffer.
- **`App/`**: a one-screen SwiftUI demo.

## Request defaults

| Setting | Value | Why |
|---|---|---|
| Model | `claude-opus-5-5` | The current default model |
| Thinking | adaptive, `display: "summarized"` | Thinking text streams into the thinking block. The default display is empty |
| Effort | `medium` | Claude Opus 5.5's default, made explicit. Try `low` for quick chat |
| Fallbacks | `"default"` (beta `server-side-fallback-2026-07-01`) | If the model declines, the API re-runs the request on a recommended model, on the same stream |
| `max_tokens` | 64,000 | Streaming, so no HTTP timeout concerns |

If the response ends with `stop_reason: "refusal"` or `"max_tokens"`, the app shows a one-line notice under the text.

## Run it

```bash
swift test   # the adapter's tests run on macOS, with no API key needed
```

```bash
cd App && xcodegen generate && open AnthropicChat.xcodeproj
```

Paste your API key into the app; it's kept in memory only. **Never ship an API key inside an app.** In production, have your backend hold the key and relay the stream to the app.
