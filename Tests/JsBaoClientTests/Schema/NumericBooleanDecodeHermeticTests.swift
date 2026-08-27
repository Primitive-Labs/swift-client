import XCTest
@testable import JsBaoClient
import YSwift

/// A `boolean` field whose CRDT value is the number `0`/`1` rather than a
/// literal `true`/`false` (#2825).
///
/// Any workflow write can produce that today (#2823, #2824), and the JS client
/// renders those rows fine — it reads the value with JS truthiness. The Swift
/// read path used to accept only the strings `"true"`/`"false"`, so `"0"`
/// decoded to `nil`, the field never landed in the SQLite mirror row, and the
/// generated `init?(row:)` required-field guard dropped the whole record.
///
/// The same file's row-side `rowBoolValue` already accepts `.number(0)` /
/// `.number(1)`; the yrs-string decode is held to the same rule here. Both
/// halves are server-free: a plain `YDocument` plus the in-memory query engine.
final class NumericBooleanDecodeHermeticTests: XCTestCase {

    // MARK: - The decode itself

    /// The reported case: `0`/`1` in the CRDT decode as booleans.
    func testNumericZeroAndOneDecodeAsBoolean() {
        XCTAssertEqual(
            PrimitiveValue.decode(yrsString: "0", as: .boolean),
            .boolean(false)
        )
        XCTAssertEqual(
            PrimitiveValue.decode(yrsString: "1", as: .boolean),
            .boolean(true)
        )
    }

    /// Literal booleans still decode as before — the widening is additive.
    func testLiteralBooleansStillDecode() {
        XCTAssertEqual(PrimitiveValue.decode(yrsString: "true", as: .boolean), .boolean(true))
        XCTAssertEqual(PrimitiveValue.decode(yrsString: "false", as: .boolean), .boolean(false))
    }

    /// Truthiness matches `rowBoolValue`: every non-zero number is `true`,
    /// including negatives and non-integral values.
    func testAnyNonZeroNumberIsTrue() {
        for raw in ["2", "-1", "0.5", "1e3"] {
            XCTAssertEqual(
                PrimitiveValue.decode(yrsString: raw, as: .boolean),
                .boolean(true),
                "\(raw) should read as true"
            )
        }
        XCTAssertEqual(PrimitiveValue.decode(yrsString: "-0", as: .boolean), .boolean(false))
    }

    /// The widening stops at numbers. A quoted string or arbitrary garbage in
    /// a boolean field is still undecodable — coercing `"yes"` (or `"false"`,
    /// the *string*) would invent a value the writer never wrote.
    func testNonNumericValuesStillFailToDecode() {
        XCTAssertNil(PrimitiveValue.decode(yrsString: "\"yes\"", as: .boolean))
        XCTAssertNil(PrimitiveValue.decode(yrsString: "\"false\"", as: .boolean))
        XCTAssertNil(PrimitiveValue.decode(yrsString: "null", as: .boolean))
        XCTAssertNil(PrimitiveValue.decode(yrsString: "", as: .boolean))
    }

    // MARK: - End to end: the row survives the query

    /// The issue's chain, start to finish: a record written with `.number(0)`
    /// / `.number(1)` in a declared `boolean` field (nothing validates the
    /// write today — #2824) must still come back from `query()` with the
    /// field readable, not as a NULL column that drops the row from a typed
    /// decode.
    func testMistypedBooleanRowKeepsFieldThroughQuery() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "transactions_2825",
            fields: [
                "id":      FieldDescriptor(type: .id),
                "amount":  FieldDescriptor(type: .number, required: true),
                "pending": FieldDescriptor(type: .boolean, required: true),
            ]
        ))

        _ = try model.create(id: "t1", values: [
            "amount": .number(10), "pending": .number(0),
        ])
        _ = try model.create(id: "t2", values: [
            "amount": .number(20), "pending": .number(1),
        ])

        let rows = try model.query().sorted {
            ($0["id"]?.stringValue ?? "") < ($1["id"]?.stringValue ?? "")
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?["pending"]?.rowBoolValue, false,
                       "0 in a boolean field must land in the row, not as NULL")
        XCTAssertEqual(rows.last?["pending"]?.rowBoolValue, true)

        // The record read path agrees with the mirror row.
        XCTAssertEqual(model.find(id: "t1")?["pending"]?.asBoolean, false)
        XCTAssertEqual(model.find(id: "t2")?["pending"]?.asBoolean, true)

        // And the field is queryable, which is what the app was doing when
        // the rows vanished.
        XCTAssertEqual(try model.query(["pending": true]).count, 1)
    }
}
