# RFC-007: Moving the GenUI Host to A2UI 1.0

| | |
|---|---|
| **Status** | Implemented |
| **Spec** | [A2UI 1.0](https://a2ui.org/specification/v1.0-a2ui/), marked current in [`versions.json`](https://a2ui.org/specification/versions.json), and the [1.0 basic catalog](https://github.com/google/A2UI/tree/main/catalogs/basic/v1) |
| **Updates** | RFC-005 (the host), RFC-006 (where the versioning keys live) |

## Decision

**Speak A2UI 1.0 natively, and upgrade v0.9 messages to 1.0 as they're decoded.** Everything after the decoder (store, tree, catalogs, views) sees one format. A surface remembers the version its agent used, so replies to a v0.9 agent stay in v0.9.

## What changed in the spec, and what the host does

| A2UI 1.0 | Host |
|---|---|
| `"version": "1.0"`; MIME type `application/a2ui+json` | `A2UIVersion.current`, `A2UIVersion.mimeType`. `v0.9` and `v0.9.1` are still accepted. A message with no version is read as 1.0. |
| Bindings are `{"@path": …}`, calls are `{"@call": …}`. A plain `{"path": …}` is data. | `A2UIEvaluator`. `A2UILegacy.upgrade` rewrites v0.9 components. Template `path` stays unprefixed. |
| `@accessibility`, `@checks`, `@catalogId`, `@metadata` on every component | Read through `A2UIComponent` accessors. Literal objects unescape `@@`, and reject other `@` keys with `EXPRESSION_ERROR`. |
| `createSurface`: no `theme`. Optional `catalogId`, inline `components` and `dataModel`. | `A2UISurfaceDefinition`. `theme` is ignored. |
| `updateDataModel` requires `value`; `null` deletes | Enforced for 1.0; a v0.9 message with no value still deletes. |
| Functions run in both directions: `callRendererFunction` and `callAgentFunction`, each with a response | `A2UIFunctionRegistry` (the basic catalog's 14 functions, plus the app's own). The store answers `callRendererFunction` through `onMessageToAgent`. A tapped action whose function isn't registered here becomes `A2UIAction.callAgentFunction`. |
| `allowedCallers` and `requiresUserActivation` | The agent can't call `rendererOnly` functions (`INVALID_FUNCTION_CALL`). Activation-only functions such as `openUrl` run only from an action, and never from a binding or a check. |
| `@checks`, and validation functions return `{valid, code, message, severity}` | `A2UISurface.failingChecks`. A Button with a failing check is disabled and its action doesn't fire. Inputs show the messages. |
| Catalogs can be mixed in one surface, resolved per component: `@catalogId`, then the surface default, then an error | `A2UISurfaceView(catalogs:)`. A component with neither id isn't drawn, as the spec requires. |
| `allowedParents` / `allowedChildren` | `A2UIComponentSchema` carries them. The tree marks a disallowed node `UNALLOWED_PARENT` or `UNALLOWED_CHILD`. |
| Catalog definition format (`protocolVersion`, flat component schemas, `functions` map) | `A2UICatalogManifest.catalogDefinition(functions:)`, for `inlineCatalogs` or publishing. |
| Renderer capabilities `{"1.0": {"supportedCatalogIds", "inlineCatalogs"}}` | `A2UICatalogManifest.rendererCapabilities(supporting:inline:)`. |
| Errors: `INTEGRITY_ERROR` and the others | `A2UIRendererMessage.error`. A duplicate `createSurface` is reported to the agent. |
| Text `variant` is `caption` or `body`; headings are Markdown | `#` to `######` headings render as headings. `h1`–`h5` still work for v0.9 agents. |
| Basic catalog: `placeholder`, `Slider.steps`, `Video.posterUrl`, `ChoicePicker.displayStyle` and `filterable`, 59 icon names | Done. Tabs, Modal, Video and AudioPlayer are new, so all 18 components render natively. |
| Media URL rules: `http(s)://host`, `data:`, same-host relative paths, tabs and backslashes stripped before the check | `A2UIURLPolicy`. `openUrl` allows http and https only. |

## RFC-006 under 1.0

1.0 validates components strictly, so FluidStreamKit's own keys move into the extension slot the spec provides:

- `@metadata.extensions.fluid_fallback` replaces `fallback`.
- `@metadata.extensions.fluid_minVersion` replaces `minVersion`.
- A catalog definition carries `metadata.extensions.fluid_version` for components above version 1.

The plain keys are still read, and v0.9 components are moved automatically.

## Conformance

`Tests/FluidStreamHostTests/Fixtures` holds Google's 43 official 1.0 basic-catalog examples (Apache-2.0, unchanged). `ConformanceTests` runs every one end to end and checks four things:

- It decodes and applies with no diagnostics.
- It builds a tree with nothing pending or invalid.
- Every component type is in the basic catalog.
- Every property, action context and check evaluates without an error.

## Known gaps

- **Strict schema validation.** The host accepts unknown properties instead of sending `VALIDATION_FAILED`. The spec allows renderers to ignore unrecognized keys.
- **The regex dialect.** Pattern size, the forbidden constructs, ASCII `\d` and `\w`, and nested unbounded quantifiers (safety rule 2) are enforced. Rules 3 and 4 (overlapping alternation, adjacent overlapping quantifiers) aren't yet. `$` follows ICU, which also matches before a final newline.
- **`pluralize`** has CLDR rules for English, French, Portuguese, Russian, Ukrainian, Polish, Arabic and the languages with no plural forms. Other languages use the English rule.
- **Icons given as `{"svgPath": …}`** show a placeholder symbol.
- **Agent functions in passive bindings** aren't routed to the agent. Only actions call agent functions; a binding to one resolves to nothing.
- **`live` regions** mark the view as updating frequently. Assertive announcements aren't posted yet.
