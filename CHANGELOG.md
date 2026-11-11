# Changelog

All notable changes to FluidStreamKit. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added
- **A2UI 1.0** (RFC-007). The host speaks 1.0 natively and upgrades v0.9 messages as it decodes them:
  - `@path` and `@call` bindings, `@accessibility`, `@checks`, `@catalogId` and `@metadata`;
  - `createSurface` with inline components and data, and `updateDataModel` where `null` deletes;
  - function calls in both directions (`callRendererFunction`, `callAgentFunction` and their responses), with `allowedCallers` and `requiresUserActivation` enforced;
  - all 14 basic-catalog functions, including `formatString` with nested calls, and a regex dialect that rejects unsafe patterns;
  - `@checks` validation: failing checks disable a Button and show messages under inputs;
  - mixed catalogs resolved per component, `allowedParents` and `allowedChildren`, 1.0 catalog definitions, and renderer capabilities;
  - renderer error messages, such as `INTEGRITY_ERROR` for a duplicate surface;
  - `@accessibility` mapped to VoiceOver, and Markdown headings in Text.
- Tabs, Modal, Video and AudioPlayer, so the basic catalog renders all 18 components natively.
- A conformance suite that runs Google's 43 official A2UI 1.0 examples end to end.
- `FluidStreamHost` (v2, in progress, RFC-005): A2UI message decoding, a JSONL line decoder, per-surface component and data-model state with JSON Pointer bindings, a resolved component tree (pending children, templates, cycle and size limits), input write-back and action messages.
- `FluidStreamHostUI` (v2, in progress): `A2UISurfaceView` and `A2UICatalog`, with native SwiftUI views for Text, Image, Icon, Row, Column, List, Card, Divider, Button, TextField, CheckBox and Slider. Apps add or replace components with `register(_:)`, and media URLs are filtered to http, https and data.
- Catalog schemas, versioning and fallbacks (RFC-006):
  - `A2UIComponentSchema` and `A2UICatalogManifest` describe what a build can render, as JSON, with `agentInstructions()` for the agent's prompt;
  - `A2UIDowncompiler` rewrites unknown or too-new components into their declared fallbacks and reports each substitution;
  - components can ask for a version and name an inline fallback (in `@metadata.extensions` under A2UI 1.0);
  - `A2UICatalog.register(_ schema:)` and `manifest(version:)`.
- `ChoicePicker` and `DateTimeInput` in the basic catalog, and `A2UICatalog.fluid`, which adds a data-driven `Table` under its own catalog id.
- `Examples/GenUIDemo`: a scripted agent streaming a surface, with a custom component and a booking round trip.

### Changed
- `A2UIMessage.createSurface` takes an `A2UISurfaceDefinition`, `updateDataModel` takes a non-optional value, and `A2UIAction` adds `callAgentFunction` and `error`. `A2UISurfaceView` takes `catalogs:`, and `clientCapabilities` is now `rendererCapabilities`.
- `A2UICatalog.basic` uses the 1.0 basic catalog id and still answers to the v0.9 ids.

### Fixed
- Input bindings read live from the store, so a control can't snap back to stale data.

## [1.0.0] - 2026-11-09

### Added
- **FluidStreamCore**
  - `StreamBufferActor`: a fixed-capacity UTF-8 ring buffer.
    - It never splits a character.
    - It applies backpressure when full.
    - It enforces a single producer.
    - It drains backlogs over a bounded number of frames.
  - `DisplayLinkCoordinator`: drains the buffer at most once per display frame.
    - It pauses when idle and in the background, including a background state that existed before `start()`.
  - `FrameTicker`, with `DisplayLinkTicker` (`CADisplayLink` in `.common` mode) and `ManualFrameTicker` for tests.
- **FluidStreamParser**
  - `StreamParser`: a single-pass parser for prose, `<thinking>`, `<tool_call>` JSON and code fences.
    - It handles tags split across chunks.
    - It recovers from malformed or unterminated blocks.
- **FluidStreamUI**
  - `StreamSession`: the whole pipeline. It ignores a second concurrent `start()`, and a session released without `cancel()` doesn't leak its producer.
  - `StreamDocument`: renders into TextKit 2.
    - Only the line being written is ever edited; everything above it is frozen.
    - Inline Markdown renders without flicker as it streams.
  - `StreamTextView` and `FluidStreamView`: auto-scroll that follows new text and stops as soon as the user scrolls back.
  - Accessibility: VoiceOver announces finished sentences, and text follows Dynamic Type.
  - Instruments signposts: each rendered frame appears as a `Frame` interval on the Points of Interest track.
  - `import FluidStreamUI` re-exports Core and Parser, so one import is enough.
- **Examples/AnthropicChat**: a Claude Messages API streaming adapter (SSE parsing and event bridging) and a demo app.
- README, `llms.txt`, RFC-001 to RFC-003, and the MIT license.

### Performance
Measured with Instruments on an iPhone 16 Pro (iOS 26.6.1), 6,000 tokens at 150 tok/s with jitter, median of 3 runs: 2.3 ms/s of hitch time for FluidStreamKit vs 210 ms/s for naive SwiftUI `Text(markdown)`, with no potential hangs.

[1.0.0]: https://github.com/zhaziragaripolla/FluidStreamKit/releases/tag/1.0.0
