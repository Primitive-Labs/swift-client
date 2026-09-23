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
            return PrimitiveValue.encodeNumberForYrs(n)
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
            default:
                // A `boolean` field whose CRDT value is the NUMBER 0/1 rather
                // than a literal boolean (#2825). Workflow writes produce that
                // today (#2823, #2824), and the JS client reads those rows fine
                // via truthiness — a strict decode here returned nil, the field
                // never landed in the SQLite mirror row, and the generated
                // `init?(row:)` required-field guard then dropped the whole
                // record. The row-side `rowBoolValue` already reads
                // `.number(0)` / `.number(1)`; this is the same rule on the
                // yrs-string side. Non-finite values are not booleans.
                guard let n = Double(yrsString), n.isFinite else { return nil }
                return .boolean(n != 0)
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

    // Immutable shared `ISO8601DateFormatter`s. The class is documented as
    // thread-safe for formatting/parsing, and these are configured once and
    // never mutated, so concurrent reads are safe even though the type is
    // not `Sendable` — hence `nonisolated(unsafe)`.
    nonisolated(unsafe) private static let isoDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) private static let isoDateFormatterFractional: ISO8601DateFormatter = {
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

    /// Encode a `Double` the way JSON.stringify in JS does — byte-for-
    /// byte identical to `Number.prototype.toString(10)` (#1117).
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
        return jsNumberString(n)
    }

    /// `encodeNumber`, adjusted for the one place the JS string is not a
    /// legal input: the yrs FFI (#3456).
    ///
    /// `YrsMap.insert` / `tryUpdate` parse their `value` with
    /// `Any::from_json(...).unwrap()` (yniffi `lib/src/map.rs`), and a
    /// BARE INTEGER LITERAL — no decimal point, no exponent — takes that
    /// parser's INTEGER branch, which mishandles the same number a JS
    /// client writes as a float in two different ways.
    ///
    /// Past `i64::MAX` the parse FAILS and the `unwrap` aborts the
    /// process — `EXC_CRASH (SIGABRT)` from inside the CRDT write, with
    /// nothing for the app to catch (`Value 13000000000000000000 out of
    /// range for i64`). ECMA-262 prints full digits up to 1e21, so
    /// roughly half of `UInt64.random(in: 1...UInt64.max)` lands there.
    ///
    /// Below it the parse succeeds and lands the WRONG TYPE.
    /// `Any::try_from(u64)` / `Any::from(i64)` (`yrs/src/any.rs`) answer
    /// `Any::Number(f64)` only up to `F64_MAX_SAFE_INTEGER`, `2^53 - 1`;
    /// above that they answer `Any::BigInt(i64)`, which yrs encodes as
    /// lib0 type 122 and yjs's `readAny` decodes as a JS `bigint`.
    /// Nothing downstream expects one — `JSON.stringify` throws on a
    /// BigInt and no `typeof value === "number"` check sees it — while a
    /// JS client writing the same number sends a float64, type 123.
    ///
    /// So the boundary is `Number.MAX_SAFE_INTEGER`, not `Int64.max`:
    /// above it the literal has to carry a decimal point or an exponent so
    /// the parser takes its float branch and the value lands as the
    /// `Any::Number(f64)` a JS client produces. Every other value —
    /// fractional, already exponential (`1e+21` and up), or integral within
    /// the safe band — is returned untouched, so ordinary numbers keep
    /// their exact js-bao bytes, and the bare literal is exact there
    /// anyway.
    ///
    /// WHICH float literal is not a free choice, because the parser's float
    /// branch is not correctly rounded. It reads the digits into a `u64`
    /// significand and then computes `significand as f64 * 10^exponent`, so
    /// a significand past `2^53` is rounded BEFORE the scaling and the
    /// result can miss the double the caller handed us. Simply appending
    /// `.0` to the js-bao digits does exactly that — `70338045433163640.0`
    /// comes back as `70338045433163632`, a silent 1-ulp change to an
    /// already-representable value, and the unique-index key (built from
    /// the caller's value, `encodeNumber`) no longer describes what was
    /// stored. So `exactFloatLiteral` picks a literal the parser's own
    /// arithmetic turns back into this exact double, and returns nil when
    /// no literal does.
    ///
    /// `encodeNumber` itself is deliberately NOT adjusted: it is the
    /// js-bao `String(value)` twin that builds unique-index KEYS, and a
    /// Y.Map key is never parsed as JSON. Giving those keys an exponent
    /// would stop them colliding with the entries a JS client writes.
    ///
    /// - Returns: the literal, or `nil` for a value that must not be
    ///   written — a non-finite number (skipped on write, #1117) or, past
    ///   `2^64`, one of the rare doubles this parser cannot be made to
    ///   reproduce. `DynamicModel` rejects the latter with a
    ///   field-naming error before it mutates anything.
    static func encodeNumberForYrs(_ n: Double) -> String? {
        guard let s = encodeNumber(n) else { return nil }
        if s.contains(".") || s.contains("e") || s.contains("E") { return s }
        if abs(n) <= maxSafeInteger { return s }
        return exactFloatLiteral(for: n)
    }

    /// The shortest `<significand>e<exponent>` literal that yrs' JSON
    /// parser turns back into exactly `n`, or nil when there is none.
    ///
    /// The parser (serde_json's `f64_from_parts`, reached through
    /// `Any::from_json`) accumulates the literal's digits into a `u64` and
    /// then evaluates `Double(significand) * 10^exponent` in f64 — one
    /// table lookup, one multiply. `candidate * power == magnitude` below
    /// is that same expression, so a candidate that passes it is one the
    /// parser reproduces bit for bit:
    ///
    ///   - `10^exponent` for `exponent <= 22` is exactly representable, so
    ///     the multiply is the only rounding, and it is correctly rounded;
    ///   - the significand is written as the digits of an integral double
    ///     below `2^64`, which is what the parser's `u64` holds, so
    ///     `Double(significand)` gives that double back unchanged.
    ///
    /// Descending `exponent` yields the shortest significand that works —
    /// `13e18` rather than `13000000000000000000e0` — which keeps the
    /// literal close to the digits js-bao would print.
    ///
    /// Every double in `(2^53, 2^64)` is covered by `exponent = 0`, where
    /// the significand is the value's own exact integer form: that is the
    /// whole band the report is about, including every `UInt64`. Above
    /// `2^64` the significand no longer fits and the search can come up
    /// empty (about 1 value in 1500 there) — no JSON literal reaches those
    /// doubles through this parser, so the encoder refuses rather than
    /// storing a neighbor.
    static func exactFloatLiteral(for n: Double) -> String? {
        let magnitude = abs(n)
        let sign = n < 0 ? "-" : ""
        for exponent in stride(from: exactPowersOfTen.count - 1, through: 0, by: -1) {
            let power = exactPowersOfTen[exponent]
            let candidate = (magnitude / power).rounded()
            guard candidate >= 1, candidate < twoToThe64 else { continue }
            guard candidate * power == magnitude else { continue }
            return "\(sign)\(UInt64(candidate))e\(exponent)"
        }
        return nil
    }

    /// JS's `Number.MAX_SAFE_INTEGER` (`2^53 - 1`), which is also yrs'
    /// `F64_MAX_SAFE_INTEGER` — the largest integer literal the yrs JSON
    /// parser still turns into an `Any::Number`.
    private static let maxSafeInteger = 9_007_199_254_740_991.0

    /// The ceiling on a `u64` significand: `Double(UInt64(x))` is exact
    /// for an integral `x` strictly below this.
    private static let twoToThe64 = 18_446_744_073_709_551_616.0

    /// `10^0 … 10^22` — every power of ten a Double holds exactly, which
    /// is also the range in which the parser's scaling step introduces no
    /// error of its own.
    private static let exactPowersOfTen: [Double] = [
        1, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
        1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
    ]

    /// ECMA-262 `Number::toString(x, 10)` for a finite Double.
    ///
    /// Swift's own `String(Double)` is also shortest-round-trip, but it
    /// formats differently from JS at the edges: `1e20` prints as
    /// "1e+20" where JS prints "100000000000000000000" (full digits up
    /// to 1e21), `1e-7` prints as "1e-07" (zero-padded exponent) where
    /// JS prints "1e-7", `1e-6` prints as "1e-06" where JS prints
    /// "0.000001", and integral values carry a trailing ".0". Since
    /// these strings go onto the wire (yrs scalar values, unique-index
    /// keys), they must match js-bao byte-for-byte.
    ///
    /// Approach: take Swift's shortest-round-trip digits, normalize to
    /// (digits s, decimal exponent n) with value = s × 10^(n − k),
    /// k = digit count, then apply the spec's four layout rules:
    ///   - k ≤ n ≤ 21         → digits + (n − k) zeros
    ///   - 0 < n ≤ 21, n < k  → digits with point after n digits
    ///   - −6 < n ≤ 0         → "0." + (−n zeros) + digits
    ///   - otherwise          → d[.ddd]e±(n−1), exponent unpadded
    static func jsNumberString(_ x: Double) -> String {
        if x == 0 { return "0" } // JS: String(0) and String(-0) are "0"
        if x < 0 { return "-" + jsNumberString(-x) }

        // --- Extract shortest-round-trip digits + decimal exponent ---
        let repr = String(x) // e.g. "123.456", "1e+20", "1.5e-07"
        var digits: String
        var n: Int // decimal exponent: value = 0.digits × 10^n

        if let eIdx = repr.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            let mantissa = repr[..<eIdx]
            let expPart = repr[repr.index(after: eIdx)...]
            let exp = Int(expPart) ?? 0
            // Mantissa is "d" or "d.ddd" (never zero-leading here
            // because x > 0 and Swift normalizes to one integer digit).
            let intFrac = mantissa.split(separator: ".", maxSplits: 1)
            let intDigits = String(intFrac[0])
            let fracDigits = intFrac.count > 1 ? String(intFrac[1]) : ""
            digits = intDigits + fracDigits
            n = exp + intDigits.count
        } else {
            let intFrac = repr.split(separator: ".", maxSplits: 1)
            var intDigits = String(intFrac[0])
            let fracDigits = intFrac.count > 1 ? String(intFrac[1]) : ""
            // Strip leading zeros ("0.001" → int "" frac "001").
            while intDigits.first == "0" { intDigits.removeFirst() }
            if intDigits.isEmpty {
                // Pure fraction: locate the first significant digit.
                var leadingZeros = 0
                for ch in fracDigits {
                    if ch == "0" { leadingZeros += 1 } else { break }
                }
                digits = String(fracDigits.dropFirst(leadingZeros))
                n = -leadingZeros
            } else {
                digits = intDigits + fracDigits
                n = intDigits.count
            }
        }
        // Strip trailing zeros — the spec's s has no trailing zeros.
        while digits.hasSuffix("0") { digits.removeLast() }
        let k = digits.count

        // --- Lay out per Number::toString ---
        if k <= n && n <= 21 {
            return String(digits) + String(repeating: "0", count: n - k)
        }
        if 0 < n && n <= 21 {
            let idx = digits.index(digits.startIndex, offsetBy: n)
            return "\(digits[..<idx]).\(digits[idx...])"
        }
        if -6 < n && n <= 0 {
            return "0." + String(repeating: "0", count: -n) + String(digits)
        }
        // Exponential. JS prints the exponent without zero padding.
        let expVal = n - 1
        let expStr = expVal >= 0 ? "+\(expVal)" : "\(expVal)"
        if k == 1 {
            return String(digits) + "e" + expStr
        }
        return "\(digits.prefix(1)).\(digits.dropFirst())e\(expStr)"
    }
}
