# RFC-001: Display-Synchronized Token Buffering

| | |
|---|---|
| **Status** | Implemented in 1.0.0 |
| **Module** | `FluidStreamCore` |

## TL;DR

**Put incoming SSE bytes in an actor-owned, fixed-capacity UTF-8 ring buffer, and drain it once per frame from a `CADisplayLink` on the main actor.** This caps UI mutations at one per vsync (≤120/s) no matter how bursty the network is. It keeps every flush on a valid UTF-8 boundary and gives the producer real backpressure. The cost is a 120 Hz wake-up while streaming, which we limit by pausing the link after a short idle window. We rejected `Combine` throttling/debounce and `DispatchSourceTimer` because neither is phase-locked to the display. Each of them would bring back the hitches this library exists to remove.

## Problem

- At 150 tok/s (~600 B/s) a stream averages ~1.25 tokens per 8.33 ms frame. The network doesn't deliver at that average, though. TCP reads arrive in bursts of 5–20 tokens with gaps of 50–200 ms between them.
- Today's naive path (`@Observable var text` → `Text(markdown)`) invalidates once per token, and every invalidation re-parses the whole document. That's O(N) work per token and O(N²) per response, all on the main thread. Long responses miss frames as a result.
- What we need is **at most one UI mutation per displayed frame, aligned to the frame deadline, and none when there's nothing new.**

## Options & Trade-off Matrix

| Criterion | A. `Combine` `.throttle` / `.debounce` | B. `DispatchSourceTimer` @ 8.33 ms | **C. `CADisplayLink` (chosen)** |
|---|---|---|---|
| **Phase alignment to vsync** | ❌ None. Flushes land at arbitrary points in the frame, so the effective budget varies from 0 to 8.33 ms. | ❌ None. Clock drift makes flushes "beat" against the 120 Hz refresh, giving periodic hitches. | ✅ Phase-locked. `targetTimestamp` gives the real deadline. |
| **Adapts to ProMotion / Low Power (120→60→10 Hz)** | ❌ No | ❌ No. Keeps doing work for frames that are never shown. | ✅ Automatic. Honors `preferredFrameRateRange`. |
| **Behaviour under steady stream** | ⚠️ `debounce` is trailing-edge, so it **starves** while tokens keep arriving. `throttle(latest:)` works but drops the intermediate values unless we accumulate them separately anyway. | ✅ Fires reliably | ✅ Fires reliably |
| **CPU cost when idle** | Low (event-driven) | Medium. The timer keeps firing until we cancel it. | Medium at 120 Hz. **Mitigated** by auto-pausing after N idle frames and waking on the next append. |
| **Memory** | A publisher chain plus a type-erased subscriber, with a possible allocation per value | Small | Small. One `CADisplayLink` plus a weak proxy. |
| **Concurrency fit (Swift 6)** | ⚠️ Poor. Combine isn't `Sendable`-annotated, so we'd need `@preconcurrency` imports. | ⚠️ Fair. It's GCD, not structured concurrency. | ✅ Good. It's `@MainActor` and bridges into an `AsyncStream` with `.bufferingNewest(1)`. |
| **Backgrounding** | Manual | Manual. Keeps firing in the background unless suspended. | Manual (`isPaused`), but the link is cheap to pause and resume. |
| **Complexity** | Low code, high hidden semantics | Low | Medium. Needs a proxy to break the retain cycle, idle-pause logic and lifecycle hooks. |

## Design

```
URLSession.bytes ──append()──▶ StreamBufferActor (UTF-8 ring, cap 64 KiB)
                                      ▲  drain(budget) once per tick
CADisplayLink ─tick─▶ AsyncStream(.bufferingNewest(1)) ─▶ @MainActor consumer ─▶ onFlush(FrameBatch)
```

1. **Ring buffer, not `String +=`.** Bytes are copied once on ingest and once on drain. Capacity is fixed, so nothing reallocates while streaming.
2. **UTF-8-safe drain.** A flush never ends in the middle of a scalar. A trailing partial sequence (for example the first 2 of 🧠's 4 bytes) stays in the buffer until the next frame. Malformed bytes are repaired to U+FFFD, so a bad byte can't stall the stream.
3. **Backpressure.** If the ring is full, `append` suspends the producer, and the next drain resumes it. Cancelling the producer task resumes it with `CancellationError`.
4. **Single-producer contract.** An SSE connection has exactly one reader loop. A second concurrent `append` throws instead of silently interleaving bytes.
5. **Adaptive budget.** Each frame drains `max(maxBytesPerFrame, backlog / catchUpFrames)`. A backlog that piled up while the app was backgrounded therefore clears in a bounded number of frames instead of one giant layout pass.
6. **Tick coalescing.** If the main actor falls behind, ticks that haven't been handled yet collapse to the newest one (`.bufferingNewest(1)`). We never run two drains for one frame.

## Risks & Open Questions

- **Actor-hop latency.** `drain` is `async`, so the flush runs on the main actor's next turn after the vsync callback rather than synchronously inside it. We expect it to land well within the frame because the work inside the actor takes microseconds. *Validation:* use Instruments' Animation Hitches in `BenchmarkApp` and record time from `tick.timestamp` to flush completion. *Fallback:* move to a `Mutex`-guarded ring (iOS 18+) so the drain runs synchronously on main.
- **Battery at 120 Hz.** The 120 Hz rate only applies while bytes are arriving. The link pauses after 6 idle frames (~50 ms). On iPhone this rate also requires `CADisableMinimumFrameDurationOnPhone = YES` in the host app's Info.plist. Without that key iOS caps the link at 60 Hz, and our code still works correctly.
- **Out of scope:** markdown/tag parsing (RFC-002) and TextKit 2 layout (RFC-003).

## Success Metrics

- 0 hitches above 8.33 ms in `BenchmarkApp` at 150 tok/s with ±80 ms jitter, on an iPhone 15 Pro at 120 Hz.
- ≤ 1 `onFlush` call per displayed frame (asserted in tests).
- Main-thread time per frame spent in `FluidStreamCore` < 0.5 ms (Time Profiler).
