import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Tests `PrimitiveRecord` — the dynamic per-record wrapper around an
/// inner Y.Map. Identity is the Y.Map itself (important for Work Item 2
/// per-record observation).
final class PrimitiveRecordTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "tasks",
        fields: [
            "id":       FieldDescriptor(type: .id),
            "title":    FieldDescriptor(type: .string),
            "priority": FieldDescriptor(type: .number),
            "done":     FieldDescriptor(type: .boolean),
            "dueAt":    FieldDescriptor(type: .date),
        ]
    )

    // MARK: - Basic read / write

    func testCreateAndReadScalarFields() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        let record = try DynamicModel(doc: doc, schema: schema).create(id: "t1", values: [
            "title": .string("Buy milk"),
            "priority": .number(3),
            "done": .boolean(false),
            "dueAt": .date("2026-04-21T12:00:00Z"),
        ])

        XCTAssertEqual(record.id, "t1")
        XCTAssertEqual(record.modelName, "tasks")
        XCTAssertEqual(record["title"], .string("Buy milk"))
        XCTAssertEqual(record["priority"], .number(3))
        XCTAssertEqual(record["done"], .boolean(false))
        XCTAssertEqual(record["dueAt"], .date("2026-04-21T12:00:00Z"))
    }

    /// The record's `id` is also written as a field inside the nested map,
    /// matching js-bao's `extractItemData` contract. Without this, a JS
    /// reader silently drops the record from its SQLite mirror.
    func testRecordWritesIdFieldInsideNestedMap() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "t1", values: ["title": .string("hi")])

        // Reach into the Y.Map directly and confirm the "id" field is
        // present inside the nested record Y.Map.
        let rawId: String? = doc.transactSync { txn in
            let tasks = txn.transactionGetMap(name: "tasks")
            let rec = tasks?.getMap(tx: txn, key: "t1")
            return try? rec?.get(tx: txn, key: "id")
        }
        XCTAssertEqual(rawId, "\"t1\"")
    }

    // MARK: - Subscript assignment

    func testSubscriptAssignmentUpdatesField() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        let model = DynamicModel(doc: doc, schema: schema)
        let record = try model.create(id: "t1", values: ["title": .string("one")])

        record["title"] = .string("two")
        record["priority"] = .number(5)

        // Re-read from the model to confirm persistence.
        let fresh = model.find(id: "t1")
        XCTAssertEqual(fresh?["title"], .string("two"))
        XCTAssertEqual(fresh?["priority"], .number(5))
    }

    /// Setting a subscript to nil removes the field from the underlying map.
    func testSubscriptNilRemovesField() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        let model = DynamicModel(doc: doc, schema: schema)
        let record = try model.create(id: "t1", values: [
            "title": .string("gone soon"),
            "priority": .number(3),
        ])

        record["priority"] = nil
        XCTAssertNil(record["priority"])
        XCTAssertEqual(record["title"], .string("gone soon"))
    }

    // MARK: - Unknown-field preservation (the load-bearing property)

    /// If a record has a field Swift's schema doesn't know about, reading
    /// via snapshot() must still return it (raw), and a subsequent write
    /// of a DIFFERENT field must leave the unknown field intact.
    func testUnknownFieldSurvivesRoundTrip() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        // Simulate "another client wrote an unknown field" by writing it
        // directly against the raw Y.Map.
        doc.transactSync { txn in
            let tasks = txn.transactionGetOrInsertMap(name: "tasks")
            let rec = tasks.getOrInsertMap(tx: txn, key: "t1")
            rec.insert(tx: txn, key: "id",    value: "\"t1\"")
            rec.insert(tx: txn, key: "title", value: "\"hello\"")
            rec.insert(tx: txn, key: "experimentalFlag", value: "true")
        }

        let model = DynamicModel(doc: doc, schema: schema)
        let record = model.find(id: "t1")
        XCTAssertNotNil(record)
        XCTAssertTrue(record!.fieldNames().contains("experimentalFlag"),
                      "Unknown field must show up in fieldNames")
        XCTAssertEqual(record!.rawValue(for: "experimentalFlag"), "true")

        // Modify a known field; the unknown field must remain.
        record!["title"] = .string("world")

        let rawExperimental: String? = doc.transactSync { txn in
            let tasks = txn.transactionGetMap(name: "tasks")
            let rec = tasks?.getMap(tx: txn, key: "t1")
            return try? rec?.get(tx: txn, key: "experimentalFlag")
        }
        XCTAssertEqual(rawExperimental, "true",
                       "Unknown field must survive a write to a known field")
    }

    // MARK: - Find / list

    func testFindReturnsNilForUnknownId() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        let model = DynamicModel(doc: doc, schema: schema)
        XCTAssertNil(model.find(id: "not_there"))
    }

    func testFindAllReturnsAllRecords() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "t1", values: ["title": .string("one")])
        _ = try model.create(id: "t2", values: ["title": .string("two")])
        _ = try model.create(id: "t3", values: ["title": .string("three")])

        let ids = Set(model.findAll().map(\.id))
        XCTAssertEqual(ids, ["t1", "t2", "t3"])
    }

    // MARK: - Delete

    func testDeleteRemovesRecord() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "t1", values: ["title": .string("bye")])
        XCTAssertNotNil(model.find(id: "t1"))

        model.delete(id: "t1")
        XCTAssertNil(model.find(id: "t1"))
    }

    // MARK: - Defaults from schema

    /// When the schema specifies a function default for a field, creating
    /// a record without supplying that field auto-populates it from the
    /// registered generator (e.g. `$generate_ulid` → ULID).
    func testCreateAppliesFunctionDefault() throws {
        let fieldSchema = PrimitiveSchema(
            name: "things",
            fields: [
                "id": FieldDescriptor(
                    type: .id,
                    autoAssign: true,
                    default: .function(name: "generate_ulid")
                ),
                "name": FieldDescriptor(type: .string),
            ]
        )

        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncModelMeta(doc: doc, schema: fieldSchema)

        let model = DynamicModel(doc: doc, schema: fieldSchema)
        // Don't supply id — it should be auto-generated.
        let record = try model.create(values: ["name": .string("hi")])
        XCTAssertEqual(record.id.count, 26, "Auto-assigned ULID must be 26 chars")
        XCTAssertEqual(record["name"], .string("hi"))
    }

    /// Scalar defaults apply when the caller omits the field.
    func testCreateAppliesScalarDefault() throws {
        let fieldSchema = PrimitiveSchema(
            name: "counters",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "count": FieldDescriptor(type: .number, default: .scalar(.number(0))),
            ]
        )

        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncModelMeta(doc: doc, schema: fieldSchema)

        let model = DynamicModel(doc: doc, schema: fieldSchema)
        let record = try model.create(id: "c1", values: [:])
        XCTAssertEqual(record["count"], .number(0))
    }
}
