import Foundation

// MARK: - Parsing JSON text

extension JSONValue {
    /// The JSON text parsed, or `nil` when it is not JSON.
    ///
    /// Gives the value `JSONDecoder` gives for the same text, without the
    /// `Decodable` path: `init(from:)` has to probe each kind with `try?`, so
    /// it throws — and pays for — a Swift error per probe that misses, which on
    /// the record-log store's per-entry and per-row reads was most of the time
    /// an acknowledgement took. This reads the bytes once and throws nothing.
    ///
    /// Numbers follow the type's one numeric case: a number too large for a
    /// `Double` is not JSON this type can carry, so the text reads as `nil`.
    init?(jsonText text: String) {
        var text = text
        guard let value = text.withUTF8({ bytes -> JSONValue? in
            var parser = JSONTextParser(bytes: bytes)
            return parser.document()
        }) else { return nil }
        self = value
    }
}

/// An RFC 8259 reader over UTF-8 bytes that a Swift `String` already
/// validated, so it never has to check the encoding — only the grammar. It
/// accepts what `JSONDecoder` accepts, a comma before a close included.
///
/// Every `nil` here is spelled as a branch or `Optional.none`, never as a bare
/// ternary arm: `JSONValue` is `ExpressibleByNilLiteral`, so `cond ? value : nil`
/// reads as JSON `null` rather than as no value.
private struct JSONTextParser {
    let bytes: UnsafeBufferPointer<UInt8>
    var at = 0
    var depth = 0

    /// The nesting `JSONDecoder` accepts; deeper text is refused rather than
    /// recursing without bound.
    static let maxDepth = 512

    init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    mutating func document() -> JSONValue? {
        // A byte-order mark is skipped where the decoder skips one: first.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { at = 3 }
        skipWhitespace()
        guard let value = value() else { return nil }
        skipWhitespace()
        guard at == bytes.count else { return nil }
        return value
    }

    // MARK: - Values

    private mutating func value() -> JSONValue? {
        guard at < bytes.count else { return nil }
        switch bytes[at] {
        case UInt8(ascii: "{"): return object()
        case UInt8(ascii: "["): return array()
        case UInt8(ascii: "\""): return string().map(JSONValue.string)
        case UInt8(ascii: "t"): return literal("true") ? JSONValue.bool(true) : Optional.none
        case UInt8(ascii: "f"): return literal("false") ? JSONValue.bool(false) : Optional.none
        case UInt8(ascii: "n"): return literal("null") ? JSONValue.null : Optional.none
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return number()
        default: return nil
        }
    }

    private mutating func object() -> JSONValue? {
        guard enter() else { return nil }
        defer { depth -= 1 }
        at += 1
        var members: [String: JSONValue] = [:]
        skipWhitespace()
        if consume(UInt8(ascii: "}")) { return .object(members) }
        while true {
            guard at < bytes.count, bytes[at] == UInt8(ascii: "\""), let key = string() else { return nil }
            skipWhitespace()
            guard consume(UInt8(ascii: ":")) else { return nil }
            skipWhitespace()
            // A repeated key keeps its first value, as `JSONDecoder` does — and,
            // as it does, never converts the later one.
            if members[key] == nil {
                guard let member = value() else { return nil }
                members[key] = member
            } else {
                guard skipValue() else { return nil }
            }
            skipWhitespace()
            let more = consume(UInt8(ascii: ","))
            if more { skipWhitespace() }
            // A comma before the close is accepted, as `JSONDecoder` accepts it.
            if consume(UInt8(ascii: "}")) { return .object(members) }
            guard more else { return nil }
        }
    }

    private mutating func array() -> JSONValue? {
        guard enter() else { return nil }
        defer { depth -= 1 }
        at += 1
        var elements: [JSONValue] = []
        skipWhitespace()
        if consume(UInt8(ascii: "]")) { return .array(elements) }
        while true {
            guard let element = value() else { return nil }
            elements.append(element)
            skipWhitespace()
            let more = consume(UInt8(ascii: ","))
            if more { skipWhitespace() }
            if consume(UInt8(ascii: "]")) { return .array(elements) }
            guard more else { return nil }
        }
    }

