import XCTest
@testable import JsBaoClient
import YSwift

/// Stress-tests `swift-bao-codegen`'s emitter and the runtime layer's
/// enforcement of every TOML knob the emitter writes into a generated
/// `PrimitiveSchema` literal.
///
/// Models live in `CodegenAcceptance/fixture.toml` (alongside the
/// existing TaskRecord acceptance test). Generated source is committed
/// at `CodegenAcceptance/Generated/` and compiled into this target
/// directly — no plugin attached. Re-roll after an emitter change with:
///
/// ```sh
/// swift run swift-bao-codegen \
///   --input  Tests/JsBaoClientTests/Schema/CodegenAcceptance/fixture.toml \
///   --output Tests/JsBaoClientTests/Schema/CodegenAcceptance/Generated
/// ```
///
/// Sections:
///   - "literal" tests assert what the codegen wrote into static schemas
///   - "round-trip" tests write through `TypedModel<T>` and read back
///   - "enforcement" tests call into validators and unique-constraint
///     paths to confirm the runtime honors what the codegen declared
///   - "runtime" tests are smoke checks for filter / sort / aggregate
///     behavior using gauntlet records as fixtures
final class CodegenGauntletTests: XCTestCase {

    // MARK: - Static schema literal sanity

    func testCrashTestSchemaLiteral() {
        let s = CrashTestRecord.primitiveSchema
        XCTAssertEqual(s.name, "crashTest")

        // Field types
        XCTAssertEqual(s.fields["id"]?.type,           .id)
        XCTAssertEqual(s.fields["tags"]?.type,         .stringset)
        XCTAssertEqual(s.fields["requiredTags"]?.type, .stringset)
        XCTAssertEqual(s.fields["email"]?.type,        .string)
        XCTAssertEqual(s.fields["boundedName"]?.type,  .string)
        XCTAssertEqual(s.fields["default"]?.type,      .string)
        XCTAssertEqual(s.fields["where"]?.type,        .string)
        XCTAssertEqual(s.fields["score"]?.type,        .number)
        XCTAssertEqual(s.fields["active"]?.type,       .boolean)

        // Modifiers
        XCTAssertEqual(s.fields["requiredTags"]?.required, true)
        XCTAssertEqual(s.fields["email"]?.unique,          true)
        XCTAssertEqual(s.fields["boundedName"]?.maxLength, 20)
        XCTAssertEqual(s.fields["tags"]?.maxCount,         5)
        XCTAssertEqual(s.fields["score"]?.indexed,         true)

        // Defaults
        XCTAssertEqual(s.fields["default"]?.default, .scalar(.string("fallback")))
        XCTAssertEqual(s.fields["score"]?.default,   .scalar(.number(100)))
        XCTAssertEqual(s.fields["active"]?.default,  .scalar(.boolean(true)))

        // Compound unique on (boundedName, score)
        let combo = s.constraints["name_score_combo"]
        XCTAssertEqual(combo?.fields, ["boundedName", "score"])
    }

    func testRelTestRelationshipsLiteral() {
        let rels = RelTestRecord.primitiveSchema.relationships
        XCTAssertEqual(rels["task"]?.type,    "refersTo")
        XCTAssertEqual(rels["profile"]?.type, "hasMany")
        XCTAssertEqual(rels["viaJoin"]?.type, "hasManyThrough")

        // refersTo carries `relatedIdField`.
        XCTAssertEqual(rels["task"]?.properties["relatedIdField"], "taskId")

        // hasMany carries the optional ordering keys.
        XCTAssertEqual(rels["profile"]?.properties["orderByField"],   "displayName")
        XCTAssertEqual(rels["profile"]?.properties["orderDirection"], "asc")

        // hasManyThrough carries the join_model triple.
        XCTAssertEqual(rels["viaJoin"]?.properties["joinModel"],            "barebones")
        XCTAssertEqual(rels["viaJoin"]?.properties["joinModelLocalField"],  "id")
        XCTAssertEqual(rels["viaJoin"]?.properties["joinModelRelatedField"], "id")
    }

