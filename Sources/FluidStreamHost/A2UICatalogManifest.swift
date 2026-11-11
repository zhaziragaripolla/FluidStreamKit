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
    /// Component types this one may sit inside (`"Surface"` for the top level), or nil for any.
    public var allowedParents: [String]?
    /// Component types this one may contain, or nil for any.
    public var allowedChildren: [String]?

    public init(name: String, version: Int = 1, description: String? = nil,
                properties: [Property] = [], fallback: Fallback? = nil,
                allowedParents: [String]? = nil, allowedChildren: [String]? = nil) {
        self.name = name
        self.version = version
        self.description = description
        self.properties = properties
        self.fallback = fallback
        self.allowedParents = allowedParents
        self.allowedChildren = allowedChildren
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        description = try c.decodeIfPresent(String.self, forKey: .description)
        properties = try c.decodeIfPresent([Property].self, forKey: .properties) ?? []
        fallback = try c.decodeIfPresent(Fallback.self, forKey: .fallback)
        allowedParents = try c.decodeIfPresent([String].self, forKey: .allowedParents)
        allowedChildren = try c.decodeIfPresent([String].self, forKey: .allowedChildren)
    }

    /// The component in A2UI 1.0 catalog form: a flat object schema whose `component` is a
    /// constant, with properties typed by the common A2UI types.
    public var catalogJSON: JSONValue {
        var props: [String: JSONValue] = ["component": ["const": .string(name)]]
        for p in properties {
            var schema: [String: JSONValue]
            switch p.type {
            case .string: schema = ["$ref": "common_types.json#/$defs/DynamicString"]
            case .number: schema = ["$ref": "common_types.json#/$defs/DynamicNumber"]
            case .boolean: schema = ["$ref": "common_types.json#/$defs/DynamicBoolean"]
            case .array: schema = ["type": "array"]
            case .object: schema = ["type": "object"]
            case .any: schema = ["$ref": "common_types.json#/$defs/DynamicValue"]
            case .component: schema = ["$ref": "common_types.json#/$defs/Child"]
            case .componentList: schema = ["$ref": "common_types.json#/$defs/ChildList"]
            case .action: schema = ["$ref": "common_types.json#/$defs/Action"]
            }
            if let d = p.description { schema["description"] = .string(d) }
            props[p.name] = .object(schema)
        }
        var o: [String: JSONValue] = [
            "type": "object",
            "properties": .object(props),
            "required": .array((["component"] + properties.filter(\.required).map(\.name)).map(JSONValue.string)),
        ]
        if let description { o["description"] = .string(description) }
        if let allowedParents { o["allowedParents"] = .array(allowedParents.map(JSONValue.string)) }
        if let allowedChildren { o["allowedChildren"] = .array(allowedChildren.map(JSONValue.string)) }
        if version > 1 { o["metadata"] = ["extensions": .object([A2UIExtensionKey.componentVersion: .number(Double(version))])] }
        return .object(o)
    }
}

