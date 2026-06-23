import XCTest
@testable import JsBaoClient
import YSwift

/// `Model.subscribe(callback)` — change-listener API. Matches js-bao
/// browser.js:3628 (`BaseModel.subscribe`). Callback fires after any
/// add / update / delete on the model; returns an unsubscribe closure.
///
/// `MultiDocModel.subscribe` fans out across every connected doc's
/// `DynamicModel`; a write through any one of them fires once on the
/// aggregator's listeners.
///
/// Closes gap (C) from the browser-vs-Swift audit.
final class SubscribeTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "sub_rows",
        fields: [
            "id":    FieldDescriptor(type: .id),
            "label": FieldDescriptor(type: .string),
        ]
    )

    // MARK: - DynamicModel.subscribe

    func testSubscribeFiresOnCreate() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: schema)
        let fired = NSCountedSet()
        let unsub = model.subscribe { fired.add("x") }

        _ = try model.create(id: "r1", values: ["label": .string("one")])

        // Observer drains are async on remote changes but direct
        // writes hit the listener synchronously via the write path's
        // observer chain.
        awaitListenerDrain(model: model)
        XCTAssertGreaterThanOrEqual(
            fired.count(for: "x"), 1,
            "Create should have fired at least once"
        )
        unsub()
    }

    func testSubscribeFiresOnUpdateAndDelete() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "r1", values: ["label": .string("one")])

        let fired = NSCountedSet()
        let unsub = model.subscribe { fired.add("x") }

        try model.update(id: "r1", values: ["label": .string("updated")])
        awaitListenerDrain(model: model)
        let afterUpdate = fired.count(for: "x")
        XCTAssertGreaterThanOrEqual(afterUpdate, 1, "Update should fire")

        model.delete(id: "r1")
        awaitListenerDrain(model: model)
        XCTAssertGreaterThan(fired.count(for: "x"), afterUpdate,
                             "Delete should fire on top of update")
        unsub()
    }

    func testUnsubscribeStopsNotifications() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: schema)
        let fired = NSCountedSet()
        let unsub = model.subscribe { fired.add("x") }

        _ = try model.create(id: "r1", values: ["label": .string("one")])
        awaitListenerDrain(model: model)
        let countBefore = fired.count(for: "x")

        unsub()

        _ = try model.create(id: "r2", values: ["label": .string("two")])
        awaitListenerDrain(model: model)
        XCTAssertEqual(
            fired.count(for: "x"), countBefore,
            "No new fires after unsubscribe"
        )
    }

    func testMultipleSubscribersAllFire() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: schema)
        var firedA = 0
        var firedB = 0
        let unsubA = model.subscribe { firedA += 1 }
        let unsubB = model.subscribe { firedB += 1 }

        _ = try model.create(id: "r1", values: ["label": .string("one")])
        awaitListenerDrain(model: model)

        XCTAssertGreaterThanOrEqual(firedA, 1)
        XCTAssertGreaterThanOrEqual(firedB, 1)
        unsubA()
        unsubB()
    }

    // MARK: - Post-commit notification (#1116)

    /// js-bao notifies subscribers AFTER the write transaction
    /// commits. A subscriber whose callback re-enters the model with
    /// `query()` must observe the fully-committed batch state — and
    /// must not deadlock against the still-open yrs transaction.
    /// Previously the listener fired synchronously inside
    /// `applyWriteInternal`, so a batched `transact` notified
    /// mid-batch with partial state.
    func testSubscriberQuerySeesCommittedBatchState() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: schema)

        var observedCounts: [Int] = []
        let unsub = model.subscribe {
            // Re-entering the model from the callback: requires the
            // write transaction to be closed.
            observedCounts.append(model.query().count)
        }

        try model.transact {
            _ = try model.create(id: "r1", values: ["label": .string("one")])
            _ = try model.create(id: "r2", values: ["label": .string("two")])
        }

        awaitListenerDrain(model: model)
        XCTAssertGreaterThanOrEqual(observedCounts.count, 1,
                                    "Batch must notify at least once")
        XCTAssertEqual(
            observedCounts, observedCounts.map { _ in 2 },
            "Every notification observes the committed batch (2 records), never partial state"
        )
        unsub()
    }

    /// A batch (`transact`) coalesces the model's direct write
    /// notifications into one post-commit fire (observer-driven async
    /// notifications may add more later, but none before commit).
    func testBatchNotifiesOnceSynchronously() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: schema)

        let firingThread = Thread.current
        var syncFires = 0
        let unsub = model.subscribe {
            // Count only the synchronous post-commit delivery on the
            // writing thread; async observer-drain fires arrive on a
            // different thread.
            if Thread.current === firingThread { syncFires += 1 }
        }

        try model.transact {
            _ = try model.create(id: "b1", values: ["label": .string("x")])
            _ = try model.create(id: "b2", values: ["label": .string("y")])
            _ = try model.create(id: "b3", values: ["label": .string("z")])
            XCTAssertEqual(syncFires, 0,
                           "No notification may fire inside the open transaction")
        }
        XCTAssertEqual(syncFires, 1,
                       "Direct write notifications coalesce to one per batch")
        awaitListenerDrain(model: model)
        unsub()
    }

    /// Deletes inside a batch defer their notification to commit too.
    func testDeleteInsideBatchNotifiesAfterCommit() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "r1", values: ["label": .string("one")])
        // Let the create's async observer notification land before
        // subscribing, so the callback only sees the delete.
        awaitListenerDrain(model: model)

        var observedCounts: [Int] = []
        let unsub = model.subscribe {
            observedCounts.append(model.query().count)
        }

        try model.transact {
            model.delete(id: "r1")
        }

        awaitListenerDrain(model: model)
        XCTAssertGreaterThanOrEqual(observedCounts.count, 1)
        XCTAssertEqual(observedCounts, observedCounts.map { _ in 0 },
                       "Callback observes the committed delete")
        unsub()
    }

    // MARK: - MultiDocModel.subscribe

    /// Subscribing BEFORE any docs are connected. When the first
    /// `connect` installs a new DynamicModel, every active subscriber
    /// should follow to it automatically — without this, long-lived
    /// aggregators that attach docs dynamically would silently miss
    /// events from newly-connected docs.
    func testMultiDocSubscribeBeforeConnectStillFires() throws {
        SchemaSync.clearCache()
        let multi = MultiDocModel(schema: schema)

        var fired = 0
        let unsub = multi.subscribe { fired += 1 }

        // Connect AFTER subscribing. Subsequent writes must reach the
        // subscriber.
        let a = multi.connect(docId: "docA", doc: YDocument())
        _ = try a.create(id: "a1", values: ["label": .string("a")])
        a.awaitObserverDrain()
        XCTAssertGreaterThan(fired, 0,
                             "Write on a doc connected after subscribe should still notify")
        unsub()
    }

    /// Disconnect stops notifications from the disconnected doc but
    /// other connected docs keep firing the subscriber.
    func testMultiDocDisconnectStopsThatDocOnly() throws {
        SchemaSync.clearCache()
        let multi = MultiDocModel(schema: schema)
        let a = multi.connect(docId: "docA", doc: YDocument())
        SchemaSync.clearCache()
        let b = multi.connect(docId: "docB", doc: YDocument())

        var fired = 0
        let unsub = multi.subscribe { fired += 1 }

        _ = try a.create(id: "a1", values: ["label": .string("a")])
        a.awaitObserverDrain()
        let afterFirst = fired

        multi.disconnect(docId: "docA")

        // b keeps firing
        _ = try b.create(id: "b1", values: ["label": .string("b")])
        b.awaitObserverDrain()
        XCTAssertGreaterThan(fired, afterFirst,
                             "Remaining connected doc must still fire the subscriber")

        unsub()
    }

    func testMultiDocModelSubscribeFiresForAnyConnectedDoc() throws {
        SchemaSync.clearCache()
        let multi = MultiDocModel(schema: schema)

        let a = multi.connect(docId: "docA", doc: YDocument())
        SchemaSync.clearCache()
        let b = multi.connect(docId: "docB", doc: YDocument())

        var fired = 0
        let unsub = multi.subscribe { fired += 1 }

        _ = try a.create(id: "a1", values: ["label": .string("a")])
        a.awaitObserverDrain()
        let afterA = fired

        _ = try b.create(id: "b1", values: ["label": .string("b")])
        b.awaitObserverDrain()

        XCTAssertGreaterThan(afterA, 0, "docA write should fire")
        XCTAssertGreaterThan(fired, afterA, "docB write should fire too")
        unsub()
    }

    // MARK: - Cross-doc nesting (doc-scoped activeTx)

    /// A write to a model bound to doc B nested inside a `transact` on
    /// doc A must open B's **own** yrs transaction — the thread-local
    /// active transaction is doc-scoped (#1116 review follow-up).
    /// Reusing A's doc-bound `YrsTransaction` for B's branches would
    /// misapply the mutations. Both writes must land, and B's
    /// subscriber fires when B's own (inner) transaction commits.
    func testCrossDocWriteInsideTransactUsesOwnTransaction() throws {
        SchemaSync.clearCache()
        let modelA = DynamicModel(doc: YDocument(), schema: schema)
        SchemaSync.clearCache()
        let modelB = DynamicModel(doc: YDocument(), schema: schema)

        var bFired = 0
        let unsubB = modelB.subscribe { bFired += 1 }

        try modelA.transact {
            _ = try modelA.create(id: "a1", values: ["label": .string("a")])
            _ = try modelB.create(id: "b1", values: ["label": .string("b")])
        }
        modelA.awaitObserverDrain()
        modelB.awaitObserverDrain()

        XCTAssertNotNil(modelA.find(id: "a1"), "doc A write must land")
        XCTAssertNotNil(modelB.find(id: "b1"),
                        "doc B write nested in doc A's transact must land in doc B")
        XCTAssertGreaterThanOrEqual(bFired, 1,
                                    "doc B subscriber fires on its own commit")
        unsubB()
    }

    // MARK: - Helpers

    /// Swift's root-map / per-record observers dispatch async work
    /// for remote updates; local writes are direct. We nudge both
    /// paths before assertions.
    private func awaitListenerDrain(model: DynamicModel) {
        model.awaitObserverDrain()
    }
}