    func testSnakeCaseModelNameMapsToPascalCaseSwiftType() {
        // Default codegen rule: `user_profile` → `UserProfileRecord`.
        // The literal token below is the proof — this file would not
        // compile if the codegen had named it differently.
        XCTAssertEqual(UserProfileRecord.modelName, "user_profile")
    }

    func testEmptyFieldsModel_primitiveValuesIsEmpty() {
        let v = BareBonesRecord(id: "x").primitiveValues()
        XCTAssertTrue(v.isEmpty, "expected [:], got \(v)")
    }

    func testReservedKeywordFields_usableAsProperties() {
        // Property reads need backticks (compiler enforces this — the
        // codegen escapes them at the declaration site for the same
        // reason). Both lookups must compile and round-trip the value.
        let r = CrashTestRecord(
            id: "x",
            requiredTags: ["t"],
            default: "via init",     // labels don't need backticks
            where: "kitchen"
        )
        XCTAssertEqual(r.`default`, "via init")
        XCTAssertEqual(r.`where`,   "kitchen")
    }

    // MARK: - Round-trips through TypedModel

    func testStringsetRoundTrip_requiredAndOptional() throws {
        let model = freshCrashTestModel()
        try model.create(CrashTestRecord(
            id: "s1",
            tags: ["x", "y", "z"],
            requiredTags: ["alpha", "beta"]
        ))
        let read = try XCTUnwrap(model.find(id: "s1"))
        XCTAssertEqual(read.requiredTags, ["alpha", "beta"])
        XCTAssertEqual(read.tags,         ["x", "y", "z"])
    }

    func testStringsetRoundTrip_emptySetReadsBackEmptyOrNil() throws {
        let model = freshCrashTestModel()
        try model.create(CrashTestRecord(
            id: "empty",
            tags: [],
            requiredTags: []
        ))
        let read = try XCTUnwrap(model.find(id: "empty"))
        // Empty stringsets read back as either an empty Set or nil
        // depending on the storage path. Either is fine — what we
        // care about is no spurious membership.
        XCTAssertTrue(read.requiredTags.isEmpty,
                      "requiredTags should be empty, got \(read.requiredTags)")
        XCTAssertTrue((read.tags ?? []).isEmpty,
                      "tags should be empty, got \(read.tags ?? [])")
    }

    func testInitRowFromDynamicQuery_includingStringset() throws {
        // `init?(record:)` is exercised by every `.find` / `.findAll`
        // call above. The codegen also emits a separate `init?(row:)`
        // for the SQLite-backed `dynamic.query` path — that's what
        // real demo pages use to feed `BaoDataLoader`. Stringsets are
        // the spicy bit: the query engine writes stringset columns
        // back into the row dict as `[String]` (Swift array), not as
        // `Set<String>`, so a direct `as? Set<String>` cast in the
        // codegen would silently drop every row.
        let model = freshCrashTestModel()
        try model.create(CrashTestRecord(
            id: "row1",
            requiredTags: ["alpha", "beta"],
            email: "row@e.com",
            boundedName: "row-test",
            score: 7
        ))
        let rows = model.dynamic.query(["id": "row1"])
        let typed = rows.compactMap(CrashTestRecord.init(row:))
        XCTAssertEqual(typed.count, 1,
                       "compactMap dropped the row — init?(row:) returned nil")
        let first = try XCTUnwrap(typed.first)
        XCTAssertEqual(first.boundedName,  "row-test")
        XCTAssertEqual(first.email,        "row@e.com")
        XCTAssertEqual(first.score,        7)
        XCTAssertEqual(first.requiredTags, ["alpha", "beta"])
    }

