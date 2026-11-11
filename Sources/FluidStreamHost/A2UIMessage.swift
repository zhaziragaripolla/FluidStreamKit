public import Foundation

/// The A2UI protocol versions this host speaks.
///
/// A2UI 1.0 is the native format. Messages marked `v0.9` or `v0.9.1` are still accepted and
/// upgraded to the 1.0 shapes as they're decoded (see ``A2UILegacy``), so the rest of the host
/// only ever sees 1.0.
public enum A2UIVersion {
    /// The version written on outgoing messages.
    public static let current = "1.0"
    /// Older versions that are upgraded on decode.
    public static let legacy: Set<String> = ["v0.9", "v0.9.1"]
    public static let supported: Set<String> = legacy.union([current])
    /// The MIME type of an A2UI message.
    public static let mimeType = "application/a2ui+json"
    /// The 1.0 basic catalog.
    public static let basicCatalogID = "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"
    /// Every basic-catalog identifier this host renders, current and legacy.
    public static let basicCatalogIDs: Set<String> = [
        basicCatalogID,
        "https://a2ui.org/specification/v0_9_1/catalogs/basic/catalog.json",
        "https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json",
    ]
}

/// One component of a surface: `{"id": …, "component": "<Type>", …properties}`.
public struct A2UIComponent: Sendable, Hashable, Identifiable {
    public let id: String
    /// The component type, such as `Text` or `StayCard`.
    public let type: String
    /// Every property except `id` and `component`, including the `@`-prefixed envelope keys.
    public let properties: [String: JSONValue]

    public init(id: String, type: String, properties: [String: JSONValue] = [:]) {
        self.id = id
        self.type = type
        self.properties = properties
    }

    public subscript(key: String) -> JSONValue? { properties[key] }

    /// The catalog this component comes from, when it overrides the surface's default.
    public var catalogId: String? { properties["@catalogId"]?.stringValue }

    /// `@accessibility`: `label`, `description`, `live` and `hidden`.
    public var accessibility: [String: JSONValue]? { properties["@accessibility"]?.objectValue }

    /// `@checks`: validation rules, each `{"condition": …, "message": …}`.
    public var checks: [JSONValue] { properties["@checks"]?.arrayValue ?? [] }

    /// `@metadata.extensions`: vendor data, such as FluidStreamKit's fallback rules.
    public var extensions: [String: JSONValue] { properties["@metadata"]?["extensions"]?.objectValue ?? [:] }

    /// Child references, in the order the component lists them: `child`, `children` (a list or
    /// a template), `tabs[].child`, then a Modal's `trigger` and `content`.
    public var childReferences: [A2UIChildReference] {
        var refs: [A2UIChildReference] = []
        if let id = properties["child"]?.stringValue { refs.append(.id(id)) }
        switch properties["children"] {
        case .array(let items):
            refs += items.compactMap { $0.stringValue.map(A2UIChildReference.id) }
        case .object(let o):
            if let componentId = o["componentId"]?.stringValue, let path = o["path"]?.stringValue {
                refs.append(.template(componentId: componentId, path: path))
            }
        default:
            break
        }
        if let tabs = properties["tabs"]?.arrayValue {
            refs += tabs.compactMap { $0["child"]?.stringValue.map(A2UIChildReference.id) }
        }
        for key in ["trigger", "content"] {
            if let id = properties[key]?.stringValue { refs.append(.id(id)) }
        }
        return refs
    }
}

public enum A2UIChildReference: Sendable, Hashable {
    case id(String)
    /// One copy of `componentId` per item of the array at `path`, each scoped to its item.
    case template(componentId: String, path: String)
}

/// A `{"@call": …, "args": …, "catalogId": …}` function call.
public struct A2UIFunctionCall: Sendable, Hashable {
    public var name: String
    public var catalogId: String?
    public var args: [String: JSONValue]

    public init(name: String, catalogId: String? = nil, args: [String: JSONValue] = [:]) {
        self.name = name
        self.catalogId = catalogId
        self.args = args
    }

