public import Foundation

/// The basic catalog's rule for media URLs from the agent: trim whitespace, then allow only
/// `http:`, `https:` and `data:` URLs, or relative paths that don't start with `//`.
public enum A2UIURLPolicy {
    /// The URL if it's allowed, resolved against `base` when it's relative. A relative URL with no
    /// base is rejected, since there is nothing safe to resolve it against.
    public static func allowedURL(_ string: String, relativeTo base: URL? = nil) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64 << 10 else { return nil }
        if let colon = trimmed.firstIndex(of: ":"),
           !trimmed[..<colon].contains("/"), !trimmed[..<colon].contains("?"), !trimmed[..<colon].contains("#") {
            let scheme = trimmed[..<colon].lowercased()
            guard ["http", "https", "data"].contains(scheme) else { return nil }
            return URL(string: trimmed)
        }
        guard !trimmed.hasPrefix("//"), let base else { return nil }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }
}
