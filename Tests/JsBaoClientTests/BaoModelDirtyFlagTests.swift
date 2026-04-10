import XCTest
@testable import JsBaoClient
import YSwift

/// Unit tests for the dirty-flag short-circuit in `BaoModel<T>`.
///
/// Background: previously `BaoModel.query()` / `count()` / `aggregate()`
/// did a full O(n) `DELETE FROM table` + bulk `INSERT` rebuild of the
/// SQLite mirror on EVERY call. The fix subscribes to `doc.observeUpdate`
/// and only rebuilds the mirror when the doc has actually mutated since
/// the previous query.
///
/// These tests use a fresh in-process `YDocument()` and need no server.
final class BaoModelDirtyFlagTests: XCTestCase {

    // MARK: - Test record type

    struct TaskRecord: BaoModelRecord {
        static let modelName = "tasks-dirty-flag-test"
        static let fields: [FieldDefinition] = [
            FieldDefinition("id", .string),
            FieldDefinition("title", .string),
            FieldDefinition("priority", .number),
            FieldDefinition("done", .boolean),
        ]

        let id: String
        let title: String
        let priority: Double
        let done: Bool

        init(id: String, title: String, priority: Double, done: Bool) {
            self.id = id
            self.title = title
            self.priority = priority
            self.done = done
        }

        init(fields: [String: Any]) {
            self.id = fields["id"] as? String ?? ""
            self.title = fields["title"] as? String ?? ""
            self.priority = (fields["priority"] as? Double)
                ?? Double(fields["priority"] as? Int ?? 0)
            // SQLite stores booleans as INTEGER, so they round-trip back as Int
            if let b = fields["done"] as? Bool {
                self.done = b
            } else if let i = fields["done"] as? Int {
                self.done = i != 0
            } else {
                self.done = false
            }
        }

        func toFields() -> [String: Any] {
            return [
                "id": id,
                "title": title,
                "priority": priority,
                "done": done,
            ]
        }
    }

    // MARK: - Helpers

    private func makeModel() -> (YDocument, BaoModel<TaskRecord>) {
        let doc = YDocument()
        let model = BaoModel<TaskRecord>(doc: doc)
        return (doc, model)
    }

    // MARK: - Dirty-flag behavior

    /// The first query on a fresh model should trigger exactly one
    /// rebuild (because the index starts dirty).
    func testFirstQueryTriggersExactlyOneSync() {
        let (_, model) = makeModel()
        XCTAssertEqual(model.syncCallCount, 0, "No sync should have run before any query")

        _ = model.query()
        XCTAssertEqual(model.syncCallCount, 1, "First query must trigger one rebuild")
    }

    /// **The headline fix.** Repeated queries with no intervening mutations
    /// should reuse the existing SQLite mirror instead of rebuilding it on
    /// every call. Previously this counter would have been 5; now it should
    /// stay at 1.
    func testRepeatedQueriesSkipRebuildWhenNothingChanged() {
        let (_, model) = makeModel()

        _ = model.query()
        _ = model.query()
        _ = model.query()
        _ = model.count()
        _ = model.query()

        XCTAssertEqual(
            model.syncCallCount, 1,
            "Five queries with no mutations between them should result in exactly one rebuild"
        )
    }

    /// After a `create()`, `observeUpdate` should mark the index dirty so
    /// the next query rebuilds — but only one rebuild, not one per query.
    func testCreateMarksDirtyAndCoalescesRebuilds() {
        let (_, model) = makeModel()

        _ = model.query()
        XCTAssertEqual(model.syncCallCount, 1)

        model.create(TaskRecord(id: "t1", title: "first", priority: 1, done: false))
        model.create(TaskRecord(id: "t2", title: "second", priority: 2, done: false))
        model.create(TaskRecord(id: "t3", title: "third", priority: 3, done: true))

        // Three writes between queries should coalesce into a single rebuild
        // on the next query, not three.
        _ = model.query()
        XCTAssertEqual(
            model.syncCallCount, 2,
            "Three writes should coalesce into one rebuild on the next query"
        )

        _ = model.query()
        _ = model.count()
        XCTAssertEqual(
            model.syncCallCount, 2,
            "Subsequent queries with no mutations must not rebuild"
        )
    }

