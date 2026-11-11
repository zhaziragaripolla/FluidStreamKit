#if DEBUG
import SwiftUI

/// A small surface streamed message by message, for Xcode previews.
@MainActor
private func sampleStore() -> A2UISurfaceStore {
    let jsonl = """
    {"version":"1.0","createSurface":{"surfaceId":"trip","catalogId":"https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"}}
    {"version":"1.0","updateComponents":{"surfaceId":"trip","components":[{"id":"root","component":"Column","children":["title","card","stops","agree","nights","book"]},{"id":"title","component":"Text","text":"## A slow weekend in Lisbon"},{"id":"card","component":"Card","child":"card-body"},{"id":"card-body","component":"Column","children":["stay","price"]},{"id":"stay","component":"Text","text":{"@call":"formatString","args":{"value":"#### ${/stay/name}"}}},{"id":"price","component":"Text","variant":"caption","text":{"@path":"/stay/price"}},{"id":"stops","component":"List","children":{"componentId":"stop","path":"/stops"}},{"id":"stop","component":"Row","children":["stop-icon","stop-name"]},{"id":"stop-icon","component":"Icon","name":"locationOn"},{"id":"stop-name","component":"Text","text":{"@path":"name"}},{"id":"agree","component":"CheckBox","label":"Late checkout","value":{"@path":"/form/late"}},{"id":"nights","component":"Slider","label":"Nights","min":1,"max":7,"value":{"@path":"/form/nights"}},{"id":"book","component":"Button","variant":"primary","child":"book-label","action":{"event":{"name":"book","context":{"nights":{"@path":"/form/nights"}}}}},{"id":"book-label","component":"Text","text":"Book this stay"}]}}
    {"version":"1.0","updateDataModel":{"surfaceId":"trip","value":{"stay":{"name":"Alfama River Suite","price":"€148 / night"},"stops":[{"name":"Miradouro de Santa Luzia"},{"name":"Tram 28"},{"name":"Time Out Market"}],"form":{"late":false,"nights":2}}}}

    """
    let store = A2UISurfaceStore()
    var decoder = A2UILineDecoder()
    store.apply(decoder.feed(Array(jsonl.utf8)))
    return store
}

#Preview("A2UI surface") {
    ScrollView {
        A2UISurfaceView(store: sampleStore(), surfaceId: "trip") { action in
            print(action)
        }
        .padding()
    }
}
#endif
