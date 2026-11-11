public import Foundation

/// The basic catalog's URL rules for agent-supplied URLs.
public enum A2UIURLPolicy {
    /// A media URL (`Image`, `Video`, `AudioPlayer`) if it's allowed: `http://` or `https://`
    /// with a host, a `data:` URL, or a relative path that doesn't point at another host.
    /// Relative URLs resolve against `base`; with no base they're rejected.
    public static func allowedURL(_ string: String, relativeTo base: URL? = nil) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64 << 10 else { return nil }
        // Browsers ignore tabs and newlines inside URLs, so check the scheme without them.
        let head = String(trimmed.prefix(64).filter { $0 != "\t" && $0 != "\n" && $0 != "\r" })
        if let colon = head.firstIndex(of: ":"),
           !head[..<colon].contains("/"), !head[..<colon].contains("\\"),
           !head[..<colon].contains("?"), !head[..<colon].contains("#") {
            let scheme = head[..<colon].lowercased()
            if scheme == "data" { return URL(string: trimmed) }
            guard scheme == "http" || scheme == "https" else { return nil }
            guard trimmed.contains("\t") == false, trimmed.contains("\n") == false,
                  let url = URL(string: trimmed), let host = url.host, !host.isEmpty,
                  trimmed.dropFirst(scheme.count + 1).hasPrefix("//") else { return nil }
            return url
        }
        let slashes = head.replacingOccurrences(of: "\\", with: "/")
        guard !slashes.hasPrefix("//"), let base else { return nil }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }

    /// A URL `openUrl` may open: absolute `http` or `https` with a host, nothing else.
    public static func openableURL(_ string: String) -> URL? {
        guard let url = allowedURL(string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}
