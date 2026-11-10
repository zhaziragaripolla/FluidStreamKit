# RFC-006: Catalog Schema, Versioning and Fallbacks

| | |
|---|---|
| **Status** | Draft. First slice implemented on `v2/genui-host` |
| **Module** | `FluidStreamHost` (pure Swift, no UI, so it runs on a device or a server) |
| **Depends on** | RFC-005 (the A2UI host) |

## TL;DR

**Describe every component an app build can render as data: a schema with a version and, optionally, a fallback. Publish that description as a catalog manifest. Use it in two places: the agent reads it to know what it may send, and a deterministic down-compiler rewrites anything a given build can't render into components it can.** An installed app is frozen until its next App Store release, while the agent changes daily. This layer is what keeps old builds rendering something sensible. It doesn't depend on which renderer draws the result, and the hosted control plane (a registry of manifests per app build) is this same logic run as a service.

## Problem

- **The agent can't see the app.** It doesn't know which components this build has, which properties they take, or which versions. Today that knowledge lives in someone's head or in a hand-written prompt.
- **Builds drift.** Version 4.1 of an app knows `HotelCard` with a name and a price. The backend starts sending a `HotelCard` that needs a photo gallery, or a brand-new `FlightCard`. Users on 4.1 see a blank space, or nothing.
- **A2UI leaves this open.** A surface names a `catalogId`, and the client can advertise the catalog ids it supports. There is no version per component and no rule for what to show when a component is unknown. Other renderers we looked at fall back to the reply's plain text.

## Options & Trade-off Matrix

| Criterion | A. Agent prompt lists components by hand | B. One catalog id per app release | **C. Schemas + versions + declared fallbacks (chosen)** |
|---|---|---|---|
| **Agent knows what a build renders** | Only if someone keeps the prompt in sync | Yes, coarsely: one id per release | **Yes, per component and per version**, generated from the app |
| **Old build, newer component** | Blank or broken | The agent must keep one prompt per release | **Rewritten to its declared fallback**, on a server or on the device |
| **New component ships without an app release** | No | No | **Partly**: as its fallback, built from components the build already has |
| **Works with other renderers** | n/a | Yes | **Yes**: the output is plain A2UI |
| **Cost** | None up front, pain later | Many catalogs to maintain | One schema per component, written once |

## Design

**Component schema.** One per component type:

```json
{
  "name": "HotelCard",
  "version": 3,
  "description": "A bookable stay.",
  "properties": [
    {"name": "name", "type": "string", "required": true},
    {"name": "price", "type": "string"},
    {"name": "photos", "type": "array", "since": 3}
  ],
  "fallback": {"components": [
    {"id": "root", "component": "Card", "child": "body"},
    {"id": "body", "component": "Column", "children": ["title", "price"]},
    {"id": "title", "component": "Text", "variant": "h4", "text": {"$prop": "name"}},
    {"id": "price", "component": "Text", "variant": "caption", "text": {"$prop": "price"}}
  ]}
}
```

- `version` is a whole number that goes up when the component gains something an older build can't show.
- `fallback` is a small A2UI fragment. `{"$prop": "name"}` copies a property from the original component, including a data binding if it had one. The fragment's first component takes the original's id, so everything that pointed at the original still points at something.

**Catalog manifest.** `{catalogId, version, components: [schema]}`. An app generates it from its `A2UICatalog`, so it can't drift from the code. It serves three readers:
- the agent, as instructions on what it may send (`agentInstructions()`);
- the down-compiler, as the description of the target build;
- a registry, keyed by app build.

**Asking for a version.** A component may carry `"minVersion": 3`, meaning "only render me if you support version 3 of this type". It's an extra property, so renderers that don't know it ignore it.

**Two ways to degrade:**

1. **Down-compile (deterministic, preferred).** `A2UIDowncompiler(source:target:)` takes the newest catalog (which holds the fallbacks) and the target build's manifest. Any component the target can't render is replaced by its fallback, repeatedly, until everything is supported or no rule applies. With no rule, the component becomes a `Text` of its most text-like property, or an empty container. It returns the rewritten components and a list of substitutions, which is the raw material for observability. The same code runs on a backend, in a hosted service, or on the device.
2. **Inline fallback (no server needed).** A component may name `"fallback": "<component id>"`. A build that doesn't know the type, or is too old for its `minVersion`, renders that other component instead. The agent pays a few extra tokens, and it works with no infrastructure at all.

**What is not in this RFC:** the hosted registry, authentication, and analytics. Those are a separate design once real apps show what they need.

## Risks & Open Questions

- **This extends A2UI.** `minVersion`, `fallback` and the manifest format are ours. They're additive and ignored by other renderers, but the spec may add its own answer. If it does, we adopt theirs and keep the down-compiler.
- **Fallback quality.** A fallback is only as good as the person who wrote it. A booking card that degrades to two lines of text has lost its button. *Mitigation:* fallbacks may include actions, and the substitution report shows how often each one is used.
- **Property-level drift.** v1 handles "unknown type" and "version too new". It doesn't yet strip or rewrite single properties a build doesn't know (the `since` field is recorded for that).
- **Where it runs.** In the request path it adds latency and a point of failure. The design keeps the transform pure and local, so a team can run it in its own backend with manifests fetched from a registry.

## Success Metrics

- A manifest generated from a catalog lists every registered component, and round-trips through JSON unchanged.
- Down-compiling for a build that supports everything changes nothing.
- An unknown or too-new component never reaches a build that can't render it: it's replaced, and the substitution is reported.
- Chained fallbacks (v3 to v2 to basic components) end, even with a rule that loops.
