import Foundation

// MARK: - URLEncoding

/// Percent-encoding for a single URL value — one path segment or one query
/// value.
///
/// Every sub-API used to hand-escape each value with Foundation's
/// component-level charsets (`.urlPathAllowed` / `.urlQueryAllowed`). Those sets
/// describe the characters legal in a *whole* path or query, so every character
/// that *separates* values inside a component — `+ & = / ; : @ space` and more —
/// passes through unescaped. A `+` in a query value then decodes to a space on
/// the server, a `/` in a path value splits into extra path segments, and so on.
/// `HttpClient.buildURLRequest` interpolates the assembled string onto the wire
/// verbatim (`.percentEncodedPath` / `.percentEncodedQuery`), so each value must
/// already be fully escaped before it reaches the path.
///
/// `encodeComponent` escapes a value the way JavaScript's `encodeURIComponent`
/// does: only the unreserved set (`A–Z a–z 0–9 - _ . ! ~ * ' ( )`) survives, and
/// everything else — reserved characters included — is percent-encoded. This is
/// the same encoding the JS client gets from `URLSearchParams`, so the two
/// clients put the same bytes on the wire. Route both path segments and query
/// values through it (prefer `URLQuery` for query strings) so a value cannot
/// reach the wire unescaped, and a sub-API added later cannot reintroduce a
/// hand-rolled, wrong-charset escape.
enum URLEncoding {
    /// The `encodeURIComponent` unreserved set: ASCII alphanumerics plus
    /// `-_.!~*'()`.
    ///
    /// Built from an explicit ASCII list rather than `CharacterSet.alphanumerics`,
    /// which is Unicode-aware and would leave non-ASCII letters (e.g. `é`)
    /// unescaped — `encodeURIComponent` percent-encodes those as UTF-8.
    private static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyz")
        set.insert(charactersIn: "0123456789")
        set.insert(charactersIn: "-_.!~*'()")
        return set
    }()

    /// Percent-encode a single value with `encodeURIComponent` semantics.
    ///
    /// Because the unreserved set excludes `/`, this also escapes a `/` inside a
    /// value, so a value cannot break out into extra path segments — the
    /// single-path-segment guarantee the older `.urlPathAllowed` sites lacked.
    ///
    /// `addingPercentEncoding` only returns `nil` when the string can't be
    /// represented in the target encoding, which never happens for a Swift
    /// `String` (always valid Unicode). The `?? value` keeps the call
    /// non-throwing; it is not a reachable fallback.
    static func encodeComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}

// MARK: - URLQuery

/// Order-preserving query-string builder — the `URLSearchParams` equivalent.
///
/// Each value is percent-encoded with `encodeURIComponent` semantics
/// (`URLEncoding.encodeComponent`) as it is added, so no call site can forget to
/// escape one. `append` preserves the caller's order and does not deduplicate
/// keys, matching the hand-built parameter arrays it replaces.
struct URLQuery {
    private var parts: [String] = []

    init() {}

    /// Append `key=value`, percent-encoding both.
    ///
    /// Keys are almost always literal constants (`cursor`, `email`, …) for which
    /// encoding is a no-op, but encoding them too keeps caller-supplied keys
    /// (e.g. Gemini passthrough query params) safe.
    mutating func append(_ key: String, _ value: String) {
        parts.append("\(URLEncoding.encodeComponent(key))=\(URLEncoding.encodeComponent(value))")
    }

    /// Append `key=value` for an integer value (e.g. `limit`).
    mutating func append(_ key: String, _ value: Int) {
        append(key, String(value))
    }

    /// Append `key=value` only when `value` is non-nil.
    mutating func appendIfPresent(_ key: String, _ value: String?) {
        if let value { append(key, value) }
    }

    /// Whether any parameters have been added.
    var isEmpty: Bool { parts.isEmpty }

    /// The query string with a leading `?`, or `""` when empty. Interpolate it
    /// directly after the path: `"/groups\(query.queryString)"`.
    var queryString: String {
        parts.isEmpty ? "" : "?\(parts.joined(separator: "&"))"
    }
}