    /// Reads a call from its JSON form, or nil if `value` isn't one.
    public init?(_ value: JSONValue?) {
        guard case .object(let o)? = value, let name = o["@call"]?.stringValue else { return nil }
        self.init(name: name, catalogId: o["catalogId"]?.stringValue, args: o["args"]?.objectValue ?? [:])
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["@call": .string(name)]
        if !args.isEmpty { o["args"] = .object(args) }
        if let catalogId { o["catalogId"] = .string(catalogId) }
        return .object(o)
    }
}

/// The answer to a function call: a value or an error.
public struct A2UIFunctionResponse: Sendable, Hashable {
    public var functionCallId: String
    public var result: Result<JSONValue, A2UIFunctionError>

    public init(functionCallId: String, result: Result<JSONValue, A2UIFunctionError>) {
        self.functionCallId = functionCallId
        self.result = result
    }

    public var json: JSONValue {
        switch result {
        case .success(let value):
            return ["functionCallId": .string(functionCallId), "value": value]
        case .failure(let error):
            return ["functionCallId": .string(functionCallId),
                    "error": ["code": .string(error.code), "message": .string(error.message)]]
        }
    }
}

/// A function failed or wasn't allowed. `code` is an A2UI error code such as
/// `INVALID_FUNCTION_CALL` or `EXPRESSION_ERROR`.
public struct A2UIFunctionError: Error, Sendable, Hashable, CustomStringConvertible {
    public var code: String
    public var message: String
    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
    public var description: String { "\(code): \(message)" }

    public static func invalidCall(_ message: String) -> Self { .init("INVALID_FUNCTION_CALL", message) }
    public static func expression(_ message: String) -> Self { .init("EXPRESSION_ERROR", message) }
    public static func execution(_ message: String) -> Self { .init("EXECUTION_ERROR", message) }
}

/// `createSurface`: a new surface, optionally with its first components and data.
public struct A2UISurfaceDefinition: Sendable, Hashable {
    public var surfaceId: String
    /// The default catalog for components and function calls that don't name their own.
    public var catalogId: String?
    public var sendDataModel: Bool
    public var components: [A2UIComponent]
    public var dataModel: JSONValue?
    public var metadata: JSONValue?
    /// The protocol version the agent spoke when it created the surface.
    public var protocolVersion: String

    public init(surfaceId: String, catalogId: String?, sendDataModel: Bool = false, components: [A2UIComponent] = [],
                dataModel: JSONValue? = nil, metadata: JSONValue? = nil, protocolVersion: String = A2UIVersion.current) {
        self.surfaceId = surfaceId
        self.catalogId = catalogId
        self.sendDataModel = sendDataModel
        self.components = components
        self.dataModel = dataModel
        self.metadata = metadata
        self.protocolVersion = protocolVersion
    }
}

/// An agent-to-renderer A2UI message.
public enum A2UIMessage: Sendable, Equatable {
    case createSurface(A2UISurfaceDefinition)
    case updateComponents(surfaceId: String, components: [A2UIComponent])
    /// `value == .null` removes the value at `path`. `path` "/" replaces the whole model.
    case updateDataModel(surfaceId: String, path: String, value: JSONValue)
    case deleteSurface(surfaceId: String)
    /// The agent asks the renderer to run one of its functions and answer.
    case callRendererFunction(functionCallId: String, surfaceId: String?, call: A2UIFunctionCall)
    /// The agent's answer to a `callAgentFunction`.
    case agentFunctionResponse(A2UIFunctionResponse)

    /// The surface the message is about, if any.
    public var surfaceId: String? {
        switch self {
        case .createSurface(let d): return d.surfaceId
        case .updateComponents(let id, _), .updateDataModel(let id, _, _), .deleteSurface(let id): return id
        case .callRendererFunction(_, let id, _): return id
        case .agentFunctionResponse: return nil
        }
    }
}

