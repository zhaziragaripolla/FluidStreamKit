@_exported public import FluidStreamHost
public import SwiftUI
import Foundation

/// Maps A2UI component type names to SwiftUI views.
///
/// Start from ``basic`` and register your own components; a registration with a standard
/// name replaces the standard view.
///
/// ```swift
/// var catalog = A2UICatalog.basic
/// catalog.register("ProductCard") { context in
///     if let product = context.props(as: Product.self) { ProductCard(product) }
/// }
/// ```
public struct A2UICatalog {
    public typealias Builder = @MainActor (A2UIComponentContext) -> AnyView

    /// The catalog id this app advertises to the agent.
    public var id: String
    private var builders: [String: Builder]
    private var schemas: [String: A2UIComponentSchema] = [:]

    public init(id: String, builders: [String: Builder] = [:]) {
        self.id = id
        self.builders = builders
    }

    /// Adds a component together with its schema: its version, properties and fallback. The
    /// schema is what the agent and the down-compiler learn about it (RFC-006).
    public mutating func register<Content: View>(
        _ schema: A2UIComponentSchema,
        @ViewBuilder _ build: @escaping @MainActor (A2UIComponentContext) -> Content
    ) {
        register(schema.name, build)
        schemas[schema.name] = schema
    }

    /// Attaches or replaces the schema of an already registered component.
    public mutating func describe(_ schema: A2UIComponentSchema) {
        guard builders[schema.name] != nil else { return }
        schemas[schema.name] = schema
    }

    public func schema(for type: String) -> A2UIComponentSchema? {
        builders[type] == nil ? nil : (schemas[type] ?? A2UIComponentSchema(name: type))
    }

    /// Everything this catalog can render, as data. `version` is yours: a build number works.
    public func manifest(version: String) -> A2UICatalogManifest {
        A2UICatalogManifest(catalogId: id, version: version, components: builders.keys.compactMap { schema(for: $0) })
    }

    /// Whether this catalog can render the component at the version it asks for.
    public func supports(_ component: A2UIComponent) -> Bool {
        guard let schema = schema(for: component.type) else { return false }
        return component.minimumVersion <= schema.version
    }

    /// Adds a component, or replaces the one with the same name.
    public mutating func register<Content: View>(
        _ type: String,
        @ViewBuilder _ build: @escaping @MainActor (A2UIComponentContext) -> Content
    ) {
        builders[type] = { AnyView(build($0)) }
    }

    /// A copy with `type` added or replaced.
    public func registering<Content: View>(
        _ type: String,
        @ViewBuilder _ build: @escaping @MainActor (A2UIComponentContext) -> Content
    ) -> A2UICatalog {
        var copy = self
        copy.register(type, build)
        return copy
    }

    /// A copy with the component and its schema added or replaced.
    public func registering<Content: View>(
        _ schema: A2UIComponentSchema,
        @ViewBuilder _ build: @escaping @MainActor (A2UIComponentContext) -> Content
    ) -> A2UICatalog {
        var copy = self
        copy.register(schema, build)
        return copy
    }

    public var componentTypes: Set<String> { Set(builders.keys) }

    func builder(for type: String) -> Builder? { builders[type] }
}

/// What a component's view gets: its properties resolved against the data model, its children,
/// and ways to write input back and fire its action.
@MainActor
public struct A2UIComponentContext {
    public let node: ResolvedNode
    public let component: A2UIComponent
    public let surface: A2UISurface
    let environment: A2UIRenderEnvironment

    public var children: [ResolvedNode] { node.children }

    /// A property with bindings resolved: a literal, or the data-model value it's bound to.
    public func value(_ key: String) -> JSONValue? {
        surface.resolve(component[key], scope: node.scope)
    }

    public func string(_ key: String) -> String? { value(key)?.displayString }
    public func double(_ key: String) -> Double? { value(key)?.doubleValue }
    public func bool(_ key: String) -> Bool? { value(key)?.boolValue }

