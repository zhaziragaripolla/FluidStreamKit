import Foundation

/// A JSON value: the agent's data model and every component property are stored this way.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// The value as display text, following A2UI's conversion rules: numbers and booleans become
    /// their text, null becomes "", and arrays and objects become JSON.
    public var displayString: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return Self.format(n)
        case .string(let s): return s
        case .array, .object:
            guard let data = try? JSONValue.encoder.encode(self) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func format(_ n: Double) -> String {
        if n.isFinite, n.rounded() == n, abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - JSON Pointer (RFC 6901)

/// A parsed JSON Pointer such as `/user/name` or `/items/0`. A2UI uses `/` for the whole model.
public struct JSONPointer: Sendable, Hashable, CustomStringConvertible {
    public var tokens: [String]

    public static let root = JSONPointer(tokens: [])

    public init(tokens: [String]) { self.tokens = tokens }

    /// Parses an absolute pointer. Returns nil unless the string is empty or starts with `/`.
    public init?(_ string: String) {
        if string.isEmpty || string == "/" { self.tokens = []; return }
        guard string.hasPrefix("/") else { return nil }
        self.tokens = string.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map {
            $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
    }

    /// Resolves `path` against `scope`: absolute paths stand alone, and relative paths (no leading
    /// slash, used inside templates) are appended to the scope.
    public static func resolve(_ path: String, in scope: JSONPointer) -> JSONPointer? {
        if path.hasPrefix("/") || path.isEmpty { return JSONPointer(path) }
        guard let relative = JSONPointer("/" + path) else { return nil }
        return JSONPointer(tokens: scope.tokens + relative.tokens)
    }

    public func appending(_ token: String) -> JSONPointer { JSONPointer(tokens: tokens + [token]) }

    public var description: String {
        tokens.isEmpty ? "/" : tokens.map {
            "/" + $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
        }.joined()
    }
}

extension JSONValue {
    /// The value at `pointer`, or nil if any step is missing.
    public func value(at pointer: JSONPointer) -> JSONValue? {
        var current = self
        for token in pointer.tokens {
            switch current {
            case .object(let o):
                guard let next = o[token] else { return nil }
                current = next
            case .array(let a):
                guard let i = Int(token), a.indices.contains(i) else { return nil }
                current = a[i]
            default:
                return nil
            }
        }
        return current
    }

    /// Writes `newValue` at `pointer`, creating objects for missing steps. In an array, an index
    /// equal to the count (or `-`) appends. Returns false and leaves the value unchanged if the
    /// pointer can't be written (an array index out of range, or a non-numeric array index).
    @discardableResult
    public mutating func set(_ newValue: JSONValue, at pointer: JSONPointer) -> Bool {
        guard let updated = setting(newValue, tokens: pointer.tokens[...]) else { return false }
        self = updated
        return true
    }

    private func setting(_ newValue: JSONValue, tokens: ArraySlice<String>) -> JSONValue? {
        guard let token = tokens.first else { return newValue }
        let rest = tokens.dropFirst()
        switch self {
        case .array(var a):
            let index = token == "-" ? a.count : Int(token)
            guard let i = index, i >= 0, i <= a.count else { return nil }
            if i == a.count {
                guard let child = JSONValue.null.setting(newValue, tokens: rest) else { return nil }
                a.append(child)
            } else {
                guard let child = a[i].setting(newValue, tokens: rest) else { return nil }
                a[i] = child
            }
            return .array(a)
        case .object(var o):
            guard let child = (o[token] ?? .null).setting(newValue, tokens: rest) else { return nil }
            o[token] = child
            return .object(o)
        default:
            guard let child = JSONValue.null.setting(newValue, tokens: rest) else { return nil }
            return .object([token: child])
        }
    }

    /// Removes the value at `pointer`. Removing the root resets to an empty object.
    @discardableResult
    public mutating func remove(at pointer: JSONPointer) -> Bool {
        guard let last = pointer.tokens.last else { self = .object([:]); return true }
        let parent = JSONPointer(tokens: Array(pointer.tokens.dropLast()))
        switch value(at: parent) {
        case .object(var o):
            guard o.removeValue(forKey: last) != nil else { return false }
            return set(.object(o), at: parent)
        case .array(var a):
            guard let i = Int(last), a.indices.contains(i) else { return false }
            a.remove(at: i)
            return set(.array(a), at: parent)
        default:
            return false
        }
    }
}
