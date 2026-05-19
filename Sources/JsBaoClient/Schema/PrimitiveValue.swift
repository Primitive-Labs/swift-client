import Foundation

/// The canonical set of field types in the js-bao / Primitive wire protocol.
///
/// Named `PrimitiveFieldType` to disambiguate from the older, typed-struct
/// `FieldType` used by `BaoModel<T>`. This is the runtime-schema type used
/// by `PrimitiveValue`, `PrimitiveSchema`, and the `_meta_*` write/read paths.
public enum PrimitiveFieldType: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case string
    case number
    case boolean
    case date
    case id
    case stringset
    case json
}

/// A single field value as understood by the runtime schema layer.
///
/// These are the abstract Swift representations of wire values. The
/// `.stringset` case is special: it maps to a *nested* Y.Map in the CRDT,
/// not to a scalar JSON value. Every other case round-trips through the
/// Yrs FFI as a JSON-encoded string.
public enum PrimitiveValue: Equatable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case date(String)
    case id(String)
    case stringset(Set<String>)
    case json(Data)

    public var fieldType: PrimitiveFieldType {
        switch self {
        case .string:    return .string
        case .number:    return .number
        case .boolean:   return .boolean
        case .date:      return .date
        case .id:        return .id
        case .stringset: return .stringset
        case .json:      return .json
        }
    }

    // MARK: - Convenience accessors

    public var asString: String? {
        switch self {
        case let .string(s): return s
        case let .id(s):     return s
        case let .date(s):   return s
        default:             return nil
        }
    }

    public var asNumber: Double? {
        if case let .number(n) = self { return n }
        return nil
    }

    public var asBoolean: Bool? {
        if case let .boolean(b) = self { return b }
        return nil
    }

    public var asId: String? {
        if case let .id(s) = self { return s }
        return nil
    }

    public var asDateString: String? {
        if case let .date(s) = self { return s }
        return nil
    }

    public var asDate: Date? {
        guard case let .date(s) = self else { return nil }
        if let d = PrimitiveValue.isoDateFormatterFractional.date(from: s) { return d }
        return PrimitiveValue.isoDateFormatter.date(from: s)
    }

    public var asStringSet: Set<String>? {
        if case let .stringset(s) = self { return s }
        return nil
    }

    public var asJson: Data? {
        if case let .json(d) = self { return d }
        return nil
    }

    // MARK: - Yrs FFI encoding

    /// Encode into the JSON string expected by the Yniffi `YrsMap.insert`
    /// call, which is parsed by the Rust side into `lib0::Any`. Returns
    /// `nil` for `.stringset`: those must be written through a nested-map
    /// path, not as a scalar, and a nil return is a loud signal that the
    /// caller routed them wrong.
    public func encodedForYrs() -> String? {
        switch self {
        case let .string(s):
            return PrimitiveValue.jsonEncodeString(s)
        case let .number(n):
            // nil for non-finite values (NaN, ±Infinity) — the runtime
            // skips the field on write rather than crashing the
            // Rust FFI with invalid JSON.
            return PrimitiveValue.encodeNumber(n)
        case let .boolean(b):
            return b ? "true" : "false"
        case let .id(s):
            return PrimitiveValue.jsonEncodeString(s)
        case let .date(s):
            return PrimitiveValue.jsonEncodeString(s)
        case let .json(d):
            // The user handed us raw JSON bytes. Wrap the text as a JSON
            // string so the whole thing round-trips as a string on the wire
            // — this mirrors js-bao's "JSON-encoded string field" convention.
            let text = String(data: d, encoding: .utf8) ?? ""
            return PrimitiveValue.jsonEncodeString(text)
        case .stringset:
            return nil
        }
    }

    /// Decode a JSON string coming back from `YrsMap.get`, given the
    /// declared `PrimitiveFieldType` for the field. Returns `nil` for
    /// malformed input or for types that don't travel as scalars
    /// (`.stringset` — nested Y.Map, read via a different path).
    public static func decode(yrsString: String, as type: PrimitiveFieldType) -> PrimitiveValue? {
        switch type {
        case .string:
            guard let s = decodeJsonString(yrsString) else { return nil }
            return .string(s)
        case .number:
            guard let n = Double(yrsString) else { return nil }
            return .number(n)
        case .boolean:
            switch yrsString {
            case "true":  return .boolean(true)
            case "false": return .boolean(false)
            default:      return nil
            }
        case .id:
            guard let s = decodeJsonString(yrsString) else { return nil }
            return .id(s)
        case .date:
            guard let s = decodeJsonString(yrsString) else { return nil }
            return .date(s)
        case .json:
            guard let s = decodeJsonString(yrsString) else { return nil }
            return .json(Data(s.utf8))
        case .stringset:
            return nil
        }
    }

    // MARK: - Helpers

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoDateFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// JSON-encode a string: surround with `"` and escape inner chars.
    /// Minimal RFC 8259 coverage — `\` `"` `\n` `\r` `\t` — matching
    /// what js-bao's JSON.stringify emits for the common-case strings
    /// js-bao uses in `_meta_*`.
    static func jsonEncodeString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"":  out += "\\\""
            case "\\":  out += "\\\\"
            case "\n":  out += "\\n"
            case "\r":  out += "\\r"
            case "\t":  out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out += String(ch)
                }
            }
        }
        out += "\""
        return out
    }

    /// Inverse of `jsonEncodeString` — parse a `"..."` string with the
    /// common JSON escapes. Returns `nil` if the input is not a
    /// well-formed JSON string literal.
    static func decodeJsonString(_ s: String) -> String? {
        guard s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 else { return nil }
        let body = s.dropFirst().dropLast()
        var out = ""
        out.reserveCapacity(body.count)
        var i = body.startIndex
        while i < body.endIndex {
            let ch = body[i]
            if ch == "\\" {
                let next = body.index(after: i)
                guard next < body.endIndex else { return nil }
                switch body[next] {
                case "\"": out += "\""
                case "\\": out += "\\"
                case "/":  out += "/"
                case "n":  out += "\n"
                case "r":  out += "\r"
                case "t":  out += "\t"
                case "b":  out += "\u{08}"
                case "f":  out += "\u{0C}"
                case "u":
                    let hexStart = body.index(after: next)
                    let hexEnd = body.index(hexStart, offsetBy: 4, limitedBy: body.endIndex) ?? body.endIndex
                    guard body.distance(from: hexStart, to: hexEnd) == 4,
                          let scalar = UInt32(body[hexStart..<hexEnd], radix: 16),
                          let u = Unicode.Scalar(scalar) else { return nil }
                    out.unicodeScalars.append(u)
                    i = hexEnd
                    continue
                default: return nil
                }
                i = body.index(after: next)
            } else {
                out.append(ch)
                i = body.index(after: i)
            }
        }
        return out
    }

    /// Encode a `Double` the way JSON.stringify in JS does: integer values
    /// have no trailing `.0`, everything else uses the shortest roundtrip
    /// decimal. Swift's `"\(n)"` prints `42.0` for `42`; strip that.
    ///
    /// Returns `nil` for **non-finite** values (NaN, ±Infinity). Those
    /// don't have a valid JSON representation, and the yrs FFI parses
    /// every `map.set(key, value)` write as JSON — so emitting "nan"
    /// or "inf" panics the underlying Rust process. Callers must
    /// route around the field (the runtime treats nil as "skip this
    /// field on write"), or validate at the application layer
    /// before reaching the encoder.
    static func encodeNumber(_ n: Double) -> String? {
        guard n.isFinite else { return nil }
        if n == n.rounded(), abs(n) < 1e16 {
            return String(Int64(n))
        }
        return String(n)
    }
}