    /// Every property, resolved, decoded into your own type. Nil if it doesn't decode.
    public func props<T: Decodable>(as type: T.Type) -> T? {
        var resolved = component.properties.mapValues { surface.resolve($0, scope: node.scope) ?? .null }
        resolved["id"] = .string(component.id)
        guard let data = try? JSONEncoder().encode(JSONValue.object(resolved)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// The data-model location a property is bound to, if it's bound.
    public func bindingPointer(_ key: String) -> JSONPointer? {
        surface.bindingPointer(component[key], scope: node.scope)
    }

    /// Writes user input to the location `key` is bound to. Literal properties are read-only.
    public func write(_ newValue: JSONValue, to key: String) {
        guard let pointer = bindingPointer(key) else { return }
        environment.store.setValue(newValue, at: pointer, surfaceId: surface.id)
    }

    /// A SwiftUI binding for a two-way input property.
    public func binding<T>(_ key: String, default fallback: T, get: @escaping (JSONValue) -> T?,
                           set: @escaping (T) -> JSONValue) -> Binding<T> {
        // Read live from the store, not from this context's snapshot: SwiftUI controls can keep
        // a binding longer than one render, and a stale read would snap the control back.
        let store = environment.store, surfaceId = surface.id, property = component[key], scope = node.scope
        return Binding(
            get: { store.surfaces[surfaceId]?.resolve(property, scope: scope).flatMap(get) ?? fallback },
            set: { write(set($0), to: key) }
        )
    }

    /// Fires the component's `action`, if it has one.
    public func performAction() {
        guard let action = environment.store.action(for: node, surfaceId: surface.id) else { return }
        environment.onAction(action)
    }

    /// Renders a child node with the same catalog.
    public func render(_ child: ResolvedNode) -> some View {
        A2UINodeView(node: child, environment: environment)
    }

    /// The child built from component `id`, rendered, or nothing.
    @ViewBuilder
    public func render(childId id: String?) -> some View {
        if let id, let child = node.child(id) { render(child) }
    }

    /// A media URL property, filtered by ``A2UIURLPolicy``.
    public func url(_ key: String) -> URL? {
        string(key).flatMap { A2UIURLPolicy.allowedURL($0, relativeTo: environment.baseURL) }
    }
}

@MainActor
struct A2UIRenderEnvironment {
    let store: A2UISurfaceStore
    let surfaceId: String
    let catalog: A2UICatalog
    let baseURL: URL?
    let onAction: @MainActor (A2UIAction) -> Void
}

/// Renders one A2UI surface from a store, updating as messages arrive.
public struct A2UISurfaceView: View {
    private let store: A2UISurfaceStore
    private let surfaceId: String
    private let catalog: A2UICatalog
    private let baseURL: URL?
    private let onAction: @MainActor (A2UIAction) -> Void

    /// - Parameters:
    ///   - baseURL: Where relative media URLs resolve. Without one they're not loaded.
    ///   - onAction: Called on taps. Send `.event` to the agent; decide yourself whether to run
    ///     a `.localFunction` such as `openUrl`.
    public init(
        store: A2UISurfaceStore, surfaceId: String, catalog: A2UICatalog = .basic, baseURL: URL? = nil,
        onAction: @escaping @MainActor (A2UIAction) -> Void = { _ in }
    ) {
        self.store = store
        self.surfaceId = surfaceId
        self.catalog = catalog
        self.baseURL = baseURL
        self.onAction = onAction
    }

    public var body: some View {
        if let tree = store.surfaces[surfaceId]?.resolvedTree() {
            A2UINodeView(
                node: tree,
                environment: A2UIRenderEnvironment(store: store, surfaceId: surfaceId, catalog: catalog, baseURL: baseURL, onAction: onAction))
        }
    }
}

struct A2UINodeView: View {
    let node: ResolvedNode
    let environment: A2UIRenderEnvironment

    var body: some View {
        switch node.state {
        case .pending:
            A2UIPlaceholder()
        case .invalid:
            EmptyView()
        case .ready(let component):
            if let surface = environment.store.surfaces[environment.surfaceId] {
                let context = A2UIComponentContext(node: node, component: component, surface: surface, environment: environment)
                if environment.catalog.supports(component), let build = environment.catalog.builder(for: component.type) {
                    build(context)
                } else if let fallback = node.fallback {
                    // Unknown type, or newer than this build: show what the agent named instead.
                    A2UINodeView(node: fallback, environment: environment)
                } else {
                    A2UIFallbackView(context: context)
                }
            }
        }
    }
}

/// Shown while a referenced component hasn't arrived.
struct A2UIPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.quaternary)
            .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18)
            .accessibilityHidden(true)
    }
}

/// An unknown component type: show its text if it has any, otherwise nothing. Never raw JSON.
struct A2UIFallbackView: View {
    let context: A2UIComponentContext

    var body: some View {
        if let text = context.string("text") ?? context.string("label") {
            Text(text)
        }
    }
}
