import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// End-to-end acceptance tests covering the explicit criteria in the
/// Work Item 1 plan:
///
///   1. **Round-trip: Swift → Swift via update bytes** (proxy for
///      cross-platform — wire format survives serialize/deserialize, so
///      js-bao reading the same bytes will see the same structure).
///   2. **Schema-less doc** — JS-style "no _meta_*" docs are still
///      discoverable.
///   3. **Unknown-field preservation** — fields the typed schema doesn't
///      know about survive a write to a different field.
///   4. **Drift survival** — typed getter returns nil; dynamic raw value
///      is still readable.
///   5. **Function default resolution** — `$generate_ulid` produces a
///      ULID at create time.
///   6. **Idempotent + additive schemaSync** — repeat sync is a no-op
///      and never deletes existing keys.
final class SchemaAcceptanceTests: XCTestCase {

    private let candidateNames = ["users", "items", "todos", "things"]

    // MARK: - 1. Wire-format survives serialize/deserialize

    /// Swift writes a model and serializes the doc to update bytes;
    /// a fresh doc applies those bytes; discoverSchema on the fresh doc
    /// returns the same `PrimitiveSchema`. This is the proxy test for
    /// "any other client can read what Swift wrote": the wire bytes are
    /// the contract and they survive a full round-trip through
    /// `encodeStateAsUpdate` / `applyUpdate`.
    func testRoundTripPreservesEverything() throws {
        let src = YDocument()
        SchemaSync.clearCache()
        let written = PrimitiveSchema(
            name: "users",
            fields: [
                "id":       FieldDescriptor(type: .id, indexed: true, autoAssign: true,
                                            default: .function(name: "generate_ulid")),
                "email":    FieldDescriptor(type: .string, unique: true),
                "name":     FieldDescriptor(type: .string),
                "tags":     FieldDescriptor(type: .stringset, maxLength: 64, maxCount: 8),
                "joined":   FieldDescriptor(type: .date, required: true),
                "active":   FieldDescriptor(type: .boolean, default: .scalar(.boolean(true))),
                "score":    FieldDescriptor(type: .number, default: .scalar(.number(0))),
            ],
            constraints: [
                "uq_email_active": ConstraintDescriptor(
                    name: "uq_email_active",
                    fields: ["email", "active"]
                ),
            ],
            relationships: [
                "posts": .hasMany(model: "posts", relatedIdField: "userId",
                                  orderByField: "createdAt", orderDirection: "DESC"),
            ]
        )
        SchemaSync.syncModelMeta(doc: src, schema: written)

        // Serialize → deserialize round-trip
        let updateBytes: Data = src.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }
        let dst = YDocument()
        dst.transactSync { txn in
            _ = try? txn.transactionApplyUpdate(update: Array(updateBytes))
        }

