import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Tests `SchemaDiscovery.discoverSchema` — the read path that decodes
/// `_meta_*` YMaps back into `PrimitiveSchema` values.
///
/// The core contract: if a JS client can read the `_meta_*` maps Swift
/// writes, then Swift must be able to read them back into structurally
/// equivalent `PrimitiveSchema` values, and vice-versa.
///
/// Note on API shape: Yniffi's current FFI does not expose root-type
/// iteration (yrs `Doc.root_refs()` is not surfaced), so every public
/// `discoverSchema` call takes a list of candidate model names. Extending
/// the FFI to enumerate roots is tracked as follow-up work in the
/// YSwift fork; it's not required for Work Item 1 and the explicit-names
/// form is how most callers already know what they're looking for.
final class SchemaDiscoveryTests: XCTestCase {

    /// Grab-bag of names the individual tests use. Passing a superset is
    /// harmless: a name with no `_meta_*` and no data map simply yields
    /// no entry in the discovered result.
    private let candidateNames = [
        "users", "articles", "products", "posts", "items",
        "todos", "bookkeeping", "_bookkeeping",
    ]

    // MARK: - Round-trips within Swift

    func testDiscoverBasicModel() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let written = PrimitiveSchema(
            name: "users",
            fields: [
                "id":    FieldDescriptor(type: .id, indexed: true, autoAssign: true,
                                         default: .function(name: "generate_ulid")),
                "email": FieldDescriptor(type: .string, unique: true),
                "name":  FieldDescriptor(type: .string),
            ]
        )
        SchemaSync.syncModelMeta(doc: doc, schema: written)

