# Changelog

All notable changes to FluidStreamKit. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org).

## [Unreleased]

### Pending for 1.0.0
- Instruments measurements (Animation Hitches) on a 120 Hz iPhone, median of 3 runs per mode.
- The 30-second comparison video.

## [1.0.0] - not yet tagged

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