public enum A2UIDecodingError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidJSON
    case notAnObject
    case unsupportedVersion(String)
    /// The envelope didn't hold exactly one known message.
    case unknownMessage(keys: [String])
    case missingField(String, message: String)
    case lineTooLong(bytes: Int)

    public var description: String {
        switch self {
        case .invalidJSON: return "Line is not valid JSON"
        case .notAnObject: return "Message is not a JSON object"
        case .unsupportedVersion(let v): return "Unsupported A2UI version \(v)"
        case .unknownMessage(let keys): return "No known message in keys \(keys.sorted())"
        case .missingField(let f, let m): return "\(m) is missing \(f)"
        case .lineTooLong(let n): return "Line of \(n) bytes exceeds the limit and was dropped"
        }
    }
}

extension A2UIMessage {
    static let decoder = JSONDecoder()

    /// Decodes one JSONL line.
    public static func decode(line: some DataProtocol) throws(A2UIDecodingError) -> A2UIMessage {
        let value: JSONValue
        do { value = try decoder.decode(JSONValue.self, from: Data(line)) } catch { throw .invalidJSON }
        return try decode(value)
    }

    /// Decodes one message. `"version": "1.0"` is the native format; `v0.9` and `v0.9.1` are
    /// upgraded to it. A message with no version is read as 1.0.
    public static func decode(_ value: JSONValue) throws(A2UIDecodingError) -> A2UIMessage {
        guard case .object(let envelope) = value else { throw .notAnObject }
        var version = A2UIVersion.current
        if let raw = envelope["version"] {
            guard let v = raw.stringValue, A2UIVersion.supported.contains(v) else {
                throw .unsupportedVersion(raw.displayString)
            }
            version = v
        }
        let legacy = A2UIVersion.legacy.contains(version)
        let kinds = envelope.keys.filter { $0 != "version" }
        guard kinds.count == 1, let kind = kinds.first, case .object(let body)? = envelope[kind] else {
            throw .unknownMessage(keys: Array(envelope.keys))
        }
        func surfaceId() throws(A2UIDecodingError) -> String {
            guard let id = body["surfaceId"]?.stringValue else { throw .missingField("surfaceId", message: kind) }
            return id
        }
        func components(_ list: [JSONValue]) -> [A2UIComponent] {
            // A malformed entry is skipped, not fatal: the rest of the surface still renders.
            list.compactMap { entry -> A2UIComponent? in
                guard case .object(var props) = entry,
                      let id = props.removeValue(forKey: "id")?.stringValue,
                      let type = props.removeValue(forKey: "component")?.stringValue else { return nil }
                let component = A2UIComponent(id: id, type: type, properties: props)
                return legacy ? A2UILegacy.upgrade(component) : component
            }
        }
        switch kind {
        case "createSurface":
            let catalogId = body["catalogId"]?.stringValue
            if legacy, catalogId == nil { throw .missingField("catalogId", message: kind) }
            return .createSurface(A2UISurfaceDefinition(
                surfaceId: try surfaceId(), catalogId: catalogId,
                sendDataModel: body["sendDataModel"]?.boolValue ?? false,
                components: components(body["components"]?.arrayValue ?? []),
                dataModel: body["dataModel"], metadata: body["metadata"], protocolVersion: version))
        case "updateComponents":
            guard let list = body["components"]?.arrayValue else { throw .missingField("components", message: kind) }
            return .updateComponents(surfaceId: try surfaceId(), components: components(list))
        case "updateDataModel":
            // 1.0 requires `value`; null deletes. In v0.9 an omitted value deleted.
            let fallback: JSONValue? = legacy ? .null : nil
            guard let value = body["value"] ?? fallback else { throw .missingField("value", message: kind) }
            return .updateDataModel(surfaceId: try surfaceId(), path: body["path"]?.stringValue ?? "/", value: value)
        case "deleteSurface":
            return .deleteSurface(surfaceId: try surfaceId())
        case "callRendererFunction":
            guard let id = body["functionCallId"]?.stringValue else { throw .missingField("functionCallId", message: kind) }
            guard let call = A2UIFunctionCall(body["callFunction"]) else { throw .missingField("callFunction", message: kind) }
            guard call.catalogId != nil else { throw .missingField("callFunction.catalogId", message: kind) }
            return .callRendererFunction(functionCallId: id, surfaceId: body["surfaceId"]?.stringValue, call: call)
        case "agentFunctionResponse":
            guard let id = body["functionCallId"]?.stringValue else { throw .missingField("functionCallId", message: kind) }
            if let error = body["error"] {
                return .agentFunctionResponse(A2UIFunctionResponse(functionCallId: id, result: .failure(A2UIFunctionError(
                    error["code"]?.stringValue ?? "EXECUTION_ERROR", error["message"]?.stringValue ?? ""))))
            }
            guard let value = body["value"] else { throw .missingField("value", message: kind) }
            return .agentFunctionResponse(A2UIFunctionResponse(functionCallId: id, result: .success(value)))
        default:
            throw .unknownMessage(keys: Array(envelope.keys))
        }
    }
}

