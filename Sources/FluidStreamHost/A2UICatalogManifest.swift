public import Foundation

/// What one component type accepts, as data: its version, its properties and what to show in
/// its place on a build that can't render it (RFC-006).
public struct A2UIComponentSchema: Sendable, Hashable, Codable {
    public struct Property: Sendable, Hashable, Codable {
        public enum Kind: String, Sendable, Codable {
            case string, number, boolean, array, object, any
            /// The id of another component.
            case component
            /// A list of component ids, or a template.
            case componentList
            case action
        }

        public var name: String
        public var type: Kind
        public var required: Bool
        public var description: String?
        /// The component version that introduced this property.
        public var since: Int?

        public init(_ name: String, _ type: Kind, required: Bool = false, _ description: String? = nil, since: Int? = nil) {
            self.name = name
            self.type = type
            self.required = required
            self.description = description
            self.since = since
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            type = try c.decodeIfPresent(Kind.self, forKey: .type) ?? .any
            required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
            description = try c.decodeIfPresent(String.self, forKey: .description)
            since = try c.decodeIfPresent(Int.self, forKey: .since)
        }
    }

    /// An A2UI fragment shown in place of the component. The first entry takes the original
    /// component's id. `{"$prop": "name"}` copies a property from the original.
    public struct Fallback: Sendable, Hashable, Codable {
        public var components: [JSONValue]
        public init(components: [JSONValue]) { self.components = components }
    }

    public var name: String
    /// Goes up when the component gains something an older build can't show.
    public var version: Int
    public var description: String?
    public var properties: [Property]
    public var fallback: Fallback?

    public init(name: String, version: Int = 1, description: String? = nil,
                properties: [Property] = [], fallback: Fallback? = nil) {
        self.name = name
        self.version = version
        self.description = description
        self.properties = properties
        self.fallback = fallback
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        description = try c.decodeIfPresent(String.self, forKey: .description)
        properties = try c.decodeIfPresent([Property].self, forKey: .properties) ?? []
        fallback = try c.decodeIfPresent(Fallback.self, forKey: .fallback)
    }
}

extension A2UIComponent {
    /// The component version the agent asked for with `"minVersion"`. Defaults to 1.
    public var minimumVersion: Int {
        guard let n = properties["minVersion"]?.doubleValue, n >= 1, n < 1_000_000 else { return 1 }
        return Int(n)
    }
}

/// Everything one app build can render. Generate it from the app's catalog, give it to the
/// agent, and use it as the target when down-compiling.
public struct A2UICatalogManifest: Sendable, Hashable, Codable {
    public var catalogId: String
    /// The catalog's own version, for example the app's build number.
    public var version: String
    public var components: [A2UIComponentSchema]

    public init(catalogId: String, version: String, components: [A2UIComponentSchema]) {
        self.catalogId = catalogId
        self.version = version
        self.components = components.sorted { $0.name < $1.name }
    }

    public func schema(for type: String) -> A2UIComponentSchema? {
        components.first { $0.name == type }
    }

    /// Whether this build can render the component: it knows the type, at the version asked for.
    public func supports(_ component: A2UIComponent) -> Bool {
        guard let schema = schema(for: component.type) else { return false }
        return component.minimumVersion <= schema.version
    }

    /// The manifest as JSON with sorted keys, so the same catalog always gives the same bytes.
    public func encoded() throws -> Data {
        try JSONValue.encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> A2UICatalogManifest {
        try JSONDecoder().decode(A2UICatalogManifest.self, from: data)
    }

    /// The `a2uiClientCapabilities` value a client sends with its requests.
    public var clientCapabilities: JSONValue {
        .object([A2UIVersion.current: ["supportedCatalogIds": [.string(catalogId)]]])
    }

    /// A plain-text description for the agent's prompt: which components it may send and with
    /// which properties.
    public func agentInstructions() -> String {
        var lines = [
            "You can show UI with A2UI \(A2UIVersion.current). Use catalogId \"\(catalogId)\" (version \(version)).",
            "Only these components exist in this app. Never send any other component type.",
            "",
        ]
        for schema in components {
            var head = "- \(schema.name) (v\(schema.version))"
            if let description = schema.description { head += ": \(description)" }
            lines.append(head)
            for property in schema.properties {
                var line = "    \(property.name): \(property.type.rawValue)"
                if property.required { line += ", required" }
                if let description = property.description { line += ". \(description)" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
}

extension A2UIComponentSchema {
    /// Schemas for the basic-catalog components this package renders today.
    public static let basicSubset: [A2UIComponentSchema] = [
        .init(name: "Text", description: "A run of text. Supports simple Markdown.", properties: [
            .init("text", .string, required: true, "Literal, or {\"path\": \"/pointer\"}"),
            .init("variant", .string, "h1, h2, h3, h4, h5, caption or body"),
        ]),
        .init(name: "Image", properties: [
            .init("url", .string, required: true, "http, https or data URL"),
            .init("description", .string, "Read by screen readers"),
            .init("fit", .string, "contain or cover"),
            .init("variant", .string, "icon, avatar, smallFeature, mediumFeature, largeFeature or header"),
        ]),
        .init(name: "Icon", properties: [.init("name", .string, required: true)]),
        .init(name: "Row", description: "Lays children out side by side.", properties: [
            .init("children", .componentList, required: true),
            .init("justify", .string, "start, center, end or spaceBetween"),
            .init("align", .string, "start, center or end"),
        ]),
        .init(name: "Column", description: "Stacks children vertically.", properties: [
            .init("children", .componentList, required: true),
            .init("justify", .string),
            .init("align", .string, "start, center or end"),
        ]),
        .init(name: "List", description: "A list, often from a template over a data array.", properties: [
            .init("children", .componentList, required: true, "Ids, or {\"componentId\", \"path\"}"),
            .init("direction", .string, "vertical or horizontal"),
        ]),
        .init(name: "Card", properties: [.init("child", .component, required: true)]),
        .init(name: "Divider", properties: [.init("axis", .string, "horizontal or vertical")]),
        .init(name: "Button", properties: [
            .init("child", .component, required: true, "Usually a Text"),
            .init("variant", .string, "default, primary or borderless"),
            .init("action", .action, required: true, "{\"event\": {\"name\", \"context\"}}"),
        ]),
        .init(name: "TextField", properties: [
            .init("label", .string),
            .init("value", .string, "Bind with {\"path\"} to receive what the user types"),
            .init("variant", .string, "shortText, longText, number or obscured"),
        ]),
        .init(name: "CheckBox", properties: [
            .init("label", .string, required: true),
            .init("value", .boolean, "Bind with {\"path\"}"),
        ]),
        .init(name: "Slider", properties: [
            .init("label", .string),
            .init("value", .number, "Bind with {\"path\"}"),
            .init("min", .number),
            .init("max", .number),
        ]),
    ]
}