extension A2UIComponent {
    /// The component version the agent asked for, in `@metadata.extensions.fluid_minVersion`
    /// (or a plain `minVersion` property). Defaults to 1.
    public var minimumVersion: Int {
        let raw = extensions[A2UIExtensionKey.minVersion] ?? properties["minVersion"]
        guard let n = raw?.doubleValue, n >= 1, n < 1_000_000 else { return 1 }
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

    /// The `a2uiRendererCapabilities` value a renderer sends with its requests.
    public var rendererCapabilities: JSONValue {
        A2UICatalogManifest.rendererCapabilities(supporting: [self])
    }

    /// Capabilities for several catalogs, which A2UI 1.0 lets an agent mix in one surface.
    /// Pass `inline: true` only when the agent accepts inline catalogs.
    public static func rendererCapabilities(supporting manifests: [A2UICatalogManifest], inline: Bool = false,
                                            functions: A2UIFunctionRegistry? = nil) -> JSONValue {
        var caps: [String: JSONValue] = ["supportedCatalogIds": .array(manifests.map { .string($0.catalogId) })]
        if inline { caps["inlineCatalogs"] = .array(manifests.map { $0.catalogDefinition(functions: functions) }) }
        return .object([A2UIVersion.current: .object(caps)])
    }

    /// The catalog as an A2UI 1.0 catalog definition, for `inlineCatalogs` or for publishing.
    public func catalogDefinition(functions: A2UIFunctionRegistry? = nil, instructions: String? = nil) -> JSONValue {
        let defs: [String: JSONValue] = [
            "anyComponent": ["oneOf": .array(components.map { .object(["$ref": .string("#/components/\($0.name)")]) }),
                             "discriminator": ["propertyName": "component"]],
            "anyFunction": ["oneOf": .array((functions?.definitions.keys.sorted() ?? []).map { .object(["$ref": .string("#/functions/\($0)")]) })],
        ]
        var o: [String: JSONValue] = [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$id": .string(catalogId),
            "catalogId": .string(catalogId),
            "protocolVersion": .string(A2UIVersion.current),
            "title": .string("Catalog \(version)"),
            "components": .object(Dictionary(uniqueKeysWithValues: components.map { ($0.name, $0.catalogJSON) })),
            "$defs": .object(defs),
        ]
        if let functions, !functions.definitions.isEmpty {
            o["functions"] = .object(functions.definitions.mapValues(\.catalogJSON))
        }
        if let instructions { o["instructions"] = .string(instructions) }
        return .object(o)
    }

    /// Composition rules (`allowedParents`, `allowedChildren`) for building a surface's tree.
    public var compositionRules: A2UISurface.CompositionRules {
        var rules = A2UISurface.CompositionRules()
        for c in components {
            if let p = c.allowedParents { rules.allowedParents[c.name] = Set(p) }
            if let ch = c.allowedChildren { rules.allowedChildren[c.name] = Set(ch) }
        }
        return rules
    }

    /// A plain-text description for the agent's prompt: which components it may send and with
    /// which properties.
    public func agentInstructions() -> String {
        var lines = [
            "You can show UI with A2UI \(A2UIVersion.current). Use catalogId \"\(catalogId)\" (version \(version)).",
            "Only these components exist in this app. Never send any other component type.",
            "Bind a property to data with {\"@path\": \"/pointer\"}. Call a function with {\"@call\": \"name\", \"args\": {…}}.",
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
            .init("text", .string, required: true, "Literal, {\"@path\": \"/pointer\"}, or formatString. Markdown, including # headings"),
            .init("variant", .string, "caption or body"),
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
            .init("children", .componentList, required: true, "Ids, or a template {\"componentId\", \"path\"}"),
            .init("direction", .string, "vertical or horizontal"),
        ]),
        .init(name: "Card", properties: [.init("child", .component, required: true)]),
        .init(name: "Divider", properties: [.init("axis", .string, "horizontal or vertical")]),
        .init(name: "Button", properties: [
            .init("child", .component, required: true, "Usually a Text"),
            .init("variant", .string, "default, primary or borderless"),
            .init("action", .action, required: true, "{\"event\": {\"name\", \"context\"}} or {\"functionCall\": {…}}"),
        ]),
        .init(name: "TextField", properties: [
            .init("label", .string),
            .init("value", .string, required: true, "Bind with {\"@path\"} to receive what the user types"),
            .init("placeholder", .string),
            .init("variant", .string, "shortText, longText, number or obscured"),
        ]),
        .init(name: "CheckBox", properties: [
            .init("label", .string, required: true),
            .init("value", .boolean, "Bind with {\"@path\"}"),
        ]),
        .init(name: "ChoicePicker", description: "Pick one or several options.", properties: [
            .init("options", .array, required: true, "[{\"label\": \"Email\", \"value\": \"email\"}]"),
            .init("value", .array, "Selected values. Bind with {\"@path\"}"),
            .init("variant", .string, "mutuallyExclusive (default) or multipleSelection"),
            .init("displayStyle", .string, "checkbox (default) or chips"),
            .init("filterable", .boolean),
            .init("label", .string),
        ]),
        .init(name: "DateTimeInput", properties: [
            .init("value", .string, "ISO 8601. Bind with {\"@path\"}"),
            .init("label", .string),
            .init("enableDate", .boolean),
            .init("enableTime", .boolean, "Default false"),
            .init("min", .string, "ISO 8601"),
            .init("max", .string, "ISO 8601"),
        ]),
        .init(name: "Slider", properties: [
            .init("label", .string),
            .init("value", .number, "Bind with {\"@path\"}"),
            .init("min", .number),
            .init("max", .number, required: true),
            .init("steps", .number, "Number of discrete steps"),
        ]),
        .init(name: "Tabs", properties: [
            .init("tabs", .array, required: true, "[{\"title\": \"Details\", \"child\": \"details\"}]"),
        ]),
        .init(name: "Modal", description: "Shows content in a sheet when the trigger is tapped.", properties: [
            .init("trigger", .component, required: true),
            .init("content", .component, required: true),
        ]),
        .init(name: "Video", properties: [
            .init("url", .string, required: true),
            .init("posterUrl", .string),
        ]),
        .init(name: "AudioPlayer", properties: [
            .init("url", .string, required: true),
            .init("description", .string),
        ]),
    ]
}