/// Upgrades v0.9 components to their A2UI 1.0 form, so the rest of the host sees one format.
public enum A2UILegacy {
    /// `{"path": p}` → `{"@path": p}`, `{"call": f, …}` → `{"@call": f, …}`, `accessibility` →
    /// `@accessibility`, `checks` → `@checks`, `validationRegexp` → a `regex` check, and
    /// FluidStreamKit's `fallback` and `minVersion` → `@metadata.extensions`.
    public static func upgrade(_ component: A2UIComponent) -> A2UIComponent {
        var props: [String: JSONValue] = [:]
        var extensions: [String: JSONValue] = [:]
        var checks: [JSONValue] = []
        var regexChecks: [JSONValue] = []
        for (key, value) in component.properties {
            switch key {
            case "accessibility": props["@accessibility"] = upgradeValue(value)
            case "checks": checks += (upgradeValue(value).arrayValue ?? [])
            case "fallback": extensions[A2UIExtensionKey.fallback] = value
            case "minVersion": extensions[A2UIExtensionKey.minVersion] = value
            case "validationRegexp":
                if let pattern = value.stringValue {
                    regexChecks.append(["condition": ["@call": "regex", "args": [
                        "value": component["value"].map(upgradeValue) ?? .null, "pattern": .string(pattern)]]])
                }
            case "children":
                // A template's `path` stays unprefixed in 1.0.
                if case .object = value { props[key] = value } else { props[key] = upgradeValue(value) }
            default: props[key] = upgradeValue(value)
            }
        }
        checks += regexChecks
        if !checks.isEmpty { props["@checks"] = .array(checks) }
        if !extensions.isEmpty { props["@metadata"] = ["extensions": .object(extensions)] }
        return A2UIComponent(id: component.id, type: component.type, properties: props)
    }

    static func upgradeValue(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let o):
            if o.count == 1, let path = o["path"]?.stringValue { return ["@path": .string(path)] }
            if let name = o["call"]?.stringValue {
                var call: [String: JSONValue] = ["@call": .string(name)]
                if let args = o["args"] { call["args"] = upgradeValue(args) }
                return .object(call)   // `returnType` isn't sent on the wire in 1.0.
            }
            return .object(o.mapValues(upgradeValue))
        case .array(let items):
            return .array(items.map(upgradeValue))
        default:
            return value
        }
    }
}

/// Keys FluidStreamKit reads from a component's `@metadata.extensions`.
public enum A2UIExtensionKey {
    /// The id of a component to show if this build can't render this one (RFC-006).
    public static let fallback = "fluid_fallback"
    /// The lowest component version that renders this correctly (RFC-006).
    public static let minVersion = "fluid_minVersion"
    /// In a catalog definition: the component's own version (RFC-006).
    public static let componentVersion = "fluid_version"
}
