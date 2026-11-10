import Foundation
import SwiftUI
import Testing
@testable import FluidStreamHost
@testable import FluidStreamHostUI

/// The newest catalog: HotelCard is at v3 and FlightCard is new. Both declare fallbacks.
private let hotelV3 = A2UIComponentSchema(
    name: "HotelCard", version: 3, description: "A bookable stay.",
    properties: [.init("name", .string, required: true), .init("price", .string), .init("photos", .array, since: 3)],
    fallback: .init(components: [
        ["id": "root", "component": "Card", "child": "body"],
        ["id": "body", "component": "Column", "children": ["title", "price"]],
        ["id": "title", "component": "Text", "variant": "h4", "text": ["$prop": "name"]],
        ["id": "price", "component": "Text", "variant": "caption", "text": ["$prop": "price"]],
    ]))

private let flightV1 = A2UIComponentSchema(
    name: "FlightCard",
    fallback: .init(components: [["id": "root", "component": "HotelCard", "minVersion": 3, "name": ["$prop": "route"]]]))

private let newest = A2UICatalogManifest(
    catalogId: "app", version: "5.0", components: A2UIComponentSchema.basicSubset + [hotelV3, flightV1])

/// An old build: it has HotelCard v1 and no FlightCard.
private let oldBuild = A2UICatalogManifest(
    catalogId: "app", version: "4.1",
    components: A2UIComponentSchema.basicSubset + [A2UIComponentSchema(name: "HotelCard", version: 1)])

@Suite("Catalog manifest")
struct CatalogManifestTests {
    @Test func roundTripsThroughJSONAndIsStable() throws {
        let data = try newest.encoded()
        #expect(try A2UICatalogManifest.decode(data) == newest)
        #expect(try newest.encoded() == data)
        #expect(newest.components.map(\.name) == newest.components.map(\.name).sorted())
    }

    @Test func decodesAMinimalHandWrittenManifest() throws {
        let json = #"{"catalogId":"c","version":"1","components":[{"name":"Thing","properties":[{"name":"title"}]}]}"#
        let manifest = try A2UICatalogManifest.decode(Data(json.utf8))
        let thing = try #require(manifest.schema(for: "Thing"))
        #expect(thing.version == 1)
        #expect(thing.properties == [.init("title", .any)])
    }

    @Test func supportsChecksTypeAndVersion() {
        #expect(oldBuild.supports(A2UIComponent(id: "a", type: "HotelCard")))
        #expect(!oldBuild.supports(A2UIComponent(id: "a", type: "HotelCard", properties: ["minVersion": 3])))
        #expect(!oldBuild.supports(A2UIComponent(id: "a", type: "FlightCard")))
        #expect(newest.supports(A2UIComponent(id: "a", type: "HotelCard", properties: ["minVersion": 3])))
    }

    @Test func agentInstructionsListEveryComponent() {
        let text = newest.agentInstructions()
        #expect(text.contains(#"catalogId "app" (version 5.0)"#))
        #expect(text.contains("- HotelCard (v3): A bookable stay."))
        #expect(text.contains("    name: string, required"))
        for schema in newest.components { #expect(text.contains("- \(schema.name) (v")) }
        #expect(newest.clientCapabilities == ["v0.9.1": ["supportedCatalogIds": ["app"]]])
    }
}

@Suite("Down-compiler")
struct DowncompilerTests {
    let compiler = A2UIDowncompiler(source: newest, target: oldBuild)

    @Test func supportedComponentsPassThroughUnchanged() {
        let components = [
            A2UIComponent(id: "root", type: "Column", properties: ["children": ["h"]]),
            A2UIComponent(id: "h", type: "HotelCard", properties: ["name": "Suite"]),
        ]
        let result = compiler.downcompile(components)
        #expect(result.components == components)
        #expect(result.substitutions.isEmpty)
        #expect(A2UIDowncompiler(source: newest, target: newest).downcompile(components).components == components)
    }