    func testInitRowFromDynamicQuery_booleanRoundTrip() throws {
        // Booleans are stored as SQLite INTEGER and read back as
        // `Int` (0/1) by `BaoModelQueryEngine.executeQuery`, so a
        // direct `as? Bool` cast in the codegen would silently drop
        // every bool. The emitter falls back through `as? Int`.
        let model = freshCrashTestModel()
        try model.create(CrashTestRecord(
            id: "boolT",
            requiredTags: ["t"],
            active: true
        ))
        try model.create(CrashTestRecord(
            id: "boolF",
            requiredTags: ["t"],
            active: false
        ))
        let rows = model.dynamic.query(nil, options: QueryOptions(sort: ["id": 1]))
        let typed = rows.compactMap(CrashTestRecord.init(row:))
        XCTAssertEqual(typed.count, 2,
                       "init?(row:) dropped a boolean row")
        let byId = Dictionary(uniqueKeysWithValues: typed.map { ($0.id, $0) })
        XCTAssertEqual(byId["boolT"]?.active, true,
                       "active should round-trip true, got \(String(describing: byId["boolT"]?.active))")
        XCTAssertEqual(byId["boolF"]?.active, false,
                       "active should round-trip false, got \(String(describing: byId["boolF"]?.active))")
    }

    func testReservedKeywordFields_roundTripThroughDoc() throws {
        let model = freshCrashTestModel()
        try model.create(CrashTestRecord(
            id: "kw1",
            requiredTags: ["t"],
            default: "explicit",
            where: "kitchen"
        ))
        let read = try XCTUnwrap(model.find(id: "kw1"))
        XCTAssertEqual(read.`default`, "explicit")
        XCTAssertEqual(read.`where`,   "kitchen")
    }

    func testInitFailsWhenRequiredFieldMissing_returnsNil() throws {
        // The runtime's `requiredFieldMissing` validator fires on
        // `create`, so we can't write a record that's missing a
        // required field directly. Instead: write a valid record,
        // then *clear* the required field via the PrimitiveRecord
        // subscript (which routes to `clearField`, no validation).
        // After that, the typed `find` should degrade to nil while
        // the dynamic record stays readable — the exact failure mode
        // a schema-evolution drift would produce in the wild.
        let model = freshCrashTestModel()
        try model.create(CrashTestRecord(
            id: "orphan",
            requiredTags: ["t"]
        ))
        let raw = try XCTUnwrap(model.dynamic.find(id: "orphan"))
        raw["requiredTags"] = nil

        XCTAssertNil(model.find(id: "orphan"),
                     "typed find should fail on missing required field")
        XCTAssertNotNil(model.dynamic.find(id: "orphan"),
                        "dynamic record must still be readable")
    }

    // MARK: - Validation & uniqueness enforcement

    func testStringsetMaxCountEnforced() throws {
        // `tags` (the optional stringset) is the field that carries
        // `max_count = 5`. `requiredTags` has no max — putting six
        // items there is fine.
        let model = freshCrashTestModel()
        XCTAssertThrowsError(
            try model.create(CrashTestRecord(
                id: "over",
                tags: ["a", "b", "c", "d", "e", "f"],   // 6 > max 5
                requiredTags: ["t"]
            ))
        ) { error in
            guard let e = error as? FieldValidationError else {
                return XCTFail("expected FieldValidationError, got \(error)")
            }
            if case .stringsetMaxCountExceeded = e { return }
            XCTFail("expected .stringsetMaxCountExceeded, got \(e)")
        }
    }

    func testSingleFieldUniqueViolation_email() throws {
        let model = freshCrashTestModel()
        try model.create(CrashTestRecord(
            id: "u1",
            requiredTags: ["t"],
            email: "dup@example.com"
        ))
        XCTAssertThrowsError(
            try model.create(CrashTestRecord(
                id: "u2",
                requiredTags: ["t"],
                email: "dup@example.com"
            ))
        ) { error in
            XCTAssertTrue(error is UniqueConstraintViolationError,
                          "expected UniqueConstraintViolationError, got \(error)")
        }
    }

    func testCompoundUniqueViolation_boundedNameAndScore() throws {
        let model = freshCrashTestModel()
        try model.create(CrashTestRecord(
            id: "c1",
            requiredTags: ["t"],            // single-field unique on email
            email: "u1@example.com",       // distinct emails — proves the
            boundedName: "shared",          // is not what's firing.
            score: 42
        ))
        XCTAssertThrowsError(
            try model.create(CrashTestRecord(
                id: "c2",
                requiredTags: ["t"],
                email: "u2@example.com",
                boundedName: "shared",
                score: 42
            ))
        ) { error in
            XCTAssertTrue(error is UniqueConstraintViolationError,
                          "expected UniqueConstraintViolationError, got \(error)")
        }
    }

