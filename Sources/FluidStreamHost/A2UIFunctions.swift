public import Foundation

/// A function a catalog defines: what it returns, who may call it, and what it does.
public struct A2UIFunctionDefinition: Sendable {
    /// Who may invoke the function (A2UI `allowedCallers`).
    public enum Callers: String, Sendable, Hashable {
        /// Only the renderer: from a binding, a check, or a component's action.
        case rendererOnly
        /// Only the agent, through `callRendererFunction`.
        case agentOnly
        case rendererOrAgent
    }

    public enum Body: Sendable {
        /// Computes a value from its arguments, with no side effects.
        case pure(@Sendable (A2UIFunctionArguments) throws(A2UIFunctionError) -> JSONValue)
        /// A side effect the app performs, such as opening a URL. The closure checks the
        /// arguments; the app gets them through ``A2UIAction/localFunction(name:args:)``.
        case effect(@Sendable (A2UIFunctionArguments) throws(A2UIFunctionError) -> [String: JSONValue])
    }

    public var name: String
    /// `string`, `number`, `boolean`, `array`, `object`, `validationResult`, `any` or `void`.
    public var returnType: String
    public var allowedCallers: Callers
    /// Runs only from a user gesture, such as a button tap. Implies ``Callers/rendererOnly``.
    public var requiresUserActivation: Bool
    public var description: String?
    /// The JSON Schema `properties` of `args`, for the catalog definition.
    public var arguments: [String: JSONValue]
    public var requiredArguments: [String]
    public var body: Body

    public init(_ name: String, returns returnType: String, callers: Callers = .rendererOnly,
                requiresUserActivation: Bool = false, description: String? = nil,
                arguments: [String: JSONValue] = [:], required: [String] = [], body: Body) {
        self.name = name
        self.returnType = returnType
        self.allowedCallers = requiresUserActivation ? .rendererOnly : callers
        self.requiresUserActivation = requiresUserActivation
        self.description = description
        self.arguments = arguments
        self.requiredArguments = required
        self.body = body
    }

    /// The definition in A2UI 1.0 catalog form.
    public var catalogJSON: JSONValue {
        var args: [String: JSONValue] = ["type": "object", "properties": .object(arguments)]
        if !requiredArguments.isEmpty { args["required"] = .array(requiredArguments.map(JSONValue.string)) }
        var o: [String: JSONValue] = [
            "type": "object",
            "properties": ["@call": ["const": .string(name)], "args": .object(args)],
            "required": ["@call"],
            "returnType": .string(returnType),
        ]
        if allowedCallers != .rendererOnly { o["allowedCallers"] = .string(allowedCallers.rawValue) }
        if requiresUserActivation { o["requiresUserActivation"] = true }
        if let description { o["description"] = .string(description) }
        return .object(o)
    }
}

/// A function's arguments, already resolved against the data model.
public struct A2UIFunctionArguments: Sendable {
    public var values: [String: JSONValue]
    public var locale: Locale

    public subscript(key: String) -> JSONValue? {
        guard let v = values[key], v != .null else { return nil }
        return v
    }

    public func string(_ key: String) -> String? { self[key]?.displayString }

