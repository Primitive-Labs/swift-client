import Foundation

/// How each number of a db3 `vector` field is stored (#5225): `f32` (IEEE 754
/// binary32), `f16` (binary16) or `i8` (a signed byte per number, with one
/// binary32 scale for the vector).
public enum VectorElement: String, Sendable, Codable, Hashable, CaseIterable {
    case f32
    case f16
    case i8
}

/// A vector field's encoding: how many numbers it holds and how each is stored.
public struct VectorEncoding: Sendable, Codable, Hashable {
    /// How many numbers the vector holds (at least 1).
    public var dims: Int
    /// How each number is stored.
    public var element: VectorElement

    public init(dims: Int, element: VectorElement) {
        self.dims = dims
        self.element = element
    }
}

/// The vector codec (#5225): how a db3 `vector` field's numbers become the
/// base64 text stored in the record, and back. js-bao's `encodeVector`,
/// `decodeVector` and `vectorBytes`, byte for byte (a shared fixture pins the
/// layout).
///
/// Layout, little-endian:
/// - `f32`: `4 · dims` bytes of binary32.
/// - `f16`: `2 · dims` bytes of binary16, rounded to nearest even.
/// - `i8`: a 4-byte binary32 scale, then `dims` signed bytes, where
///   `scale = max|v| / 127` and `code = round(v / scale)` (half away from
///   zero); an all-zero vector is scale 0 with zero codes.
///
/// The stored value is RFC 4648 standard base64, with padding, of those bytes.
/// A value that does not fit is refused `JsBaoError(.db3VectorInvalid)`.
///
/// ```swift
/// let encoding = VectorEncoding(dims: 3, element: .f32)
/// let text = try VectorCodec.encode([1, -2, 0.5], encoding: encoding)  // "AACAPwAAAMAAAAA/"
/// let numbers = try VectorCodec.decode(text, encoding: encoding)       // [1, -2, 0.5]
/// ```
public enum VectorCodec {
    /// The largest magnitude a binary16 element holds.
    public static let f16Max: Float = 65504

    /// How many bytes a vector of `encoding` takes: `4·dims`, `2·dims` or `4 + dims`.
    public static func byteLength(_ encoding: VectorEncoding) -> Int {
        switch encoding.element {
        case .f32: return 4 * encoding.dims
        case .f16: return 2 * encoding.dims
        case .i8: return 4 + encoding.dims
        }
    }

    /// How many base64 characters a vector of `encoding` takes: `4·ceil(bytes/3)`.
    public static func base64Length(_ encoding: VectorEncoding) -> Int {
        4 * ((byteLength(encoding) + 2) / 3)
    }

    /// The encoding as people read it: `768 × f32`.
    public static func describe(_ encoding: VectorEncoding) -> String {
        "\(encoding.dims) × \(encoding.element.rawValue)"
    }

    /// The encoding as a refusal names it: `768 × f32, 4096 base64 characters`.
    static func describeField(_ encoding: VectorEncoding) -> String {
        "\(describe(encoding)), \(base64Length(encoding)) base64 characters"
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf16)

    private static let sextets: [Int16] = {
        var table = [Int16](repeating: -1, count: 128)
        for (i, code) in alphabet.enumerated() { table[Int(code)] = Int16(i) }
        return table
    }()

    private static func sextet(_ code: UInt16) -> Int {
        code < 128 ? Int(sextets[Int(code)]) : -1
    }

    /// Whether `text` is the canonical RFC 4648 standard base64 (with padding)
    /// of exactly `bytes` bytes: `4·ceil(bytes/3)` characters from the standard
    /// alphabet, the padding the length needs and nothing else, and zero unused
    /// bits in the last data character. Judged without decoding.
    public static func isCanonical(_ text: String, bytes: Int) -> Bool {
        guard bytes >= 1 else { return false }
        let codes = Array(text.utf16)
        guard codes.count == 4 * ((bytes + 2) / 3) else { return false }
        let remainder = bytes % 3
        let padding = remainder == 0 ? 0 : 3 - remainder
        let dataLength = codes.count - padding
        for i in 0..<dataLength where sextet(codes[i]) < 0 { return false }
        for i in dataLength..<codes.count where codes[i] != 61 /* = */ { return false }
        guard padding > 0 else { return true }
        // One byte left over: the last data character carries 2 bits, 4 unused.
        // Two bytes left over: it carries 4 bits, 2 unused.
        return sextet(codes[dataLength - 1]) & (padding == 2 ? 0x0f : 0x03) == 0
    }

    private static func invalid(_ message: String) -> JsBaoError {
        JsBaoError(code: .db3VectorInvalid, message: message)
    }

    private static func check(_ encoding: VectorEncoding) throws {
        guard encoding.dims >= 1 else {
            throw invalid("A vector encoding needs an integer dims of at least 1 and an element of f32, f16, i8")
        }
    }

