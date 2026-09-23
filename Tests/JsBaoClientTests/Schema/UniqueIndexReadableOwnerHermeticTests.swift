import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// A query and the unique index see the same rows (#3252).
///
/// The `_uniqueIdx_*` maps are a cache over the records, not the record
/// store: an entry can name a record the replica does not hold yet (its
/// structs have not landed), or one that no longer holds the key. On a
/// fresh install the app found no `household_ref` row for a document and
/// then had its save refused for exactly that row — `query` and the
/// constraint disagreed about what the document contains.
///
/// The contract these tests pin, from both sides:
///
/// - The constraint fires only for an index entry whose owner is
///   *readable*: the record map exists under that id and the key built
///   from its stored fields is the key being claimed. Anything else is a
///   stale entry — a miss, rewritten to the new record.
/// - When the constraint does fire, the record it cites is the one a
///   `query` on the constraint field returns.
///
/// Server-free: two `YDocument`s stand in for the writer and the fresh
/// replica, and a stale entry is written the way a not-yet-landed record's
/// index write would leave it.
final class UniqueIndexReadableOwnerHermeticTests: XCTestCase {

    /// The issue's model: `mainDocumentId` is the unique field.
    private let schema = PrimitiveSchema(
        name: "household_ref_3252",
        fields: [
            "id":             FieldDescriptor(type: .id),
            "mainDocumentId": FieldDescriptor(type: .id, unique: true),
            "name":           FieldDescriptor(type: .string),
        ]
    )

    private var constraintName: String {
        schema.resolvedUniqueConstraints.first { $0.fields == ["mainDocumentId"] }!.name
    }

    private var indexMapName: String {
        UniqueIndex.mapName(modelName: schema.name, constraintName: constraintName)
    }

    private func makeModel() -> (YDocument, DynamicModel) {
        SchemaSync.clearCache()
        let doc = YDocument()
        return (doc, DynamicModel(doc: doc, schema: schema))
    }

    /// Leave an index entry with no record behind it — the state a replica
    /// is in when a record's index write has landed and its record map has
    /// not (or the record was removed without the index being cleaned).
    private func writeStaleIndexEntry(doc: YDocument, key: String, owner: String) {
        doc.transactSync { [indexMapName] txn in
            let index = txn.transactionGetOrInsertMap(name: indexMapName)
            index.insert(tx: txn, key: key, value: PrimitiveValue.jsonEncodeString(owner))
        }
    }

    private func indexOwner(doc: YDocument, key: String) -> String? {
        doc.transactSync { [indexMapName] txn in
            let index = txn.transactionGetOrInsertMap(name: indexMapName)
            guard let raw = try? index.get(tx: txn, key: key) else { return nil }
            return PrimitiveValue.decodeJsonString(raw)
        }
    }

    private func encodeState(_ doc: YDocument) -> [UInt8] {
        doc.transactSync { txn in txn.transactionEncodeStateAsUpdate() }
    }

    private func apply(_ update: [UInt8], to doc: YDocument) {
        doc.transactSync { txn in
            _ = try? txn.transactionApplyUpdate(update: update)
        }
    }

    // MARK: - Fresh replica: both sides agree once the sync lands

    /// A model connected before its document's first sync — the fresh
    /// install shape — reports the landed row from `query` and from the
    /// constraint alike: the query returns it, and a colliding save is
    /// refused citing it.
    func testFreshReplicaQueryAndConstraintAgreeAfterSync() throws {
        let (writerDoc, writer) = makeModel()
        _ = try writer.create(id: "r1", values: [
            "mainDocumentId": .id("doc-B"), "name": .string("B"),
        ])
        let update = encodeState(writerDoc)

        // The replica's model is connected while its document is empty.
        let (replicaDoc, replica) = makeModel()
        XCTAssertEqual(try replica.query(["mainDocumentId": "doc-B"]).count, 0)
        apply(update, to: replicaDoc)

        let rows = try replica.query(["mainDocumentId": "doc-B"])
        XCTAssertEqual(rows.map { $0["id"]?.stringValue }, ["r1"],
                       "query must return the row the sync delivered")

        XCTAssertThrowsError(
            try replica.create(id: "r2", values: ["mainDocumentId": .id("doc-B")])
        ) { error in
            guard let violation = error as? UniqueConstraintViolationError else {
                return XCTFail("Expected UniqueConstraintViolationError, got \(error)")
            }
            XCTAssertEqual(violation.existingRecordId, "r1")
            XCTAssertEqual(violation.attemptedRecordId, "r2")
        }
    }

    // MARK: - A stale entry does not fire

