import XCTest
@testable import JsBaoClient
import YSwift

/// Field-level save semantics (#2459).
///
/// js-bao's `BaseModel.save` writes only the fields the caller actually
/// assigned (`_localChanges`), and drops even those when the value already
/// equals what's persisted (`_diffWithYjsData`). The Swift client used to send
/// the full `primitiveValues()` dict and write every key, so the documented
/// fetch–mutate–save idiom re-wrote untouched fields with stale values and
/// clobbered another device's concurrent edit.
///
/// These tests pin both halves of the parity:
///   1. the write path honors a caller-supplied changed-field set, and
///   2. a changed field whose value already matches the record is not
///      re-written.
final class FieldLevelSaveTests: XCTestCase {

    private static let schema = PrimitiveSchema(
        name: "fieldLevelTasks",
        fields: [
            "id":       FieldDescriptor(type: .id),
            "title":    FieldDescriptor(type: .string, required: true),
            "priority": FieldDescriptor(type: .number),
            "tags":     FieldDescriptor(type: .stringset),
        ]
    )

    override func setUp() {
        super.setUp()
        SchemaSync.clearCache()
    }

    // MARK: - Helpers

    /// Encode the full state of `source` and apply it to `target`.
    private func sync(from source: YDocument, to target: YDocument) {
        let svTxn = target.document.transact(origin: nil)
        let sv = svTxn.transactionStateVector()
        svTxn.free()

        let diffTxn = source.document.transact(origin: nil)
        let update = (try? diffTxn.transactionEncodeStateAsUpdateFromSv(stateVector: sv)) ?? []
        diffTxn.free()

        if !update.isEmpty {
            let applyTxn = target.document.transact(origin: nil)
            try? applyTxn.transactionApplyUpdate(update: update)
            applyTxn.free()
        }
    }

    private func makePair() -> (YDocument, DynamicModel, YDocument, DynamicModel) {
        let docA = YDocument()
        let docB = YDocument()
        let a = DynamicModel(doc: docA, schema: Self.schema)
        let b = DynamicModel(doc: docB, schema: Self.schema)
        return (docA, a, docB, b)
    }

    // MARK: - 1. The reported bug: an untouched field is not re-written

    func testSaveWithChangedFieldsDoesNotClobberAnotherDevicesEdit() throws {
        let (docA, modelA, docB, modelB) = makePair()

        _ = try modelA.create(id: "t1", values: [
            "title":    .string("original"),
            "priority": .number(5),
        ])
        sync(from: docA, to: docB)

        // Device A fetches the record — its snapshot holds priority 5.
        let fetched = try XCTUnwrap(modelA.find(id: "t1"))
        let snapshot: [String: PrimitiveValue] = [
            "title":    .string(fetched["title"]?.asString ?? ""),
            "priority": .number(fetched["priority"]?.asNumber ?? 0),
        ]

        // Device B edits a DIFFERENT field and that edit reaches A first.
        try modelB.update(id: "t1", values: ["priority": .number(9)])
        sync(from: docB, to: docA)

        // Device A now saves its (stale) snapshot with only `title` changed.
        var mutated = snapshot
        mutated["title"] = .string("A's new title")
        _ = try modelA.save(id: "t1", values: mutated, changedFields: ["title"])

        let readA = try XCTUnwrap(modelA.find(id: "t1"))
        XCTAssertEqual(readA["title"], .string("A's new title"))
        XCTAssertEqual(
            readA["priority"], .number(9),
            "save() re-wrote `priority` from a stale snapshot — B's concurrent field edit was lost"
        )

        // And the merged view on B agrees.
        sync(from: docA, to: docB)
        let readB = try XCTUnwrap(modelB.find(id: "t1"))
        XCTAssertEqual(readB["title"], .string("A's new title"))
        XCTAssertEqual(readB["priority"], .number(9))
    }