    public func number(_ key: String) -> Double? {
        switch self[key] {
        case .number(let n): return n
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public func requireNumber(_ key: String) throws(A2UIFunctionError) -> Double {
        guard let n = number(key) else { throw .expression("'\(key)' isn't a number") }
        return n
    }
}

/// The functions a renderer can run, by name.
public struct A2UIFunctionRegistry: Sendable {
    public private(set) var definitions: [String: A2UIFunctionDefinition] = [:]

    public init(_ definitions: [A2UIFunctionDefinition] = []) {
        for d in definitions { self.definitions[d.name] = d }
    }

    public subscript(name: String) -> A2UIFunctionDefinition? { definitions[name] }

    /// Adds a function, or replaces the one with the same name.
    public mutating func register(_ definition: A2UIFunctionDefinition) {
        definitions[definition.name] = definition
    }

    public func registering(_ definition: A2UIFunctionDefinition) -> A2UIFunctionRegistry {
        var copy = self
        copy.register(definition)
        return copy
    }

    /// The A2UI 1.0 basic catalog's functions.
    public static let basic = A2UIFunctionRegistry(A2UIBasicFunctions.all)
}

// MARK: - Evaluation

/// Resolves dynamic values (literals, `{"@path"}` bindings and `{"@call"}` function calls)
/// against one surface's data model.
public struct A2UIEvaluator: Sendable {
    public var dataModel: JSONValue
    /// Where relative paths resolve: the template item, or the root.
    public var scope: JSONPointer
    /// The item index inside a list template, for `@index`.
    public var index: Int?
    public var functions: A2UIFunctionRegistry
    /// True only while handling a user gesture.
    public var userActivated: Bool
    public var locale: Locale

    public init(dataModel: JSONValue, scope: JSONPointer = .root, index: Int? = nil,
                functions: A2UIFunctionRegistry = .basic, userActivated: Bool = false, locale: Locale = .current) {
        self.dataModel = dataModel
        self.scope = scope
        self.index = index
        self.functions = functions
        self.userActivated = userActivated
        self.locale = locale
    }

    /// Calls nest at most this deep, so agent output can't exhaust the stack.
    static let maxDepth = 32

    /// The value of a dynamic property. A binding to nothing is `.null`.
    public func evaluate(_ value: JSONValue) throws(A2UIFunctionError) -> JSONValue {
        try evaluate(value, depth: 0)
    }

    func evaluate(_ value: JSONValue, depth: Int) throws(A2UIFunctionError) -> JSONValue {
        guard depth < Self.maxDepth else { throw .expression("Expressions are nested too deeply") }
        guard case .object(let o) = value else { return value }
        if let path = o["@path"] {
            guard o.count == 1, let p = path.stringValue else { throw .expression("A binding has only '@path'") }
            return read(p)
        }
        if o["@call"] != nil {
            guard let call = A2UIFunctionCall(value) else { throw .expression("'@call' must be a function name") }
            return try self.call(call, depth: depth + 1)
        }
        // A literal object. A leading `@` is escaped as `@@`; any other `@` key is reserved.
        var out: [String: JSONValue] = [:]
        for (key, v) in o {
            if key.hasPrefix("@@") {
                out[String(key.dropFirst())] = v
            } else if key.hasPrefix("@") {
                throw .expression("Unknown key '\(key)'")
            } else {
                out[key] = v
            }
        }
        return .object(out)
    }

    /// A data-model value by path, relative to ``scope`` unless it starts with `/`.
    public func read(_ path: String) -> JSONValue {
        guard let pointer = JSONPointer.resolve(path, in: scope) else { return .null }
        return dataModel.value(at: pointer) ?? .null
    }

    /// Runs a pure function call.
    public func call(_ call: A2UIFunctionCall) throws(A2UIFunctionError) -> JSONValue {
        try self.call(call, depth: 0)
    }

    func call(_ call: A2UIFunctionCall, depth: Int) throws(A2UIFunctionError) -> JSONValue {
        if call.name == "@index" {
            guard let index else { throw .execution("@index is only available inside a list template") }
            let offset = try evaluateArgument(call.args["offset"] ?? 0, depth: depth).doubleValue ?? 0
            return .number(Double(index) + offset)
        }
        guard !call.name.hasPrefix("@") else { throw .expression("Unknown system function \(call.name)") }
        guard let definition = functions[call.name] else {
            throw .expression("Function '\(call.name)' isn't available on this renderer")
        }
        guard definition.allowedCallers != .agentOnly else {
            throw .invalidCall("Function '\(call.name)' can only be called by the agent")
        }
        guard !definition.requiresUserActivation || userActivated else {
            throw .expression("Function '\(call.name)' needs a user gesture")
        }
        let args = try arguments(of: call, depth: depth)
        switch definition.body {
        case .pure(let run):
            if call.name == "formatString", let template = call.args["value"]?.stringValue {
                // formatString reads its own `${…}` expressions with this evaluator.
                return .string(try A2UIFormatString.render(template, evaluator: self, depth: depth))
            }
            return try run(args)
        case .effect:
            throw .expression("Function '\(call.name)' has side effects and runs only from an action")
        }
    }

    /// A call's arguments, each resolved.
    public func arguments(of call: A2UIFunctionCall) throws(A2UIFunctionError) -> A2UIFunctionArguments {
        try arguments(of: call, depth: 0)
    }

    func arguments(of call: A2UIFunctionCall, depth: Int) throws(A2UIFunctionError) -> A2UIFunctionArguments {
        var values: [String: JSONValue] = [:]
        for (key, value) in call.args { values[key] = try evaluateArgument(value, depth: depth) }
        return A2UIFunctionArguments(values: values, locale: locale)
    }

    /// Like ``evaluate(_:)``, and also resolves bindings and calls inside arrays, as in
    /// `and(values: [{"@path": …}, …])`.
    func evaluateArgument(_ value: JSONValue, depth: Int) throws(A2UIFunctionError) -> JSONValue {
        if case .array(let items) = value {
            var out: [JSONValue] = []
            for item in items { out.append(try evaluateArgument(item, depth: depth + 1)) }
            return .array(out)
        }
        return try evaluate(value, depth: depth + 1)
    }

    /// A value as a boolean: `true`, or a validation result whose `valid` is true.
    public static func truthiness(_ value: JSONValue) -> Bool {
        switch value {
        case .bool(let b): return b
        case .object(let o): return o["valid"]?.boolValue ?? false
        default: return false
        }
    }
}

// MARK: - formatString

/// The `${expression}` interpolation of `formatString`: paths, quoted strings, numbers,
/// `true`/`false`/`null`, and calls such as `formatCurrency(value: ${/total}, currency: 'USD')`.
public enum A2UIFormatString {
    public static func render(_ template: String, evaluator: A2UIEvaluator) throws(A2UIFunctionError) -> String {
        try render(template, evaluator: evaluator, depth: 0)
    }

    static func render(_ template: String, evaluator: A2UIEvaluator, depth: Int) throws(A2UIFunctionError) -> String {
        var parser = Parser(Array(template.unicodeScalars), evaluator: evaluator, depth: depth)
        return try parser.template()
    }

    struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        let evaluator: A2UIEvaluator
        let depth: Int

        init(_ s: [Unicode.Scalar], evaluator: A2UIEvaluator, depth: Int) {
            self.s = s
            self.evaluator = evaluator
            self.depth = depth
        }

        func peek(_ offset: Int = 0) -> Unicode.Scalar? { i + offset < s.count ? s[i + offset] : nil }

        mutating func template() throws(A2UIFunctionError) -> String {
            var out = String.UnicodeScalarView()
            while let c = peek() {
                if c == "\\", peek(1) == "$", peek(2) == "{" {
                    out.append(contentsOf: "${".unicodeScalars)
                    i += 3
                } else if c == "$", peek(1) == "{" {
                    i += 2
                    let value = try expression()
                    skipSpaces()
                    guard peek() == "}" else { throw .expression("Missing '}' in formatString") }
                    i += 1
                    out.append(contentsOf: value.displayString.unicodeScalars)
                } else {
                    out.append(c)
                    i += 1
                }
            }
            return String(out)
        }

        mutating func skipSpaces() {
            while let c = peek(), c == " " || c == "\t" || c == "\n" { i += 1 }
        }

        mutating func expression() throws(A2UIFunctionError) -> JSONValue {
            guard depth < A2UIEvaluator.maxDepth else { throw .expression("Expressions are nested too deeply") }
            skipSpaces()
            guard let c = peek() else { throw .expression("Empty expression in formatString") }
            if c == "$", peek(1) == "{" {
                i += 2
                let value = try expression()
                skipSpaces()
                guard peek() == "}" else { throw .expression("Missing '}' in formatString") }
                i += 1
                return value
            }
            if c == "'" || c == "\"" { return .string(try quoted(c)) }
            if c == "-" || ("0"..."9").contains(c) {
                let start = i
                i += 1
                while let d = peek(), ("0"..."9").contains(d) || d == "." { i += 1 }
                let text = String(String.UnicodeScalarView(s[start..<i]))
                guard let n = Double(text) else { throw .expression("Bad number '\(text)'") }
                return .number(n)
            }
            // A word: a keyword, a function call, or a relative path. Or an absolute path.
            let start = i
            while let d = peek(), !" \t\n,)}(:".unicodeScalars.contains(d) { i += 1 }
            let word = String(String.UnicodeScalarView(s[start..<i]))
            guard !word.isEmpty else { throw .expression("Unexpected '\(Character(c))' in formatString") }
            switch word {
            case "true": return true
            case "false": return false
            case "null": return .null
            default: break
            }
            skipSpaces()
            if peek() == "(", !word.contains("/") {
                i += 1
                let call = try callArguments(name: word)
                var nested = evaluator
                nested.userActivated = false
                return try nested.call(call, depth: depth + 1)
            }
            return evaluator.read(word)
        }

        mutating func callArguments(name: String) throws(A2UIFunctionError) -> A2UIFunctionCall {
            var args: [String: JSONValue] = [:]
            skipSpaces()
            if peek() == ")" { i += 1; return A2UIFunctionCall(name: name) }
            while true {
                skipSpaces()
                let start = i
                while let d = peek(), d != ":" && d != " " && d != ")" { i += 1 }
                let key = String(String.UnicodeScalarView(s[start..<i]))
                skipSpaces()
                guard !key.isEmpty, peek() == ":" else { throw .expression("Expected 'name: value' in \(name)(…)") }
                i += 1
                // Already-evaluated values: the call must not evaluate them again.
                let value = try expression()
                args[key] = Self.literal(value)
                skipSpaces()
                if peek() == "," { i += 1; continue }
                if peek() == ")" { i += 1; break }
                throw .expression("Expected ',' or ')' in \(name)(…)")
            }
            return A2UIFunctionCall(name: name, args: args)
        }

        /// Escapes an object so it reads back as itself, not as a binding or call.
        static func literal(_ value: JSONValue) -> JSONValue {
            guard case .object(let o) = value else { return value }
            var out: [String: JSONValue] = [:]
            for (k, v) in o { out[k.hasPrefix("@") ? "@" + k : k] = v }
            return .object(out)
        }

        mutating func quoted(_ quote: Unicode.Scalar) throws(A2UIFunctionError) -> String {
            i += 1
            var out = String.UnicodeScalarView()
            while let c = peek() {
                i += 1
                if c == "\\", let next = peek() { out.append(next); i += 1; continue }
                if c == quote { return String(out) }
                out.append(c)
            }
            throw .expression("Unterminated string in formatString")
        }
    }
}