    /// An index entry naming a record the document does not hold is not a
    /// violation: the save lands and the entry now names the new record.
    func testIndexEntryWithNoRecordDoesNotFire() throws {
        let (doc, model) = makeModel()
        writeStaleIndexEntry(doc: doc, key: "doc-B", owner: "ghost")
        XCTAssertEqual(try model.query(["mainDocumentId": "doc-B"]).count, 0,
                       "nothing readable holds the key")

        XCTAssertNoThrow(
            try model.create(id: "r2", values: [
                "mainDocumentId": .id("doc-B"), "name": .string("B"),
            ]),
            "a row the query cannot see must not block the save"
        )
        XCTAssertEqual(indexOwner(doc: doc, key: "doc-B"), "r2",
                       "the stale entry is rewritten to the record that landed")
        XCTAssertEqual(try model.query(["mainDocumentId": "doc-B"]).map { $0["id"]?.stringValue },
                       ["r2"])
    }

    /// The same rule for `save(id:values:)`, the generated `save(in:)` path
    /// the issue's `HouseholdRef(...).save(in: rootDoc)` runs.
    func testSaveWithStaleIndexEntryLands() throws {
        let (doc, model) = makeModel()
        writeStaleIndexEntry(doc: doc, key: "doc-B", owner: "ghost")

        XCTAssertNoThrow(
            try model.save(id: "r2", values: ["mainDocumentId": .id("doc-B")])
        )
        XCTAssertEqual(indexOwner(doc: doc, key: "doc-B"), "r2")
        XCTAssertNotNil(model.find(id: "r2"))
    }

    /// An entry whose owner exists but holds a different value — left by a
    /// field change that did not clean the index — is stale too.
    func testIndexEntryWhoseOwnerHoldsAnotherKeyDoesNotFire() throws {
        let (doc, model) = makeModel()
        _ = try model.create(id: "r1", values: ["mainDocumentId": .id("doc-C")])
        writeStaleIndexEntry(doc: doc, key: "doc-B", owner: "r1")

        XCTAssertNoThrow(
            try model.create(id: "r2", values: ["mainDocumentId": .id("doc-B")])
        )
        XCTAssertEqual(indexOwner(doc: doc, key: "doc-B"), "r2")
        XCTAssertEqual(indexOwner(doc: doc, key: "doc-C"), "r1",
                       "the owner's real key is untouched")
    }

    // MARK: - The upsert lookups treat a stale entry as a miss

    /// `upsertByUnique(mode: .mustNotExist)` is the "insert, this must be
    /// new" form: a stale entry must not refuse it.
    func testUpsertByUniqueMustNotExistIgnoresStaleEntry() throws {
        let (doc, model) = makeModel()
        writeStaleIndexEntry(doc: doc, key: "doc-B", owner: "ghost")

        let result = try model.upsertByUnique(
            constraint: constraintName,
            data: ["mainDocumentId": .id("doc-B"), "name": .string("B")],
            mode: .mustNotExist,
            id: "r2"
        )
        XCTAssertTrue(result.wasCreated)
        XCTAssertEqual(result.record.id, "r2")
        XCTAssertEqual(indexOwner(doc: doc, key: "doc-B"), "r2")
    }

    /// `.either` inserts rather than merging into an id nobody can read.
    func testUpsertByUniqueEitherInsertsOverStaleEntry() throws {
        let (doc, model) = makeModel()
        writeStaleIndexEntry(doc: doc, key: "doc-B", owner: "ghost")

        let result = try model.upsertByUnique(
            constraint: constraintName,
            data: ["mainDocumentId": .id("doc-B"), "name": .string("B")],
            id: "r2"
        )
        XCTAssertTrue(result.wasCreated, "no readable match — this is an insert")
        XCTAssertEqual(result.record.id, "r2")
        XCTAssertNil(model.find(id: "ghost"),
                     "the phantom id is not materialized as a record")
    }

    /// `upsert(on:)` — the generated `save(in:upsertOn:)` — has its own
    /// lookup and follows the same rule.
    func testUpsertOnInsertsOverStaleEntry() throws {
        let (doc, model) = makeModel()
        writeStaleIndexEntry(doc: doc, key: "doc-B", owner: "ghost")

        let result = try model.upsert(
            ["mainDocumentId": .id("doc-B"), "name": .string("B")],
            on: "mainDocumentId",
            id: "r2"
        )
        XCTAssertTrue(result.wasCreated)
        XCTAssertEqual(result.record.id, "r2")
        XCTAssertEqual(indexOwner(doc: doc, key: "doc-B"), "r2")
    }

