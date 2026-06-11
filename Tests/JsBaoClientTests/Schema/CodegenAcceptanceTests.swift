import XCTest
@testable import JsBaoClient
import YSwift

/// End-to-end acceptance test for the `swift-bao-codegen` build-tool
/// pipeline.
///
/// Two things are checked here:
///
///  1. **The generated source compiles against `JsBaoClient`.** The
///     fixture's golden output (`CodegenAcceptance/Generated/`) is
///     committed and gets compiled as a regular member of the test
///     target — so if `JsBaoClient`'s public API changes in a way that
///     breaks generated code, this target fails to build.
///
///  2. **The generated `TaskRecord` round-trips through `TypedModel`.**
///     This catches semantic drift: e.g. if the emitter started writing
///     `.string(date)` instead of `.date(date)`, the runtime value would
///     read back wrong on the way out.
///
/// To re-roll the golden file after intentionally changing the emitter:
/// ```
/// swift run swift-bao-codegen \
///   --input  Tests/JsBaoClientTests/Schema/CodegenAcceptance/fixture.toml \
///   --output Tests/JsBaoClientTests/Schema/CodegenAcceptance/Generated
/// ```
final class CodegenAcceptanceTests: XCTestCase {

    func testGeneratedSchemaMatchesHandConstructed() {
        // Field set + flags should match the TOML fixture.
        let s = TaskRecord.primitiveSchema
        XCTAssertEqual(s.name, "tasks")
        XCTAssertEqual(s.fields["title"]?.type, .string)
        XCTAssertEqual(s.fields["title"]?.required, true)
        XCTAssertEqual(s.fields["priority"]?.indexed, true)
        XCTAssertEqual(s.fields["tags"]?.type, .stringset)
        XCTAssertEqual(s.fields["createdAt"]?.type, .date)
        XCTAssertEqual(s.fields["id"]?.type, .id)
    }

    func testRoundTripThroughTypedModel() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = TypedModel<TaskRecord>(doc: doc)

        let original = TaskRecord(
            id: "t1",
            title: "Ship it",
            priority: 3,
            tags: ["urgent", "backend"],
            createdAt: "2026-04-27T00:00:00Z"
        )
        _ = try model.create(original)

        let loaded = try XCTUnwrap(model.find(id: "t1"))
        XCTAssertEqual(loaded.id, "t1")
        XCTAssertEqual(loaded.title, "Ship it")
        XCTAssertEqual(loaded.priority, 3)
        XCTAssertEqual(loaded.tags, ["urgent", "backend"])
        XCTAssertEqual(loaded.createdAt, "2026-04-27T00:00:00Z")
    }

    func testOptionalFieldsAreOmittedFromValues() {
        let task = TaskRecord(id: "t1", title: "minimal")
        let values = task.primitiveValues()
        XCTAssertEqual(values["title"], .string("minimal"))
        // Optional fields not set → not in the dict.
        XCTAssertNil(values["priority"])
        XCTAssertNil(values["tags"])
        XCTAssertNil(values["createdAt"])
        // `id` is intentionally NOT in primitiveValues() — DynamicModel
        // writes it separately on create.
        XCTAssertNil(values["id"])
    }

    // MARK: - Upsert facade (#1053) — through the REAL generated methods

    /// `save(in:upsertOn:)` on the generated facade: insert on no match,
    /// merge (existing id wins, returned record carries it) on match.
    /// Exercises the emitted code itself, not a hand-written mirror.
    func testGeneratedSaveUpsertOnSingleFieldUnique() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        defer { JsBaoClient.clearDefault() }
        SchemaSync.clearCache()
        client.registerModels([CrashTestRecord.self])

        let (doc, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))

        // No match → insert under the struct's id.
        let inserted = try CrashTestRecord(
            id: "c1", requiredTags: ["a"], email: "x@y.z", boundedName: "first"
        ).save(in: doc, upsertOn: "email")
        XCTAssertEqual(inserted.id, "c1")
        XCTAssertEqual(CrashTestRecord.count(), 1)

        // Match → merge into c1; resolved record keeps the existing id
        // and reflects the merged fields. No duplicate row.
        let merged = try CrashTestRecord(
            id: "c2", requiredTags: ["a"], email: "x@y.z", boundedName: "second"
        ).save(in: doc, upsertOn: "email")
        XCTAssertEqual(merged.id, "c1", "merge must resolve to the existing record's id")
        XCTAssertEqual(merged.boundedName, "second")
        XCTAssertEqual(CrashTestRecord.count(), 1, "upsertOn must merge, not duplicate")
        // #992 made the generated `find` async-throws, so the merge-side
        // assertion can't live in an autoclosure — await it first.
        let mergedAway = try await CrashTestRecord.find("c2")
        XCTAssertNil(mergedAway)

        // upsertOn against a field with no single-field unique constraint
        // throws (boundedName is only part of the compound constraint).
        XCTAssertThrowsError(
            try CrashTestRecord(
                id: "c3", requiredTags: ["a"], boundedName: "second"
            ).save(in: doc, upsertOn: "boundedName")
        ) { error in
            XCTAssertEqual(error as? UpsertError,
                           .noSingleFieldUniqueConstraint(field: "boundedName"))
        }
    }

    /// `upsertByUnique(_:mode:in:)` on the generated facade with the
    /// COMPOUND constraint `name_score_combo` (boundedName, score) — the
    /// part `save(in:upsertOn:)` can't reach.
    func testGeneratedUpsertByUniqueCompoundConstraint() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        defer { JsBaoClient.clearDefault() }
        SchemaSync.clearCache()
        client.registerModels([CrashTestRecord.self])

        let (doc, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))

        // Insert (no match on the compound key).
        let inserted = try CrashTestRecord(
            id: "k1", requiredTags: ["a"], boundedName: "ada", score: 100
        ).upsertByUnique("name_score_combo", in: doc)
        XCTAssertEqual(inserted.id, "k1")

        // Same (boundedName, score) pair → merge, existing id wins.
        let merged = try CrashTestRecord(
            id: "k2", requiredTags: ["a", "b"], boundedName: "ada", score: 100, active: false
        ).upsertByUnique("name_score_combo", in: doc)
        XCTAssertEqual(merged.id, "k1")
        XCTAssertEqual(merged.active, false)
        XCTAssertEqual(CrashTestRecord.count(), 1)

        // Different score → different compound key → second record.
        let other = try CrashTestRecord(
            id: "k3", requiredTags: ["a"], boundedName: "ada", score: 200
        ).upsertByUnique("name_score_combo", in: doc)
        XCTAssertEqual(other.id, "k3")
        XCTAssertEqual(CrashTestRecord.count(), 2)

        // A record missing a constraint field can't build the lookup key.
        XCTAssertThrowsError(
            try CrashTestRecord(id: "k4", requiredTags: ["a"], boundedName: "ada")
                .upsertByUnique("name_score_combo", in: doc)
        ) { error in
            XCTAssertEqual(error as? UpsertByUniqueError,
                           .missingConstraintField(field: "score"))
        }
    }
}