        let discovered = SchemaDiscovery.discoverSchema(
            doc: dst,
            modelNames: candidateNames + ["users"]
        ).models["users"]
        XCTAssertNotNil(discovered)
        XCTAssertEqual(discovered?.fields.count, written.fields.count)
        for (name, expected) in written.fields {
            XCTAssertEqual(
                discovered?.fields[name],
                expected,
                "Field \(name) lost across update round-trip"
            )
        }
        XCTAssertEqual(discovered?.constraints["uq_email_active"]?.fields,
                       ["email", "active"])
        XCTAssertEqual(discovered?.relationships["posts"]?.type, "hasMany")
        XCTAssertEqual(discovered?.relationships["posts"]?.properties["orderDirection"],
                       "DESC")
    }

    // MARK: - 2. Schema-less docs

    /// A doc populated with only record data (no _meta_*) — Swift infers
    /// field types from the records.
    func testSchemaLessDocIsDiscoverable() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        doc.transactSync { txn in
            let todos = txn.transactionGetOrInsertMap(name: "todos")
            for (i, title) in ["a", "b", "c"].enumerated() {
                let rec = todos.getOrInsertMap(tx: txn, key: "t\(i)")
                rec.insert(tx: txn, key: "title", value: PrimitiveValue.jsonEncodeString(title))
                rec.insert(tx: txn, key: "done",  value: "false")
            }
        }

        let discovered = SchemaDiscovery.discoverSchema(doc: doc, modelNames: ["todos"])
        XCTAssertEqual(discovered.models["todos"]?.fields["title"]?.type, .string)
        XCTAssertEqual(discovered.models["todos"]?.fields["done"]?.type, .boolean)
    }

    // MARK: - 3. Unknown-field preservation

    /// Plan acceptance criterion: "JS writes a record with a field
    /// Swift's codegen doesn't know about. Swift reads the record (sees
    /// it via PrimitiveRecord escape hatch), modifies a different field,
    /// writes back. JS reads the record and still sees the unknown field
    /// unchanged."
    func testUnknownFieldSurvivesSwiftSideEdit() throws {
        let doc = YDocument()
        SchemaSync.clearCache()

        // Schema knows {id, name}; data has an extra "experimentalFlag".
        let schema = PrimitiveSchema(
            name: "items",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "name": FieldDescriptor(type: .string),
            ]
        )
        SchemaSync.syncModelMeta(doc: doc, schema: schema)
        doc.transactSync { txn in
            let items = txn.transactionGetOrInsertMap(name: "items")
            let rec = items.getOrInsertMap(tx: txn, key: "i1")
            rec.insert(tx: txn, key: "id",   value: "\"i1\"")
            rec.insert(tx: txn, key: "name", value: "\"old\"")
            rec.insert(tx: txn, key: "experimentalFlag", value: "true")
        }

        let model = DynamicModel(doc: doc, schema: schema)
        let record = model.find(id: "i1")
        record?["name"] = .string("new")

        // The unknown field must still be present and unchanged.
        XCTAssertEqual(record?.rawValue(for: "experimentalFlag"), "true")
    }

    // MARK: - 4. Drift: typed getter returns nil; dynamic accessor still works

    func testTypedAccessReturnsNilOnDriftButDynamicWorks() throws {
        struct Item: PrimitiveModel, Equatable {
            static let modelName = "drift_items"
            static let primitiveSchema = PrimitiveSchema(
                name: "drift_items",
                fields: [
                    "id":    FieldDescriptor(type: .id),
                    "count": FieldDescriptor(type: .number),
                ]
            )
            var id: String
            var count: Double

            init(id: String, count: Double) {
                self.id = id; self.count = count
            }
            init?(record: PrimitiveRecord) {
                guard let n = record["count"]?.asNumber else { return nil }
                self.id = record.id
                self.count = n
            }
            func primitiveValues() -> [String: PrimitiveValue] {
                ["count": .number(count)]
            }
        }

        let doc = YDocument()
        SchemaSync.clearCache()
        let typed = TypedModel<Item>(doc: doc)

        // Seed with a string in the count field — drift.
        doc.transactSync { txn in
            let m = txn.transactionGetOrInsertMap(name: "drift_items")
            let r = m.getOrInsertMap(tx: txn, key: "i1")
            r.insert(tx: txn, key: "id",    value: "\"i1\"")
            r.insert(tx: txn, key: "count", value: "\"oops\"")
        }

        // Typed access fails gracefully.
        XCTAssertNil(typed.find(id: "i1"),
                     "Typed getter must return nil on type drift")

        // Dynamic raw access still works — the escape hatch.
        let dynRecord = typed.dynamic.find(id: "i1")
        XCTAssertEqual(dynRecord?.rawValue(for: "count"), "\"oops\"")
    }

    // MARK: - 5. Function default resolution

    func testFunctionDefaultGeneratesUlidAtCreate() throws {
        let schema = PrimitiveSchema(
            name: "things",
            fields: [
                "id": FieldDescriptor(
                    type: .id,
                    autoAssign: true,
                    default: .function(name: "generate_ulid")
                )
            ]
        )
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)

        let r = try model.create(values: [:])
        XCTAssertEqual(r.id.count, 26, "generate_ulid must yield a 26-char ULID")
    }

    // MARK: - 6. Idempotent + additive schemaSync

    func testIdempotentAndAdditive() throws {
        let doc = YDocument()
        SchemaSync.clearCache()

        // Seed an extra "legacy_field" first so we can verify additivity.
        doc.transactSync { txn in
            let meta = txn.transactionGetOrInsertMap(name: "_meta_acceptance_items")
            let legacy = meta.getOrInsertMap(tx: txn, key: "legacy")
            legacy.insert(tx: txn, key: "type", value: "\"string\"")
        }

        let schema = PrimitiveSchema(
            name: "acceptance_items",
            fields: ["name": FieldDescriptor(type: .string)]
        )
        SchemaSync.syncModelMeta(doc: doc, schema: schema)
        let s1: Data = doc.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }

        // Repeat sync. Cache short-circuits, but even if cache is cleared
        // the CRDT-level tryUpdate keeps things idempotent.
        SchemaSync.clearCache()
        SchemaSync.syncModelMeta(doc: doc, schema: schema)
        let s2: Data = doc.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }
        XCTAssertEqual(s1, s2, "Repeat sync must produce no new updates")

        // The legacy field is still there.
        let discovered = SchemaDiscovery.discoverSchema(
            doc: doc,
            modelNames: ["acceptance_items"]
        ).models["acceptance_items"]
        XCTAssertNotNil(discovered?.fields["name"])
        XCTAssertNotNil(discovered?.fields["legacy"])
    }
}
