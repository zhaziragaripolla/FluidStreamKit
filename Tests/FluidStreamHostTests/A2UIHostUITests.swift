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
        store.apply(.create("s", catalog: "c"))
        store.apply(.updateComponents(surfaceId: "s", components: [component]))
        store.apply(.updateDataModel(surfaceId: "s", path: "/", value: data))
        let surface = try #require(store.surfaces["s"])
        let node = try #require(surface.resolvedTree())
        let env = A2UIRenderEnvironment(store: store, surfaceId: "s", catalogs: [.basic], baseURL: nil, onAction: { _ in })
        return (A2UIComponentContext(node: node, component: component, surface: surface, environment: env), store)
    }

    @Test func basicCatalogCoversAllOfA2UI10() {
        let expected: Set = ["Text", "Image", "Icon", "Video", "AudioPlayer", "Row", "Column", "List", "Card",
                             "Tabs", "Modal", "Divider", "Button", "TextField", "CheckBox", "ChoicePicker",
                             "Slider", "DateTimeInput"]
        #expect(A2UICatalog.basic.componentTypes == expected)
        #expect(A2UICatalog.basic.id == A2UIVersion.basicCatalogID)
        #expect(A2UICatalog.basic.answers(to: "https://a2ui.org/specification/v0_9_1/catalogs/basic/catalog.json"))
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
            A2UIComponent(id: "root", type: "ProductCard", properties: ["title": ["@path": "/p/title"], "price": 148]),
            data: ["p": ["title": "River Suite"]])
        #expect(ctx.props(as: Product.self) == Product(id: "root", title: "River Suite", price: 148))
        #expect(ctx.string("title") == "River Suite")
    }

    @Test func inputWritesGoToTheBoundPathOnly() throws {
        let (bound, store) = try context(
            A2UIComponent(id: "root", type: "CheckBox", properties: ["label": "Agree", "value": ["@path": "/form/agreed"]]))
        let toggle = bound.binding("value", default: false, get: { $0.boolValue }, set: { .bool($0) })
        #expect(toggle.wrappedValue == false)
        toggle.wrappedValue = true
        #expect(store.surfaces["s"]?.dataModel.value(at: JSONPointer("/form/agreed")!) == true)

        let (literal, literalStore) = try context(
            A2UIComponent(id: "root", type: "CheckBox", properties: ["value": true]))
        literal.write(false, to: "value")   // literals are read-only
        #expect(literalStore.surfaces["s"]?.dataModel == [:])
    }

    @Test func bindingsReadLiveFromTheStore() throws {
        let (ctx, store) = try context(
            A2UIComponent(id: "root", type: "TextField", properties: ["value": ["@path": "/name"]]),
            data: ["name": "Alex"])
        // A control can keep a binding made in an earlier render; it must still see new data.
        let text = ctx.binding("value", default: "", get: { $0.stringValue }, set: { .string($0) })
        store.apply(.updateDataModel(surfaceId: "s", path: "/name", value: "Sam"))
        #expect(text.wrappedValue == "Sam")
    }

    @Test func fluidCatalogAddsTableUnderItsOwnId() {
        let fluid = A2UICatalog.fluid
        #expect(fluid.componentTypes == A2UICatalog.basic.componentTypes.union(["Table"]))
        #expect(fluid.id != A2UICatalog.basic.id)
        #expect(fluid.manifest(version: "1").schema(for: "Table")?.fallback != nil)
    }

    @Test func choicePickerSelection() {
        let options = A2UIChoice.options(from: [["label": "Email", "value": "email"], "phone", ["label": "No value"]])
        #expect(options == [.init(label: "Email", value: "email"), .init(label: "phone", value: "phone")])
        #expect(A2UIChoice.selection(from: ["a", "b"]) == ["a", "b"])
        #expect(A2UIChoice.selection(from: "a") == ["a"])
        #expect(A2UIChoice.selection(from: nil) == [])
        #expect(A2UIChoice.toggling("b", in: ["a"], exclusive: false) == ["a", "b"])
        #expect(A2UIChoice.toggling("a", in: ["a", "b"], exclusive: false) == ["b"])
        #expect(A2UIChoice.toggling("b", in: ["a"], exclusive: true) == ["b"])
    }

    @Test func dateValuesRoundTripAsISO8601() throws {
        let day = try #require(A2UIDateValue.parse("2026-11-14"))
        #expect(A2UIDateValue.format(day, includesTime: false) == "2026-11-14")
        let moment = try #require(A2UIDateValue.parse("2026-11-14T09:30:00Z"))
        #expect(A2UIDateValue.format(moment, includesTime: true) == "2026-11-14T09:30:00Z")
        #expect(A2UIDateValue.parse("next tuesday") == nil)
    }

    @Test func tableCellsComeFromRowData() throws {
        let (ctx, _) = try context(
            A2UIComponent(id: "root", type: "Table", properties: [
                "columns": [["title": "Hotel", "path": "name"], ["title": "Night", "path": "price/amount", "align": "end"], ["path": "missing"]],
                "rows": ["@path": "/hotels"],
            ]),
            data: ["hotels": [["name": "Baixa Loft", "price": ["amount": 112]], ["name": "Cascais Garden", "price": ["amount": 96]]]])
        let columns = A2UITable.columns(from: ctx.value("columns"))
        #expect(columns.map(\.title) == ["Hotel", "Night", "missing"])
        #expect(columns.map(\.alignsEnd) == [false, true, false])
        #expect(A2UITable.cells(rows: ctx.value("rows"), columns: columns) == [["Baixa Loft", "112", ""], ["Cascais Garden", "96", ""]])
        #expect(A2UITable.cells(rows: .array(Array(repeating: [:], count: 500)), columns: columns).count == 200)
        #expect(A2UITable.cells(rows: nil, columns: columns).isEmpty)
    }

    @Test func iconNamesMapToSymbols() {
        #expect(A2UIIconView.symbol(for: "check") == "checkmark")
        #expect(A2UIIconView.symbol(for: "payment") == "creditcard")
        #expect(A2UIIconView.symbol(for: "star.fill") == "star.fill")
    }
}