    @Test func tooNewComponentBecomesItsDeclaredFallback() {
        let card = A2UIComponent(id: "stay", type: "HotelCard", properties: [
            "minVersion": 3, "name": ["path": "/stay/name"], "price": "€148", "photos": ["a.jpg"],
        ])
        let result = compiler.downcompile([card])
        #expect(result.components == [
            A2UIComponent(id: "stay", type: "Card", properties: ["child": "stay~body"]),
            A2UIComponent(id: "stay~body", type: "Column", properties: ["children": ["stay~title", "stay~price"]]),
            // The data binding is carried over, so the fallback still updates live.
            A2UIComponent(id: "stay~title", type: "Text", properties: ["variant": "h4", "text": ["path": "/stay/name"]]),
            A2UIComponent(id: "stay~price", type: "Text", properties: ["variant": "caption", "text": "€148"]),
        ])
        #expect(result.substitutions == [.init(
            componentId: "stay", type: "HotelCard",
            reason: .newerVersion(required: 3, supported: 1), outcome: .declaredFallback)])
    }

    @Test func fallbacksChainUntilTheBuildCanRenderEverything() {
        // FlightCard falls back to HotelCard v3, which this build is also too old for.
        let result = compiler.downcompile([A2UIComponent(id: "f", type: "FlightCard", properties: ["route": "LIS → OPO"])])
        #expect(result.components.map(\.type) == ["Card", "Column", "Text", "Text"])
        #expect(result.components[2].properties["text"] == "LIS → OPO")
        #expect(result.components[3].properties["text"] == nil)   // no price was given: property dropped
        #expect(result.substitutions.map(\.type) == ["FlightCard", "HotelCard"])
        #expect(result.components.allSatisfy(oldBuild.supports))
    }

    @Test func aRuleThatLoopsStillEnds() {
        let loop = A2UIComponentSchema(name: "Loop", fallback: .init(components: [["id": "root", "component": "Loop"]]))
        let source = A2UICatalogManifest(catalogId: "app", version: "9", components: [loop])
        let result = A2UIDowncompiler(source: source, target: oldBuild).downcompile([A2UIComponent(id: "x", type: "Loop")])
        #expect(result.components == [A2UIComponent(id: "x", type: "Column", properties: ["children": []])])
        #expect(result.substitutions.last?.outcome == .generic)
    }

    @Test func withNoRuleTextSurvivesAndReferencesStillResolve() {
        let result = compiler.downcompile([
            A2UIComponent(id: "a", type: "Mystery", properties: ["title": "Hello"]),
            A2UIComponent(id: "b", type: "Mystery"),
            A2UIComponent(id: "c", type: "Mystery", properties: ["fallback": "a"]),
        ])
        #expect(result.components == [
            A2UIComponent(id: "a", type: "Text", properties: ["text": "Hello"]),
            A2UIComponent(id: "b", type: "Column", properties: ["children": []]),
            A2UIComponent(id: "c", type: "Mystery", properties: ["fallback": "a"]),   // left for the device
        ])
        #expect(result.substitutions.map(\.outcome) == [.generic, .generic, .inlineFallback])
        #expect(result.substitutions.allSatisfy { $0.reason == .unknownType })
    }

    @Test func onlyComponentMessagesAreRewritten() {
        let data = A2UIMessage.updateDataModel(surfaceId: "s", path: "/x", value: 1)
        #expect(compiler.downcompile(data).message == data)
        let (message, substitutions) = compiler.downcompile(
            .updateComponents(surfaceId: "s", components: [A2UIComponent(id: "f", type: "FlightCard")]))
        #expect(substitutions.count == 2)
        guard case .updateComponents("s", let components) = message else { Issue.record("wrong message"); return }
        #expect(components.first?.type == "Card")
    }
}

@Suite("Catalog schemas and inline fallback")
@MainActor
struct CatalogSchemaTests {
    @Test func basicCatalogDescribesItself() {
        let manifest = A2UICatalog.basic.manifest(version: "1")
        #expect(Set(manifest.components.map(\.name)) == A2UICatalog.basic.componentTypes)
        #expect(manifest.schema(for: "Text")?.properties.first?.name == "text")
        #expect(manifest.catalogId == A2UICatalog.basic.id)
    }

    @Test func registeredSchemasReachTheManifestAndGateVersions() {
        var catalog = A2UICatalog.basic
        catalog.register(A2UIComponentSchema(name: "HotelCard", version: 2)) { _ in Text("card") }
        catalog.register("Plain") { _ in Text("plain") }
        let manifest = catalog.manifest(version: "4.2")
        #expect(manifest.schema(for: "HotelCard")?.version == 2)
        #expect(manifest.schema(for: "Plain") == A2UIComponentSchema(name: "Plain"))   // a bare schema
        #expect(catalog.supports(A2UIComponent(id: "a", type: "HotelCard", properties: ["minVersion": 2])))
        #expect(!catalog.supports(A2UIComponent(id: "a", type: "HotelCard", properties: ["minVersion": 3])))
        #expect(!catalog.supports(A2UIComponent(id: "a", type: "Nope")))
    }

    @Test func inlineFallbackResolvesBesideChildren() throws {
        let store = A2UISurfaceStore()
        store.apply(.createSurface(surfaceId: "s", catalogId: "c", theme: nil, sendDataModel: false))
        store.apply(.updateComponents(surfaceId: "s", components: [
            A2UIComponent(id: "root", type: "FlightCard", properties: ["child": "inner", "fallback": "plain"]),
            A2UIComponent(id: "plain", type: "Text", properties: ["text": "LIS → OPO"]),
        ]))
        let tree = try #require(store.surfaces["s"]?.resolvedTree())
        #expect(tree.children.map(\.componentId) == ["inner"])     // the fallback is not a child
        #expect(tree.fallback?.component?.type == "Text")
    }
}
