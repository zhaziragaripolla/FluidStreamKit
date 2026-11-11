@_exported public import FluidStreamHost
public import SwiftUI
import Foundation

/// Maps A2UI component type names to SwiftUI views, under one catalog id.
///
/// A2UI 1.0 lets an agent mix catalogs in one surface: each component is drawn by the catalog
/// its `@catalogId` names, or the surface's default catalog. Give ``A2UISurfaceView`` every
/// catalog your app renders.
///
/// ```swift
/// var catalog = A2UICatalog(id: "com.example:catalog/1")
/// catalog.register(productCardSchema) { context in
///     if let product = context.props(as: Product.self) { ProductCard(product) }
/// }
/// ```
public struct A2UICatalog {
    public typealias Builder = @MainActor (A2UIComponentContext) -> AnyView

    /// The catalog id this app advertises to the agent.
    public var id: String
    /// Other ids this catalog also answers to, such as older versions of the same catalog.
    public var aliases: Set<String> = []
    private var builders: [String: Builder]
    private var schemas: [String: A2UIComponentSchema] = [:]

    public init(id: String, builders: [String: Builder] = [:]) {
        self.id = id
        self.builders = builders
    }

    /// A new catalog with its own id that starts with every component of `base`. Use it to
    /// add your components on top of the basic catalog without claiming the basic catalog's id.
    public init(id: String, including base: A2UICatalog) {
        self = base
        self.id = id
        self.aliases = []
    }

    /// Whether this catalog answers to `catalogId`.
    public func answers(to catalogId: String) -> Bool {
        catalogId == id || aliases.contains(catalogId)
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

    /// `allowedParents` and `allowedChildren` from the registered schemas.
    public var compositionRules: A2UISurface.CompositionRules {
        manifest(version: "").compositionRules
    }

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

    /// A property with bindings and function calls resolved.
    public func value(_ key: String) -> JSONValue? {
        resolve(component[key])
    }

    /// Any dynamic value, resolved in this component's scope.
    public func resolve(_ value: JSONValue?) -> JSONValue? {
        surface.resolve(value, scope: node.scope, index: node.index, functions: environment.store.functions)
    }

    public func string(_ key: String) -> String? { value(key)?.displayString }
    public func double(_ key: String) -> Double? { value(key)?.doubleValue }
    public func bool(_ key: String) -> Bool? { value(key).map(A2UIEvaluator.truthiness) }

    /// Every property, resolved, decoded into your own type. Nil if it doesn't decode.
    public func props<T: Decodable>(as type: T.Type) -> T? {
        var resolved: [String: JSONValue] = [:]
        for (key, value) in component.properties where !key.hasPrefix("@") { resolved[key] = resolve(value) ?? .null }
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
        let store = environment.store, surfaceId = surface.id, property = component[key]
        let scope = node.scope, index = node.index
        return Binding(
            get: {
                store.surfaces[surfaceId]?.resolve(property, scope: scope, index: index, functions: store.functions)
                    .flatMap(get) ?? fallback
            },
            set: { write(set($0), to: key) }
        )
    }

    /// The component's `@checks` that fail right now. A Button with a failing check is disabled.
    public var failingChecks: [A2UICheckFailure] {
        let live = environment.store.surfaces[surface.id] ?? surface
        return live.failingChecks(of: component, scope: node.scope, index: node.index, functions: environment.store.functions)
    }

    /// Fires the component's `action`, if it has one.
    public func performAction() {
        guard let action = environment.store.action(for: node, surfaceId: surface.id) else { return }
        environment.onAction(action)
    }

    /// Renders a child node with the same catalogs.
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
    let catalogs: [A2UICatalog]
    let baseURL: URL?
    let onAction: @MainActor (A2UIAction) -> Void

    /// The catalog that draws `component`: the one its `@catalogId` names, or the surface's
    /// default. A2UI 1.0 has no other fallback, so a component with neither isn't drawn.
    func catalog(for component: A2UIComponent, in surface: A2UISurface) -> A2UICatalog? {
        guard let id = component.catalogId ?? surface.catalogId else { return nil }
        return catalogs.first { $0.answers(to: id) }
    }
}

/// Renders one A2UI surface from a store, updating as messages arrive.
public struct A2UISurfaceView: View {
    private let store: A2UISurfaceStore
    private let surfaceId: String
    private let catalogs: [A2UICatalog]
    private let baseURL: URL?
    private let onAction: @MainActor (A2UIAction) -> Void

