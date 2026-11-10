/// Rewrites components a build can't render into ones it can, using the fallbacks declared in
/// the newest catalog (RFC-006). Deterministic and pure, so it runs on a server or on the device.
public struct A2UIDowncompiler: Sendable {
    /// The newest catalog: where the fallback rules live.
    public let source: A2UICatalogManifest
    /// What the receiving build can render.
    public let target: A2UICatalogManifest
    /// How many fallbacks may chain (v3 to v2 to basic) before giving up.
    public var maxPasses = 8

    public init(source: A2UICatalogManifest, target: A2UICatalogManifest) {
        self.source = source
        self.target = target
    }

    public struct Substitution: Sendable, Hashable {
        public enum Reason: Sendable, Hashable {
            case unknownType
            case newerVersion(required: Int, supported: Int)
        }
        public enum Outcome: Sendable, Hashable {
            /// Replaced by the fallback declared in the source catalog.
            case declaredFallback
            /// Left alone: the component names its own `fallback` for the device to use.
            case inlineFallback
            /// No rule: replaced by plain text, or by an empty container.
            case generic
        }
        public let componentId: String
        public let type: String
        public let reason: Reason
        public let outcome: Outcome
    }

    public struct Result: Sendable, Hashable {
        public var components: [A2UIComponent]
        public var substitutions: [Substitution]
    }

    public func downcompile(_ components: [A2UIComponent]) -> Result {
        var result = Result(components: [], substitutions: [])
        for component in components { process(component, pass: 0, into: &result) }
        return result
    }

    /// Down-compiles an `updateComponents` message. Other messages pass through unchanged.
    public func downcompile(_ message: A2UIMessage) -> (message: A2UIMessage, substitutions: [Substitution]) {
        guard case .updateComponents(let surfaceId, let components) = message else { return (message, []) }
        let result = downcompile(components)
        return (.updateComponents(surfaceId: surfaceId, components: result.components), result.substitutions)
    }

    private func process(_ component: A2UIComponent, pass: Int, into result: inout Result) {
        if target.supports(component) {
            result.components.append(component)
            return
        }
        let reason: Substitution.Reason
        if let known = target.schema(for: component.type) {
            reason = .newerVersion(required: component.minimumVersion, supported: known.version)
        } else {
            reason = .unknownType
        }
        func note(_ outcome: Substitution.Outcome) {
            result.substitutions.append(Substitution(
                componentId: component.id, type: component.type, reason: reason, outcome: outcome))
        }

        if pass < maxPasses, let fallback = source.schema(for: component.type)?.fallback,
           let expanded = Self.expand(fallback, for: component), !expanded.isEmpty {
            note(.declaredFallback)
            for replacement in expanded { process(replacement, pass: pass + 1, into: &result) }
        } else if component["fallback"]?.stringValue != nil {
            note(.inlineFallback)
            result.components.append(component)
        } else {
            note(.generic)
            result.components.append(Self.genericReplacement(for: component))
        }
    }

    /// Instantiates a fallback fragment for one component. The fragment's first entry takes the
    /// component's id; the others get `<id>~<local id>`.
    static func expand(_ fallback: A2UIComponentSchema.Fallback, for original: A2UIComponent) -> [A2UIComponent]? {
        var localIds: [String: String] = [:]
        for (index, entry) in fallback.components.enumerated() {
            guard let local = entry["id"]?.stringValue else { return nil }
            localIds[local] = index == 0 ? original.id : "\(original.id)~\(local)"
        }
        func substitute(_ value: JSONValue, key: String?) -> JSONValue? {
            switch value {
            case .object(let object):
                if object.count == 1, let name = object["$prop"]?.stringValue {
                    return original.properties[name]
                }
                var out: [String: JSONValue] = [:]
                for (k, v) in object { out[k] = substitute(v, key: k) }
                return .object(out)
            case .array(let items):
                return .array(items.compactMap { substitute($0, key: key) })
            case .string(let s):
                // Ids inside the fragment are local; point them at the instantiated ids.
                if let key, ["child", "children", "trigger", "content"].contains(key), let mapped = localIds[s] {
                    return .string(mapped)
                }
                return value
            default:
                return value
            }
        }
        var out: [A2UIComponent] = []
        for entry in fallback.components {
            guard case .object(var props) = entry,
                  let local = props.removeValue(forKey: "id")?.stringValue, let id = localIds[local],
                  let type = props.removeValue(forKey: "component")?.stringValue else { return nil }
            var resolved: [String: JSONValue] = [:]
            for (k, v) in props { resolved[k] = substitute(v, key: k) }   // a missing $prop drops the property
            out.append(A2UIComponent(id: id, type: type, properties: resolved))
        }
        return out
    }

    /// With no rule to follow: keep the component's most text-like property as a `Text`, or
    /// leave an empty `Column` so that whatever pointed at it still resolves.
    static func genericReplacement(for component: A2UIComponent) -> A2UIComponent {
        for key in ["text", "label", "title", "name", "description"] {
            if let value = component[key], value != .null {
                return A2UIComponent(id: component.id, type: "Text", properties: ["text": value])
            }
        }
        return A2UIComponent(id: component.id, type: "Column", properties: ["children": []])
    }
}
