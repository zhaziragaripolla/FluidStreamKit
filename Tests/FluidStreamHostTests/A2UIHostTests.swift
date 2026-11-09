import Foundation
import Testing
@testable import FluidStreamHost

// Payloads below are the A2UI v0.9.1 examples from a2ui.org (messages reference, data binding
// and actions pages), so these double as the start of the conformance suite.

let profileStream = """
{"version": "v0.9.1", "createSurface": {"surfaceId": "user_profile_card", "catalogId": "https://a2ui.org/specification/v0_9_1/catalogs/basic/catalog.json", "theme": {"primaryColor": "#00BFFF"}, "sendDataModel": true}}
{"version": "v0.9.1", "updateComponents": {"surfaceId": "user_profile_card", "components": [{"id": "root", "component": "Column", "children": ["user_name", "user_title"]}, {"id": "user_name", "component": "Text", "text": {"path": "/user/name"}}, {"id": "user_title", "component": "Text", "text": "Software Engineer"}]}}
{"version": "v0.9.1", "updateDataModel": {"surfaceId": "user_profile_card", "path": "/user/name", "value": "Jane Doe"}}

"""

@MainActor
func store(feeding text: String, chunkSize: Int? = nil) -> A2UISurfaceStore {
    let store = A2UISurfaceStore()
    var decoder = A2UILineDecoder()
    let bytes = Array(text.utf8)
    let size = chunkSize ?? max(bytes.count, 1)
    var i = 0
    while i < bytes.count {
        store.apply(decoder.feed(bytes[i..<min(i + size, bytes.count)]))
        i += size
    }
    store.apply(decoder.finish())
    return store
}

/// The tree as a compact string: `id(child,child)`, with `?` for pending and `!` for invalid.
func shape(_ node: ResolvedNode) -> String {
    let mark: String
    switch node.state {
    case .ready: mark = ""
    case .pending: mark = "?"
    case .invalid: mark = "!"
    }
    let kids = node.children.isEmpty ? "" : "(" + node.children.map(shape).joined(separator: ",") + ")"
    return node.id + mark + kids
}

@Suite("JSON Pointer")
struct JSONPointerTests {
    @Test func parsesAndEscapes() {
        #expect(JSONPointer("/")?.tokens == [])
        #expect(JSONPointer("")?.tokens == [])
        #expect(JSONPointer("/a~1b/c~0d/0")?.tokens == ["a/b", "c~d", "0"])
        #expect(JSONPointer("no-slash") == nil)
        #expect(JSONPointer(tokens: ["a/b", "c~d"]).description == "/a~1b/c~0d")
    }

    @Test func resolvesRelativeInScope() {
        let scope = JSONPointer("/products/0")!
        #expect(JSONPointer.resolve("name", in: scope)?.description == "/products/0/name")
        #expect(JSONPointer.resolve("/user", in: scope)?.description == "/user")
    }

    @Test func setUpsertsAndRemoves() {
        var model: JSONValue = [:]
        let writes = [
            model.set("Jane", at: JSONPointer("/user/name")!),
            model.set(["a"], at: JSONPointer("/list")!),
            model.set("b", at: JSONPointer("/list/1")!),      // index == count appends
            model.set("c", at: JSONPointer("/list/-")!),
            model.set("x", at: JSONPointer("/list/9")!),      // out of range: rejected
        ]
        #expect(writes == [true, true, true, true, false])
        #expect(model.value(at: JSONPointer("/user/name")!) == "Jane")
        #expect(model.value(at: JSONPointer("/list")!) == ["a", "b", "c"])
        let removed = model.remove(at: JSONPointer("/list/0")!)
        #expect(removed)
        #expect(model.value(at: JSONPointer("/list")!) == ["b", "c"])
        let replaced = model.set(["replaced": true], at: .root)
        #expect(replaced)
        #expect(model == ["replaced": true])
    }

    @Test func displayStringFollowsA2UIRules() {
        #expect(JSONValue.number(4).displayString == "4")
        #expect(JSONValue.number(4.5).displayString == "4.5")
        #expect(JSONValue.bool(true).displayString == "true")
        #expect(JSONValue.null.displayString == "")
        let object: JSONValue = ["a": 1]
        #expect(object.displayString == #"{"a":1}"#)
    }
}

