import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Tests `SchemaSync.syncModelMeta` — the byte-for-byte wire-format
/// writer. Every assertion here mirrors a property of js-bao's
/// `syncModelMeta` in `/src/models/metaSync.ts` so Swift-authored docs
/// are indistinguishable from JS-authored ones as seen by
/// `discoverSchema`.
///
/// These tests use an in-process `YDocument` — no dev server required.
final class SchemaSyncTests: XCTestCase {

    // MARK: - Helpers

    /// Read the JSON form of a scalar value stored at `key` inside the
    /// Y.Map reachable by the path. Returns the raw JSON string the Yrs
    /// FFI hands back (e.g. `"\"string\""`, `"42"`, `"true"`).
    ///
    /// Uses the tx-scoped `transactionGetMap` variant — `doc.getMap(name:)`
    /// takes yrs's non-reentrant write lock and deadlocks when called from
    /// inside an open `transactSync` block.
    private func rawValue(
        in doc: YDocument,
        mapPath: [String],
        key: String
    ) -> String? {
        return doc.transactSync { txn in
            guard let rootName = mapPath.first,
                  var current = txn.transactionGetMap(name: rootName) else { return nil }
            for step in mapPath.dropFirst() {
                guard let next = current.getMap(tx: txn, key: step) else { return nil }
                current = next
            }
            return try? current.get(tx: txn, key: key)
        }
    }

    private func hasChildMap(
        in doc: YDocument,
        mapPath: [String],
        childKey: String
    ) -> Bool {
        return doc.transactSync { txn in
            guard let rootName = mapPath.first,
                  var current = txn.transactionGetMap(name: rootName) else { return false }
            for step in mapPath.dropFirst() {
                guard let next = current.getMap(tx: txn, key: step) else { return false }
                current = next
            }
            return current.getMap(tx: txn, key: childKey) != nil
        }
    }

    private func mapKeys(
        in doc: YDocument,
        path: [String]
    ) -> Set<String> {
        return doc.transactSync { txn in
            guard let rootName = path.first,
                  var current = txn.transactionGetMap(name: rootName) else { return [] }
            for step in path.dropFirst() {
                guard let next = current.getMap(tx: txn, key: step) else { return [] }
                current = next
            }
            let collector = KeyCollector()
            current.keys(tx: txn, delegate: collector)
            return Set(collector.keys)
        }
    }

    private final class KeyCollector: YrsMapIteratorDelegate {
        var keys: [String] = []
        func call(value: String) { keys.append(value) }
    }