    /// Encode numbers as a vector field's stored base64.
    ///
    /// - Throws: `JsBaoError(.db3VectorInvalid)` for the wrong length, a number
    ///   that is not finite, or an `f16` value whose rounded magnitude exceeds 65504.
    public static func encode(_ values: [Float], encoding: VectorEncoding) throws -> String {
        try check(encoding)
        let label = describe(encoding)
        guard values.count == encoding.dims else {
            throw invalid("A \(label) vector holds \(encoding.dims) numbers, not \(values.count)")
        }
        for (i, value) in values.enumerated() where !value.isFinite {
            throw invalid("A \(label) vector holds finite numbers; element \(i) is \(jsText(value))")
        }
        var bytes = [UInt8](repeating: 0, count: byteLength(encoding))
        func put32(_ bits: UInt32, at offset: Int) {
            for k in 0..<4 { bytes[offset + k] = UInt8(truncatingIfNeeded: bits >> (8 * UInt32(k))) }
        }
        switch encoding.element {
        case .f32:
            for (i, value) in values.enumerated() { put32(value.bitPattern, at: 4 * i) }
        case .f16:
            for (i, value) in values.enumerated() {
                let bits = f16Bits(value)
                if bits & 0x7c00 == 0x7c00 {
                    throw invalid("A \(label) vector holds magnitudes up to 65504; element \(i) is \(jsText(value))")
                }
                bytes[2 * i] = UInt8(truncatingIfNeeded: bits)
                bytes[2 * i + 1] = UInt8(truncatingIfNeeded: bits >> 8)
            }
        case .i8:
            // Computed in binary64 as js-bao computes it, the scale rounded to binary32.
            let max = values.reduce(0.0) { Swift.max($0, abs(Double($1))) }
            let scale = Float(max / 127)
            put32(scale.bitPattern, at: 0)
            if scale != 0 {
                for (i, value) in values.enumerated() {
                    let q = Double(value) / Double(scale)
                    let magnitude = Swift.min(127, Swift.max(-127, (abs(q) + 0.5).rounded(.down)))
                    bytes[4 + i] = UInt8(bitPattern: Int8(q < 0 ? -magnitude : magnitude))
                }
            }
        }
        return Data(bytes).base64EncodedString()
    }

    /// The raw bytes of a stored vector value.
    ///
    /// - Throws: `JsBaoError(.db3VectorInvalid)` when the text is not canonical
    ///   standard base64.
    public static func bytes(_ base64: String) throws -> [UInt8] {
        let length = base64.utf16.count
        let padding = base64.hasSuffix("==") ? 2 : base64.hasSuffix("=") ? 1 : 0
        guard length > 0, length % 4 == 0, isCanonical(base64, bytes: length / 4 * 3 - padding),
              let data = Data(base64Encoded: base64)
        else { throw invalid("A stored vector is canonical standard base64 with padding") }
        return [UInt8](data)
    }

    /// Decode a stored vector value to its numbers; `f16` and `i8` elements are
    /// converted to binary32.
    ///
    /// - Throws: `JsBaoError(.db3VectorInvalid)` when the text is not the
    ///   canonical base64 of a vector of `encoding`.
    public static func decode(_ base64: String, encoding: VectorEncoding) throws -> [Float] {
        try check(encoding)
        guard isCanonical(base64, bytes: byteLength(encoding)), let data = Data(base64Encoded: base64) else {
            throw invalid("A \(describe(encoding)) vector is \(base64Length(encoding)) base64 characters")
        }
        let bytes = [UInt8](data)
        func get32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
        }
        switch encoding.element {
        case .f32:
            return (0..<encoding.dims).map { Float(bitPattern: get32(4 * $0)) }
        case .f16:
            return (0..<encoding.dims).map { Float(f16Value(UInt16(bytes[2 * $0]) | UInt16(bytes[2 * $0 + 1]) << 8)) }
        case .i8:
            let scale = Double(Float(bitPattern: get32(0)))
            return (0..<encoding.dims).map { Float(Double(Int8(bitPattern: bytes[4 + $0])) * scale) }
        }
    }

    /// The binary16 bits of a binary32 value, rounded to nearest even; overflow is infinity.
    private static func f16Bits(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = (bits >> 16) & 0x8000
        let exponent = Int((bits >> 23) & 0xff)
        let mantissa = bits & 0x7f_ffff
        let e = exponent - 127 + 15
        if e >= 0x1f { return UInt16(sign | 0x7c00) }
        if e <= 0 {
            // A binary16 subnormal (or zero): the significand with its implicit
            // 1, shifted to units of 2^-24.
            let shift = UInt32(14 - e)
            if shift > 24 { return UInt16(sign) }
            let full = mantissa | 0x80_0000
            var m = full >> shift
            let rest = full & ((1 << shift) - 1)
            let halfway = UInt32(1) << (shift - 1)
            if rest > halfway || (rest == halfway && m & 1 == 1) { m += 1 }
            return UInt16(sign | m)
        }
        var h = UInt32(e) << 10 | mantissa >> 13
        let rest = mantissa & 0x1fff
        if rest > 0x1000 || (rest == 0x1000 && h & 1 == 1) { h += 1 }
        // A carry out of the mantissa raises the exponent, possibly to infinity.
        return UInt16(sign | h)
    }

    private static func f16Value(_ bits: UInt16) -> Double {
        let sign: Double = bits & 0x8000 != 0 ? -1 : 1
        let exponent = Int((bits >> 10) & 0x1f)
        let mantissa = Double(bits & 0x3ff)
        if exponent == 0 { return sign * mantissa * pow(2, -24) }
        if exponent == 0x1f { return mantissa != 0 ? .nan : sign * .infinity }
        return sign * (1 + mantissa / 1024) * pow(2, Double(exponent - 15))
    }

    /// A number as JavaScript's `String` prints it, for a refusal's message.
    private static func jsText(_ value: Float) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        return PrimitiveValue.jsNumberString(Double(value))
    }
}
