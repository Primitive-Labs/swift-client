import XCTest
@testable import JsBaoClient
import YSwift

/// `TypedModel<T>` (Helpers/TestOnlyTypedModel.swift) is the test-local typed
/// wrapper the codegen round-trip suites write through. Both of its
/// `findByUnique` overloads guarded on `record["id"] as? String` — a cast from
/// the subscript's `PrimitiveValue?` to `String` that can never succeed — so
/// each returned nil for every input, index hit included (#3314). Nine test
/// files use `TypedModel` and none called these two overloads, which is why a
/// helper that could not work went unnoticed until the warning-free tier
/// reported the cast.
///
/// `PrimitiveRecord` carries its id as a stored `String` property, so the
/// lookup does not need the subscript at all.
final class TestOnlyTypedModelFindByUniqueHermeticTests: XCTestCase {

    // `crashTest` carries both shapes: `email` is `unique: true` (a synthetic
    // single-field constraint) and `name_score_combo` is an explicit compound
    // one over `boundedName` + `score`.
    private func makeModel() -> TypedModel<CrashTestRecord> {
        SchemaSync.clearCache()
        return TypedModel<CrashTestRecord>(doc: YDocument())
    }

    private func alice() -> CrashTestRecord {
        CrashTestRecord(
            id: "c1",
            requiredTags: ["t"],
            email: "alice@example.com",
            boundedName: "alice",
            score: 7
        )
    }

    /// The single-field overload resolves an index hit to the typed record.
    func testFindByUniqueSingleFieldReturnsTheRecord() throws {
        let model = makeModel()
        try model.create(alice())

        let found = try model.findByUnique(
            constraint: "crashTest_email_unique",
            value: .string("alice@example.com")
        )

        XCTAssertEqual(found?.id, "c1")
        XCTAssertEqual(found?.email, "alice@example.com")
    }

    /// The compound overload does too, given the constraint's fields in order.
    func testFindByUniqueCompoundReturnsTheRecord() throws {
        let model = makeModel()
        try model.create(alice())

        let found = try model.findByUnique(
            constraint: "name_score_combo",
            values: [.string("alice"), .number(7)]
        )

        XCTAssertEqual(found?.id, "c1")
        XCTAssertEqual(found?.boundedName, "alice")
    }

    /// An index miss still returns nil: the fix resolves a hit, it does not
    /// turn every lookup into one.
    func testFindByUniqueMissStillReturnsNil() throws {
        let model = makeModel()
        try model.create(alice())

        XCTAssertNil(try model.findByUnique(
            constraint: "crashTest_email_unique",
            value: .string("nobody@example.com")
        ))
        XCTAssertNil(try model.findByUnique(
            constraint: "name_score_combo",
            values: [.string("alice"), .number(8)]
        ))
    }
}
