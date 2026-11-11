public import Foundation

/// The A2UI 1.0 basic catalog's functions: formatting, validation, logic and `openUrl`.
public enum A2UIBasicFunctions {
    public static let all: [A2UIFunctionDefinition] = [
        formatString, formatNumber, formatCurrency, formatDate, pluralize,
        required, regex, length, numeric, email,
        and, or, not, openUrl,
    ]

    static let dynamicString: JSONValue = ["$ref": "common_types.json#/$defs/DynamicString"]
    static let dynamicNumber: JSONValue = ["$ref": "common_types.json#/$defs/DynamicNumber"]
    static let dynamicValue: JSONValue = ["$ref": "common_types.json#/$defs/DynamicValue"]
    static let dynamicBoolean: JSONValue = ["$ref": "common_types.json#/$defs/DynamicBoolean"]

    static func valid(_ ok: Bool) -> JSONValue { ["valid": .bool(ok)] }

    // MARK: Formatting

    public static let formatString = A2UIFunctionDefinition(
        "formatString", returns: "string",
        description: "Interpolates ${expression} blocks: paths, literals and function calls.",
        arguments: ["value": dynamicString], required: ["value"],
        body: .pure { args in .string(args.string("value") ?? "") })   // The evaluator renders the template.

    public static let formatNumber = A2UIFunctionDefinition(
        "formatNumber", returns: "string",
        arguments: ["value": dynamicNumber, "decimals": dynamicNumber, "grouping": dynamicBoolean], required: ["value"],
        body: .pure { args throws(A2UIFunctionError) in
            let n = try args.requireNumber("value")
            return .string(numberFormatter(args, style: .decimal).string(from: NSNumber(value: n)) ?? JSONValue.format(n))
        })

    public static let formatCurrency = A2UIFunctionDefinition(
        "formatCurrency", returns: "string",
        arguments: ["value": dynamicNumber, "currency": dynamicString, "decimals": dynamicNumber, "grouping": dynamicBoolean],
        required: ["value", "currency"],
        body: .pure { args throws(A2UIFunctionError) in
            let n = try args.requireNumber("value")
            guard let code = args.string("currency"), code.count == 3 else { throw .expression("'currency' must be an ISO 4217 code") }
            let f = numberFormatter(args, style: .currency)
            f.currencyCode = code.uppercased()
            return .string(f.string(from: NSNumber(value: n)) ?? "\(code) \(JSONValue.format(n))")
        })

