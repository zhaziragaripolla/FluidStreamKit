# GenUIDemo

A one-screen demo of the v2 GenUI host (RFC-005). A scripted "agent" streams an answer, with no network and no API key:

1. The intro text streams through the v1 engine (`FluidStreamView`).
2. An A2UI v0.9.1 surface then arrives as JSONL, a few bytes at a time. Components that are referenced before they arrive show as placeholders, and bound text fills in when the data model lands.
3. `StayCard` is the app's own component, added with `catalog.register("StayCard")` and decoded with `context.props(as:)`.
4. Typing a name updates the "Booking for" line through the data model. Tapping **Book this stay** shows the `action` message an app would send to its agent, and the scripted agent replies by replacing the button.

## Run it

```bash
cd Examples/GenUIDemo && xcodegen generate && open GenUIDemo.xcodeproj
```

The script is in `Sources/AgentScript.swift`. Edit the JSON there to try other surfaces.
