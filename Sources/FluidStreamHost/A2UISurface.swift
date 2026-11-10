/// One A2UI surface: its components, keyed by id, and its data model.
public struct A2UISurface: Sendable, Hashable, Identifiable {
    public let id: String
    public let catalogId: String
    public let theme: JSONValue?
    public let sendDataModel: Bool
    public internal(set) var components: [String: A2UIComponent] = [:]
    public internal(set) var dataModel: JSONValue = .object([:])

    public init(id: String, catalogId: String, theme: JSONValue? = nil, sendDataModel: Bool = false) {
        self.id = id
        self.catalogId = catalogId
        self.theme = theme
        self.sendDataModel = sendDataModel
    }

    /// Adds or replaces components by id.
    public mutating func upsert(_ updates: [A2UIComponent]) {
        for component in updates { components[component.id] = component }
    }

    /// Applies an `updateDataModel`. Returns false if the path is invalid.
    @discardableResult
    public mutating func updateData(path: String, value: JSONValue?) -> Bool {
        guard let pointer = JSONPointer(path) else { return false }
        if let value { return dataModel.set(value, at: pointer) }
        return dataModel.remove(at: pointer)
    }

    // MARK: Values

    /// Resolves a property value: a literal stays as is, `{"path": …}` reads the data model
    /// (relative paths resolve against `scope`), and `{"call": …}` is not supported yet (nil).
    public func resolve(_ value: JSONValue?, scope: JSONPointer = .root) -> JSONValue? {
        guard let value else { return nil }
        if let pointer = bindingPointer(value, scope: scope) {
            return dataModel.value(at: pointer)
        }
        if case .object(let o) = value, o["call"] != nil { return nil }
        return value
    }

    /// The data-model pointer a property is bound to, or nil if it's a literal.
    public func bindingPointer(_ value: JSONValue?, scope: JSONPointer = .root) -> JSONPointer? {
        guard case .object(let o)? = value, o.count == 1, let path = o["path"]?.stringValue else { return nil }
        return JSONPointer.resolve(path, in: scope)
    }

    /// A property as display text, or nil if it's absent or unresolved.
    public func string(_ key: String, of component: A2UIComponent, scope: JSONPointer = .root) -> String? {
        resolve(component[key], scope: scope)?.displayString
    }

    // MARK: Tree

    /// Limits that keep untrusted agent output from exhausting memory or the stack.
    public struct Limits: Sendable, Hashable {
        public var maxDepth = 64
        public var maxNodes = 2_000
        public init() {}
    }

    /// The tree rooted at the component with id `root`, or nil until `root` arrives.
    ///
    /// Children that haven't arrived yet are `.pending` nodes, so a renderer can show a
    /// placeholder. A reference cycle, or going past `limits`, gives an `.invalid` node.
    public func resolvedTree(limits: Limits = Limits()) -> ResolvedNode? {
        guard components["root"] != nil else { return nil }
        var budget = limits.maxNodes
        return node("root", scope: .root, ancestors: [], depth: 0, limits: limits, budget: &budget)
    }

    private func node(
        _ componentId: String, scope: JSONPointer, ancestors: Set<String>, depth: Int,
        limits: Limits, budget: inout Int
    ) -> ResolvedNode {
        let key = ResolvedNode.key(componentId, scope)
        guard budget > 0 else { return ResolvedNode(id: key, componentId: componentId, scope: scope, state: .invalid("Node limit reached")) }
        budget -= 1
        guard let component = components[componentId] else {
            return ResolvedNode(id: key, componentId: componentId, scope: scope, state: .pending)
        }
        guard !ancestors.contains(key) else {
            return ResolvedNode(id: key, componentId: componentId, scope: scope, state: .invalid("Circular reference"))
        }
        guard depth < limits.maxDepth else {
            return ResolvedNode(id: key, componentId: componentId, scope: scope, state: .invalid("Too deeply nested"))
        }
        var path = ancestors
        path.insert(key)
        var children: [ResolvedNode] = []
        for ref in component.childReferences {
            switch ref {
            case .id(let childId):
                children.append(node(childId, scope: scope, ancestors: path, depth: depth + 1, limits: limits, budget: &budget))
            case .template(let childId, let dataPath):
                guard let base = JSONPointer.resolve(dataPath, in: scope) else { continue }
                switch dataModel.value(at: base) {
                case .array(let items):
                    for index in items.indices {
                        guard budget > 0 else { break }
                        children.append(node(childId, scope: base.appending(String(index)), ancestors: path,
                                             depth: depth + 1, limits: limits, budget: &budget))
                    }
                case .object(let items):
                    for itemKey in items.keys.sorted() {
                        guard budget > 0 else { break }
                        children.append(node(childId, scope: base.appending(itemKey), ancestors: path,
                                             depth: depth + 1, limits: limits, budget: &budget))
                    }
                default:
                    break   // The data hasn't arrived yet: no items.
                }
            }
        }
        var resolved = ResolvedNode(id: key, componentId: componentId, scope: scope, state: .ready(component), children: children)
        // An inline fallback (RFC-006): another component to show if this build can't render this one.
        if let fallbackId = component["fallback"]?.stringValue {
            resolved.fallbackNodes = [node(fallbackId, scope: scope, ancestors: path, depth: depth + 1, limits: limits, budget: &budget)]
        }
        return resolved
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
    public let state: State
    public var children: [ResolvedNode] = []
    var fallbackNodes: [ResolvedNode] = []

    /// The component named by this one's `"fallback"` property, if any. Not part of `children`.
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