    /// A string, `at` on its opening quote.
    private mutating func string() -> String? {
        at += 1
        let start = at
        // Most strings have no escape: they are their own bytes.
        while at < bytes.count {
            let byte = bytes[at]
            if byte == UInt8(ascii: "\"") {
                let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<at]), as: UTF8.self)
                at += 1
                return text
            }
            if byte == UInt8(ascii: "\\") { break }
            if byte < 0x20 { return nil }
            at += 1
        }
        guard at < bytes.count else { return nil }

        var decoded = Array(UnsafeBufferPointer(rebasing: bytes[start..<at]))
        while at < bytes.count {
            let byte = bytes[at]
            switch byte {
            case UInt8(ascii: "\""):
                at += 1
                return String(decoding: decoded, as: UTF8.self)
            case UInt8(ascii: "\\"):
                at += 1
                guard at < bytes.count else { return nil }
                let escape = bytes[at]
                at += 1
                switch escape {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): decoded.append(escape)
                case UInt8(ascii: "b"): decoded.append(0x08)
                case UInt8(ascii: "f"): decoded.append(0x0C)
                case UInt8(ascii: "n"): decoded.append(0x0A)
                case UInt8(ascii: "r"): decoded.append(0x0D)
                case UInt8(ascii: "t"): decoded.append(0x09)
                case UInt8(ascii: "u"):
                    guard let scalar = unicodeEscape() else { return nil }
                    decoded.append(contentsOf: UTF8.encode(scalar)!)
                default: return nil
                }
            default:
                if byte < 0x20 { return nil }
                decoded.append(byte)
                at += 1
            }
        }
        return nil
    }

    /// The scalar a `\u` escape names, `at` just past the `u`; a surrogate pair
    /// is two escapes, and half of one is not a scalar.
    private mutating func unicodeEscape() -> Unicode.Scalar? {
        guard let unit = hexUnit() else { return nil }
        switch unit {
        case 0xD800...0xDBFF:
            guard at + 1 < bytes.count, bytes[at] == UInt8(ascii: "\\"), bytes[at + 1] == UInt8(ascii: "u") else {
                return nil
            }
            at += 2
            guard let low = hexUnit(), (0xDC00...0xDFFF).contains(low) else { return nil }
            return Unicode.Scalar(0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00))
        case 0xDC00...0xDFFF:
            return nil
        default:
            return Unicode.Scalar(unit)
        }
    }

    private mutating func hexUnit() -> UInt16? {
        guard at + 4 <= bytes.count else { return nil }
        var unit: UInt16 = 0
        for _ in 0..<4 {
            let byte = bytes[at]
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: return nil
            }
            unit = unit << 4 | UInt16(digit)
            at += 1
        }
        return unit
    }

    /// A number, by the JSON grammar: `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`.
    private mutating func number() -> JSONValue? {
        let start = at
        let negative = consume(UInt8(ascii: "-"))
        guard at < bytes.count, isDigit(bytes[at]) else { return nil }
        let integerStart = at
        if bytes[at] == UInt8(ascii: "0") {
            at += 1
        } else {
            while at < bytes.count, isDigit(bytes[at]) { at += 1 }
        }
        let integerEnd = at
        var plain = true
        if consume(UInt8(ascii: ".")) {
            plain = false
            guard at < bytes.count, isDigit(bytes[at]) else { return nil }
            while at < bytes.count, isDigit(bytes[at]) { at += 1 }
        }
        let mantissaEnd = at
        if at < bytes.count, bytes[at] == UInt8(ascii: "e") || bytes[at] == UInt8(ascii: "E") {
            plain = false
            at += 1
            if at < bytes.count, bytes[at] == UInt8(ascii: "+") || bytes[at] == UInt8(ascii: "-") { at += 1 }
            guard at < bytes.count, isDigit(bytes[at]) else { return nil }
            while at < bytes.count, isDigit(bytes[at]) { at += 1 }
        }
        // A whole number of up to 15 digits is exact in a `Double`, so it is
        // read directly; anything else goes through the correctly rounded
        // conversion the decoder uses.
        if plain, integerEnd - integerStart <= 15 {
            var magnitude: Int64 = 0
            for index in integerStart..<integerEnd { magnitude = magnitude * 10 + Int64(bytes[index] - UInt8(ascii: "0")) }
            let value = Double(magnitude)
            return .number(negative ? -value : value)
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<at]), as: UTF8.self)
        guard let value = Double(text), value.isFinite else { return nil }
        // Like a number too large, one too small to be anything but zero is
        // refused rather than read as zero — `JSONDecoder` refuses it too.
        if value == 0, bytes[integerStart..<mantissaEnd].contains(where: { $0 > UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) {
            return nil
        }
        return .number(value)
    }

    // MARK: - Discarded values

    /// A value a repeated key carries, passed over. `JSONDecoder` keeps the
    /// first value and only scans this one, so only what its scanner checks is
    /// checked: the nesting, the literals, the separators, a string's close and
    /// a `\u`'s four characters. A number is any run of number characters and
    /// a string's contents are not read, so a value the type could not carry
    /// does not refuse the object that keeps the first.
    private mutating func skipValue() -> Bool {
        guard at < bytes.count else { return false }
        switch bytes[at] {
        case UInt8(ascii: "{"): return skipContainer(close: UInt8(ascii: "}"), keyed: true)
        case UInt8(ascii: "["): return skipContainer(close: UInt8(ascii: "]"), keyed: false)
        case UInt8(ascii: "\""): return skipString()
        case UInt8(ascii: "t"): return literal("true")
        case UInt8(ascii: "f"): return literal("false")
        case UInt8(ascii: "n"): return literal("null")
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            while at < bytes.count {
                switch bytes[at] {
                case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"),
                     UInt8(ascii: "+"), UInt8(ascii: "-"):
                    at += 1
                default:
                    return true
                }
            }
            return true
        default: return false
        }
    }

    private mutating func skipContainer(close: UInt8, keyed: Bool) -> Bool {
        guard enter() else { return false }
        defer { depth -= 1 }
        at += 1
        skipWhitespace()
        if consume(close) { return true }
        while true {
            if keyed {
                guard at < bytes.count, bytes[at] == UInt8(ascii: "\""), skipString() else { return false }
                skipWhitespace()
                guard consume(UInt8(ascii: ":")) else { return false }
                skipWhitespace()
            }
            guard skipValue() else { return false }
            skipWhitespace()
            let more = consume(UInt8(ascii: ","))
            if more { skipWhitespace() }
            if consume(close) { return true }
            guard more else { return false }
        }
    }

    /// A string, `at` on its opening quote, passed over to its close.
    private mutating func skipString() -> Bool {
        at += 1
        while at < bytes.count {
            switch bytes[at] {
            case UInt8(ascii: "\""):
                at += 1
                return true
            case UInt8(ascii: "\\"):
                guard at + 1 < bytes.count else { return false }
                at += bytes[at + 1] == UInt8(ascii: "u") ? 6 : 2
            default:
                at += 1
            }
        }
        return false
    }

    // MARK: - Bytes

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private mutating func enter() -> Bool {
        depth += 1
        return depth <= Self.maxDepth
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard at < bytes.count, bytes[at] == byte else { return false }
        at += 1
        return true
    }

    private mutating func literal(_ word: StaticString) -> Bool {
        let count = word.utf8CodeUnitCount
        guard at + count <= bytes.count else { return false }
        for offset in 0..<count where bytes[at + offset] != word.utf8Start[offset] { return false }
        at += count
        return true
    }

    private mutating func skipWhitespace() {
        while at < bytes.count {
            switch bytes[at] {
            case 0x20, 0x09, 0x0A, 0x0D: at += 1
            default: return
            }
        }
    }
}