    /// Full CRDT state as raw update bytes. Used to verify an op was
    /// a true no-op: identical bytes before and after mean no new updates.
    private func fullStateBytes(_ doc: YDocument) -> Data {
        return doc.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }
    }

    // MARK: - Field metadata

    func testSyncWritesTopLevelMetaMap() throws {
        let doc = YDocument()
        let schema = PrimitiveSchema(
            name: "users",
            fields: ["id": FieldDescriptor(type: .id)]
        )
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        // _meta_users should exist and contain an "id" child map.
        XCTAssertTrue(hasChildMap(in: doc, mapPath: ["_meta_users"], childKey: "id"))
    }

    func testSyncAlwaysWritesTypeKey() throws {
        let doc = YDocument()
        let schema = PrimitiveSchema(
            name: "tags",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "name": FieldDescriptor(type: .string),
            ]
        )
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        XCTAssertEqual(
            rawValue(in: doc, mapPath: ["_meta_tags", "id"], key: "type"),
            "\"id\""
        )
        XCTAssertEqual(
            rawValue(in: doc, mapPath: ["_meta_tags", "name"], key: "type"),
            "\"string\""
        )
    }

    func testSyncOnlyWritesTruthyBooleanFlags() throws {
        let doc = YDocument()
        let schema = PrimitiveSchema(
            name: "users",
            fields: [
                "email": FieldDescriptor(
                    type: .string,
                    indexed: true,
                    unique: false,
                    required: true,
                    autoAssign: false
                ),
            ]
        )
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        let keys = mapKeys(in: doc, path: ["_meta_users", "email"])
        XCTAssertTrue(keys.contains("type"))
        XCTAssertTrue(keys.contains("indexed"))
        XCTAssertTrue(keys.contains("required"))
        XCTAssertFalse(keys.contains("unique"),
                       "False flags must not appear on the wire")
        XCTAssertFalse(keys.contains("autoAssign"),
                       "False flags must not appear on the wire")
    }

    func testSyncWritesMaxLengthAndMaxCount() throws {
        let doc = YDocument()
        let schema = PrimitiveSchema(
            name: "articles",
            fields: [
                "tags": FieldDescriptor(
                    type: .stringset,
                    maxLength: 64,
                    maxCount: 10
                ),
            ]
        )
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        XCTAssertEqual(
            rawValue(in: doc, mapPath: ["_meta_articles", "tags"], key: "maxLength"),
            "64"
        )
        XCTAssertEqual(
            rawValue(in: doc, mapPath: ["_meta_articles", "tags"], key: "maxCount"),
            "10"
        )
    }

    // MARK: - Defaults

    func testSyncWritesScalarDefault() throws {
        let doc = YDocument()
        let schema = PrimitiveSchema(
            name: "articles",
            fields: [
                "views": FieldDescriptor(
                    type: .number,
                    default: .scalar(.number(0))
                ),
            ]
        )
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        XCTAssertEqual(
            rawValue(in: doc, mapPath: ["_meta_articles", "views"], key: "default"),
            "0"
        )
    }

    func testSyncWritesStringDefault() throws {
        let doc = YDocument()
        let schema = PrimitiveSchema(
            name: "products",
            fields: [
                "tenantId": FieldDescriptor(
                    type: .string,
                    default: .scalar(.string(""))
                ),
            ]
        )
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        XCTAssertEqual(
            rawValue(in: doc, mapPath: ["_meta_products", "tenantId"], key: "default"),
            "\"\""
        )
    }

    /// Function defaults encode as the `"$<name>"` sentinel string.
    func testSyncWritesFunctionDefaultAsDollarName() throws {
        let doc = YDocument()
        let schema = PrimitiveSchema(
            name: "users",
            fields: [
                "id": FieldDescriptor(
                    type: .id,
                    autoAssign: true,
                    default: .function(name: "generate_ulid")
                ),
            ]
        )
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        XCTAssertEqual(
            rawValue(in: doc, mapPath: ["_meta_users", "id"], key: "default"),
            "\"$generate_ulid\""
        )
    }

    // MARK: - Compound constraints

    func testSyncWritesCompoundConstraintWithJsonEncodedFields() throws {
        let doc = YDocument()
        let schema = PrimitiveSchema(
            name: "unique_products",
            fields: [
                "tenantId": FieldDescriptor(type: .string, indexed: true),
                "sku":      FieldDescriptor(type: .string, indexed: true),
            ],
            constraints: [
                "uq_tenant_sku": ConstraintDescriptor(
                    name: "uq_tenant_sku",
                    fields: ["tenantId", "sku"]
                )
            ]
        )
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        // _constraints.uq_tenant_sku exists as a Y.Map
        XCTAssertTrue(hasChildMap(
            in: doc,
            mapPath: ["_meta_unique_products", "_constraints"],
            childKey: "uq_tenant_sku"
        ))

        // type = "unique"
        XCTAssertEqual(
            rawValue(in: doc,
                     mapPath: ["_meta_unique_products", "_constraints", "uq_tenant_sku"],
                     key: "type"),
            "\"unique\""
        )

        // fields = JSON-encoded string "[\"tenantId\",\"sku\"]"
        XCTAssertEqual(
            rawValue(in: doc,
                     mapPath: ["_meta_unique_products", "_constraints", "uq_tenant_sku"],
                     key: "fields"),
            "\"[\\\"tenantId\\\",\\\"sku\\\"]\""
        )
    }

    /// Single-field unique constraints belong on the field (`unique = true`)
    /// and do NOT appear in `_constraints`. Matches metaSync.ts:113-115.
    func testSyncSkipsSingleFieldUniqueFromConstraints() throws {
        let doc = YDocument()
        let schema = PrimitiveSchema(
            name: "users",
            fields: ["email": FieldDescriptor(type: .string, unique: true)]
        )
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        // email.unique = true
        XCTAssertEqual(
            rawValue(in: doc, mapPath: ["_meta_users", "email"], key: "unique"),
            "true"
        )
        // _constraints should NOT exist
        XCTAssertFalse(mapKeys(in: doc, path: ["_meta_users"]).contains("_constraints"))
    }

    // MARK: - Relationships

    func testSyncWritesRelationshipsRefersTo() throws {
        let doc = YDocument()
        let schema = PrimitiveSchema(
            name: "posts",
            fields: ["id": FieldDescriptor(type: .id)],
            relationships: [
                "author": .refersTo(model: "users", relatedIdField: "userId")
            ]
        )
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        XCTAssertTrue(hasChildMap(
            in: doc,
            mapPath: ["_meta_posts", "_relationships"],
            childKey: "author"
        ))
        XCTAssertEqual(
            rawValue(in: doc, mapPath: ["_meta_posts", "_relationships", "author"],
                     key: "type"),
            "\"refersTo\""
        )
        XCTAssertEqual(
            rawValue(in: doc, mapPath: ["_meta_posts", "_relationships", "author"],
                     key: "model"),
            "\"users\""
        )
        XCTAssertEqual(
            rawValue(in: doc, mapPath: ["_meta_posts", "_relationships", "author"],
                     key: "relatedIdField"),
            "\"userId\""
        )
    }

    func testSyncWritesRelationshipsHasManyWithOptionals() throws {
        let doc = YDocument()
        let schema = PrimitiveSchema(
            name: "users",
            fields: ["id": FieldDescriptor(type: .id)],
            relationships: [
                "posts": .hasMany(
                    model: "posts",
                    relatedIdField: "userId",
                    orderByField: "createdAt",
                    orderDirection: "DESC"
                )
            ]
        )
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        let keys = mapKeys(in: doc, path: ["_meta_users", "_relationships", "posts"])
        XCTAssertEqual(keys, ["type", "model", "relatedIdField", "orderByField", "orderDirection"])
    }

    func testSyncWritesRelationshipsHasManyThrough() throws {
        let doc = YDocument()
        let schema = PrimitiveSchema(
            name: "posts",
            fields: ["id": FieldDescriptor(type: .id)],
            relationships: [
                "tags": .hasManyThrough(
                    model: "tags",
                    joinModel: "post_tag_links",
                    joinModelLocalField: "postId",
                    joinModelRelatedField: "tagId"
                )
            ]
        )
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        let keys = mapKeys(in: doc, path: ["_meta_posts", "_relationships", "tags"])
        XCTAssertTrue(keys.contains("joinModel"))
        XCTAssertTrue(keys.contains("joinModelLocalField"))
        XCTAssertTrue(keys.contains("joinModelRelatedField"))
    }

    // MARK: - Idempotency and cache

    /// A second identical sync on the same doc must not grow the CRDT.
    /// Verifies js-bao's session-cache contract: repeat syncs are free.
    func testSyncIsIdempotentAcrossRepeatedCalls() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let schema = PrimitiveSchema(
            name: "items",
            fields: ["id": FieldDescriptor(type: .id, default: .function(name: "generate_ulid"))]
        )

        SchemaSync.syncModelMeta(doc: doc, schema: schema)
        let stateAfterFirst = fullStateBytes(doc)

        SchemaSync.syncModelMeta(doc: doc, schema: schema)
        let stateAfterSecond = fullStateBytes(doc)

        XCTAssertEqual(
            stateAfterFirst, stateAfterSecond,
            "Identical second sync must not emit additional CRDT updates"
        )
    }

    /// After `clearCache`, a repeat sync may still be a no-op because the
    /// underlying Y.Map is idempotent — but the function must not throw
    /// or corrupt the doc.
    func testSyncAfterClearCacheIsSafe() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let schema = PrimitiveSchema(
            name: "items",
            fields: ["id": FieldDescriptor(type: .id)]
        )
        SchemaSync.syncModelMeta(doc: doc, schema: schema)
        SchemaSync.clearCache(doc: doc)
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        // Still present and correct
        XCTAssertEqual(
            rawValue(in: doc, mapPath: ["_meta_items", "id"], key: "type"),
            "\"id\""
        )
    }

    /// Additive: fields already in _meta_* that Swift's schema doesn't know
    /// about must survive the sync.
    func testSyncPreservesPreExistingFields() throws {
        let doc = YDocument()
        SchemaSync.clearCache()

        // Pretend a "legacy" field was written by some other client first.
        doc.transactSync { txn in
            let meta = txn.transactionGetOrInsertMap(name: "_meta_items")
            let legacy = meta.getOrInsertMap(tx: txn, key: "legacy_field")
            legacy.insert(tx: txn, key: "type", value: "\"string\"")
        }

        // Swift's schema only knows about "id".
        let schema = PrimitiveSchema(
            name: "items",
            fields: ["id": FieldDescriptor(type: .id)]
        )
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        // Swift's field is written, legacy field is preserved.
        XCTAssertTrue(hasChildMap(in: doc, mapPath: ["_meta_items"], childKey: "id"))
        XCTAssertTrue(hasChildMap(in: doc, mapPath: ["_meta_items"], childKey: "legacy_field"))
        XCTAssertEqual(
            rawValue(in: doc, mapPath: ["_meta_items", "legacy_field"], key: "type"),
            "\"string\""
        )
    }
}
