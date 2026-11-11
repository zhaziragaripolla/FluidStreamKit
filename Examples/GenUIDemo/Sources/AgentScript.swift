import FluidStreamHostUI

/// What the scripted agent "sends". In a real app these bytes come from your backend.
enum AgentScript {
    static let prompt = "Plan a slow weekend in Lisbon, somewhere with a river view."

    static let intro = "Here's a **slow weekend in Lisbon**. I found a suite in Alfama with a river view, and three stops within a short walk."

    /// One A2UI 1.0 message per line (JSONL). The root arrives first, so its children start as
    /// placeholders. Headings are Markdown; `\u0023` is `#`, escaped so it can't end the raw string.
    static let surface: [String] = [
        #"{"version":"1.0","createSurface":{"surfaceId":"trip","catalogId":"dev.fluidstreamkit.genuidemo:catalog/1"}}"#,
        #"{"version":"1.0","updateComponents":{"surfaceId":"trip","components":[{"id":"root","component":"Column","children":["headline","stay","stops-title","stops","form","book"]}]}}"#,
        #"{"version":"1.0","updateComponents":{"surfaceId":"trip","components":[{"id":"headline","component":"Text","text":"\u0023\u0023\u0023 Your weekend, planned"}]}}"#,
        #"{"version":"1.0","updateComponents":{"surfaceId":"trip","components":[{"id":"stay","component":"StayCard","name":{"@path":"/stay/name"},"price":{"@path":"/stay/price"},"rating":{"@path":"/stay/rating"},"perks":{"@path":"/stay/perks"}}]}}"#,
        #"{"version":"1.0","updateDataModel":{"surfaceId":"trip","path":"/stay","value":{"name":"Alfama River Suite","price":"€148 / night","rating":4.9,"perks":["River view","2 nights","Check-in Sat"]}}}"#,
        #"{"version":"1.0","updateComponents":{"surfaceId":"trip","components":[{"id":"stops-title","component":"Text","text":"\u0023\u0023\u0023\u0023\u0023 Worth a stop"},{"id":"stops","component":"List","children":{"componentId":"stop","path":"/stops"}},{"id":"stop","component":"Row","children":["stop-icon","stop-text"]},{"id":"stop-icon","component":"Icon","name":{"@path":"icon"}},{"id":"stop-text","component":"Column","children":["stop-name","stop-note"]},{"id":"stop-name","component":"Text","text":{"@path":"name"}},{"id":"stop-note","component":"Text","variant":"caption","text":{"@path":"note"}}]}}"#,
        #"{"version":"1.0","updateDataModel":{"surfaceId":"trip","path":"/stops","value":[{"icon":"binoculars.fill","name":"Miradouro de Santa Luzia","note":"Best at sunrise · 4 min walk"}]}}"#,
        #"{"version":"1.0","updateDataModel":{"surfaceId":"trip","path":"/stops/1","value":{"icon":"tram.fill","name":"Tram 28","note":"Ride it early, before the queues"}}}"#,
        #"{"version":"1.0","updateDataModel":{"surfaceId":"trip","path":"/stops/2","value":{"icon":"fork.knife","name":"Time Out Market","note":"Lunch · 15 min by tram"}}}"#,
        #"{"version":"1.0","updateDataModel":{"surfaceId":"trip","path":"/form","value":{"name":"Alex","late":false}}}"#,
        #"{"version":"1.0","updateComponents":{"surfaceId":"trip","components":[{"id":"form","component":"Card","child":"form-body"},{"id":"form-body","component":"Column","children":["name-field","late","for-row"]},{"id":"name-field","component":"TextField","label":"Name on booking","placeholder":"Your full name","value":{"@path":"/form/name"},"@checks":[{"condition":{"@call":"length","args":{"value":{"@path":"/form/name"},"min":2}},"message":"Enter the name on your ID"}]},{"id":"late","component":"CheckBox","label":"Late checkout (free)","value":{"@path":"/form/late"}},{"id":"for-row","component":"Text","variant":"caption","text":{"@call":"formatString","args":{"value":"Booking for ${/form/name}"}}}]}}"#,
        #"{"version":"1.0","updateComponents":{"surfaceId":"trip","components":[{"id":"book","component":"Button","variant":"primary","child":"book-label","@checks":[{"condition":{"@call":"required","args":{"value":{"@path":"/form/name"}}}}],"action":{"event":{"name":"book","userMessage":{"@call":"formatString","args":{"value":"Book ${/stay/name}"}},"context":{"stay":{"@path":"/stay/name"},"name":{"@path":"/form/name"},"late":{"@path":"/form/late"}}}}},{"id":"book-label","component":"Text","text":"Book this stay"}]}}"#,
    ]

    /// The agent's answer to the `book` event: it swaps the button for a confirmation.
    /// Built as values, not string-pasted JSON, because the name is user input.
    static func bookingReply(to event: A2UIActionEvent) -> [JSONValue] {
        let name = event.context["name"]?.displayString ?? ""
        let late = event.context["late"]?.boolValue == true
        let stay = event.context["stay"]?.displayString ?? "your stay"
        let status = "Booked \(stay) for \(name.isEmpty ? "you" : name)" + (late ? " · late checkout" : "")
        return [
            ["version": "1.0", "updateDataModel": ["surfaceId": "trip", "path": "/status", "value": .string(status)]],
            ["version": "1.0", "updateComponents": ["surfaceId": "trip", "components": [
                ["id": "book", "component": "Row", "children": ["done-icon", "done-text"]],
                ["id": "done-icon", "component": "Icon", "name": "checkmark.seal.fill"],
                ["id": "done-text", "component": "Text", "text": ["@path": "/status"],
                 "@accessibility": ["live": "polite"]],
            ]]],
        ]
    }
}
