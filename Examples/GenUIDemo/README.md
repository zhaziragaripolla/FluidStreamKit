# GenUIDemo

A one-screen demo of the v2 GenUI host (RFC-005). A scripted "agent" streams an answer, with no network and no API key:

1. The intro text streams through the v1 engine (`FluidStreamView`).
2. An A2UI 1.0 surface then arrives as JSONL, a few bytes at a time. Components that are referenced before they arrive show as placeholders, and bound text fills in when the data model lands.
3. `StayCard` is the app's own component. The app's catalog has its own id (`dev.fluidstreamkit.genuidemo:catalog/1`), starts from the basic catalog, and adds `StayCard`, decoded with `context.props(as:)`.
4. Typing a name updates the "Booking for" line, a `formatString` over the data model. Clearing the name disables **Book this stay** through its `@checks`. Tapping it shows the `action` message an app would send to its agent, and the scripted agent replies by replacing the button.

## Run it

```bash
cd Examples/GenUIDemo && xcodegen generate && open GenUIDemo.xcodeproj
```

The script is in `Sources/AgentScript.swift`. Edit the JSON there to try other surfaces.