    /// Deletes should also mark the index dirty.
    func testDeleteMarksDirty() {
        let (_, model) = makeModel()
        model.create(TaskRecord(id: "t1", title: "first", priority: 1, done: false))

        _ = model.query()
        let countAfterFirstQuery = model.syncCallCount

        model.delete("t1")
        _ = model.query()

        XCTAssertEqual(
            model.syncCallCount, countAfterFirstQuery + 1,
            "Delete should mark dirty so the next query rebuilds exactly once"
        )
    }

    /// Updates should also mark the index dirty.
    func testUpdateMarksDirty() {
        let (_, model) = makeModel()
        model.create(TaskRecord(id: "t1", title: "first", priority: 1, done: false))

        _ = model.query()
        let countAfterFirstQuery = model.syncCallCount

        model.update("t1", ["done": true])
        _ = model.query()

        XCTAssertEqual(
            model.syncCallCount, countAfterFirstQuery + 1,
            "Update should mark dirty so the next query rebuilds exactly once"
        )
    }

    /// `refreshQueryIndex()` should always force a rebuild even if the
    /// index appears clean.
    func testRefreshQueryIndexForcesRebuild() {
        let (_, model) = makeModel()
        _ = model.query()
        let after = model.syncCallCount

        model.refreshQueryIndex()
        XCTAssertEqual(
            model.syncCallCount, after + 1,
            "refreshQueryIndex must always rebuild"
        )
    }

    // MARK: - End-to-end correctness

    /// Sanity check that the dirty-flag short-circuit doesn't cause stale
    /// query results: writes followed by queries must always reflect the
    /// latest state.
    func testCorrectnessAcrossMutationsAndQueries() {
        let (_, model) = makeModel()

        // Initially empty
        XCTAssertEqual(model.query().count, 0)
        XCTAssertEqual(model.count(), 0)

        // Insert three records
        model.create(TaskRecord(id: "a", title: "alpha", priority: 1, done: false))
        model.create(TaskRecord(id: "b", title: "beta", priority: 2, done: true))
        model.create(TaskRecord(id: "c", title: "gamma", priority: 3, done: false))

        XCTAssertEqual(model.count(), 3)
        XCTAssertEqual(model.query().count, 3)
        XCTAssertEqual(model.count(["done": true]), 1)
        XCTAssertEqual(model.count(["done": false]), 2)

        // Update one
        model.update("a", ["done": true])
        XCTAssertEqual(model.count(["done": true]), 2)
        XCTAssertEqual(model.count(["done": false]), 1)

        // Delete one
        model.delete("c")
        XCTAssertEqual(model.count(), 2)
        let remainingIds = Set(model.query().map { $0.id })
        XCTAssertEqual(remainingIds, ["a", "b"])

        // Filter that should match exactly one record
        let highPriorityDone = model.query(["priority": ["$gte": 2], "done": true])
        XCTAssertEqual(highPriorityDone.count, 1)
        XCTAssertEqual(highPriorityDone.first?.id, "b")
    }

    /// Mixing reads and writes should still produce correct results without
    /// the per-query rebuild.
    func testInterleavedReadsAndWritesStaysCorrect() {
        let (_, model) = makeModel()

        model.create(TaskRecord(id: "1", title: "one", priority: 1, done: false))
        XCTAssertEqual(model.count(), 1)

        model.create(TaskRecord(id: "2", title: "two", priority: 2, done: false))
        XCTAssertEqual(model.count(), 2)

        model.update("1", ["priority": 5.0])
        let sorted = model.query(nil, options: QueryOptions(sort: ["priority": -1]))
        XCTAssertEqual(sorted.map { $0.id }, ["1", "2"])

        model.delete("1")
        XCTAssertEqual(model.count(), 1)
        XCTAssertEqual(model.query().first?.id, "2")
    }
}