    static func numberFormatter(_ args: A2UIFunctionArguments, style: NumberFormatter.Style) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = args.locale
        f.numberStyle = style
        f.usesGroupingSeparator = args["grouping"]?.boolValue ?? true
        if let d = args.number("decimals"), d >= 0, d <= 20 {
            f.minimumFractionDigits = Int(d)
            f.maximumFractionDigits = Int(d)
        }
        return f
    }

    public static let formatDate = A2UIFunctionDefinition(
        "formatDate", returns: "string",
        description: "Formats a date with a Unicode TR35 pattern such as 'yyyy-MM-dd'.",
        arguments: ["value": dynamicValue, "format": dynamicString], required: ["value", "format"],
        body: .pure { args throws(A2UIFunctionError) in
            guard let date = parseDate(args["value"]) else { throw .expression("'value' isn't a date") }
            let f = DateFormatter()
            f.locale = args.locale
            f.dateFormat = args.string("format") ?? "yyyy-MM-dd"
            return .string(f.string(from: date))
        })

    /// ISO 8601 (date, or date and time), or a number of milliseconds since 1970.
    public static func parseDate(_ value: JSONValue?) -> Date? {
        switch value {
        case .number(let n): return Date(timeIntervalSince1970: n / 1000)
        case .string(let s):
            let s = s.trimmingCharacters(in: .whitespaces)
            if let d = try? Date(s, strategy: .iso8601) { return d }
            if let d = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return d }
            let local = DateFormatter()
            local.locale = Locale(identifier: "en_US_POSIX")
            for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd", "HH:mm:ss", "HH:mm"] {
                local.dateFormat = format
                if let d = local.date(from: s) { return d }
            }
            return nil
        default: return nil
        }
    }

    public static let pluralize = A2UIFunctionDefinition(
        "pluralize", returns: "string",
        arguments: ["value": dynamicNumber, "zero": dynamicString, "one": dynamicString, "two": dynamicString,
                    "few": dynamicString, "many": dynamicString, "other": dynamicString],
        required: ["value", "other"],
        body: .pure { args throws(A2UIFunctionError) in
            let n = try args.requireNumber("value")
            let category = pluralCategory(n, language: args.locale.language.languageCode?.identifier ?? "en")
            return .string(args.string(category) ?? args.string("other") ?? "")
        })

    /// CLDR plural categories for common languages; others use the English rule.
    static func pluralCategory(_ n: Double, language: String) -> String {
        let isInteger = n == n.rounded()
        let i = Int(abs(n))
        switch language {
        case "ja", "zh", "ko", "th", "vi", "id": return "other"
        case "fr", "pt": return (isInteger && (i == 0 || i == 1)) ? "one" : "other"
        case "ru", "uk":
            guard isInteger else { return "other" }
            if i % 10 == 1, i % 100 != 11 { return "one" }
            if (2...4).contains(i % 10), !(12...14).contains(i % 100) { return "few" }
            return "many"
        case "pl":
            guard isInteger else { return "other" }
            if i == 1 { return "one" }
            if (2...4).contains(i % 10), !(12...14).contains(i % 100) { return "few" }
            return "many"
        case "ar":
            guard isInteger else { return "other" }
            switch i {
            case 0: return "zero"
            case 1: return "one"
            case 2: return "two"
            default:
                if (3...10).contains(i % 100) { return "few" }
                if (11...99).contains(i % 100) { return "many" }
                return "other"
            }
        default: return (isInteger && i == 1) ? "one" : "other"
        }
    }

    // MARK: Validation

    public static let required = A2UIFunctionDefinition(
        "required", returns: "validationResult", arguments: ["value": dynamicValue], required: ["value"],
        body: .pure { args in
            switch args.values["value"] ?? .null {
            case .null: return valid(false)
            case .string(let s): return valid(!s.isEmpty)
            case .array(let a): return valid(!a.isEmpty)
            default: return valid(true)
            }
        })

    public static let regex = A2UIFunctionDefinition(
        "regex", returns: "validationResult",
        arguments: ["value": dynamicString, "pattern": dynamicString], required: ["value", "pattern"],
        body: .pure { args throws(A2UIFunctionError) in
            let pattern = args.string("pattern") ?? ""
            let compiled = try A2UIRegex.compile(pattern)
            let value = args.string("value") ?? ""
            guard value.unicodeScalars.count <= 4_096 else { return valid(false) }
            let range = NSRange(value.startIndex..., in: value)
            return valid(compiled.firstMatch(in: value, range: range) != nil)
        })

    public static let length = A2UIFunctionDefinition(
        "length", returns: "validationResult",
        arguments: ["value": dynamicString, "min": dynamicNumber, "max": dynamicNumber], required: ["value"],
        body: .pure { args in
            let count: Int
            switch args.values["value"] ?? .null {
            case .array(let a): count = a.count
            case .null: count = 0
            case let v: count = v.displayString.count
            }
            if let min = args.number("min"), Double(count) < min { return valid(false) }
            if let max = args.number("max"), Double(count) > max { return valid(false) }
            return valid(true)
        })

    public static let numeric = A2UIFunctionDefinition(
        "numeric", returns: "validationResult",
        arguments: ["value": dynamicValue, "min": dynamicNumber, "max": dynamicNumber], required: ["value"],
        body: .pure { args in
            guard let n = args.number("value"), n.isFinite else { return valid(false) }
            if let min = args.number("min"), n < min { return valid(false) }
            if let max = args.number("max"), n > max { return valid(false) }
            return valid(true)
        })

    public static let email = A2UIFunctionDefinition(
        "email", returns: "validationResult", arguments: ["value": dynamicString], required: ["value"],
        body: .pure { args in
            let s = args.string("value") ?? ""
            let parts = s.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !s.contains(where: \.isWhitespace) else { return valid(false) }
            let domain = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            return valid(domain.count >= 2 && domain.allSatisfy { !$0.isEmpty })
        })

    // MARK: Logic

    public static let and = A2UIFunctionDefinition(
        "and", returns: "boolean", arguments: ["values": ["type": "array", "items": dynamicBoolean]], required: ["values"],
        body: .pure { args in .bool((args["values"]?.arrayValue ?? []).allSatisfy(A2UIEvaluator.truthiness)) })

    public static let or = A2UIFunctionDefinition(
        "or", returns: "boolean", arguments: ["values": ["type": "array", "items": dynamicBoolean]], required: ["values"],
        body: .pure { args in .bool((args["values"]?.arrayValue ?? []).contains(where: A2UIEvaluator.truthiness)) })

    public static let not = A2UIFunctionDefinition(
        "not", returns: "boolean", arguments: ["value": dynamicBoolean], required: ["value"],
        body: .pure { args in .bool(!A2UIEvaluator.truthiness(args.values["value"] ?? .null)) })

    // MARK: Effects

    public static let openUrl = A2UIFunctionDefinition(
        "openUrl", returns: "void", requiresUserActivation: true,
        description: "Opens an http or https URL in the system browser.",
        arguments: ["url": dynamicString], required: ["url"],
        body: .effect { args throws(A2UIFunctionError) in
            guard let url = args.string("url").flatMap(A2UIURLPolicy.openableURL) else {
                throw .execution("openUrl accepts only http and https URLs")
            }
            return ["url": .string(url.absoluteString)]
        })
}

