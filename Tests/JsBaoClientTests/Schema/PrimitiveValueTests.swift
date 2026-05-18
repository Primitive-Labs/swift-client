import XCTest
@testable import JsBaoClient

/// Covers `PrimitiveValue`, the runtime-schema scalar-value representation
/// that crosses the Yrs FFI boundary on the write path and is reconstructed
/// from the FFI's JSON string on the read path.
///
/// Wire-compatibility target: js-bao's `_meta_*`/record-data YMap encoding.
/// The Yrs FFI parses every `insert(key, value)` string as JSON into
/// `lib0::Any`, so the encoded form below must match what js-bao produces
/// when it calls `map.set(key, primitiveValue)` directly.
final class PrimitiveValueTests: XCTestCase {

    // MARK: - Construction + accessors

    func testStringCase() throws {
        let v = PrimitiveValue.string("hello")
        XCTAssertEqual(v.asString, "hello")
        XCTAssertNil(v.asNumber)
        XCTAssertNil(v.asBoolean)
        XCTAssertEqual(v.fieldType, .string)
    }

    func testNumberCase() throws {
        let v = PrimitiveValue.number(42.5)
        XCTAssertEqual(v.asNumber, 42.5)
        XCTAssertNil(v.asString)
        XCTAssertEqual(v.fieldType, .number)
    }

    func testBooleanCase() throws {
        let t = PrimitiveValue.boolean(true)
        let f = PrimitiveValue.boolean(false)
        XCTAssertEqual(t.asBoolean, true)
        XCTAssertEqual(f.asBoolean, false)
        XCTAssertEqual(t.fieldType, .boolean)
    }

    func testIdCase() throws {
        let v = PrimitiveValue.id("01H8ABCD")
        XCTAssertEqual(v.asId, "01H8ABCD")
        XCTAssertEqual(v.asString, "01H8ABCD") // ids are strings on the wire
        XCTAssertEqual(v.fieldType, .id)
    }

    func testDateCase() throws {
        let iso = "2026-04-21T12:00:00Z"
        let v = PrimitiveValue.date(iso)
        XCTAssertEqual(v.asDateString, iso)
        XCTAssertEqual(v.asString, iso)
        XCTAssertNotNil(v.asDate, "ISO 8601 date string should parse into Date")
        XCTAssertEqual(v.fieldType, .date)
    }

    func testDateAccessorReturnsNilForMalformed() throws {
        let v = PrimitiveValue.date("not a date")
        XCTAssertNil(v.asDate)
    }

    func testStringSetCase() throws {
        let v = PrimitiveValue.stringset(["a", "b", "c"])
        XCTAssertEqual(v.asStringSet, ["a", "b", "c"])
        XCTAssertEqual(v.fieldType, .stringset)
    }

    func testJsonCase() throws {
        let payload = Data("{\"k\":1}".utf8)
        let v = PrimitiveValue.json(payload)
        XCTAssertEqual(v.asJson, payload)
        XCTAssertEqual(v.fieldType, .json)
    }

    // MARK: - Encoding to Yrs FFI (JSON string the Rust side parses into lib0::Any)

    /// Yrs stores strings as JSON strings: `"hello"` → `"\"hello\""`.
    func testEncodeString() throws {
        XCTAssertEqual(PrimitiveValue.string("hello").encodedForYrs(), "\"hello\"")
    }

    /// Strings with quotes + backslashes + newlines must be JSON-escaped.
    func testEncodeStringWithSpecialChars() throws {
        let v = PrimitiveValue.string("she said \"hi\"\nok")
        XCTAssertEqual(v.encodedForYrs(), "\"she said \\\"hi\\\"\\nok\"")
    }

    /// Numbers go raw: `42` → `"42"`, `42.5` → `"42.5"`.
    func testEncodeNumber() throws {
        XCTAssertEqual(PrimitiveValue.number(42).encodedForYrs(), "42")
        XCTAssertEqual(PrimitiveValue.number(42.5).encodedForYrs(), "42.5")
        XCTAssertEqual(PrimitiveValue.number(-1.25).encodedForYrs(), "-1.25")
    }

    /// Integer-valued doubles must encode without a trailing `.0` to match
    /// how js-bao / JSON.stringify serializes integer JS numbers.
    func testEncodeIntegerDoubleDoesNotHaveTrailingZero() throws {
        XCTAssertEqual(PrimitiveValue.number(42.0).encodedForYrs(), "42")
        XCTAssertEqual(PrimitiveValue.number(0.0).encodedForYrs(), "0")
    }