    /// The cross-document search behind the generated `upsertByUnique(in:)`
    /// skips a stale entry in one document and inserts into the target.
    func testCrossDocumentUpsertByUniqueSkipsStaleEntry() throws {
        SchemaSync.clearCache()
        let shared = MultiDocModel(schema: schema)
        let docA = YDocument()
        let docB = YDocument()
        shared.connect(docId: "A", doc: docA)
        shared.connect(docId: "B", doc: docB)
        writeStaleIndexEntry(doc: docA, key: "doc-B", owner: "ghost")

        let result = try shared.upsertByUnique(
            constraint: constraintName,
            data: ["mainDocumentId": .id("doc-B")],
            id: "r2",
            targetDocId: "B"
        )
        XCTAssertTrue(result.wasCreated)
        XCTAssertEqual(shared.find(id: "r2")?.docId, "B")
    }

    // MARK: - A stale entry does not hide a readable owner

    /// The index names a ghost, but a readable row still holds the key —
    /// the row `query` returns. A stale entry is a miss for the index, not
    /// a license to duplicate: the save is refused citing the readable row,
    /// exactly as it would be with the entry intact.
    func testStaleEntryPointingElsewhereStillFiresForReadableOwner() throws {
        let (doc, model) = makeModel()
        _ = try model.create(id: "r1", values: [
            "mainDocumentId": .id("doc-B"), "name": .string("B"),
        ])
        writeStaleIndexEntry(doc: doc, key: "doc-B", owner: "ghost")
        XCTAssertEqual(try model.query(["mainDocumentId": "doc-B"]).map { $0["id"]?.stringValue },
                       ["r1"], "precondition: the query returns the readable owner")

        XCTAssertThrowsError(
            try model.create(id: "r2", values: ["mainDocumentId": .id("doc-B")])
        ) { error in
            guard let violation = error as? UniqueConstraintViolationError else {
                return XCTFail("Expected UniqueConstraintViolationError, got \(error)")
            }
            XCTAssertEqual(violation.existingRecordId, "r1",
                           "the row cited is the one the query returns, not the ghost")
            XCTAssertEqual(violation.attemptedRecordId, "r2")
        }
        XCTAssertEqual(try model.query(["mainDocumentId": "doc-B"]).map { $0["id"]?.stringValue },
                       ["r1"], "no duplicate landed")
        XCTAssertEqual(model.find(id: "r1")?["name"], .string("B"),
                       "the readable owner is untouched")
    }

    /// A row the index does not name at all — written before index
    /// maintenance, say — collides the same way.
    func testMissingEntryStillFiresForReadableOwner() throws {
        let (doc, model) = makeModel()
        _ = try model.create(id: "r1", values: ["mainDocumentId": .id("doc-B")])
        doc.transactSync { [indexMapName] txn in
            let index = txn.transactionGetOrInsertMap(name: indexMapName)
            _ = try? index.remove(tx: txn, key: "doc-B")
        }
        XCTAssertNil(indexOwner(doc: doc, key: "doc-B"), "precondition: no entry")

        XCTAssertThrowsError(
            try model.create(id: "r2", values: ["mainDocumentId": .id("doc-B")])
        ) { error in
            XCTAssertEqual((error as? UniqueConstraintViolationError)?.existingRecordId, "r1")
        }
    }

    /// An update that keeps its own key is not its own conflict, with or
    /// without the index entry behind it.
    func testUpdateKeepingOwnKeyIsNotAConflict() throws {
        let (doc, model) = makeModel()
        _ = try model.create(id: "r1", values: [
            "mainDocumentId": .id("doc-B"), "name": .string("B"),
        ])
        writeStaleIndexEntry(doc: doc, key: "doc-B", owner: "ghost")

        XCTAssertNoThrow(
            try model.update(id: "r1", values: ["name": .string("B2")])
        )
        XCTAssertEqual(model.find(id: "r1")?["name"], .string("B2"))
        XCTAssertEqual(indexOwner(doc: doc, key: "doc-B"), "r1",
                       "the write puts the entry back on its real owner")
    }

    /// `upsert(on:)` merges into the readable owner the query returns
    /// rather than inserting a duplicate beside it.
    func testUpsertOnMergesIntoReadableOwnerBehindStaleEntry() throws {
        let (doc, model) = makeModel()
        _ = try model.create(id: "r1", values: [
            "mainDocumentId": .id("doc-B"), "name": .string("B"),
        ])
        writeStaleIndexEntry(doc: doc, key: "doc-B", owner: "ghost")

        let result = try model.upsert(
            ["mainDocumentId": .id("doc-B"), "name": .string("B2")],
            on: "mainDocumentId"
        )
        XCTAssertFalse(result.wasCreated)
        XCTAssertEqual(result.record.id, "r1")
        XCTAssertEqual(model.find(id: "r1")?["name"], .string("B2"))
        XCTAssertEqual(indexOwner(doc: doc, key: "doc-B"), "r1")
    }

