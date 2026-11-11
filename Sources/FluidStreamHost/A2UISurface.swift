/// One A2UI surface: its components, keyed by id, and its data model.
public struct A2UISurface: Sendable, Hashable, Identifiable {
    public let id: String
    /// The default catalog for components that don't name their own (`@catalogId`).
    public let catalogId: String?
    public let sendDataModel: Bool
    /// The protocol version the agent used for `createSurface`; replies use the same one.
    public let protocolVersion: String
    public let metadata: JSONValue?
    public internal(set) var components: [String: A2UIComponent] = [:]
    public internal(set) var dataModel: JSONValue = .object([:])

    public init(id: String, catalogId: String?, sendDataModel: Bool = false,
                protocolVersion: String = A2UIVersion.current, metadata: JSONValue? = nil) {
        self.id = id
        self.catalogId = catalogId
        self.sendDataModel = sendDataModel
        self.protocolVersion = protocolVersion
        self.metadata = metadata
    }

    /// A surface from `createSurface`, with its inline data model and components applied.
    public init(_ definition: A2UISurfaceDefinition) {
        self.init(id: definition.surfaceId, catalogId: definition.catalogId, sendDataModel: definition.sendDataModel,
                  protocolVersion: definition.protocolVersion, metadata: definition.metadata)
        if let model = definition.dataModel { dataModel = model }
        upsert(definition.components)
    }

    /// Adds or replaces components by id.
    public mutating func upsert(_ updates: [A2UIComponent]) {
        for component in updates { components[component.id] = component }
    }

    /// Applies an `updateDataModel`: `null` removes, anything else upserts. Returns false if the
    /// path is invalid.
    @discardableResult
    public mutating func updateData(path: String, value: JSONValue) -> Bool {
        guard let pointer = JSONPointer(path) else { return false }
        if value == .null {
            if pointer.tokens.isEmpty { dataModel = .object([:]); return true }
            return dataModel.remove(at: pointer)
        }
        return dataModel.set(value, at: pointer)
    }

    // MARK: Values

    /// An evaluator for this surface's data, at a template item.
    public func evaluator(scope: JSONPointer = .root, index: Int? = nil,
                          functions: A2UIFunctionRegistry = .basic, userActivated: Bool = false) -> A2UIEvaluator {
        A2UIEvaluator(dataModel: dataModel, scope: scope, index: index, functions: functions, userActivated: userActivated)
    }

    /// A property's value: a literal, a bound data-model value (`{"@path": …}`), or a function
    /// result (`{"@call": …}`). Nil if it's absent, bound to nothing, or fails to evaluate.
    public func resolve(_ value: JSONValue?, scope: JSONPointer = .root, index: Int? = nil,
                        functions: A2UIFunctionRegistry = .basic) -> JSONValue? {
        guard let value, case .success(let v) = evaluate(value, scope: scope, index: index, functions: functions),
              v != .null else { return nil }
        return v
    }

    /// Like ``resolve(_:scope:index:functions:)``, with the error when evaluation fails.
    public func evaluate(_ value: JSONValue, scope: JSONPointer = .root, index: Int? = nil,
                         functions: A2UIFunctionRegistry = .basic) -> Result<JSONValue, A2UIFunctionError> {
        do throws(A2UIFunctionError) {
            return .success(try evaluator(scope: scope, index: index, functions: functions).evaluate(value))
        } catch {
            return .failure(error)
        }
    }

    /// The data-model pointer a property is bound to, or nil if it isn't a binding.
    public func bindingPointer(_ value: JSONValue?, scope: JSONPointer = .root) -> JSONPointer? {
        guard case .object(let o)? = value, o.count == 1, let path = o["@path"]?.stringValue else { return nil }
        return JSONPointer.resolve(path, in: scope)
    }

    /// A property as display text, or nil if it's absent or unresolved.
    public func string(_ key: String, of component: A2UIComponent, scope: JSONPointer = .root, index: Int? = nil) -> String? {
        resolve(component[key], scope: scope, index: index)?.displayString
    }

    /// The component's `@checks` that currently fail, with their messages.
    public func failingChecks(of component: A2UIComponent, scope: JSONPointer = .root, index: Int? = nil,
                              functions: A2UIFunctionRegistry = .basic) -> [A2UICheckFailure] {
        component.checks.compactMap { rule in
            guard let condition = rule["condition"] else { return nil }
            switch evaluate(condition, scope: scope, index: index, functions: functions) {
            case .success(let result):
                guard !A2UIEvaluator.truthiness(result) else { return nil }
                let message = result["message"]?.stringValue ?? rule["message"]?.stringValue
                return A2UICheckFailure(code: result["code"]?.stringValue, message: message,
                                        severity: result["severity"]?.stringValue ?? "error")
            case .failure(let error):
                return A2UICheckFailure(code: error.code, message: rule["message"]?.stringValue, severity: "error")
            }
        }
    }

    // MARK: Tree

    /// Limits that keep untrusted agent output from exhausting memory or the stack.
    public struct Limits: Sendable, Hashable {
        public var maxDepth = 64
        public var maxNodes = 2_000
        public init() {}
    }

    /// Which component types may contain which (catalog `allowedParents` and `allowedChildren`).
    public struct CompositionRules: Sendable {
        /// Per type: the parent types it allows, or nil for any. The surface itself is `Surface`.
        public var allowedParents: [String: Set<String>] = [:]
        /// Per type: the child types it allows, or nil for any.
        public var allowedChildren: [String: Set<String>] = [:]
        public init(allowedParents: [String: Set<String>] = [:], allowedChildren: [String: Set<String>] = [:]) {
            self.allowedParents = allowedParents
            self.allowedChildren = allowedChildren
        }