    // MARK: - Runtime smoke (filter / sort / aggregate / pagination)

    func testFilterGteOnIndexedScore() throws {
        let model = freshCrashTestModel()
        try model.create(CrashTestRecord(
            id: "high", requiredTags: ["t"], email: "h@e.com", score: 90
        ))
        try model.create(CrashTestRecord(
            id: "low",  requiredTags: ["t"], email: "l@e.com", score: 10
        ))
        let rows = model.dynamic.query(["score": ["$gte": 50]])
        let ids = Set(rows.compactMap { $0["id"] as? String })
        XCTAssertTrue(ids.contains("high"))
        XCTAssertFalse(ids.contains("low"))
    }

    func testFilterOrAndContainsText() throws {
        let model = freshCrashTestModel()
        try model.create(CrashTestRecord(
            id: "a",
            requiredTags: ["t"],
            email: "a@e.com",
            boundedName: "Alpha widget"
        ))
        try model.create(CrashTestRecord(
            id: "b",
            requiredTags: ["t"],
            email: "b@e.com",
            boundedName: "Beta gadget"
        ))
        try model.create(CrashTestRecord(
            id: "c",
            requiredTags: ["t"],
            email: "c@e.com",
            boundedName: "Gamma thing",
            score: 999
        ))
        let rows = model.dynamic.query([
            "$or": [
                ["boundedName": ["$containsText": "widget"]],
                ["score": ["$gte": 500]],
            ]
        ])
        let ids = Set(rows.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, ["a", "c"])
    }

    func testMultiFieldSortOrder() throws {
        let model = freshCrashTestModel()
        // Score 50 ties intentionally — sortOrder's secondary key
        // (id ASC) breaks the tie.
        for (i, score) in [50.0, 10.0, 50.0].enumerated() {
            try model.create(CrashTestRecord(
                id: "s\(i)",
                requiredTags: ["t"],
                email: "s\(i)@e.com",
                score: score
            ))
        }
        let sorted = model.dynamic.query(nil, options: QueryOptions(
            sortOrder: [("score", -1), ("id", 1)],
            limit: 1000
        ))
        let topScore = sorted.first?["score"] as? Double
        XCTAssertEqual(topScore, 50)
    }

    func testAggregateCountByActiveGroup() throws {
        let model = freshCrashTestModel()
        for i in 0..<3 {
            try model.create(CrashTestRecord(
                id: "t\(i)",
                requiredTags: ["t"],
                email: "t\(i)@e.com",
                active: true
            ))
        }
        for i in 0..<2 {
            try model.create(CrashTestRecord(
                id: "f\(i)",
                requiredTags: ["t"],
                email: "f\(i)@e.com",
                active: false
            ))
        }

        let groups = model.dynamic.aggregate(AggregateOptions(
            groupBy: ["active"],
            operations: [AggregateOperation(type: .count, outputField: "n")]
        ))

        // SQLite hands booleans back as 0/1 ints (storage class
        // INTEGER) — group-by row values reflect that. Normalize
        // either form into a Bool key so the assertions don't
        // depend on the storage encoding.
        var counts: [Bool: Int] = [:]
        for row in groups {
            let active: Bool?
            if let b = row["active"] as? Bool {
                active = b
            } else if let i = row["active"] as? Int {
                active = (i != 0)
            } else {
                active = nil
            }
            if let active, let n = row["n"] as? Int {
                counts[active] = n
            }
        }
        XCTAssertEqual(counts[true],  3)
        XCTAssertEqual(counts[false], 2)
    }

    func testCursorPagination_returnsNextCursor() throws {
        let model = freshCrashTestModel()
        for i in 0..<8 {
            try model.create(CrashTestRecord(
                id: "p\(i)",
                requiredTags: ["t"],
                email: "p\(i)@e.com",
                score: Double(i)
            ))
        }
        let page = try model.dynamic.queryPaged(
            nil,
            options: QueryOptions(
                sortOrder: [("score", 1)],
                limit: 3
            )
        )
        XCTAssertEqual(page.data.count, 3)
        XCTAssertNotNil(page.nextCursor, "expected nextCursor on page 1")
    }

