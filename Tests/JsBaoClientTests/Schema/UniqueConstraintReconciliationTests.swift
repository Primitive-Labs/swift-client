import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Post-merge uniqueness-invariant reconciliation — mirrors js-bao's
/// `resolveConflictsForBatch` in `BaseModel.ts`.
///
/// The scenario: two offline clients both create records that locally
/// pass the uniqueness check. After syncing, yrs merges both records
/// deterministically — both survive and now share a unique-key value,
/// violating the invariant. The reconciler scans the model's data map,
/// groups records by unique key, picks a deterministic winner (largest
/// id, matching js-bao's ULID-is-sortable convention), deletes the
/// losers, and updates the `_uniqueIdx_*` entries to point at survivors.
///
/// Not called "CRDT conflict resolution" — yrs's own merge is already
/// deterministic. This is an application-layer reconciliation of an
/// invariant that the CRDT can't enforce on its own.
final class UniqueConstraintReconciliationTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "users_recon",
        fields: [
            "id":    FieldDescriptor(type: .id),
            "email": FieldDescriptor(type: .string, unique: true),
            "name":  FieldDescriptor(type: .string),
        ]
    )

    /// Merge updates from `src` into `dst` — simulates what happens when
    /// a remote client's updates arrive over the wire.
    private func merge(from src: YDocument, into dst: YDocument) {
        let bytes = src.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }
        dst.transactSync { txn in
            _ = try? txn.transactionApplyUpdate(update: Array(bytes))
        }
    }

    // MARK: - Single-field

    /// Two offline clients both create records with the same unique
    /// email. After merge + reconciliation, only the record with the
    /// larger id survives.
    func testOfflineMergeDuplicatesReconcileToLargerId() throws {
        SchemaSync.clearCache()
        let docA = YDocument()
        let modelA = DynamicModel(doc: docA, schema: schema)
        _ = try modelA.create(id: "u1", values: [
            "email": .string("alice@x.com"),
            "name":  .string("A-copy"),
        ])

        SchemaSync.clearCache()
        let docB = YDocument()
        let modelB = DynamicModel(doc: docB, schema: schema)
        _ = try modelB.create(id: "u2", values: [
            "email": .string("alice@x.com"),
            "name":  .string("B-copy"),
        ])

        merge(from: docB, into: docA)

        // Run reconciliation synchronously so the test is deterministic.
        modelA.reconcileUniqueConstraints()

        XCTAssertNil(modelA.find(id: "u1"),
                     "Loser id (smaller) must be deleted")
        XCTAssertNotNil(modelA.find(id: "u2"),
                        "Winner id (larger) must survive")
        XCTAssertEqual(modelA.find(id: "u2")?["name"], .string("B-copy"))
    }

    /// The `_uniqueIdx_*` ends up pointing at the surviving record.
    func testReconciliationFixesUniqueIndex() throws {
        SchemaSync.clearCache()
        let docA = YDocument()
        let modelA = DynamicModel(doc: docA, schema: schema)
        _ = try modelA.create(id: "u1", values: ["email": .string("a@b.c")])

        SchemaSync.clearCache()
        let docB = YDocument()
        let modelB = DynamicModel(doc: docB, schema: schema)
        _ = try modelB.create(id: "u2", values: ["email": .string("a@b.c")])

        merge(from: docB, into: docA)
        modelA.reconcileUniqueConstraints()

        let found = try modelA.findByUnique(
            constraint: "users_recon_email_unique",
            value: .string("a@b.c")
        )
        XCTAssertEqual(found?.id, "u2",
                       "Unique index must resolve to the surviving id")
    }

    /// Reconciliation is idempotent on an already-clean doc — a second
    /// run makes no changes.
    func testReconciliationIsIdempotent() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "u1", values: ["email": .string("a@b.c")])

        let stateBefore = doc.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }
        model.reconcileUniqueConstraints()
        model.reconcileUniqueConstraints()
        let stateAfter = doc.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }
        XCTAssertEqual(stateBefore, stateAfter,
                       "Reconciling a clean doc must not emit updates")
    }

    /// A clean doc with no duplicates is not modified by reconciliation.
    func testReconciliationDoesNotTouchCleanDoc() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "u1", values: ["email": .string("a@x.c")])
        _ = try model.create(id: "u2", values: ["email": .string("b@x.c")])
        _ = try model.create(id: "u3", values: ["email": .string("c@x.c")])

        model.reconcileUniqueConstraints()

        XCTAssertEqual(model.findAll().count, 3)
    }

    // MARK: - Compound

    /// Offline merge on a compound-unique constraint: two clients both
    /// create records with the same (tenantId, sku). Reconciliation
    /// picks the larger id.
    func testCompoundDuplicatesReconcile() throws {
        let compoundSchema = PrimitiveSchema(
            name: "products_recon",
            fields: [
                "id":       FieldDescriptor(type: .id),
                "tenantId": FieldDescriptor(type: .string),
                "sku":      FieldDescriptor(type: .string),
            ],
            constraints: [
                "uq_tenant_sku": ConstraintDescriptor(
                    name: "uq_tenant_sku",
                    fields: ["tenantId", "sku"]
                )
            ]
        )

        SchemaSync.clearCache()
        let docA = YDocument()
        let modelA = DynamicModel(doc: docA, schema: compoundSchema)
        _ = try modelA.create(id: "p1", values: [
            "tenantId": .string("t1"), "sku": .string("A"),
        ])

        SchemaSync.clearCache()
        let docB = YDocument()
        let modelB = DynamicModel(doc: docB, schema: compoundSchema)
        _ = try modelB.create(id: "p2", values: [
            "tenantId": .string("t1"), "sku": .string("A"),
        ])

        merge(from: docB, into: docA)
        modelA.reconcileUniqueConstraints()

        XCTAssertNil(modelA.find(id: "p1"))
        XCTAssertNotNil(modelA.find(id: "p2"))
    }

    // MARK: - Null-valued fields are exempt

    /// Records with null/missing values for a unique field do not
    /// participate in reconciliation (matches js-bao's buildUniqueKey
    /// returning null). Two records both missing `email` can coexist.
    func testRecordsWithoutUniqueFieldAreNotReconciled() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "u1", values: [:])
        _ = try model.create(id: "u2", values: [:])

        model.reconcileUniqueConstraints()

        XCTAssertEqual(model.findAll().count, 2,
                       "Two null-keyed records must both survive")
    }

    // MARK: - Three-way merge

    /// Three offline clients all create records with the same unique
    /// value. After merging them all, only one survives.
    func testThreeWayMergeKeepsLargestId() throws {
        SchemaSync.clearCache()
        let docA = YDocument()
        let modelA = DynamicModel(doc: docA, schema: schema)
        _ = try modelA.create(id: "u_a", values: ["email": .string("x@y.c")])

        SchemaSync.clearCache()
        let docB = YDocument()
        let modelB = DynamicModel(doc: docB, schema: schema)
        _ = try modelB.create(id: "u_b", values: ["email": .string("x@y.c")])

        SchemaSync.clearCache()
        let docC = YDocument()
        let modelC = DynamicModel(doc: docC, schema: schema)
        _ = try modelC.create(id: "u_c", values: ["email": .string("x@y.c")])

        merge(from: docB, into: docA)
        merge(from: docC, into: docA)
        modelA.reconcileUniqueConstraints()

        XCTAssertNil(modelA.find(id: "u_a"))
        XCTAssertNil(modelA.find(id: "u_b"))
        XCTAssertNotNil(modelA.find(id: "u_c"),
                        "Largest id (u_c) must win across 3-way merge")
    }

    // MARK: - Auto-trigger from observer

    /// The reconciler is also wired to fire automatically after any
    /// doc update. We `applyUpdate`, then wait briefly for the async
    /// reconcile to run — no explicit call needed.
    func testReconciliationFiresAutomaticallyAfterRemoteMerge() throws {
        SchemaSync.clearCache()
        let docA = YDocument()
        let modelA = DynamicModel(doc: docA, schema: schema)
        _ = try modelA.create(id: "u1", values: ["email": .string("a@b.c")])

        SchemaSync.clearCache()
        let docB = YDocument()
        let modelB = DynamicModel(doc: docB, schema: schema)
        _ = try modelB.create(id: "u2", values: ["email": .string("a@b.c")])

        merge(from: docB, into: docA)

        // Observer dispatches reconcile asynchronously. Wait until it
        // runs (max 1s).
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if modelA.find(id: "u1") == nil { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertNil(modelA.find(id: "u1"),
                     "Async reconcile from observer must eventually run")
        XCTAssertNotNil(modelA.find(id: "u2"))
    }
}