@Suite("Message decoding")
struct MessageDecodingTests {
    @Test func decodesAllFourMessages() throws {
        let create = try A2UIMessage.decode(line: Data(#"{"version": "v0.9", "createSurface": {"surfaceId": "main", "catalogId": "c"}}"#.utf8))
        #expect(create == .createSurface(surfaceId: "main", catalogId: "c", theme: nil, sendDataModel: false))

        let update = try A2UIMessage.decode(line: Data(#"{"version":"v0.9.1","updateComponents":{"surfaceId":"s","components":[{"id":"root","component":"Text","text":"Hi","variant":"h1"}]}}"#.utf8))
        #expect(update == .updateComponents(surfaceId: "s", components: [
            A2UIComponent(id: "root", type: "Text", properties: ["text": "Hi", "variant": "h1"]),
        ]))

        let removal = try A2UIMessage.decode(line: Data(#"{"version":"v0.9.1","updateDataModel":{"surfaceId":"s","path":"/a"}}"#.utf8))
        #expect(removal == .updateDataModel(surfaceId: "s", path: "/a", value: nil))

        let wholeModel = try A2UIMessage.decode(line: Data(#"{"updateDataModel":{"surfaceId":"s","value":{"a":1}}}"#.utf8))
        #expect(wholeModel == .updateDataModel(surfaceId: "s", path: "/", value: ["a": 1]))

        let delete = try A2UIMessage.decode(line: Data(#"{"version":"v0.9.1","deleteSurface":{"surfaceId":"s"}}"#.utf8))
        #expect(delete == .deleteSurface(surfaceId: "s"))
    }

    @Test func rejectsBadEnvelopes() {
        func error(_ line: String) -> A2UIDecodingError? {
            do { _ = try A2UIMessage.decode(line: Data(line.utf8)); return nil } catch { return error }
        }
        #expect(error(#"{"version":"v0.8","surfaceUpdate":{}}"#) == .unsupportedVersion("v0.8"))
        #expect(error(#"{"version":"v0.9","createSurface":{"surfaceId":"s"}}"#) == .missingField("catalogId", message: "createSurface"))
        #expect(error(#"{"version":"v0.9","createSurface":{},"deleteSurface":{}}"#) != nil)
        #expect(error("[1,2]") == .notAnObject)
        #expect(error(#"{"version":"v0.9","updateComp"#) == .invalidJSON)
    }

    @Test func skipsMalformedComponentsButKeepsTheRest() throws {
        let message = try A2UIMessage.decode(line: Data(#"{"updateComponents":{"surfaceId":"s","components":[{"id":"a"},{"component":"Text"},{"id":"ok","component":"Divider"}]}}"#.utf8))
        #expect(message == .updateComponents(surfaceId: "s", components: [A2UIComponent(id: "ok", type: "Divider")]))
    }
}

@Suite("Line decoder")
struct LineDecoderTests {
    @Test func holdsPartialLinesAndSkipsBlanks() throws {
        var decoder = A2UILineDecoder()
        #expect(decoder.feed(Array(#"{"deleteSurface":{"surf"#.utf8)).isEmpty)
        let out = decoder.feed(Array("aceId\":\"s\"}}\r\n\n   \n".utf8))
        #expect(out.count == 1)
        #expect(try out[0].get() == .deleteSurface(surfaceId: "s"))
    }

    @Test func finishDecodesUnterminatedLastLine() {
        var decoder = A2UILineDecoder()
        _ = decoder.feed(Array(#"{"deleteSurface":{"surfaceId":"s"}}"#.utf8))
        #expect(decoder.finish().count == 1)
    }

    @Test func badLineDoesNotStopTheStream() throws {
        var decoder = A2UILineDecoder()
        let out = decoder.feed(Array("not json\n{\"deleteSurface\":{\"surfaceId\":\"s\"}}\n".utf8))
        #expect(out.count == 2)
        #expect(out[0] == .failure(.invalidJSON))
        #expect(try out[1].get() == .deleteSurface(surfaceId: "s"))
    }

    @Test func dropsOverlongLines() {
        var decoder = A2UILineDecoder(maxLineBytes: 16)
        let out = decoder.feed(Array((String(repeating: "x", count: 40) + "\n{\"deleteSurface\":{\"surfaceId\":\"s\"}}\n").utf8))
        #expect(out.count == 2)
        #expect(out[0] == .failure(.lineTooLong(bytes: 40)))
    }
}

@Suite("Surface store")
@MainActor
struct SurfaceStoreTests {
    @Test func appliesSpecExampleAndResolvesBinding() throws {
        let store = store(feeding: profileStream)
        let surface = try #require(store.surfaces["user_profile_card"])
        #expect(surface.sendDataModel)
        let tree = try #require(surface.resolvedTree())
        #expect(shape(tree) == "root(user_name,user_title)")
        let name = try #require(tree.children[0].component)
        #expect(surface.string("text", of: name) == "Jane Doe")
        #expect(store.diagnostics.isEmpty)
    }

    @Test func chunkingDoesNotChangeTheResult() {
        let whole = store(feeding: profileStream).surfaces
        for size in [1, 2, 3, 7, 64] {
            #expect(store(feeding: profileStream, chunkSize: size).surfaces == whole)
        }
    }

    @Test func pendingChildrenRenderAsPlaceholdersUntilTheyArrive() throws {
        let store = A2UISurfaceStore()
        store.apply(.createSurface(surfaceId: "s", catalogId: "c", theme: nil, sendDataModel: false))
        #expect(store.surfaces["s"]?.resolvedTree() == nil)   // no root yet
        store.apply(.updateComponents(surfaceId: "s", components: [
            A2UIComponent(id: "root", type: "Card", properties: ["child": "body"]),
        ]))
        #expect(shape(try #require(store.surfaces["s"]?.resolvedTree())) == "root(body?)")
        store.apply(.updateComponents(surfaceId: "s", components: [
            A2UIComponent(id: "body", type: "Text", properties: ["text": "Hello"]),
        ]))
        #expect(shape(try #require(store.surfaces["s"]?.resolvedTree())) == "root(body)")
    }

    @Test func updatesBeforeCreateSurfaceAreBuffered() throws {
        let store = A2UISurfaceStore()
        store.apply(.updateComponents(surfaceId: "s", components: [A2UIComponent(id: "root", type: "Divider")]))
        store.apply(.updateDataModel(surfaceId: "s", path: "/x", value: 1))
        #expect(store.surfaces["s"] == nil)
        store.apply(.createSurface(surfaceId: "s", catalogId: "c", theme: nil, sendDataModel: false))
        let surface = try #require(store.surfaces["s"])
        #expect(surface.components["root"]?.type == "Divider")
        #expect(surface.dataModel == ["x": 1])
    }

    @Test func duplicateCreateIsReportedAndDeleteRemoves() {
        let store = A2UISurfaceStore()
        store.apply(.createSurface(surfaceId: "s", catalogId: "c", theme: nil, sendDataModel: false))
        store.apply(.createSurface(surfaceId: "s", catalogId: "other", theme: nil, sendDataModel: false))
        #expect(store.surfaces["s"]?.catalogId == "c")
        #expect(store.diagnostics.map(\.message) == ["Surface already exists"])
        store.apply(.deleteSurface(surfaceId: "s"))
        store.apply(.deleteSurface(surfaceId: "missing"))   // no-op
        #expect(store.surfaces.isEmpty)
    }

    @Test func templatesExpandPerItemWithRelativeBindings() throws {
        let store = A2UISurfaceStore()
        store.apply(.createSurface(surfaceId: "s", catalogId: "c", theme: nil, sendDataModel: false))
        store.apply(.updateComponents(surfaceId: "s", components: [
            A2UIComponent(id: "root", type: "List", properties: ["children": ["componentId": "item", "path": "/products"]]),
            A2UIComponent(id: "item", type: "Text", properties: ["text": ["path": "name"]]),
        ]))
        #expect(shape(try #require(store.surfaces["s"]?.resolvedTree())) == "root")   // data not here yet
        store.apply(.updateDataModel(surfaceId: "s", path: "/products", value: [["name": "Tea"], ["name": "Cake"]]))
        let surface = try #require(store.surfaces["s"])
        let tree = try #require(surface.resolvedTree())
        #expect(shape(tree) == "root(item@/products/0,item@/products/1)")
        let texts = tree.children.map { surface.string("text", of: $0.component!, scope: $0.scope) }
        #expect(texts == ["Tea", "Cake"])
    }

    @Test func cyclesAndRunawayTemplatesAreContained() throws {
        let store = A2UISurfaceStore()
        store.apply(.createSurface(surfaceId: "s", catalogId: "c", theme: nil, sendDataModel: false))
        store.apply(.updateComponents(surfaceId: "s", components: [
            A2UIComponent(id: "root", type: "Column", properties: ["children": ["a"]]),
            A2UIComponent(id: "a", type: "Card", properties: ["child": "root"]),
        ]))
        #expect(shape(try #require(store.surfaces["s"]?.resolvedTree())) == "root(a(root!))")

        store.apply(.updateComponents(surfaceId: "s", components: [
            A2UIComponent(id: "root", type: "List", properties: ["children": ["componentId": "row", "path": "/rows"]]),
            A2UIComponent(id: "row", type: "Text"),
        ]))
        store.apply(.updateDataModel(surfaceId: "s", path: "/rows", value: .array(Array(repeating: 0, count: 10_000))))
        var limits = A2UISurface.Limits()
        limits.maxNodes = 100
        let tree = try #require(store.surfaces["s"]?.resolvedTree(limits: limits))
        #expect(tree.children.count == 99)
    }

    @Test func modalAndTabsChildrenAreReachable() throws {
        let store = A2UISurfaceStore()
        store.apply(.createSurface(surfaceId: "s", catalogId: "c", theme: nil, sendDataModel: false))
        store.apply(.updateComponents(surfaceId: "s", components: [
            A2UIComponent(id: "root", type: "Tabs", properties: ["tabs": [["title": "General", "child": "m"], ["title": "More", "child": "t2"]]]),
            A2UIComponent(id: "m", type: "Modal", properties: ["trigger": "open", "content": "body"]),
        ]))
        let tree = try #require(store.surfaces["s"]?.resolvedTree())
        #expect(shape(tree) == "root(m(open?,body?),t2?)")
        #expect(tree.child("m")?.child("body")?.componentId == "body")
    }

    @Test func inputWritesBackAndActionsResolveContextAtTapTime() throws {
        let store = A2UISurfaceStore()
        store.apply(.createSurface(surfaceId: "booking-surface", catalogId: "c", theme: nil, sendDataModel: false))
        store.apply(.updateComponents(surfaceId: "booking-surface", components: [
            A2UIComponent(id: "root", type: "Button", properties: [
                "child": "btn-text",
                "action": ["event": ["name": "submit_reservation", "context": ["time": ["path": "/reservationTime"], "size": ["path": "/partySize"]]]],
            ]),
        ]))
        store.setValue("7:00 PM", at: JSONPointer("/reservationTime")!, surfaceId: "booking-surface")
        store.setValue(4, at: JSONPointer("/partySize")!, surfaceId: "booking-surface")

        let tree = try #require(store.surfaces["booking-surface"]?.resolvedTree())
        let now = Date(timeIntervalSince1970: 1_772_016_000)   // 2026-02-25T10:40:00Z
        guard case .event(let event)? = store.action(for: tree, surfaceId: "booking-surface", now: now) else {
            Issue.record("Expected an event action"); return
        }
        #expect(event.context == ["time": "7:00 PM", "size": 4])
        let json = String(decoding: try event.encoded(), as: UTF8.self)
        #expect(json == #"{"action":{"context":{"size":4,"time":"7:00 PM"},"name":"submit_reservation","sourceComponentId":"root","surfaceId":"booking-surface","timestamp":"2026-02-25T10:40:00Z"},"version":"v0.9.1"}"#)
    }

    @Test func functionCallActionsStayOnDevice() throws {
        let store = A2UISurfaceStore()
        store.apply(.createSurface(surfaceId: "s", catalogId: "c", theme: nil, sendDataModel: false))
        store.apply(.updateComponents(surfaceId: "s", components: [
            A2UIComponent(id: "root", type: "Button", properties: [
                "action": ["functionCall": ["call": "openUrl", "args": ["url": "https://a2ui.org/help"]]],
            ]),
        ]))
        let tree = try #require(store.surfaces["s"]?.resolvedTree())
        #expect(store.action(for: tree, surfaceId: "s") == .localFunction(name: "openUrl", args: ["url": "https://a2ui.org/help"]))
    }
}
