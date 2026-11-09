# RFC-003: Incremental TextKit 2 Rendering & Velocity-Aware Auto-Scroll

| | |
|---|---|
| **Status** | Implemented in 1.0.0 |
| **Module** | `FluidStreamUI` |
| **Depends on** | RFC-001 (one flush per frame), RFC-002 (block events) |

## TL;DR

**Render into a TextKit 2 `UITextView`, and edit only the tail of the document: append to code and tool blocks, and re-render the one paragraph still being written.** Everything above the tail is *frozen*: it's never edited again, so it's never laid out again. Per-frame cost is therefore bounded by the size of the live paragraph, not of the document. Auto-scroll follows the tail until the user's finger moves the content down by 2 pt. At that point it detaches immediately, and it re-attaches only when a scroll is *projected* to land near the bottom. We keep `UITextView`, rather than writing a custom layer renderer, because it gives us selection, copy, VoiceOver and Dynamic Type for free. The custom renderer stays available as an escape hatch if profiling shows `UITextView` overhead.

## Problem

- `Text(AttributedString(markdown: whole))` rebuilds and re-lays-out the entire response every time it changes. At 120 updates/s on a 20 KB answer, that's the hitch we're here to remove.
- Inline Markdown changes the visible text: `**bold**` displays as **bold** without the asterisks. A naive append-only model would therefore show `**bo` and then have to rewrite it.
- Users scroll up to re-read while text is still streaming. If auto-scroll yanks them back down, that's the most common complaint about streaming chat UIs.

## Options & Trade-off Matrix

| Criterion | A. SwiftUI `Text(markdown)` re-render | **B. `UITextView` (TextKit 2) + tail-only edits (chosen)** | C. Custom `NSTextLayoutManager` + layer-per-fragment view |
|---|---|---|---|
| **Main-thread cost per frame** | O(document): re-parse, then full re-layout | **O(live paragraph)**. TextKit 2 re-lays-out only changed elements, and only in the viewport | O(live paragraph) |
| **Selection / copy / VoiceOver / Dynamic Type** | ✅ Free | ✅ Free | ❌ Must rebuild each: weeks of work and a big accessibility risk |
| **Memory** | Several full-document copies (String, AttributedString, SwiftUI diff) | One `NSTextStorage`. Fragments are created lazily for the viewport | Same as B, plus a layer per visible fragment |
| **Control over drawing** (code backgrounds, thinking styling) | Low | Medium, through a custom `NSTextLayoutFragment` delegate | Full |
| **Main risk** | Doesn't scale | **Silent fallback to TextKit 1** if any code touches `textView.layoutManager`. That turns every edit into a full re-layout. Guarded by a debug assert and code review | Large surface area and bugs we'd own |
| **Complexity** | Very low | Medium | High |

## Design

```
FrameBatch ─▶ StreamParser ─events─▶ StreamDocument ─(one editing transaction per frame)─▶ NSTextContentStorage
                                                                                  │
                                    UITextView(usingTextLayoutManager) ◀── NSTextLayoutManager (viewport layout)
```

1. **Frozen prefix + live tail.** `StreamDocument` keeps `frozenLength`. Prose and thinking text goes into a small `tailSource` buffer that holds the raw Markdown of the current line. Each frame, the range `frozenLength…end` is replaced with the freshly rendered line. A newline or a block boundary finalizes the line and moves `frozenLength` forward. Code and tool-call text is append-only: it never needs rewriting, so it freezes immediately.
2. **Optimistic inline Markdown.** While a line is live, an unclosed `**bo` renders as bold **bo** with the marker hidden. A trailing undecided marker (`**` at the very end) is hidden too. This avoids the "asterisks flash, then vanish" flicker. If the line ends with the marker still unclosed, the final render shows it literally. That's one rewrite, and it's still within the tail.
   - Openers and closers follow CommonMark's flanking rule, so `2 * 3` stays literal.
   - Only `*` counts as emphasis, not `_`, so `snake_case` never turns italic.
3. **Block-level styling** happens per paragraph:
   - headings `#`–`###`
   - bullets (`- `, `* `, `+ `, rendered as `•`)
   - numbered lists (with a hanging indent)
   - code blocks: monospace plus a background
   - thinking: secondary color
   - tool calls: small monospace

   Code backgrounds are drawn by an `NSTextLayoutFragment` subclass returned from the layout delegate. Text attributes alone can't paint a full-width background.
4. **One editing transaction per frame.** All of a frame's events are applied inside a single `performEditingTransaction`, so TextKit invalidates layout once per frame.
5. **Auto-scroll policy** is a pure state machine (`AutoScrollPolicy`) with tests on the host machine:

   | Event | Effect |
   |---|---|
   | Drag begins | Pause following (never fight the finger) |
   | Drag translation > 2 pt toward earlier content | **Detach immediately**, without waiting for an offset threshold |
   | Drag ends, *projected* landing ≤ 32 pt from bottom | Re-attach when the scroll lands |
   | Scroll settles ≤ 32 pt from bottom | Re-attach |
   | Status-bar tap (scroll to top) | Detach |
   | "Jump to latest" | Re-attach and scroll |

   While following, the view sets `contentOffset` once per frame **without animation**. An animated scroll at 120 Hz queues overlapping animations and causes stutter.
6. **SwiftUI boundary.** `FluidStreamView` is a `UIViewRepresentable` whose `updateUIView` is deliberately empty. Tokens never pass through SwiftUI state.

## Risks & Open Questions

- **A very long single paragraph** (thousands of characters with no newline) makes the live tail expensive to re-render. *Mitigation if needed:* freeze the tail at sentence boundaries beyond 2 KB.
- **`[text` shows its bracket until `](` arrives,** then the bracket disappears. This is a deliberate trade-off: hiding every `[` optimistically would hide legitimate brackets.
- **Dynamic Type changes** need a re-style pass over frozen text. That's a one-off O(N) operation, triggered by `UIContentSizeCategory.didChangeNotification` rather than by streaming, and it isn't implemented in v1.
- **Collapsing thinking blocks** is deferred to a follow-up. The `.fluidBlock` attribute already marks the ranges.

## Success Metrics

- No edit ever touches the frozen region (asserted in tests every frame).
- The final rendered attributed string is identical however the stream was chunked (asserted in tests).
- 0 hitches above 8.33 ms on a 20 KB response at 150 tok/s (`BenchmarkApp`, Animation Hitches).
- Detach latency: auto-scroll stops on the first drag callback that moves > 2 pt.
