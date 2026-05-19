import XCTest
@testable import JsBaoClient
import YSwift

/// Edge-case round-trips for codegen-emitted structs through the live
/// runtime. The "common path" types are covered in
/// `CodegenGauntletTests`; this file pins the **boundaries** of each
/// type — extreme numeric magnitudes, tricky stringset members, ISO
/// date variants, etc.
///
/// All tests use the existing acceptance fixtures (`TaskRecord`,
/// `CrashTestRecord`) — no new schemas. If a regression in the
/// codegen-emitted code drops or corrupts data at one of these
/// boundaries, this file fails loud.
final class CodegenEdgeCaseTests: XCTestCase {

    // MARK: - Date edge cases
    //
    // Date fields travel as JSON-encoded strings (no parsing/canonical-
    // ization on the Swift side — `String` in, `String` out). Pin a
    // representative spread of the formats users actually pass in so
    // future codec changes can't quietly normalize them.

    func testDate_isoUtcZ_roundTripsByteForByte() throws {
        let raw = "2026-04-27T12:34:56Z"
        try assertDateRoundTrip(raw)
    }

    func testDate_isoUtcWithFractionalSeconds_roundTripsByteForByte() throws {
        let raw = "2026-04-27T12:34:56.789Z"
        try assertDateRoundTrip(raw)
    }

    func testDate_isoWithPositiveTimezoneOffset_roundTripsByteForByte() throws {
        let raw = "2026-04-27T21:34:56+09:00"
        try assertDateRoundTrip(raw)
    }

    func testDate_isoWithNegativeTimezoneOffset_roundTripsByteForByte() throws {
        let raw = "2026-04-27T04:34:56-08:00"
        try assertDateRoundTrip(raw)
    }

    func testDate_dateOnlyStringRoundTrips() throws {
        // The schema declares `type = "date"` but the storage is a
        // string — the runtime doesn't validate the format. Users
        // sometimes ship plain `YYYY-MM-DD` for "all-day" semantics.
        // We just want to confirm storage doesn't mangle it.
        let raw = "2026-04-27"
        try assertDateRoundTrip(raw)
    }

    func testDate_emptyStringRoundTrips() throws {
        // Edge of the string-encoded date type — empty string is a
        // legitimate value the storage layer must preserve. (Whether
        // the *application* should accept it is a separate concern.)
        let raw = ""
        try assertDateRoundTrip(raw)
    }

    private func assertDateRoundTrip(_ raw: String, file: StaticString = #file, line: UInt = #line) throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = TypedModel<TaskRecord>(doc: doc)
        let id = "date-\(UUID().uuidString)"
        _ = try model.create(TaskRecord(
            id: id, createdAt: raw, title: "x"
        ))
        let read = try XCTUnwrap(model.find(id: id), file: file, line: line)
        XCTAssertEqual(read.createdAt, raw, "date string should round-trip unchanged", file: file, line: line)
    }

    // MARK: - Number edge cases
    //
    // Numbers are stored as `Double` and travel on the wire as decimal
    // strings (no JSON wrapping). Integer-valued Doubles drop the
    // trailing `.0` (`3` not `3.0`), matching js-bao. The interesting
    // boundaries are precision and special IEEE-754 values.

    func testNumber_zeroRoundTrips() throws {
        try assertNumberRoundTrip(0)
    }

    func testNumber_negativeIntegerRoundTrips() throws {
        try assertNumberRoundTrip(-42)
    }

    func testNumber_smallFractional_roundTrips() throws {
        try assertNumberRoundTrip(0.00001)
    }

    func testNumber_negativeFractional_roundTrips() throws {
        try assertNumberRoundTrip(-3.14159)
    }

    func testNumber_veryLargeMagnitude_roundTrips() throws {
        // Double.greatestFiniteMagnitude is on the edge of what
        // string-decimal encoding can represent without losing
        // precision. Pin the actual behavior so we know whether
        // values near the limit drift.
        let n = 1.7976931348623157e+308
        try assertNumberRoundTrip(n)
    }

    func testNumber_veryPreciseFractional_holdsPrecision() throws {
        // 17 significant digits is the round-trip precision floor for
        // Double per IEEE-754. `Double` → string → `Double` should
        // preserve the exact bit pattern.
        let n = 0.1 + 0.2  // canonical "fp lol" value: 0.30000000000000004
        try assertNumberRoundTrip(n)
    }

    /// **REAL BUG — fails today.**
    ///
    /// `Double.nan` flows through `PrimitiveValue.encodeNumber`,
    /// which calls `String(n)` on non-finite values. Swift's
    /// `String(.nan)` returns the literal `"nan"` — NOT valid JSON.
    /// The yrs FFI parses every value-write as JSON and PANICS the
    /// Rust process with `InvalidJSON(Error("expected value"))` on
    /// `model.create(..., priority: .nan)`.
    ///
    /// Fix: `encodedForYrs()` returns nil for non-finite numbers
    /// (skip the field on write), and `DynamicModel.create`
    /// validates non-finite up front and throws a typed error so
    /// the caller gets a clear "non-finite numbers cannot be
    /// persisted" message instead of a Rust panic.
    ///
    /// Round-trip via `TypedModel.create` is intentionally NOT
    /// exercised because the Rust panic would kill the whole test
    /// process; the encoder-level pin is sufficient.
    func testNumber_NaN_encoderRefusesNonFinite() throws {
        XCTAssertNil(PrimitiveValue.encodeNumber(.nan),
                     "encoder should return nil for non-finite values; currently emits invalid JSON literal 'nan' which panics the Rust FFI on write")
    }

