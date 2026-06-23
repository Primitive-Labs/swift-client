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

        // #1122: a DIFFERENT *explicit* id (designated init) colliding on
        // the unique field is now a hard conflict, mirroring js-bao's
        // `_constructorProvidedId && this.id !== existingId` guard.
        XCTAssertThrowsError(
            try CrashTestRecord(
                id: "c2", requiredTags: ["a"], email: "x@y.z", boundedName: "second"
            ).save(in: doc, upsertOn: "email")
        ) { error in
            XCTAssertEqual(error as? UpsertError,
                           .explicitIdConflict(supplied: "c2", existing: "c1"))
        }
        XCTAssertEqual(CrashTestRecord.count(), 1, "conflict must not insert a row")

        // Match with an AUTO-generated id (the id-less convenience init) →
        // silent merge into c1; resolved record keeps the existing id and
        // reflects the merged fields. No duplicate row. (js-bao auto-id
        // parity — a fresh id is discarded on merge.)
        let merged = try CrashTestRecord(
            requiredTags: ["a"], email: "x@y.z", boundedName: "second"
        ).save(in: doc, upsertOn: "email")
        XCTAssertEqual(merged.id, "c1", "merge must resolve to the existing record's id")
        XCTAssertEqual(merged.boundedName, "second")
        XCTAssertEqual(CrashTestRecord.count(), 1, "upsertOn must merge, not duplicate")

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

        // #1122: same compound key + a DIFFERENT *explicit* id is a hard
        // conflict (js-bao `_constructorProvidedId` parity).
        XCTAssertThrowsError(
            try CrashTestRecord(
                id: "k2", requiredTags: ["a", "b"], boundedName: "ada", score: 100, active: false
            ).upsertByUnique("name_score_combo", in: doc)
        ) { error in
            XCTAssertEqual(error as? UpsertError,
                           .explicitIdConflict(supplied: "k2", existing: "k1"))
        }

        // Same (boundedName, score) pair with an AUTO id → silent merge,
        // existing id wins.
        let merged = try CrashTestRecord(
            requiredTags: ["a", "b"], boundedName: "ada", score: 100, active: false
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

    // MARK: - Relationship instance accessors (#1151) — through the REAL generated methods
    //
    // The generated value-type structs expose idiomatic INSTANCE accessors
    // that auto-resolve the related model — `try await rel.task()` (refersTo),
    // `try await profile.profile()` (hasMany), `try await rel.viaJoin()`
    // (hasManyThrough) — mirroring the JS client's instance methods. These
    // exercise the emitted code itself against a live cross-document store.

    /// `refersTo`: the generated `RelTestRecord.task()` resolves the
    /// `TaskRecord` its `taskId` points at, and returns `nil` when the FK
    /// is unset / dangling.
    func testGeneratedRefersToInstanceAccessor() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        defer { JsBaoClient.clearDefault() }
        SchemaSync.clearCache()
        client.registerModels([RelTestRecord.self, TaskRecord.self])

        let (doc, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))

        _ = try TaskRecord(id: "task1", title: "Write tests").save(in: doc)
        _ = try RelTestRecord(id: "r1", taskId: "task1").save(in: doc)
        _ = try RelTestRecord(id: "r2").save(in: doc)                       // FK unset
        _ = try RelTestRecord(id: "r3", taskId: "missing").save(in: doc)    // FK dangling

        let r1Found = try await RelTestRecord.find("r1")
        let r1 = try XCTUnwrap(r1Found)
        let resolved = try await r1.task()
        XCTAssertEqual(resolved?.id, "task1")
        XCTAssertEqual(resolved?.title, "Write tests")

        let r2Found = try await RelTestRecord.find("r2")
        let r2 = try XCTUnwrap(r2Found)
        let none = try await r2.task()
        XCTAssertNil(none, "unset foreign key resolves to nil")

        let r3Found = try await RelTestRecord.find("r3")
        let r3 = try XCTUnwrap(r3Found)
        let dangling = try await r3.task()
        XCTAssertNil(dangling, "dangling foreign key resolves to nil")
    }

    /// `hasMany`: the generated `UserProfileRecord` records whose `ownerId`
    /// points back at a `relTest`-side record. (`relTest.profile` is a
    /// hasMany onto `user_profile` keyed on `ownerId`, ordered by
    /// `displayName asc`.) Verifies membership + declared ordering.
    func testGeneratedHasManyInstanceAccessor() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        defer { JsBaoClient.clearDefault() }
        SchemaSync.clearCache()
        client.registerModels([RelTestRecord.self, UserProfileRecord.self])

        let (doc, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))

        _ = try RelTestRecord(id: "owner1").save(in: doc)
        // Insert out of display order to prove the order_by_field sort applies.
        _ = try UserProfileRecord(id: "p1", displayName: "Charlie", ownerId: "owner1").save(in: doc)
        _ = try UserProfileRecord(id: "p2", displayName: "Alice", ownerId: "owner1").save(in: doc)
        _ = try UserProfileRecord(id: "p3", displayName: "Bob", ownerId: "owner1").save(in: doc)
        _ = try UserProfileRecord(id: "p4", displayName: "Zoe", ownerId: "other").save(in: doc)

        let ownerFound = try await RelTestRecord.find("owner1")
        let owner = try XCTUnwrap(ownerFound)
        let profiles = try await owner.profile()
        XCTAssertEqual(
            profiles.map(\.displayName), ["Alice", "Bob", "Charlie"],
            "hasMany must return only matching records, sorted by displayName asc"
        )
    }

    /// `hasManyThrough`: `relTest.viaJoin` reaches `user_profile` through
    /// the `barebones` join model (join_model_local_field = id,
    /// join_model_related_field = id). With both ids being the join row's
    /// own id, a barebones row `b1` links `relTest(b1)` → `user_profile(b1)`.
    func testGeneratedHasManyThroughInstanceAccessor() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        defer { JsBaoClient.clearDefault() }
        SchemaSync.clearCache()
        client.registerModels([
            RelTestRecord.self, UserProfileRecord.self, BareBonesRecord.self,
        ])

        let (doc, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))

        // local id == related id == join row id, so the source record must
        // share the join row's id to be linked through it.
        _ = try RelTestRecord(id: "j1").save(in: doc)
        _ = try BareBonesRecord(id: "j1").save(in: doc)
        _ = try UserProfileRecord(id: "j1", displayName: "Linked").save(in: doc)

        let sourceFound = try await RelTestRecord.find("j1")
        let source = try XCTUnwrap(sourceFound)
        let linked = try await source.viaJoin()
        XCTAssertEqual(linked.map(\.id), ["j1"])
        XCTAssertEqual(linked.first?.displayName, "Linked")
    }
}
