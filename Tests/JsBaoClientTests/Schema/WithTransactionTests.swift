import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Tests `DynamicModel.transact { ... }` — atomic batch writes.
///
/// Semantics matching js-bao's `BaseModel.withTransaction`:
///  - Every write inside the closure runs in ONE yrs transaction.
///    Observers fire ONCE per batch, not per write.
///  - Uniqueness enforcement spans the batch: a create later in the
///    closure sees records created earlier in the same closure for
///    conflict detection.
///  - A throw exits the closure early. Writes that happened BEFORE the
///    throw remain committed — yrs doesn't roll back mid-transaction.
///    This matches js-bao / yjs semantics.
///  - Nested `transact` calls on the same thread reuse the outer
///    transaction (no new yrs commit).
final class WithTransactionTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "tx_users",
        fields: [
            "id":    FieldDescriptor(type: .id),
            "email": FieldDescriptor(type: .string, unique: true),
            "name":  FieldDescriptor(type: .string),
        ]
    )

    // MARK: - Batching

    /// A batch of creates produces a single yrs update event, not one
    /// per write.
    func testBatchFiresOneObserverEventNotMany() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)

        final class Counter {
            let lock = NSLock()
            var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let counter = Counter()
        let sub = doc.observeUpdate { _ in counter.bump() }
        defer { sub.cancel() }

        // Baseline: already one or more events from schemaSync during
        // DynamicModel.init.
        let baseline = counter.value

        try model.transact {
            _ = try model.create(id: "u1", values: [
                "email": .string("a@b.c"), "name": .string("A"),
            ])
            _ = try model.create(id: "u2", values: [
                "email": .string("d@e.f"), "name": .string("D"),
            ])
            _ = try model.create(id: "u3", values: [
                "email": .string("g@h.i"), "name": .string("G"),
            ])
        }

        XCTAssertEqual(
            counter.value - baseline, 1,
            "Three creates inside transact must produce exactly one update"
        )
    }

    /// Without transact, each write fires its own observer event.
    func testWritesWithoutTransactFireSeparateEvents() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)
        final class Counter {
            let lock = NSLock()
            var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let counter = Counter()
        let sub = doc.observeUpdate { _ in counter.bump() }
        defer { sub.cancel() }
        let baseline = counter.value

        _ = try model.create(id: "u1", values: ["email": .string("a@b.c")])
        _ = try model.create(id: "u2", values: ["email": .string("d@e.f")])

        XCTAssertEqual(
            counter.value - baseline, 2,
            "Two independent creates must fire two observer events"
        )
    }

    // MARK: - Uniqueness spans the batch

    /// Two creates inside a single transact with the same unique value
    /// must see each other's uniqueness: the second throws.
    func testUniquenessEnforcementSpansBatch() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)

        XCTAssertThrowsError(try model.transact {
            _ = try model.create(id: "u1", values: [
                "email": .string("a@b.c"), "name": .string("A"),
            ])
            _ = try model.create(id: "u2", values: [
                "email": .string("a@b.c"), "name": .string("B"),
            ])
        }) { error in
            XCTAssertTrue(error is UniqueConstraintViolationError)
        }
    }

    /// A find inside transact sees records created earlier in the same
    /// batch — proves reads and writes share the transaction.
    func testFindInBatchSeesEarlierCreate() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)

        try model.transact {
            _ = try model.create(id: "u1", values: [
                "email": .string("a@b.c"), "name": .string("A"),
            ])
            let rec = model.find(id: "u1")
            XCTAssertEqual(rec?["email"], .string("a@b.c"))
        }
    }

    // MARK: - Partial-commit behavior on throw

    /// If the batch throws midway, writes that already happened are
    /// visible. yrs doesn't unwind partial transactions — same as js-bao.
    func testWritesBeforeThrowRemainCommitted() {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)

        struct CustomError: Error {}
        XCTAssertThrowsError(try model.transact {
            _ = try model.create(id: "u1", values: [
                "email": .string("a@b.c"), "name": .string("A"),
            ])
            throw CustomError()
        }) { error in
            XCTAssertTrue(error is CustomError)
        }
        XCTAssertNotNil(model.find(id: "u1"),
                        "yrs doesn't roll back — pre-throw writes persist")
    }

    // MARK: - Nesting

    /// A nested transact on the same thread reuses the outer
    /// transaction. We verify by observing: only one update fires for
    /// the entire nested batch.
    func testNestedTransactReusesOuterTransaction() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)
        final class Counter {
            let lock = NSLock()
            var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let counter = Counter()
        let sub = doc.observeUpdate { _ in counter.bump() }
        defer { sub.cancel() }
        let baseline = counter.value

        try model.transact {
            _ = try model.create(id: "u1", values: [
                "email": .string("a@b.c"), "name": .string("A"),
            ])
            try model.transact {
                _ = try model.create(id: "u2", values: [
                    "email": .string("d@e.f"), "name": .string("D"),
                ])
            }
        }

        XCTAssertEqual(
            counter.value - baseline, 1,
            "Nested transact must not open a second yrs transaction"
        )
    }

    // MARK: - Empty and return values

    func testEmptyTransactProducesNoUpdate() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)
        let stateBefore = doc.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }
        try model.transact { /* intentionally empty */ }
        let stateAfter = doc.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }
        XCTAssertEqual(stateBefore, stateAfter)
    }

    /// transact is generic over the closure's return type.
    func testTransactReturnsValueFromClosure() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)
        let returned: Int = try model.transact {
            _ = try model.create(id: "u1", values: ["email": .string("a@b.c")])
            return 42
        }
        XCTAssertEqual(returned, 42)
    }

    // MARK: - Mixed operations

    /// Create + update + delete inside one batch.
    func testMixedOperationsInOneBatch() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "u_pre", values: [
            "email": .string("pre@x.c"), "name": .string("Pre"),
        ])

        try model.transact {
            _ = try model.create(id: "u_new", values: [
                "email": .string("new@x.c"),
            ])
            try model.update(id: "u_pre", values: ["name": .string("Updated")])
            model.delete(id: "u_pre")
        }

        XCTAssertNil(model.find(id: "u_pre"))
        XCTAssertEqual(model.find(id: "u_new")?["email"], .string("new@x.c"))
    }
}