    /// `upsertByUnique(mode: .mustNotExist)` refuses when a readable row
    /// holds the key, whatever the index says; `.either` merges into it.
    func testUpsertByUniqueSeesReadableOwnerBehindStaleEntry() throws {
        let (doc, model) = makeModel()
        _ = try model.create(id: "r1", values: [
            "mainDocumentId": .id("doc-B"), "name": .string("B"),
        ])
        writeStaleIndexEntry(doc: doc, key: "doc-B", owner: "ghost")

        XCTAssertThrowsError(
            try model.upsertByUnique(
                constraint: constraintName,
                data: ["mainDocumentId": .id("doc-B")],
                mode: .mustNotExist,
                id: "r2"
            )
        )
        let merged = try model.upsertByUnique(
            constraint: constraintName,
            data: ["mainDocumentId": .id("doc-B"), "name": .string("B2")]
        )
        XCTAssertFalse(merged.wasCreated)
        XCTAssertEqual(merged.record.id, "r1")
        XCTAssertNil(model.find(id: "r2"))
    }

    /// The cross-document search finds the readable owner in the document
    /// that holds it, past a stale entry there.
    func testCrossDocumentUpsertByUniqueFindsReadableOwnerBehindStaleEntry() throws {
        SchemaSync.clearCache()
        let shared = MultiDocModel(schema: schema)
        let docA = YDocument()
        let docB = YDocument()
        let memberA = shared.connect(docId: "A", doc: docA)
        shared.connect(docId: "B", doc: docB)
        _ = try memberA.create(id: "r1", values: ["mainDocumentId": .id("doc-B")])
        writeStaleIndexEntry(doc: docA, key: "doc-B", owner: "ghost")

        let result = try shared.upsertByUnique(
            constraint: constraintName,
            data: ["mainDocumentId": .id("doc-B"), "name": .string("B2")],
            targetDocId: "B"
        )
        XCTAssertFalse(result.wasCreated)
        XCTAssertEqual(result.record.id, "r1")
    }

    /// `findByUnique` returns the row `query` returns.
    func testFindByUniqueReturnsReadableOwnerBehindStaleEntry() throws {
        let (doc, model) = makeModel()
        _ = try model.create(id: "r1", values: ["mainDocumentId": .id("doc-B")])
        writeStaleIndexEntry(doc: doc, key: "doc-B", owner: "ghost")

        XCTAssertEqual(
            try model.findByUnique(constraint: constraintName, value: .id("doc-B"))?.id,
            "r1"
        )
    }

    /// The mirror can lag the record store: a row the mirror still lists
    /// but the document no longer holds is not an owner.
    func testMirrorRowWithoutARecordDoesNotFire() throws {
        let (doc, model) = makeModel()
        _ = try model.create(id: "r1", values: ["mainDocumentId": .id("doc-B")])
        _ = try model.query(nil) // let the create's observer echo drain
        // Remove the record and its index entry from the document behind
        // the mirror's back, leaving the mirror row in place.
        doc.transactSync { [schema, indexMapName] txn in
            let root = txn.transactionGetOrInsertMap(name: schema.name)
            _ = try? root.remove(tx: txn, key: "r1")
            let index = txn.transactionGetOrInsertMap(name: indexMapName)
            _ = try? index.remove(tx: txn, key: "doc-B")
        }
        XCTAssertNil(model.find(id: "r1"), "precondition: the record is gone")

        XCTAssertNoThrow(
            try model.create(id: "r2", values: ["mainDocumentId": .id("doc-B")])
        )
        XCTAssertEqual(indexOwner(doc: doc, key: "doc-B"), "r2")
    }

    // MARK: - A firing constraint cites a row the query returns

    /// If the mirror behind `query` has fallen out of step with the record
    /// store, the constraint firing for a readable owner puts that owner's
    /// row back: the id the error carries is a row the caller can read.
    func testViolationCitesARowQueryReturns() throws {
        let (_, model) = makeModel()
        _ = try model.create(id: "r1", values: [
            "mainDocumentId": .id("doc-B"), "name": .string("B"),
        ])
        // Knock the mirror out from under the record store — after the
        // create's observer echo has drained, so nothing puts the row back.
        _ = try model.query(nil)
        _ = model.inspectionQueryEngine.rawQuery(
            "DELETE FROM \"\(model.inspectionTableName)\"", params: []
        )
        XCTAssertEqual(try model.query(["mainDocumentId": "doc-B"]).count, 0,
                       "precondition: the mirror no longer has the row")

        XCTAssertThrowsError(
            try model.create(id: "r2", values: ["mainDocumentId": .id("doc-B")])
        ) { error in
            XCTAssertEqual((error as? UniqueConstraintViolationError)?.existingRecordId, "r1")
        }

        XCTAssertEqual(try model.query(["mainDocumentId": "doc-B"]).map { $0["id"]?.stringValue },
                       ["r1"],
                       "the row the constraint cited is the row the query returns")
        XCTAssertEqual(model.find(id: "r1")?["name"], .string("B"))
    }
}