        let discovered = SchemaDiscovery.discoverSchema(doc: doc, modelNames: candidateNames)
        XCTAssertEqual(discovered.models.count, 1)
        let users = discovered.models["users"]
        XCTAssertNotNil(users)
        XCTAssertEqual(users?.name, "users")
        XCTAssertEqual(users?.fields["id"]?.type, .id)
        XCTAssertTrue(users?.fields["id"]?.indexed == true)
        XCTAssertTrue(users?.fields["id"]?.autoAssign == true)
        XCTAssertEqual(users?.fields["id"]?.default, .function(name: "generate_ulid"))
        XCTAssertEqual(users?.fields["email"]?.type, .string)
        XCTAssertTrue(users?.fields["email"]?.unique == true)
        XCTAssertEqual(users?.fields["name"]?.type, .string)
    }

    /// Boolean flags NOT set on the wire must be reported as false.
    func testDiscoverTreatsMissingFlagsAsFalse() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncModelMeta(doc: doc, schema: PrimitiveSchema(
            name: "users",
            fields: ["email": FieldDescriptor(type: .string)]
        ))

        let email = SchemaDiscovery.discoverSchema(doc: doc, modelNames: candidateNames)
            .models["users"]?.fields["email"]
        XCTAssertFalse(email?.indexed ?? true)
        XCTAssertFalse(email?.unique ?? true)
        XCTAssertFalse(email?.required ?? true)
        XCTAssertFalse(email?.autoAssign ?? true)
    }

    func testDiscoverMaxLengthAndMaxCount() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncModelMeta(doc: doc, schema: PrimitiveSchema(
            name: "articles",
            fields: ["tags": FieldDescriptor(type: .stringset, maxLength: 64, maxCount: 10)]
        ))

        let tags = SchemaDiscovery.discoverSchema(doc: doc, modelNames: candidateNames)
            .models["articles"]?.fields["tags"]
        XCTAssertEqual(tags?.maxLength, 64)
        XCTAssertEqual(tags?.maxCount, 10)
    }

    func testDiscoverCompoundConstraint() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncModelMeta(doc: doc, schema: PrimitiveSchema(
            name: "products",
            fields: [
                "tenantId": FieldDescriptor(type: .string),
                "sku":      FieldDescriptor(type: .string),
            ],
            constraints: [
                "uq_tenant_sku": ConstraintDescriptor(
                    name: "uq_tenant_sku",
                    fields: ["tenantId", "sku"]
                )
            ]
        ))

        let products = SchemaDiscovery.discoverSchema(doc: doc, modelNames: candidateNames)
            .models["products"]
        XCTAssertEqual(products?.constraints["uq_tenant_sku"]?.type, "unique")
        XCTAssertEqual(products?.constraints["uq_tenant_sku"]?.fields, ["tenantId", "sku"])
    }

    func testDiscoverRelationships() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncModelMeta(doc: doc, schema: PrimitiveSchema(
            name: "posts",
            fields: ["id": FieldDescriptor(type: .id)],
            relationships: [
                "author": .refersTo(model: "users", relatedIdField: "userId"),
                "tags": .hasManyThrough(
                    model: "tags",
                    joinModel: "post_tags",
                    joinModelLocalField: "postId",
                    joinModelRelatedField: "tagId"
                ),
            ]
        ))

        let posts = SchemaDiscovery.discoverSchema(doc: doc, modelNames: candidateNames)
            .models["posts"]
        XCTAssertEqual(posts?.relationships["author"]?.type, "refersTo")
        XCTAssertEqual(posts?.relationships["author"]?.model, "users")
        XCTAssertEqual(posts?.relationships["author"]?.properties["relatedIdField"], "userId")
        XCTAssertEqual(posts?.relationships["tags"]?.type, "hasManyThrough")
        XCTAssertEqual(posts?.relationships["tags"]?.properties["joinModel"], "post_tags")
    }

    /// Full round-trip: write schema → discover → equal.
    func testFullRoundTripEquality() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let written = PrimitiveSchema(
            name: "users",
            fields: [
                "id":    FieldDescriptor(type: .id, autoAssign: true,
                                         default: .function(name: "generate_ulid")),
                "email": FieldDescriptor(type: .string, unique: true),
                "views": FieldDescriptor(type: .number, default: .scalar(.number(0))),
            ]
        )
        SchemaSync.syncModelMeta(doc: doc, schema: written)

        let discovered = SchemaDiscovery.discoverSchema(doc: doc, modelNames: candidateNames)
            .models["users"]
        XCTAssertEqual(discovered?.fields.count, written.fields.count)
        for (name, expected) in written.fields {
            XCTAssertEqual(
                discovered?.fields[name],
                expected,
                "Field \(name) round-trip mismatch"
            )
        }
    }

    // MARK: - Infer-on-missing fallback

    /// When a data map exists without `_meta_*`, Swift must infer field
    /// types from sampled record data — matching js-bao's fallback path.
    func testDiscoverInfersSchemaFromDataWithoutMeta() throws {
        let doc = YDocument()
        SchemaSync.clearCache()

        // Write a "todos" data map with records, but NO _meta_todos.
        doc.transactSync { txn in
            let todos = txn.transactionGetOrInsertMap(name: "todos")
            let rec = todos.getOrInsertMap(tx: txn, key: "todo_1")
            rec.insert(tx: txn, key: "title", value: "\"Buy milk\"")
            rec.insert(tx: txn, key: "done", value: "false")
            rec.insert(tx: txn, key: "priority", value: "3")
        }

        let schema = SchemaDiscovery.discoverSchema(doc: doc, modelNames: candidateNames)
        let todos = schema.models["todos"]
        XCTAssertNotNil(todos, "A data-only top-level map should be inferred")
        XCTAssertEqual(todos?.fields["title"]?.type, .string)
        XCTAssertEqual(todos?.fields["done"]?.type, .boolean)
        XCTAssertEqual(todos?.fields["priority"]?.type, .number)
    }

    /// Top-level keys starting with `_` (other than `_meta_*`) are ignored
    /// even when the caller explicitly names them.
    func testDiscoverIgnoresInternalPrefixedKeys() throws {
        let doc = YDocument()
        SchemaSync.clearCache()

        doc.transactSync { txn in
            let other = txn.transactionGetOrInsertMap(name: "_bookkeeping")
            other.insert(tx: txn, key: "note", value: "\"skip me\"")
        }

        let schema = SchemaDiscovery.discoverSchema(doc: doc, modelNames: candidateNames)
        XCTAssertNil(schema.models["_bookkeeping"])
        XCTAssertNil(schema.models["bookkeeping"])
    }

    /// If both `_meta_{name}` and `{name}` data exist, `_meta_` wins and
    /// inference is skipped for that model.
    func testDiscoverPrefersMetaOverInferredData() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncModelMeta(doc: doc, schema: PrimitiveSchema(
            name: "items",
            fields: ["name": FieldDescriptor(type: .string)]
        ))

        doc.transactSync { txn in
            let items = txn.transactionGetOrInsertMap(name: "items")
            let rec = items.getOrInsertMap(tx: txn, key: "r1")
            rec.insert(tx: txn, key: "price", value: "42")
        }

        let items = SchemaDiscovery.discoverSchema(doc: doc, modelNames: candidateNames)
            .models["items"]
        XCTAssertNotNil(items?.fields["name"])
        XCTAssertNil(items?.fields["price"])
    }

    // MARK: - AbstractType materialization after applyUpdate

    /// After a doc receives updates via `applyUpdate`, top-level share
    /// entries are `AbstractType` until `getMap(name:)` materializes them.
    /// `discoverSchema` must handle this transparently via `transactionGetMap`.
    func testDiscoverWorksAfterApplyUpdate() throws {
        let src = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncModelMeta(doc: src, schema: PrimitiveSchema(
            name: "users",
            fields: ["email": FieldDescriptor(type: .string)]
        ))

        let update: Data = src.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }

        let dest = YDocument()
        dest.transactSync { txn in
            _ = try? txn.transactionApplyUpdate(update: Array(update))
        }

        let discovered = SchemaDiscovery.discoverSchema(doc: dest, modelNames: candidateNames)
        XCTAssertEqual(discovered.models["users"]?.fields["email"]?.type, .string)
    }

    // MARK: - Empty doc

    func testDiscoverOnEmptyDocReturnsNoModels() throws {
        let doc = YDocument()
        let schema = SchemaDiscovery.discoverSchema(doc: doc, modelNames: candidateNames)
        XCTAssertTrue(schema.models.isEmpty)
    }

    /// Names the caller doesn't include are simply not in the result.
    func testDiscoverSkipsUnnamedModels() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncModelMeta(doc: doc, schema: PrimitiveSchema(
            name: "hidden",
            fields: ["x": FieldDescriptor(type: .string)]
        ))

        // modelNames doesn't include "hidden" → not discovered.
        let schema = SchemaDiscovery.discoverSchema(doc: doc, modelNames: ["users"])
        XCTAssertTrue(schema.models.isEmpty)
    }
}