/// The A2UI regex dialect: a portable, safe subset of ECMAScript patterns.
public enum A2UIRegex {
    /// Compiles a pattern, rejecting what the A2UI dialect forbids and patterns that could
    /// backtrack for a long time.
    public static func compile(_ pattern: String) throws(A2UIFunctionError) -> NSRegularExpression {
        let scalars = Array(pattern.unicodeScalars)
        guard scalars.count <= 256 else { throw .expression("Pattern is longer than 256 characters") }
        try check(scalars)
        do {
            return try NSRegularExpression(pattern: translate(scalars), options: [])
        } catch {
            throw .expression("Pattern doesn't parse")
        }
    }

    /// Rejects backreferences, lookbehind, named groups, property escapes, `\c`, octal escapes
    /// and inline flags, and a bounded-above-one quantifier applied to a group that holds an
    /// unbounded one, such as `(a+)+`.
    static func check(_ s: [Unicode.Scalar]) throws(A2UIFunctionError) {
        var i = 0
        var inClass = false
        // For each open group: does it contain an unbounded quantifier?
        var groups: [Bool] = []
        var lastGroupUnbounded = false
        var lastWasGroup = false
        while i < s.count {
            let c = s[i]
            if c == "\\" {
                guard i + 1 < s.count else { throw .expression("Pattern ends with '\\'") }
                let n = s[i + 1]
                if ("1"..."9").contains(n) || n == "k" { throw .expression("Backreferences aren't allowed") }
                if n == "p" || n == "P" { throw .expression("Unicode property escapes aren't allowed") }
                if n == "c" { throw .expression("\\c escapes aren't allowed") }
                if n == "0", i + 2 < s.count, ("0"..."9").contains(s[i + 2]) { throw .expression("Octal escapes aren't allowed") }
                i += 2
                lastWasGroup = false
                continue
            }
            if inClass {
                if c == "]" { inClass = false }
                i += 1
                continue
            }
            switch c {
            case "[":
                inClass = true
                lastWasGroup = false
            case "(":
                if i + 1 < s.count, s[i + 1] == "?" {
                    let rest = i + 2 < s.count ? s[i + 2] : " "
                    if rest == "<" { throw .expression("Lookbehind and named groups aren't allowed") }
                    if rest != ":" && rest != "=" && rest != "!" { throw .expression("Inline flags aren't allowed") }
                }
                groups.append(false)
                lastWasGroup = false
            case ")":
                lastGroupUnbounded = groups.popLast() ?? false
                lastWasGroup = true
                i += 1
                continue
            case "*", "+", "?", "{":
                var upper = 1, unbounded = false
                if c == "*" || c == "+" { unbounded = true }
                if c == "{" {
                    var j = i + 1
                    var text = ""
                    while j < s.count, s[j] != "}" { text.unicodeScalars.append(s[j]); j += 1 }
                    let parts = text.split(separator: ",", omittingEmptySubsequences: false)
                    if parts.count == 2 && parts[1].isEmpty { unbounded = true }
                    upper = Int(parts.last ?? "") ?? Int(parts.first ?? "") ?? 1
                    i = j
                }
                if lastWasGroup, lastGroupUnbounded, unbounded || upper > 1 {
                    throw .expression("A repeated group can't contain an unbounded quantifier")
                }
                if unbounded, !groups.isEmpty { groups[groups.count - 1] = true }
                if lastWasGroup, lastGroupUnbounded, !groups.isEmpty { groups[groups.count - 1] = true }
                lastWasGroup = false
            default:
                if lastWasGroup, lastGroupUnbounded, !groups.isEmpty { groups[groups.count - 1] = true }
                lastWasGroup = false
            }
            i += 1
        }
        if lastWasGroup, lastGroupUnbounded, !groups.isEmpty { groups[groups.count - 1] = true }
    }

    /// Makes `\d` and `\w` ASCII-only, as the dialect requires.
    static func translate(_ s: [Unicode.Scalar]) -> String {
        var out = ""
        var i = 0
        var inClass = false
        while i < s.count {
            let c = s[i]
            if c == "\\", i + 1 < s.count {
                let n = s[i + 1]
                switch (n, inClass) {
                case ("d", false): out += "[0-9]"
                case ("d", true): out += "0-9"
                case ("w", false): out += "[A-Za-z0-9_]"
                case ("w", true): out += "A-Za-z0-9_"
                default: out.unicodeScalars.append(c); out.unicodeScalars.append(n)
                }
                i += 2
                continue
            }
            if c == "[" { inClass = true }
            if c == "]" { inClass = false }
            out.unicodeScalars.append(c)
            i += 1
        }
        return out
    }
}