    /// A stringset the caller never touched must not be replaced wholesale —
    /// the full-replace path is exactly how concurrent adds get lost.
    func testUntouchedStringsetIsNotRewritten() throws {
        let (docA, modelA, docB, modelB) = makePair()

        _ = try modelA.create(id: "t1", values: [
            "title": .string("original"),
            "tags":  .stringset(["a"]),
        ])
        sync(from: docA, to: docB)

        let fetched = try XCTUnwrap(modelA.find(id: "t1"))
        let snapshot: [String: PrimitiveValue] = [
            "title": .string(fetched["title"]?.asString ?? ""),
            "tags":  .stringset(fetched["tags"]?.asStringSet ?? []),
        ]

        // B adds a member concurrently; A never touches `tags`.
        try modelB.addStringsetMember(id: "t1", fieldName: "tags", member: "b")

        var mutated = snapshot
        mutated["title"] = .string("A's title")
        _ = try modelA.save(id: "t1", values: mutated, changedFields: ["title"])

        sync(from: docA, to: docB)
        sync(from: docB, to: docA)

        let readA = try XCTUnwrap(modelA.find(id: "t1"))
        XCTAssertEqual(readA["title"], .string("A's title"))
        XCTAssertEqual(
            readA["tags"]?.asStringSet, ["a", "b"],
            "the untouched stringset was replaced wholesale, dropping B's concurrent add"
        )
    }

    // MARK: - 2. Insert path still writes everything

    func testInsertIgnoresChangedFieldsAndWritesEveryValue() throws {
        let (_, modelA, _, _) = makePair()

        // An empty changed set on a record that doesn't exist yet must still
        // insert every supplied field — this is the "loaded from doc A, saved
        // into doc B" path, where nothing was ever assigned.
        _ = try modelA.save(id: "new1", values: [
            "title":    .string("fresh"),
            "priority": .number(3),
            "tags":     .stringset(["x"]),
        ], changedFields: [])

        let read = try XCTUnwrap(modelA.find(id: "new1"))
        XCTAssertEqual(read["title"],    .string("fresh"))
        XCTAssertEqual(read["priority"], .number(3))
        XCTAssertEqual(read["tags"]?.asStringSet, ["x"])
    }

    // MARK: - 3. No changed-field set → previous contract (write everything)

    func testNilChangedFieldsWritesEverySuppliedValue() throws {
        let (_, modelA, _, _) = makePair()

        _ = try modelA.create(id: "t1", values: [
            "title":    .string("original"),
            "priority": .number(5),
        ])
        // The untyped `DynamicModel` contract is unchanged: with no changed-set
        // supplied, every supplied field is a change.
        _ = try modelA.save(id: "t1", values: [
            "title":    .string("second"),
            "priority": .number(7),
        ])

        let read = try XCTUnwrap(modelA.find(id: "t1"))
        XCTAssertEqual(read["title"],    .string("second"))
        XCTAssertEqual(read["priority"], .number(7))
    }

    // MARK: - 4. Value diff: a changed field equal to the persisted value

    func testChangedFieldEqualToPersistedValueEmitsNoWrite() throws {
        let (docA, modelA, docB, modelB) = makePair()

        _ = try modelA.create(id: "t1", values: [
            "title":    .string("shared"),
            "priority": .number(1),
        ])
        sync(from: docA, to: docB)

        // B edits `title`; A has not seen it yet.
        try modelB.update(id: "t1", values: ["title": .string("B's title")])

        // A "changes" title to the value it already holds, and genuinely
        // changes priority. Only the priority op should be emitted, so B's
        // concurrent title edit survives the merge unambiguously.
        _ = try modelA.save(id: "t1", values: [
            "title":    .string("shared"),
            "priority": .number(9),
        ], changedFields: ["title", "priority"])

        sync(from: docA, to: docB)
        sync(from: docB, to: docA)

        let readA = try XCTUnwrap(modelA.find(id: "t1"))
        XCTAssertEqual(
            readA["title"], .string("B's title"),
            "a changed field whose value already matched the record was re-written, clobbering the remote edit"
        )
        XCTAssertEqual(readA["priority"], .number(9))
    }

    // MARK: - 5. Required-field validation still sees the merged state

    func testPartialUpdateDoesNotTripRequiredValidation() throws {
        let (_, modelA, _, _) = makePair()

        _ = try modelA.create(id: "t1", values: [
            "title":    .string("original"),
            "priority": .number(5),
        ])
        // `title` is required but isn't in the changed set — the merged view
        // (old + changed) still supplies it, so this must not throw.
        _ = try modelA.save(id: "t1", values: [
            "title":    .string("original"),
            "priority": .number(6),
        ], changedFields: ["priority"])

        let read = try XCTUnwrap(modelA.find(id: "t1"))
        XCTAssertEqual(read["title"],    .string("original"))
        XCTAssertEqual(read["priority"], .number(6))
    }

    // MARK: - 6. auto_stamp still fires with a change set in play