    func testEncodeBoolean() throws {
        XCTAssertEqual(PrimitiveValue.boolean(true).encodedForYrs(), "true")
        XCTAssertEqual(PrimitiveValue.boolean(false).encodedForYrs(), "false")
    }

    /// ULIDs / `id` type encode like strings (JSON string).
    func testEncodeId() throws {
        XCTAssertEqual(
            PrimitiveValue.id("01H8ABCD").encodedForYrs(),
            "\"01H8ABCD\""
        )
    }

    /// Dates encode as JSON strings containing the ISO-8601 representation.
    /// js-bao does not do any parsing at the meta layer; dates are just strings.
    func testEncodeDate() throws {
        XCTAssertEqual(
            PrimitiveValue.date("2026-04-21T12:00:00Z").encodedForYrs(),
            "\"2026-04-21T12:00:00Z\""
        )
    }

    /// The `.json` escape-hatch encodes as a JSON string containing the raw
    /// JSON text the user supplied — matches js-bao's "user-decoded JSON"
    /// storage convention for complex values.
    func testEncodeJsonTreatsBytesAsString() throws {
        let payload = Data("{\"nested\":true}".utf8)
        XCTAssertEqual(
            PrimitiveValue.json(payload).encodedForYrs(),
            "\"{\\\"nested\\\":true}\""
        )
    }

    /// StringSet is stored as a nested Y.Map, not as a scalar JSON value.
    /// `encodedForYrs()` is not meaningful for this case — the caller must
    /// route stringsets through a nested-map code path. Represent this as
    /// `nil` so a misuse at a scalar insert site is catchable.
    func testEncodeStringSetReturnsNil() throws {
        XCTAssertNil(PrimitiveValue.stringset(["a"]).encodedForYrs())
    }

    // MARK: - Decoding from Yrs FFI

    /// The FFI returns strings as `"\"hello\""` (the JSON form).
    func testDecodeString() throws {
        let v = PrimitiveValue.decode(yrsString: "\"hello\"", as: .string)
        XCTAssertEqual(v?.asString, "hello")
    }

    func testDecodeEscapedString() throws {
        let v = PrimitiveValue.decode(yrsString: "\"line1\\nline2\"", as: .string)
        XCTAssertEqual(v?.asString, "line1\nline2")
    }

    func testDecodeNumber() throws {
        XCTAssertEqual(
            PrimitiveValue.decode(yrsString: "42", as: .number)?.asNumber,
            42.0
        )
        XCTAssertEqual(
            PrimitiveValue.decode(yrsString: "42.5", as: .number)?.asNumber,
            42.5
        )
    }

    func testDecodeBoolean() throws {
        XCTAssertEqual(
            PrimitiveValue.decode(yrsString: "true", as: .boolean)?.asBoolean,
            true
        )
        XCTAssertEqual(
            PrimitiveValue.decode(yrsString: "false", as: .boolean)?.asBoolean,
            false
        )
    }

    func testDecodeId() throws {
        let v = PrimitiveValue.decode(yrsString: "\"01H8ABCD\"", as: .id)
        XCTAssertEqual(v?.asId, "01H8ABCD")
    }

    func testDecodeDate() throws {
        let iso = "2026-04-21T12:00:00Z"
        let v = PrimitiveValue.decode(yrsString: "\"\(iso)\"", as: .date)
        XCTAssertEqual(v?.asDateString, iso)
    }

    /// Decoding a malformed JSON string returns nil, not a crash.
    func testDecodeMalformedReturnsNil() throws {
        XCTAssertNil(PrimitiveValue.decode(yrsString: "not-json", as: .string))
        XCTAssertNil(PrimitiveValue.decode(yrsString: "abc", as: .number))
    }

    // MARK: - Round-trip

    /// Every encodable scalar case must round-trip through encode → decode.
    func testRoundTripAllScalarTypes() throws {
        let cases: [(PrimitiveValue, PrimitiveFieldType)] = [
            (.string("hello"), .string),
            (.string("with \"quotes\" and\nnewlines"), .string),
            (.number(42), .number),
            (.number(3.14159), .number),
            (.boolean(true), .boolean),
            (.boolean(false), .boolean),
            (.id("01H8ABCDEF"), .id),
            (.date("2026-04-21T12:00:00Z"), .date),
        ]
        for (original, type) in cases {
            let encoded = original.encodedForYrs()
            XCTAssertNotNil(encoded, "encode failed for \(original)")
            let decoded = PrimitiveValue.decode(yrsString: encoded!, as: type)
            XCTAssertEqual(decoded, original, "round-trip mismatch for \(original)")
        }
    }
}
