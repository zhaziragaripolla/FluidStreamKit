import Foundation
import SwiftUI
import Testing
@testable import FluidStreamHost
@testable import FluidStreamHostUI

@Suite("URL policy")
struct URLPolicyTests {
    @Test func allowsOnlySafeSchemes() {
        #expect(A2UIURLPolicy.allowedURL("  https://example.com/a.png ")?.absoluteString == "https://example.com/a.png")
        #expect(A2UIURLPolicy.allowedURL("HTTP://example.com") != nil)
        #expect(A2UIURLPolicy.allowedURL("data:image/png;base64,AAAA") != nil)
        #expect(A2UIURLPolicy.allowedURL("javascript:alert(1)") == nil)
        #expect(A2UIURLPolicy.allowedURL("file:///etc/passwd") == nil)
        #expect(A2UIURLPolicy.allowedURL("//evil.example/x.png", relativeTo: URL(string: "https://app.example/")) == nil)
        #expect(A2UIURLPolicy.allowedURL("") == nil)
    }

    @Test func relativeURLsNeedABase() {
        #expect(A2UIURLPolicy.allowedURL("img/a.png") == nil)
        let base = URL(string: "https://app.example/media/")
        #expect(A2UIURLPolicy.allowedURL("img/a.png", relativeTo: base)?.absoluteString == "https://app.example/media/img/a.png")
    }
}

@Suite("Catalog")
@MainActor
struct CatalogTests {
    struct Product: Decodable, Equatable {
        let id: String
        let title: String
        let price: Double
    }

    func context(_ component: A2UIComponent, data: JSONValue = [:]) throws -> (A2UIComponentContext, A2UISurfaceStore) {
        let store = A2UISurfaceStore()
        store.apply(.createSurface(surfaceId: "s", catalogId: "c", theme: nil, sendDataModel: false))
        store.apply(.updateComponents(surfaceId: "s", components: [component]))
        store.apply(.updateDataModel(surfaceId: "s", path: "/", value: data))
        let surface = try #require(store.surfaces["s"])
        let node = try #require(surface.resolvedTree())
        let env = A2UIRenderEnvironment(store: store, surfaceId: "s", catalog: .basic, baseURL: nil, onAction: { _ in })
        return (A2UIComponentContext(node: node, component: component, surface: surface, environment: env), store)
    }

    @Test func basicCatalogCoversTheFirstSlice() {
        let expected: Set = ["Text", "Image", "Icon", "Row", "Column", "List", "Card", "Divider",
                             "Button", "TextField", "CheckBox", "Slider"]
        #expect(A2UICatalog.basic.componentTypes == expected)
    }

    @Test func registerAddsAndOverrides() {
        var catalog = A2UICatalog.basic
        catalog.register("ProductCard") { _ in Text("custom") }
        catalog.register("Text") { _ in Text("override") }
        #expect(catalog.componentTypes.contains("ProductCard"))
        #expect(catalog.componentTypes.count == A2UICatalog.basic.componentTypes.count + 1)
        #expect(A2UICatalog.basic.registering("X") { _ in EmptyView() }.componentTypes.contains("X"))
    }

    @Test func propsDecodeWithBindingsResolved() throws {
        let (ctx, _) = try context(
            A2UIComponent(id: "root", type: "ProductCard", properties: ["title": ["path": "/p/title"], "price": 148]),
            data: ["p": ["title": "River Suite"]])
        #expect(ctx.props(as: Product.self) == Product(id: "root", title: "River Suite", price: 148))
        #expect(ctx.string("title") == "River Suite")
    }

    @Test func inputWritesGoToTheBoundPathOnly() throws {
        let (bound, store) = try context(
            A2UIComponent(id: "root", type: "CheckBox", properties: ["label": "Agree", "value": ["path": "/form/agreed"]]))
        let toggle = bound.binding("value", default: false, get: { $0.boolValue }, set: { .bool($0) })
        #expect(toggle.wrappedValue == false)
        toggle.wrappedValue = true
        #expect(store.surfaces["s"]?.dataModel.value(at: JSONPointer("/form/agreed")!) == true)

        let (literal, literalStore) = try context(
            A2UIComponent(id: "root", type: "CheckBox", properties: ["value": true]))
        literal.write(false, to: "value")   // literals are read-only
        #expect(literalStore.surfaces["s"]?.dataModel == [:])
    }

    @Test func iconNamesMapToSymbols() {
        #expect(A2UIIconView.symbol(for: "check") == "checkmark")
        #expect(A2UIIconView.symbol(for: "star.fill") == "star.fill")
    }
}
