public import Foundation

/// The A2UI protocol versions this host decodes. `v0.9` and `v0.9.1` share the message shapes
/// used here.
public enum A2UIVersion {
    public static let supported: Set<String> = ["v0.9", "v0.9.1"]
    /// The version written on outgoing messages.
    public static let current = "v0.9.1"
    /// The basic catalog's identifiers.
    public static let basicCatalogIDs: Set<String> = [
        "https://a2ui.org/specification/v0_9_1/catalogs/basic/catalog.json",
        "https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json",
    ]
}

/// One component of a surface: `{"id": …, "component": "<Type>", …properties}`.
public struct A2UIComponent: Sendable, Hashable, Identifiable {
    public let id: String
    /// The component type, such as `Text` or `HotelCard`.
    public let type: String
    /// Every property except `id` and `component`.
    public let properties: [String: JSONValue]

    public init(id: String, type: String, properties: [String: JSONValue] = [:]) {
        self.id = id
        self.type = type
        self.properties = properties
    }

    public subscript(key: String) -> JSONValue? { properties[key] }

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

/// A server-to-client A2UI message.
public enum A2UIMessage: Sendable, Equatable {
    case createSurface(surfaceId: String, catalogId: String, theme: JSONValue?, sendDataModel: Bool)
    case updateComponents(surfaceId: String, components: [A2UIComponent])
    /// `value == nil` means the key was omitted, which removes the value at `path`.
    case updateDataModel(surfaceId: String, path: String, value: JSONValue?)
    case deleteSurface(surfaceId: String)

    public var surfaceId: String {
        switch self {
        case .createSurface(let id, _, _, _), .updateComponents(let id, _),
             .updateDataModel(let id, _, _), .deleteSurface(let id):
            return id
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

    /// Decodes one JSONL line. A missing `version` is accepted; a version other than v0.9.x is not.
    public static func decode(line: some DataProtocol) throws(A2UIDecodingError) -> A2UIMessage {
        let value: JSONValue
        do { value = try decoder.decode(JSONValue.self, from: Data(line)) } catch { throw .invalidJSON }
        return try decode(value)
    }

    public static func decode(_ value: JSONValue) throws(A2UIDecodingError) -> A2UIMessage {
        guard case .object(let envelope) = value else { throw .notAnObject }
        if let version = envelope["version"] {
            guard let v = version.stringValue, A2UIVersion.supported.contains(v) else {
                throw .unsupportedVersion(version.displayString)
            }
        }
        let kinds = envelope.keys.filter { $0 != "version" }
        guard kinds.count == 1, let kind = kinds.first, case .object(let body)? = envelope[kind] else {
            throw .unknownMessage(keys: Array(envelope.keys))
        }
        func surfaceId() throws(A2UIDecodingError) -> String {
            guard let id = body["surfaceId"]?.stringValue else { throw .missingField("surfaceId", message: kind) }
            return id
        }
        switch kind {
        case "createSurface":
            guard let catalogId = body["catalogId"]?.stringValue else {
                throw .missingField("catalogId", message: kind)
            }
            return .createSurface(
                surfaceId: try surfaceId(), catalogId: catalogId, theme: body["theme"],
                sendDataModel: body["sendDataModel"]?.boolValue ?? false)
        case "updateComponents":
            guard let list = body["components"]?.arrayValue else { throw .missingField("components", message: kind) }
            // A malformed entry is skipped, not fatal: the rest of the surface still renders.
            let components = list.compactMap { entry -> A2UIComponent? in
                guard case .object(var props) = entry,
                      let id = props.removeValue(forKey: "id")?.stringValue,
                      let type = props.removeValue(forKey: "component")?.stringValue else { return nil }
                return A2UIComponent(id: id, type: type, properties: props)
            }
            return .updateComponents(surfaceId: try surfaceId(), components: components)
        case "updateDataModel":
            return .updateDataModel(
                surfaceId: try surfaceId(), path: body["path"]?.stringValue ?? "/", value: body["value"])
        case "deleteSurface":
            return .deleteSurface(surfaceId: try surfaceId())
        default:
            throw .unknownMessage(keys: Array(envelope.keys))
        }
    }
}