    func testAutoStampFiresEvenWhenNothingElseChanged() throws {
        let stamped = PrimitiveSchema(
            name: "fieldLevelStamped",
            fields: [
                "id":        FieldDescriptor(type: .id),
                "title":     FieldDescriptor(type: .string),
                "createdAt": FieldDescriptor(type: .number, autoStamp: .create),
                "updatedAt": FieldDescriptor(type: .number, autoStamp: .update),
            ]
        )
        let model = DynamicModel(doc: YDocument(), schema: stamped)

        _ = try model.save(id: "r1", values: ["title": .string("a")])
        let first = try XCTUnwrap(model.find(id: "r1"))
        let created = try XCTUnwrap(first["createdAt"]?.asNumber)
        let firstUpdated = try XCTUnwrap(first["updatedAt"]?.asNumber)

        // A save with an EMPTY change set (the typed facade's "read it, saved
        // it, changed nothing" case) still fires the `update` stamp — js-bao
        // stamps before it diffs — and leaves the `create` stamp alone.
        _ = try model.save(
            id: "r1",
            values: ["title": .string("a"), "createdAt": .number(created),
                     "updatedAt": .number(firstUpdated)],
            changedFields: []
        )
        let second = try XCTUnwrap(model.find(id: "r1"))
        XCTAssertEqual(second["createdAt"]?.asNumber, created,
                       "the create stamp must survive an update")
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(second["updatedAt"]?.asNumber), firstUpdated,
            "the update stamp must still fire when no user field changed"
        )
    }

    // MARK: - 7. Unique constraints still enforced on a partial write

    func testUniqueConstraintStillEnforcedWithChangedFields() throws {
        let uniqueSchema = PrimitiveSchema(
            name: "fieldLevelUniqueTasks",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "title": FieldDescriptor(type: .string, required: true),
                "slug":  FieldDescriptor(type: .string, unique: true),
            ]
        )
        let model = DynamicModel(doc: YDocument(), schema: uniqueSchema)

        _ = try model.create(id: "a", values: [
            "title": .string("A"), "slug": .string("taken"),
        ])
        _ = try model.create(id: "b", values: [
            "title": .string("B"), "slug": .string("free"),
        ])

        XCTAssertThrowsError(
            try model.save(id: "b", values: [
                "title": .string("B"), "slug": .string("taken"),
            ], changedFields: ["slug"])
        ) { error in
            XCTAssertTrue(error is UniqueConstraintViolationError)
        }

        // And the index still tracks a changed unique value.
        _ = try model.save(id: "b", values: [
            "title": .string("B"), "slug": .string("moved"),
        ], changedFields: ["slug"])
        let found = try model.findByUnique(
            constraint: "fieldLevelUniqueTasks_slug_unique", value: .string("moved")
        )
        XCTAssertEqual(found?.id, "b")
    }

    // MARK: - 8. The upsert MERGE paths honor the change set

    /// Schema for the upsert tests: a unique `slug` to match on plus a
    /// non-constraint `priority` that must survive an untouched save.
    private static let upsertSchema = PrimitiveSchema(
        name: "fieldLevelUpsertTasks",
        fields: [
            "id":       FieldDescriptor(type: .id),
            "title":    FieldDescriptor(type: .string, required: true),
            "slug":     FieldDescriptor(type: .string, unique: true),
            "priority": FieldDescriptor(type: .number),
        ]
    )

    private static let upsertSlugConstraint = "fieldLevelUpsertTasks_slug_unique"

    /// Seed one record, hand back a stale full-record snapshot of it, and
    /// land a concurrent remote edit to `priority` — the shape every upsert
    /// merge test below shares.
    private func seedForUpsertMerge(
        _ model: DynamicModel
    ) throws -> [String: PrimitiveValue] {
        _ = try model.create(id: "u1", values: [
            "title": .string("original"),
            "slug":  .string("s-1"),
            "priority": .number(5),
        ])
        let fetched = try XCTUnwrap(model.find(id: "u1"))
        let snapshot: [String: PrimitiveValue] = [
            "title":    .string(fetched["title"]?.asString ?? ""),
            "slug":     .string(fetched["slug"]?.asString ?? ""),
            "priority": .number(fetched["priority"]?.asNumber ?? 0),
        ]
        // A concurrent edit to a field this caller never touched.
        try model.update(id: "u1", values: ["priority": .number(9)])
        return snapshot
    }

    /// `upsert(_:on:)` — the path behind the generated
    /// `save(in:upsertOn:)`. The merge must write only the changed fields,
    /// and the match must still resolve: the lookup key is built from the
    /// FULL values before any narrowing, so `slug` keying the record while
    /// being absent from the change set has to keep working.
    func testUpsertMergeHonorsChangedFields() throws {
        let model = DynamicModel(doc: YDocument(), schema: Self.upsertSchema)
        var mutated = try seedForUpsertMerge(model)
        mutated["title"] = .string("upserted title")

        let result = try model.upsert(
            mutated, on: "slug", changedFields: ["title"]
        )

        XCTAssertFalse(result.wasCreated,
                       "the unique key is built from the full values, so the match must resolve")
        XCTAssertEqual(result.record.id, "u1", "the existing record's id wins on merge")

        let read = try XCTUnwrap(model.find(id: "u1"))
        XCTAssertEqual(read["title"], .string("upserted title"))
        XCTAssertEqual(
            read["priority"], .number(9),
            "the merge re-wrote `priority` from a stale snapshot — a concurrent field edit was lost"
        )
        XCTAssertEqual(read["slug"], .string("s-1"))
    }

    /// Same for the named-constraint primitive `upsertByUnique`, which
    /// merges through `mergeExisting` rather than `upsert`'s own path.
    func testUpsertByUniqueMergeHonorsChangedFields() throws {
        let model = DynamicModel(doc: YDocument(), schema: Self.upsertSchema)
        var mutated = try seedForUpsertMerge(model)
        mutated["title"] = .string("by-unique title")

        let result = try model.upsertByUnique(
            constraint: Self.upsertSlugConstraint,
            data: mutated,
            changedFields: ["title"]
        )

        XCTAssertFalse(result.wasCreated)
        XCTAssertEqual(result.record.id, "u1")

        let read = try XCTUnwrap(model.find(id: "u1"))
        XCTAssertEqual(read["title"], .string("by-unique title"))
        XCTAssertEqual(
            read["priority"], .number(9),
            "upsertByUnique's merge re-wrote an untouched field from a stale snapshot"
        )
    }

    /// And the cross-doc facade — `MultiDocModel.upsertByUnique`, the path
    /// behind the generated `upsertByUnique(_:mode:in:)`. Here the matched
    /// record already lives IN the target doc, so the write is an update
    /// and the change set applies.
    func testMultiDocUpsertByUniqueMergeHonorsChangedFields() throws {
        SchemaSync.clearCache()
        let multi = MultiDocModel(schema: Self.upsertSchema)
        let modelA = multi.connect(docId: "docA", doc: YDocument())
        SchemaSync.clearCache()
        _ = multi.connect(docId: "docB", doc: YDocument())

        var mutated = try seedForUpsertMerge(modelA)
        mutated["title"] = .string("cross-doc title")

        let result = try multi.upsertByUnique(
            constraint: Self.upsertSlugConstraint,
            data: mutated,
            targetDocId: "docA",
            changedFields: ["title"]
        )

        XCTAssertFalse(result.wasCreated)
        XCTAssertEqual(result.record.id, "u1")

        let read = try XCTUnwrap(modelA.find(id: "u1"))
        XCTAssertEqual(read["title"], .string("cross-doc title"))
        XCTAssertEqual(
            read["priority"], .number(9),
            "the cross-doc merge re-wrote an untouched field from a stale snapshot"
        )
    }

    // MARK: - 9. The value diff runs whether or not a change set is supplied

    /// The stage-2 value diff (js-bao's `_diffWithYjsData`) is NOT gated on
    /// `changedFields`: an untyped caller that supplies a value already equal
    /// to the persisted one emits no op for it either. Pinned because the
    /// `nil` contract is otherwise easy to read as "writes everything".
    func testNilChangedFieldsStillSkipsValuesEqualToPersisted() throws {
        let (docA, modelA, docB, modelB) = makePair()

        _ = try modelA.create(id: "t1", values: [
            "title":    .string("shared"),
            "priority": .number(1),
        ])
        sync(from: docA, to: docB)

        // B edits `title`; A has not seen it yet.
        try modelB.update(id: "t1", values: ["title": .string("B's title")])

        // A supplies the title it already has, with NO change set at all.
        _ = try modelA.save(id: "t1", values: [
            "title":    .string("shared"),
            "priority": .number(9),
        ])

        sync(from: docA, to: docB)
        sync(from: docB, to: docA)

        let readA = try XCTUnwrap(modelA.find(id: "t1"))
        XCTAssertEqual(
            readA["title"], .string("B's title"),
            "a supplied value equal to the persisted one must not be re-written, even with changedFields: nil"
        )
        XCTAssertEqual(readA["priority"], .number(9))
    }
}
