# RFC-005: Native A2UI GenUI Host

| | |
|---|---|
| **Status** | Draft. Implementation started on `v2/genui-host` |
| **Modules** | `FluidStreamHost` (protocol and state, no UI) and `FluidStreamHostUI` (SwiftUI rendering) |
| **Spec** | [A2UI v0.9.1](https://a2ui.org/specification/v0.9.1-a2ui/), basic catalog. Messages tagged `"v0.9"` are accepted too |
| **Depends on** | RFC-002 (the demuxer routes A2UI payloads), RFC-004 (performance methodology) |

## TL;DR

**Apply A2UI messages to a plain value model: a flat component map plus a JSON data model per surface. Each time a message lands, rebuild a small resolved tree from that model, and render the tree with native SwiftUI views looked up in a catalog the app can extend.** A message only takes effect once its whole JSONL line has arrived. Progressive rendering comes from the protocol itself: agents send many small messages, and a component that points at a child or data that hasn't arrived renders a placeholder. We rejected two alternatives:
- Parsing the JSON of a single message incrementally. It adds a streaming JSON parser for little gain.
- Hosting the reference web renderer in a web view. That would lose native media, accessibility and the 120 Hz budget.

## Problem

- The agent describes an interface, not text: cards, a playing video, a form, a button that books a hotel. Today the app gets a URL in a paragraph.
- A2UI is the payload format with the most momentum: an open, declarative JSON spec with a basic catalog of 18 components. Its official SwiftUI renderer is still listed as planned, and the one community renderer is young.
- The host has to:
  - stream: components arrive over seconds, out of order, and reference each other by id;
  - stay inside the frame budget, alongside the v1 text engine;
  - let the app plug in its own components (the hotel card is the brand);
  - never crash or show raw JSON on a bad payload.

### Spec facts this design relies on (v0.9.1)

- **JSONL envelope.** Each line is one object with `"version"` and exactly one of `createSurface`, `updateComponents`, `updateDataModel`, `deleteSurface`.
- **Flat components.** `updateComponents.components` is a flat list of `{"id", "component": "<Type>", …props}`. Exactly one component has id `root`.
- **Children are ids.** A single child uses `"child": "id"`. Several children use `"children": ["a", "b"]`, or a template: `"children": {"componentId": "row", "path": "/items"}`.
- **Values** are a literal, a binding `{"path": "/json/pointer"}` (relative inside a template), or a function call `{"call": "fn", "args": {…}}`.
- **Data model.** `updateDataModel` takes an optional `path` (a JSON Pointer, default `/`) and an optional `value`. Omitting `value` removes the key.
- **Ordering.** `createSurface` must come first. Component and data updates may arrive in either order, and references may point at things not yet received.
- **Actions.** Client-to-agent messages look like `{"version", "action": {name, surfaceId, sourceComponentId, timestamp, context}}`. The `context` values are resolved from the data model at tap time.

## Options & Trade-off Matrix

| Criterion | A. Web view + reference renderer | B. Incremental JSON parse, render partial components | **C. Line-atomic messages, value model, rebuild resolved tree (chosen)** |
|---|---|---|---|
| **Native media and accessibility** | ❌ Web media and web accessibility | ✅ | ✅ |
| **Main-thread cost per message** | A web view bridge round trip | O(bytes), plus tracking partial state | O(surface components), which is tiny: surfaces are tens of components |
| **Half-arrived JSON on screen** | Handled by the web renderer | Has to be designed for every component | **Impossible by construction**: nothing applies until the line is complete |
| **Custom components** | Need JS and web view glue | ✅ | ✅ `catalog.register("HotelCard") { … }` |
| **Testability** | UI tests only | Hard | **The state model is pure Swift**, so tests run on the Mac without a UI |
| **Complexity** | Low code, heavy runtime | High | Medium |

Option B would only matter for a single huge `updateComponents` message. Agents are encouraged to send small, incremental messages, so v2 accepts the latency of one line.

## Design

```
bytes ──▶ A2UILineDecoder ──▶ A2UIMessage ──▶ A2UISurfaceStore.apply ──▶ A2UISurface (value) ──▶ resolvedTree() ──▶ A2UISurfaceView
          JSONL framing        Decodable        @MainActor @Observable     components + data       ResolvedNode         catalog lookup
```

**`FluidStreamHost`** is Foundation and Observation only, with no UI:

- **`JSONValue`**: a `Sendable`, `Hashable` JSON enum, with RFC 6901 JSON Pointer get, upsert and remove.
- **`A2UILineDecoder`**: a byte-level JSONL framer. It holds the partial last line, so it can be fed straight from `URLSession.bytes` or SSE `data:` payloads. Each line decodes into an `A2UIMessage`. A bad line becomes a diagnostic, never a throw that ends the stream.
- **`A2UISurface`**: a value type holding `surfaceId`, `catalogId`, `theme`, `components: [id: A2UIComponent]` and `dataModel: JSONValue`.
  - `resolvedTree()` walks from `root`, expands templates against the data model, and returns a `ResolvedNode` tree.
  - Missing children become `.pending` nodes. Cycles and depth over 64 become `.invalid` nodes.
  - Node identity is `componentId` plus template scope, so SwiftUI keeps view state across rebuilds.
- **`A2UISurfaceStore`** (`@MainActor @Observable`):
  - applies messages and enforces the ordering rules (an update before `createSurface` is buffered, not dropped);
  - takes two-way input writes;
  - builds the outgoing action messages.
- **`A2UIValue`** resolves a property to a literal, a binding or a call, with relative paths resolved against the template scope. The basic catalog's formatting and validation functions are a follow-up. Until then, an unsupported call resolves to `nil` with a diagnostic.

**`FluidStreamHostUI`** (SwiftUI, iOS 17+ and macOS 14+):

- **`A2UICatalog`**: a map from component type name to a view builder. `A2UICatalog.basic` ships the standard components, and `register(_:)` adds or overrides one.
- **`A2UISurfaceView(store:surfaceId:catalog:)`** renders the resolved tree recursively. Unknown types render the fallback view.
- **Media** (`Video`, `AudioPlayer`) uses AVKit, paused off-screen. This lands after the layout and input components.
- **URL rule from the spec:** only `http:`, `https:`, `data:` and relative URLs are allowed, and `//`-relative URLs are rejected.

**Where the stream comes from.**
- A2UI is transport-agnostic, and its stable bindings are A2A and AG-UI (RFC-006). Plain JSONL over HTTP or SSE works for a custom backend.
- Inside a text answer, A2UI payloads can arrive as a fenced block (```` ```a2ui ````). RFC-002's demuxer already isolates fences, so the renderer forwards that block's bytes to an `A2UILineDecoder`, and the surface appears inline in the answer.

## Rollout

1. **The `FluidStreamHost` state model and decoder, with tests.** This is the first slice on this branch.
2. **`FluidStreamHostUI`** with the layout, text and input components: Text, Image, Icon, Row, Column, List, Card, Divider, Button, TextField, CheckBox, Slider.
3. **The remaining components:** Tabs, Modal, ChoicePicker and DateTimeInput, plus media (Video, AudioPlayer).
4. **The rest:**
   - the catalog functions (`required`, `formatCurrency`, …);
   - `checks` on buttons;
   - `sendDataModel` metadata;
   - inline surfaces inside a `StreamSession` answer.
5. **The example app** with the travel demo, and the RFC-004 additions from the v2 criteria (a mixed surface, 60 Hz, 400 tok/s).

## Risks & Open Questions

- **The spec is moving fast.** v0.8 is already legacy, and the v1.0 pages document renamed fields (`@path`, null deletes). Messages are decoded per version. v1.0 support is a separate, additive decoder once the spec is final.
- **Whole-surface rebuilds.** Every message rebuilds the resolved tree, and SwiftUI diffs it. That's fine for tens of components. If a surface grows to hundreds, move to per-path observation, so that a data change re-renders only the views that read that path. The criteria doc asks for this. *Validation:* Instruments on a 200-component surface.
- **Function calls** (formatting, validation) are a small expression language. Implement the basic catalog's list exactly, and never evaluate anything else.
- **Security.** Agent output is untrusted:
  - URLs are filtered;
  - `openUrl` asks the app's delegate before opening;
  - templates can't expand past a node budget (default 2,000) to cap memory.

## Success Metrics

- Every example payload from the A2UI v0.9.1 pages decodes and resolves to the expected tree (conformance tests).
- Feeding the same JSONL whole, line by line or byte by byte gives an identical surface (asserted in tests, as in RFC-002).
- Fuzzed or truncated input: 0 crashes, and 0 raw JSON shown.
- A mixed surface stays under 5 ms/s hitch time on device (RFC-004).