    /// - Parameters:
    ///   - catalogs: Every catalog the app renders. Each component is drawn by the one its
    ///     `@catalogId`, or the surface's `catalogId`, names.
    ///   - baseURL: Where relative media URLs resolve. Without one they're not loaded.
    ///   - onAction: Called on taps. Send ``A2UIAction/messageToAgent`` to the agent; decide
    ///     yourself whether to run a `.localFunction` such as `openUrl`.
    public init(
        store: A2UISurfaceStore, surfaceId: String, catalogs: [A2UICatalog] = [.basic], baseURL: URL? = nil,
        onAction: @escaping @MainActor (A2UIAction) -> Void = { _ in }
    ) {
        self.store = store
        self.surfaceId = surfaceId
        self.catalogs = catalogs
        self.baseURL = baseURL
        self.onAction = onAction
    }

    /// A surface drawn with one catalog.
    public init(
        store: A2UISurfaceStore, surfaceId: String, catalog: A2UICatalog, baseURL: URL? = nil,
        onAction: @escaping @MainActor (A2UIAction) -> Void = { _ in }
    ) {
        self.init(store: store, surfaceId: surfaceId, catalogs: [catalog], baseURL: baseURL, onAction: onAction)
    }

    public var body: some View {
        if let surface = store.surfaces[surfaceId] {
            let rules = rules(for: surface)
            if let tree = surface.resolvedTree(rules: rules) {
                A2UINodeView(
                    node: tree,
                    environment: A2UIRenderEnvironment(
                        store: store, surfaceId: surfaceId, catalogs: catalogs, baseURL: baseURL, onAction: onAction))
            }
        }
    }

    private func rules(for surface: A2UISurface) -> A2UISurface.CompositionRules {
        var rules = A2UISurface.CompositionRules()
        for catalog in catalogs {
            let r = catalog.compositionRules
            rules.allowedParents.merge(r.allowedParents) { a, _ in a }
            rules.allowedChildren.merge(r.allowedChildren) { a, _ in a }
        }
        return rules
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
                Group {
                    if let catalog = environment.catalog(for: component, in: surface), catalog.supports(component),
                       let build = catalog.builder(for: component.type) {
                        build(context)
                    } else if let fallback = node.fallback {
                        // Unknown type, or newer than this build: show what the agent named instead.
                        A2UINodeView(node: fallback, environment: environment)
                    } else {
                        A2UIFallbackView(context: context)
                    }
                }
                .modifier(A2UIAccessibility(context: context))
            }
        }
    }
}

/// Applies a component's `@accessibility` to its view: `label`, `description` (as a hint),
/// `hidden`, and `live` (marks the view as one that updates).
struct A2UIAccessibility: ViewModifier {
    let context: A2UIComponentContext

    func body(content: Content) -> some View {
        let attributes = context.component.accessibility ?? [:]
        let label = context.resolve(attributes["label"])?.displayString
        let hint = context.resolve(attributes["description"])?.displayString
        let hidden = context.resolve(attributes["hidden"]).map(A2UIEvaluator.truthiness) ?? false
        let live = attributes["live"]?.stringValue ?? "off"
        content
            .modifier(OptionalLabel(label: label))
            .modifier(OptionalHint(hint: hint))
            .accessibilityHidden(hidden)
            .accessibilityAddTraits(live == "off" ? [] : .updatesFrequently)
    }

    private struct OptionalLabel: ViewModifier {
        let label: String?
        func body(content: Content) -> some View {
            if let label { content.accessibilityLabel(label) } else { content }
        }
    }

    private struct OptionalHint: ViewModifier {
        let hint: String?
        func body(content: Content) -> some View {
            if let hint { content.accessibilityHint(hint) } else { content }
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

/// A component no catalog can draw: show its text if it has any, otherwise nothing. Never raw JSON.
struct A2UIFallbackView: View {
    let context: A2UIComponentContext

    var body: some View {
        if let text = context.string("text") ?? context.string("label") {
            Text(text)
        }
    }
}