    // MARK: - Other coverage

    func testEmptyFieldsModel_typedCRUD() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = TypedModel<BareBonesRecord>(doc: doc)
        _ = try model.create(BareBonesRecord(id: "b1"))
        _ = try model.create(BareBonesRecord(id: "b2"))
        XCTAssertEqual(model.findAll().count, 2)
    }

    func testRelTestRecord_typedCRUD() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = TypedModel<RelTestRecord>(doc: doc)
        try model.create(RelTestRecord(
            id: "r1",
            taskId: "t-1",
            profileId: "p-1"
        ))
        let read = try XCTUnwrap(model.find(id: "r1"))
        XCTAssertEqual(read.profileId, "p-1")
        XCTAssertEqual(read.taskId,    "t-1")
    }

    // MARK: - Relationship traversal driven by codegen-emitted schemas
    //
    // `testRelTestRelationshipsLiteral` above pins the schema literal —
    // proves the emitter wrote the right relationship metadata. These
    // tests close the loop end-to-end: codegen-emitted metadata flows
    // into the runtime resolvers (`refersTo` / `hasMany` /
    // `hasManyThrough`) on `PrimitiveRecord`, with no hand-built
    // schema in between. If the emitter ever drops a property or
    // renames a key, `RelationshipResolution`'s lookup will fall over
    // and these tests fail.
    //
    // We use four codegen-emitted models: RelTestRecord (parent),
    // TaskRecord (refersTo target), UserProfileRecord (hasMany +
    // hasManyThrough target), BareBonesRecord (join model). All four
    // come from the same fixture.toml.

    /// `refersTo` — relTest holds a `taskId` FK pointing at a tasks
    /// record. End-to-end: codegen-emitted RelTestRecord schema
    /// declares the `task` relationship; resolver reads
    /// `relatedIdField = "taskId"` from it; finds the matching
    /// TaskRecord.
    func testCodegenRefersTo_resolvesViaEmittedRelatedIdField() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let relTests = TypedModel<RelTestRecord>(doc: doc)
        let tasks    = TypedModel<TaskRecord>(doc: doc)

        try tasks.create(TaskRecord(id: "t-1", title: "ship the codegen"))
        try relTests.create(RelTestRecord(id: "r1", taskId: "t-1"))

        let r1 = try XCTUnwrap(relTests.dynamic.find(id: "r1"))
        let taskRecord = try XCTUnwrap(
            r1.refersTo(relationship: "task", target: tasks.dynamic)
        )

        // Convert through the codegen-emitted typed initializer so we
        // know the emitted `init?(record:)` accepts what
        // RelationshipResolution returned.
        let typedTask = try XCTUnwrap(TaskRecord(record: taskRecord))
        XCTAssertEqual(typedTask.id, "t-1")
        XCTAssertEqual(typedTask.title, "ship the codegen")
    }

    /// `refersTo` returns nil when the FK doesn't point anywhere —
    /// pinning the missing-target branch of the resolver against a
    /// codegen-emitted relationship.
    func testCodegenRefersTo_nilWhenForeignKeyTargetMissing() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let relTests = TypedModel<RelTestRecord>(doc: doc)
        let tasks    = TypedModel<TaskRecord>(doc: doc)
        // Materialize the tasks model in the doc so DynamicModel.find
        // has a root map to look in. Otherwise `find` is trivially nil
        // for reasons unrelated to the relationship.
        try tasks.create(TaskRecord(id: "decoy", title: "exists, but not the FK"))

        try relTests.create(RelTestRecord(id: "r1", taskId: "ghost"))
        let r1 = try XCTUnwrap(relTests.dynamic.find(id: "r1"))
        XCTAssertNil(try r1.refersTo(relationship: "task", target: tasks.dynamic))
    }

    /// `hasMany` — relTest's `profile` relationship points at
    /// user_profile records whose `ownerId` matches relTest.id, sorted
    /// by `displayName` ascending. End-to-end: codegen emits
    /// `relatedIdField = "ownerId"` and the orderBy/orderDirection
    /// pair; resolver reads them; result is filtered + sorted.
    func testCodegenHasMany_resolvesViaEmittedRelatedIdField_andOrders() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let relTests = TypedModel<RelTestRecord>(doc: doc)
        let profiles = TypedModel<UserProfileRecord>(doc: doc)

        try relTests.create(RelTestRecord(id: "r1"))
        try relTests.create(RelTestRecord(id: "r2"))
        // Two profiles owned by r1, one by r2. displayName chosen so
        // the asc-sort assertion below is meaningful.
        try profiles.create(UserProfileRecord(
            id: "p-charlie", displayName: "Charlie", ownerId: "r1"
        ))
        try profiles.create(UserProfileRecord(
            id: "p-alice", displayName: "Alice", ownerId: "r1"
        ))
        try profiles.create(UserProfileRecord(
            id: "p-other", displayName: "Other", ownerId: "r2"
        ))

        let r1 = try XCTUnwrap(relTests.dynamic.find(id: "r1"))
        let rows = try r1.hasMany(
            relationship: "profile", target: profiles.dynamic
        )
        let typed = rows.compactMap(UserProfileRecord.init(record:))

        // Filtering: only r1's profiles, not r2's.
        XCTAssertEqual(typed.map(\.id), ["p-alice", "p-charlie"],
                       "hasMany should filter by ownerId == r1.id")
        // Ordering: codegen emitted orderByField=displayName,
        // orderDirection=asc — Alice before Charlie.
        XCTAssertEqual(typed.map(\.displayName), ["Alice", "Charlie"],
                       "hasMany should respect emitted orderByField+orderDirection")
    }

    /// `hasManyThrough` — relTest reaches user_profile via a barebones
    /// join model. The fixture's join uses `id`=`id` for both join
    /// fields, so the row layout is contrived (matching ids across the
    /// three models); the point is that the resolver reads
    /// `joinModel`, `joinModelLocalField`, and `joinModelRelatedField`
    /// off the codegen-emitted descriptor and walks through.
    func testCodegenHasManyThrough_walksJoinModel() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let relTests = TypedModel<RelTestRecord>(doc: doc)
        let profiles = TypedModel<UserProfileRecord>(doc: doc)
        let join     = TypedModel<BareBonesRecord>(doc: doc)

        try relTests.create(RelTestRecord(id: "r1"))
        // Join row whose `id` matches r1.id (joinModelLocalField =
        // "id") and points at a user_profile by `id`
        // (joinModelRelatedField = "id").
        try join.create(BareBonesRecord(id: "r1"))
        // Target the join row points at — also via id-equals-id since
        // the fixture uses that contrived shape. Plus a decoy that
        // shouldn't appear.
        try profiles.create(UserProfileRecord(id: "r1", displayName: "Joined"))
        try profiles.create(UserProfileRecord(id: "decoy", displayName: "Skip"))

        let r1 = try XCTUnwrap(relTests.dynamic.find(id: "r1"))
        let rows = try r1.hasManyThrough(
            relationship: "viaJoin",
            joinModel: join.dynamic,
            target: profiles.dynamic
        )
        let typed = rows.compactMap(UserProfileRecord.init(record:))
        XCTAssertEqual(typed.map(\.id), ["r1"],
                       "hasManyThrough should walk join model and resolve target by id")
        XCTAssertEqual(typed.first?.displayName, "Joined")
    }

    /// Calling the wrong-typed accessor on a codegen-emitted
    /// relationship surfaces `RelationshipError.wrongType` —
    /// confirms the emitted `type` key is what the resolver checks
    /// against, not some adjacent metadata.
    func testCodegenRelationship_wrongTypeAccessorThrows() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let relTests = TypedModel<RelTestRecord>(doc: doc)
        let tasks    = TypedModel<TaskRecord>(doc: doc)
        try tasks.create(TaskRecord(id: "t-1", title: "x"))
        try relTests.create(RelTestRecord(id: "r1", taskId: "t-1"))
        let r1 = try XCTUnwrap(relTests.dynamic.find(id: "r1"))

        // `task` is a refersTo, not a hasMany — calling `hasMany`
        // should throw wrongType.
        XCTAssertThrowsError(
            try r1.hasMany(relationship: "task", target: tasks.dynamic)
        ) { error in
            guard case let RelationshipError.wrongType(name, expected, got) =
                    error else {
                return XCTFail("expected wrongType, got \(error)")
            }
            XCTAssertEqual(name, "task")
            XCTAssertEqual(expected, "hasMany")
            XCTAssertEqual(got, "refersTo")
        }
    }

    // MARK: - Codegen-emitted conformances (Equatable / Hashable / Codable)
    //
    // Codegen emits `: PrimitiveModel, Equatable, Hashable, Codable`
    // directly on the generated struct so Swift's compiler synthesizes
    // `==`, `hash(into:)`, and `init(from:)` / `encode(to:)` in the
    // same file as the type. (Synthesis only fires same-file —
    // exactly why codegen does it instead of leaving callers to
    // hand-roll ~80 lines of mechanical boilerplate per model.)
    // See docs/codegen.md → "Conformances are auto-emitted".

    func testEquatable_isAutoSynthesizedOnGeneratedStruct() {
        let a = CrashTestRecord(id: "x", requiredTags: ["t"])
        let b = CrashTestRecord(id: "x", requiredTags: ["t"])
        let c = CrashTestRecord(id: "y", requiredTags: ["t"])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testHashable_letsGeneratedStructsLiveInASet() {
        // Hashable conformance lets generated structs go in `Set`s
        // and `Dictionary` keys — common ask for de-duplication.
        let a = CrashTestRecord(id: "x", requiredTags: ["t"])
        let aDup = CrashTestRecord(id: "x", requiredTags: ["t"])
        let b = CrashTestRecord(id: "y", requiredTags: ["t"])
        let set: Set<CrashTestRecord> = [a, aDup, b]
        XCTAssertEqual(set.count, 2, "expected `a` and `aDup` to dedupe")
    }

    func testCodable_jsonRoundTripsIncludingReservedKeywordFields() throws {
        // CodingKeys synthesis handles backtick-escaped property names
        // (`default`, `where`) automatically when the conformance is
        // in the same file as the type — which is true for codegen
        // output. This test exercises both the standard fields and
        // the two reserved-keyword fields end-to-end.
        let original = CrashTestRecord(
            id: "c1",
            tags: ["x", "y"],
            requiredTags: ["alpha", "beta"],
            email: "c@e.com",
            boundedName: "name",
            default: "fallback-set",   // reserved-keyword field
            where: "kitchen",          // reserved-keyword field
            score: 9.5,
            active: true
        )
        let json = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CrashTestRecord.self, from: json)
        XCTAssertEqual(decoded, original,
                       "JSON round-trip should preserve every field, including backticked ones")
    }

    // MARK: - Helpers as free functions (recommended over extensions)
    //
    // docs/codegen.md → "Adding helpers (free functions)" recommends
    // helpers as free functions rather than Swift extensions on the
    // codegen-emitted struct, matching how the TS codegen handles
    // user-added behavior. These tests pin a few representative
    // helper shapes from the fixture's `Helpers.swift`.

    func testHelper_computedDisplayTitle() {
        let withName = CrashTestRecord(id: "x", requiredTags: [], boundedName: "shiny")
        XCTAssertEqual(displayTitle(withName), "SHINY")
        let noName = CrashTestRecord(id: "fallback-id", requiredTags: [])
        XCTAssertEqual(displayTitle(noName), "(fallback-id)")
    }

    func testHelper_factoryStylePlaceholder() {
        // Free function in place of a "convenience init" extension.
        // Funnels into the codegen designated init.
        let r = placeholderCrashTestRecord(named: "taco")
        XCTAssertEqual(r.id,          "placeholder-taco")
        XCTAssertEqual(r.boundedName, "taco")
        XCTAssertEqual(r.requiredTags, ["placeholder"])
    }

    func testHelper_genericOverPrimitiveModel() {
        // `describeAnyPrimitive<M: PrimitiveModel>` operates on the
        // protocol's static + instance requirements. Compiles against
        // a generated struct exactly because codegen emits both.
        let crash = CrashTestRecord(id: "kk", requiredTags: [])
        let task  = TaskRecord(id: "tt", title: "x")
        XCTAssertEqual(describeAnyPrimitive(crash), "crashTest#kk")
        XCTAssertEqual(describeAnyPrimitive(task),  "tasks#tt")
    }

    func testHelpersFile_lacksBannerSoCodegenSweepDoesntDeleteIt() throws {
        // Codegen's sweep at `swift-bao-codegen/main.swift:165-178`
        // only deletes files in the output dir whose first line is
        // the `// Generated by swift-bao-codegen` banner. The
        // recommended shape — free-function helpers in a sibling
        // file — must NOT carry that banner. This test guards the
        // contract by reading `Helpers.swift` and asserting its
        // first line doesn't start with the codegen banner.
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()                 // .../Schema/
            .appendingPathComponent("CodegenAcceptance") // .../Schema/CodegenAcceptance/
        let url = here.appendingPathComponent("Helpers.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        XCTAssertFalse(
            firstLine.hasPrefix("// Generated by swift-bao-codegen"),
            "Helpers.swift starts with the codegen banner, so the sweep would delete it on the next codegen run. Remove the banner."
        )
    }

    // MARK: - Update partial-write path

    func testUpdatePreservesUnchangedFields() throws {
        // `dynamic.update(id:values:)` writes only the fields it's
        // handed — the rest stay as they were. This is the path the
        // demo's BaoModelCrudDemo uses for "edit one field" flows.
        // Codegen's role here is structural: the typed model passes
        // through to the dynamic layer untouched, so an end-to-end
        // round-trip both proves the codegen-generated `init?(record:)`
        // sees the post-update state correctly.
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = TypedModel<TaskRecord>(doc: doc)

        try model.create(TaskRecord(
            id: "u1",
            title: "Original",
            priority: 5,
            tags: ["urgent", "backend"],
            createdAt: "2026-04-27T00:00:00Z"
        ))

        try model.dynamic.update(
            id: "u1",
            values: ["title": .string("Updated")]
        )

        let read = try XCTUnwrap(model.find(id: "u1"))
        XCTAssertEqual(read.title,     "Updated")
        XCTAssertEqual(read.priority,  5,
                       "priority should not have been touched")
        XCTAssertEqual(read.tags,      ["urgent", "backend"],
                       "tags should not have been touched")
        XCTAssertEqual(read.createdAt, "2026-04-27T00:00:00Z",
                       "createdAt should not have been touched")
    }

    // MARK: - FieldDescriptor.default applied at write time

    func testFieldDescriptorDefaultMaterializesAtCreate() throws {
        // The codegen emits `default: .scalar(.number(100))` /
        // `.scalar(.string("fallback"))` / `.scalar(.boolean(true))`
        // into the generated schema literal (asserted in
        // `testCrashTestSchemaLiteral`). At runtime, the
        // DynamicModel's create path materializes those defaults
        // into the record when the caller doesn't supply the field.
        // FieldValidationTests cover this for hand-written schemas;
        // here we prove the codegen-emitted literal drives the
        // same behavior.
        let model = freshCrashTestModel()
        // Write only the truly required field — leave score / active /
        // `default` unset on the wire. The runtime should fill them
        // in from the schema's declared defaults.
        _ = try model.dynamic.create(id: "d1", values: [
            "requiredTags": .stringset(["t"]),
        ])
        let rec = try XCTUnwrap(model.dynamic.find(id: "d1"))
        XCTAssertEqual(rec["score"],    .number(100),       "score default missing")
        XCTAssertEqual(rec["active"],   .boolean(true),     "active default missing")
        XCTAssertEqual(rec["default"],  .string("fallback"), "default default missing")
    }

    // MARK: - Helpers

    /// Spin up a fresh `YDocument` + `TypedModel<CrashTestRecord>`.
    /// Each test gets its own doc so writes from one don't pollute
    /// another — `SchemaSync`'s process-wide cache is reset too.
    private func freshCrashTestModel() -> TypedModel<CrashTestRecord> {
        let doc = YDocument()
        SchemaSync.clearCache()
        return TypedModel<CrashTestRecord>(doc: doc)
    }
}
