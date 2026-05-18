import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Tests the typed façade (`TypedModel<T>`) over `DynamicModel`. The
/// façade does not bypass the runtime schema — it reads/writes through
/// `PrimitiveRecord` so the wire format stays consistent with what a
/// schema-less / dynamic caller would see.
final class TypedModelTests: XCTestCase {

    struct Task: PrimitiveModel, Equatable {
        static let modelName = "tasks_typed"
        static let primitiveSchema = PrimitiveSchema(
            name: "tasks_typed",
            fields: [
                "id":       FieldDescriptor(type: .id),
                "title":    FieldDescriptor(type: .string),
                "priority": FieldDescriptor(type: .number),
                "done":     FieldDescriptor(type: .boolean),
            ]
        )

        var id: String
        var title: String
        var priority: Double
        var done: Bool

        init(id: String, title: String, priority: Double, done: Bool) {
            self.id = id
            self.title = title
            self.priority = priority
            self.done = done
        }

        init?(record: PrimitiveRecord) {
            guard let title    = record["title"]?.asString,
                  let priority = record["priority"]?.asNumber,
                  let done     = record["done"]?.asBoolean
            else { return nil }
            self.id = record.id
            self.title = title
            self.priority = priority
            self.done = done
        }

        func primitiveValues() -> [String: PrimitiveValue] {
            return [
                "title":    .string(title),
                "priority": .number(priority),
                "done":     .boolean(done),
            ]
        }
    }

    // MARK: - Basic CRUD

    func testCreateAndFind() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = TypedModel<Task>(doc: doc)

        _ = try model.create(Task(id: "t1", title: "hi", priority: 2, done: false))
        let found = model.find(id: "t1")
        XCTAssertEqual(found, Task(id: "t1", title: "hi", priority: 2, done: false))
    }

    func testFindAll() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = TypedModel<Task>(doc: doc)
        _ = try model.create(Task(id: "t1", title: "a", priority: 1, done: false))
        _ = try model.create(Task(id: "t2", title: "b", priority: 2, done: true))

        let all = model.findAll().sorted(by: { $0.id < $1.id })
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].title, "a")
        XCTAssertEqual(all[1].title, "b")
    }

    func testDelete() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = TypedModel<Task>(doc: doc)
        _ = try model.create(Task(id: "t1", title: "x", priority: 1, done: false))
        XCTAssertNotNil(model.find(id: "t1"))
        model.delete(id: "t1")
        XCTAssertNil(model.find(id: "t1"))
    }

    // MARK: - Drift: graceful degradation

    /// When the underlying record has a field of the WRONG type vs. the
    /// typed struct's expectation, the typed getter returns nil. The raw
    /// record value is still accessible via the DynamicModel escape hatch.
    func testTypedInitReturnsNilOnTypeMismatch() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = TypedModel<Task>(doc: doc)

        // Seed a record with a priority field that's a string, not a number.
        // This simulates a JS client writing incompatible data.
        doc.transactSync { txn in
            let tasks = txn.transactionGetOrInsertMap(name: "tasks_typed")
            let rec = tasks.getOrInsertMap(tx: txn, key: "t1")
            rec.insert(tx: txn, key: "id",       value: "\"t1\"")
            rec.insert(tx: txn, key: "title",    value: "\"hi\"")
            rec.insert(tx: txn, key: "priority", value: "\"not a number\"")
            rec.insert(tx: txn, key: "done",     value: "false")
        }

        XCTAssertNil(
            model.find(id: "t1"),
            "Type-mismatched field must cause typed init to fail gracefully"
        )
    }

    /// Dynamic + typed access must see the same data on the same doc —
    /// they share the underlying `_meta_*` and record Y.Maps.
    func testDynamicAndTypedShareUnderlyingStorage() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let typed = TypedModel<Task>(doc: doc)
        let dynamic = DynamicModel(doc: doc, schema: Task.primitiveSchema)

        _ = try typed.create(Task(id: "t1", title: "one", priority: 1, done: false))
        XCTAssertEqual(dynamic.find(id: "t1")?["title"], .string("one"))

        // And vice versa: write via dynamic, read via typed.
        _ = try dynamic.create(id: "t2", values: [
            "title":    .string("two"),
            "priority": .number(5),
            "done":     .boolean(true),
        ])
        let fromTyped = typed.find(id: "t2")
        XCTAssertEqual(fromTyped?.title, "two")
        XCTAssertEqual(fromTyped?.priority, 5)
        XCTAssertTrue(fromTyped?.done == true)
    }

    /// The typed model's `dynamic` accessor exposes the underlying
    /// DynamicModel for callers needing the escape hatch (snapshot,
    /// rawValue, unknown fields).
    func testDynamicEscapeHatchIsExposed() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = TypedModel<Task>(doc: doc)
        _ = try model.create(Task(id: "t1", title: "e", priority: 1, done: false))

        let dynamicRecord = model.dynamic.find(id: "t1")
        XCTAssertNotNil(dynamicRecord)
        XCTAssertEqual(dynamicRecord?["title"], .string("e"))
    }
}