        /// The A2UI error code if `child` can't sit inside `parent`.
        func violation(child: String, parent: String) -> String? {
            if let parents = allowedParents[child], !parents.contains(parent) { return "UNALLOWED_PARENT" }
            if let children = allowedChildren[parent], !children.contains(child) { return "UNALLOWED_CHILD" }
            return nil
        }
    }

    /// The tree rooted at the component with id `root`, or nil until `root` arrives.
    ///
    /// Children that haven't arrived yet are `.pending` nodes, so a renderer can show a
    /// placeholder. A reference cycle, a disallowed nesting, or going past `limits` gives an
    /// `.invalid` node.
    public func resolvedTree(limits: Limits = Limits(), rules: CompositionRules = CompositionRules()) -> ResolvedNode? {
        guard components["root"] != nil else { return nil }
        var budget = limits.maxNodes
        var builder = TreeBuilder(surface: self, limits: limits, rules: rules)
        return builder.node("root", parentType: "Surface", scope: .root, index: nil, ancestors: [], depth: 0, budget: &budget)
    }

    private struct TreeBuilder {
        let surface: A2UISurface
        let limits: Limits
        let rules: CompositionRules

        mutating func node(
            _ componentId: String, parentType: String, scope: JSONPointer, index: Int?, ancestors: Set<String>,
            depth: Int, budget: inout Int
        ) -> ResolvedNode {
            let key = ResolvedNode.key(componentId, scope)
            func invalid(_ reason: String) -> ResolvedNode {
                ResolvedNode(id: key, componentId: componentId, scope: scope, index: index, state: .invalid(reason))
            }
            guard budget > 0 else { return invalid("Node limit reached") }
            budget -= 1
            guard let component = surface.components[componentId] else {
                return ResolvedNode(id: key, componentId: componentId, scope: scope, index: index, state: .pending)
            }
            guard !ancestors.contains(key) else { return invalid("Circular reference") }
            guard depth < limits.maxDepth else { return invalid("Too deeply nested") }
            if let code = rules.violation(child: component.type, parent: parentType) {
                return invalid("\(code): \(component.type) can't be inside \(parentType)")
            }
            var path = ancestors
            path.insert(key)
            var children: [ResolvedNode] = []
            for ref in component.childReferences {
                switch ref {
                case .id(let childId):
                    children.append(node(childId, parentType: component.type, scope: scope, index: index,
                                         ancestors: path, depth: depth + 1, budget: &budget))
                case .template(let childId, let dataPath):
                    guard let base = JSONPointer.resolve(dataPath, in: scope) else { continue }
                    switch surface.dataModel.value(at: base) {
                    case .array(let items):
                        for i in items.indices {
                            guard budget > 0 else { break }
                            children.append(node(childId, parentType: component.type, scope: base.appending(String(i)),
                                                 index: i, ancestors: path, depth: depth + 1, budget: &budget))
                        }
                    case .object(let items):
                        for (i, itemKey) in items.keys.sorted().enumerated() {
                            guard budget > 0 else { break }
                            children.append(node(childId, parentType: component.type, scope: base.appending(itemKey),
                                                 index: i, ancestors: path, depth: depth + 1, budget: &budget))
                        }
                    default:
                        break   // The data hasn't arrived yet: no items.
                    }
                }
            }
            var resolved = ResolvedNode(id: key, componentId: componentId, scope: scope, index: index,
                                        state: .ready(component), children: children)
            // An inline fallback (RFC-006): another component to show if this build can't render this one.
            if let fallbackId = component.fallbackId {
                resolved.fallbackNodes = [node(fallbackId, parentType: parentType, scope: scope, index: index,
                                               ancestors: path, depth: depth + 1, budget: &budget)]
            }
            return resolved
        }
    }
}

/// A failing `@checks` rule.
public struct A2UICheckFailure: Sendable, Hashable {
    public var code: String?
    public var message: String?
    /// `error`, `warning` or `info`.
    public var severity: String
}

extension A2UIComponent {
    /// The component to show instead if this build can't render this one (RFC-006). Read from
    /// `@metadata.extensions.fluid_fallback`, or a plain `fallback` property.
    public var fallbackId: String? {
        extensions[A2UIExtensionKey.fallback]?.stringValue ?? properties["fallback"]?.stringValue
    }
}

/// A node of a surface's resolved tree, ready to render.
public struct ResolvedNode: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        case ready(A2UIComponent)
        /// Referenced but not received yet.
        case pending
        /// Can't be rendered, with the reason.
        case invalid(String)
    }

    /// Stable across rebuilds: the component id plus its template scope.
    public let id: String
    public let componentId: String
    /// The data-model item this node is scoped to inside a template, or the root.
    public let scope: JSONPointer
    /// The item's position inside a list template, for `@index`.
    public let index: Int?
    public let state: State
    public var children: [ResolvedNode] = []
    var fallbackNodes: [ResolvedNode] = []

    public init(id: String, componentId: String, scope: JSONPointer, index: Int? = nil, state: State,
                children: [ResolvedNode] = []) {
        self.id = id
        self.componentId = componentId
        self.scope = scope
        self.index = index
        self.state = state
        self.children = children
    }

    /// The component named as this one's fallback, if any. Not part of `children`.
    public var fallback: ResolvedNode? { fallbackNodes.first }

    public var component: A2UIComponent? {
        if case .ready(let c) = state { return c }
        return nil
    }

    /// The first child built from component `id`. For Modal's `trigger` and `content`, and Tabs.
    public func child(_ componentId: String) -> ResolvedNode? {
        children.first { $0.componentId == componentId }
    }

    static func key(_ componentId: String, _ scope: JSONPointer) -> String {
        scope.tokens.isEmpty ? componentId : "\(componentId)@\(scope)"
    }
}