    /// **REAL BUG — fails today.** Same shape as the NaN bug —
    /// `String(.infinity)` returns `"inf"` / `"-inf"`, also invalid
    /// JSON, also panics the Rust FFI.
    func testNumber_infinity_encoderRefusesNonFinite() throws {
        XCTAssertNil(PrimitiveValue.encodeNumber(.infinity),
                     "encoder should return nil for +infinity; currently emits 'inf' which panics the Rust FFI")
        XCTAssertNil(PrimitiveValue.encodeNumber(-.infinity),
                     "encoder should return nil for -infinity; currently emits '-inf' which panics the Rust FFI")
    }

    private func assertNumberRoundTrip(_ n: Double, file: StaticString = #file, line: UInt = #line) throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = TypedModel<TaskRecord>(doc: doc)
        let id = "num-\(UUID().uuidString)"
        _ = try model.create(TaskRecord(
            id: id, priority: n, title: "x"
        ))
        let read = try XCTUnwrap(model.find(id: id), file: file, line: line)
        XCTAssertEqual(read.priority, n, "number should round-trip unchanged: \(n)", file: file, line: line)
    }

    // MARK: - Stringset edge cases

    func testStringset_singleMember_roundTrips() throws {
        let model = freshCrashTestModel()
        _ = try model.create(CrashTestRecord(
            id: "ss-single", requiredTags: ["only"]
        ))
        let read = try XCTUnwrap(model.find(id: "ss-single"))
        XCTAssertEqual(read.requiredTags, ["only"])
    }

    func testStringset_memberWithEmbeddedQuotes_roundTrips() throws {
        // Stringset members are stored as raw Y.Map keys (no JSON
        // wrapping). Embedded `"` should pass through unchanged —
        // no escape needed, no escape applied.
        let model = freshCrashTestModel()
        let member = #"a "quoted" member"#  // a "quoted" member
        _ = try model.create(CrashTestRecord(
            id: "ss-quote", requiredTags: [member]
        ))
        let read = try XCTUnwrap(model.find(id: "ss-quote"))
        XCTAssertEqual(read.requiredTags, [member],
                       "embedded quotes should round-trip raw — no JSON escape")
    }

    func testStringset_memberWithNewlines_roundTrips() throws {
        let model = freshCrashTestModel()
        let member = "line1\nline2"
        _ = try model.create(CrashTestRecord(
            id: "ss-nl", requiredTags: [member]
        ))
        let read = try XCTUnwrap(model.find(id: "ss-nl"))
        XCTAssertEqual(read.requiredTags, [member])
    }

    func testStringset_memberWithEmoji_roundTrips() throws {
        let model = freshCrashTestModel()
        _ = try model.create(CrashTestRecord(
            id: "ss-emoji", requiredTags: ["🎉🎊"]
        ))
        let read = try XCTUnwrap(model.find(id: "ss-emoji"))
        XCTAssertEqual(read.requiredTags, ["🎉🎊"])
    }

    func testStringset_emptyStringMember_currentBehavior() throws {
        // Empty string as a member: legitimate Set<String> but a
        // weird wire encoding (Y.Map key = ""). Document the actual
        // behavior so callers know what to expect.
        let model = freshCrashTestModel()
        _ = try model.create(CrashTestRecord(
            id: "ss-empty", requiredTags: [""]
        ))
        let read = try XCTUnwrap(model.find(id: "ss-empty"))
        XCTAssertEqual(read.requiredTags, [""],
                       "empty-string member is preserved; if this changes, the runtime " +
                       "started filtering empty members and the docs need an update.")
    }

    func testStringset_veryLargeMember_roundTrips() throws {
        // Stringset has `max_count` enforcement at the field level
        // (tested elsewhere) but no `max_length` per member. Confirm
        // a 10KB member round-trips — on the assumption that y-crdt
        // doesn't truncate or reject.
        let model = freshCrashTestModel()
        let big = String(repeating: "x", count: 10_000)
        _ = try model.create(CrashTestRecord(
            id: "ss-big", requiredTags: [big]
        ))
        let read = try XCTUnwrap(model.find(id: "ss-big"))
        XCTAssertEqual(read.requiredTags, [big])
    }

    func testStringset_manyMembersBelowMaxCount_roundTrip() throws {
        // `tags` has max_count = 5; load right up to the cap and
        // verify all members survive round-trip.
        let model = freshCrashTestModel()
        let members: Set<String> = ["a", "b", "c", "d", "e"]
        _ = try model.create(CrashTestRecord(
            id: "ss-cap", requiredTags: ["t"], tags: members
        ))
        let read = try XCTUnwrap(model.find(id: "ss-cap"))
        XCTAssertEqual(read.tags, members,
                       "all 5 members at the cap should round-trip; \(read.tags ?? [])")
    }

    // MARK: - Helpers

    private func freshCrashTestModel() -> TypedModel<CrashTestRecord> {
        let doc = YDocument()
        SchemaSync.clearCache()
        return TypedModel<CrashTestRecord>(doc: doc)
    }
}
