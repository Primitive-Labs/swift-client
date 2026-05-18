import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Tests `DynamicModel` model-level behaviors. Record-level CRUD is
/// covered in `PrimitiveRecordTests`; this file focuses on things
/// specific to opening / owning a model.
final class DynamicModelTests: XCTestCase {

    /// Opening a model automatically runs `SchemaSync.syncModelMeta`
    /// so `_meta_{name}` exists immediately after init.
    func testInitWritesMetaSchema() throws {
        let doc = YDocument()
        SchemaSync.clearCache()

        _ = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "todos",
            fields: ["title": FieldDescriptor(type: .string)]
        ))

        // Confirm _meta_todos exists with the field.
        let discovered = SchemaDiscovery.discoverSchema(
            doc: doc,
            modelNames: ["todos"]
        )
        XCTAssertEqual(discovered.models["todos"]?.fields["title"]?.type, .string)
    }

    /// Creating a record with an existing id updates (upserts) rather
    /// than duplicating.
    func testCreateWithExistingIdUpserts() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let schema = PrimitiveSchema(
            name: "items",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "name": FieldDescriptor(type: .string),
            ]
        )
        let model = DynamicModel(doc: doc, schema: schema)

        _ = try model.create(id: "i1", values: ["name": .string("first")])
        _ = try model.create(id: "i1", values: ["name": .string("second")])

        XCTAssertEqual(model.findAll().count, 1)
        XCTAssertEqual(model.find(id: "i1")?["name"], .string("second"))
    }

    /// Two models on the same doc use separate top-level maps and don't
    /// collide.
    func testMultipleModelsDoNotCollide() throws {
        let doc = YDocument()
        SchemaSync.clearCache()

        let users = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "users",
            fields: ["email": FieldDescriptor(type: .string)]
        ))
        let posts = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "posts",
            fields: ["title": FieldDescriptor(type: .string)]
        ))

        _ = try users.create(id: "u1", values: ["email": .string("a@b.c")])
        _ = try posts.create(id: "p1", values: ["title": .string("hi")])

        XCTAssertEqual(users.findAll().count, 1)
        XCTAssertEqual(posts.findAll().count, 1)
        XCTAssertEqual(users.find(id: "u1")?["email"], .string("a@b.c"))
        XCTAssertEqual(posts.find(id: "p1")?["title"], .string("hi"))
    }

    /// Re-opening a model on a doc that already has `_meta_*` is a no-op
    /// at the CRDT level — the state vector doesn't grow.
    func testReopeningExistingModelIsIdempotent() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let schema = PrimitiveSchema(
            name: "items",
            fields: ["name": FieldDescriptor(type: .string)]
        )
        _ = DynamicModel(doc: doc, schema: schema)
        let state1: Data = doc.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }

        // Clear cache so the second init doesn't short-circuit out; the
        // CRDT-level tryUpdate should still make it a no-op.
        SchemaSync.clearCache()
        _ = DynamicModel(doc: doc, schema: schema)
        let state2: Data = doc.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }

        XCTAssertEqual(
            state1, state2,
            "Reopening an existing model must not emit new CRDT updates"
        )
    }
}
