import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// End-to-end Swift↔JS round-trip tests. Each test either
/// produces update bytes on one side and reads them on the other, or
/// vice-versa, using real js-bao code in a Node subprocess.
///
/// These catch wire-format regressions that the structural Swift-only
/// assertions can't, because both sides of the contract run here.
final class CrossPlatformRoundTripTests: XCTestCase {

    // MARK: - Swift writes → JS reads

    /// Swift authors a schema with every field type + all the metadata
    /// permutations; JS `discoverSchema` returns the exact same shape.
    func testSwiftWritesSchema_JsReadsDiscoverSchema() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let schema = PrimitiveSchema(
            name: "users",
            fields: [
                "id":       FieldDescriptor(type: .id, indexed: true, autoAssign: true,
                                            default: .function(name: "generate_ulid")),
                "email":    FieldDescriptor(type: .string, unique: true),
                "name":     FieldDescriptor(type: .string, required: true),
                "tags":     FieldDescriptor(type: .stringset, maxLength: 64, maxCount: 8),
                "joined":   FieldDescriptor(type: .date),
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
        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        let update = CrossPlatformHarness.updateBytes(of: doc)
        let result = try CrossPlatformHarness.runReader(
            update: update, arguments: ["discover-schema"]
        ) as? [String: Any]

        let users = (result?["models"] as? [String: Any])?["users"] as? [String: Any]
        let fields = users?["fields"] as? [String: Any]
        XCTAssertNotNil(fields)

        // Spot-check every field js-bao's discoverSchema rebuilds.
        XCTAssertEqual((fields?["id"] as? [String: Any])?["type"] as? String, "id")
        XCTAssertEqual((fields?["id"] as? [String: Any])?["autoAssign"] as? Bool, true)
        XCTAssertEqual((fields?["id"] as? [String: Any])?["default"] as? String,
                       "$generate_ulid",
                       "Function-default sentinel must survive into discoverSchema")
        XCTAssertEqual((fields?["email"] as? [String: Any])?["unique"] as? Bool, true)
        XCTAssertEqual((fields?["tags"] as? [String: Any])?["type"] as? String, "stringset")
        XCTAssertEqual((fields?["tags"] as? [String: Any])?["maxCount"] as? Int, 8)
        XCTAssertEqual((fields?["score"] as? [String: Any])?["default"] as? Int, 0)

        // Compound constraint: `fields` JSON-encoded string parsed into
        // string array by discoverSchema.
        let constraints = users?["constraints"] as? [String: Any]
        let fieldsArr = (constraints?["uq_email_active"] as? [String: Any])?["fields"]
            as? [String]
        XCTAssertEqual(fieldsArr, ["email", "active"])

        // Relationship keys all pass through.
        let rels = users?["relationships"] as? [String: Any]
        let posts = rels?["posts"] as? [String: Any]
        XCTAssertEqual(posts?["type"] as? String, "hasMany")
        XCTAssertEqual(posts?["orderDirection"] as? String, "DESC")
    }

    /// Swift writes record data; JS reads raw field values. Every scalar
    /// wire representation must match js-bao's expectations: strings as
    /// strings, numbers as numbers, booleans as booleans, dates as ISO
    /// strings, stringsets as nested Y.Maps keyed by the set members.
    func testSwiftWritesRecord_JsReadsScalars() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let schema = PrimitiveSchema(
            name: "things",
            fields: [
                "id":     FieldDescriptor(type: .id),
                "title":  FieldDescriptor(type: .string),
                "count":  FieldDescriptor(type: .number),
                "done":   FieldDescriptor(type: .boolean),
                "at":     FieldDescriptor(type: .date),
                "tags":   FieldDescriptor(type: .stringset),
            ]
        )
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "r1", values: [
            "title":  .string("hello, \"world\""),
            "count":  .number(42),
            "done":   .boolean(true),
            "at":     .date("2026-04-22T12:00:00Z"),
            "tags":   .stringset(["swift", "yrs"]),
        ])

        let update = CrossPlatformHarness.updateBytes(of: doc)
        let rec = try CrossPlatformHarness.runReader(
            update: update, arguments: ["read-record", "things", "r1"]
        ) as? [String: Any]
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?["id"] as? String, "r1")
        XCTAssertEqual(rec?["title"] as? String, "hello, \"world\"")
        XCTAssertEqual(rec?["count"] as? Int, 42)
        XCTAssertEqual(rec?["done"] as? Bool, true)
        XCTAssertEqual(rec?["at"] as? String, "2026-04-22T12:00:00Z")

        let tags = rec?["tags"] as? [String: Any]
        XCTAssertEqual(tags?["_type"] as? String, "stringset")
        XCTAssertEqual((tags?["entries"] as? [String])?.sorted(), ["swift", "yrs"])
    }

    /// Swift-side unique constraint: the `_uniqueIdx_*` map is visible
    /// to JS under the exact name and shape js-bao expects.
    func testSwiftWritesUniqueIndex_JsReadsIt() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let schema = PrimitiveSchema(
            name: "users_ix",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "email": FieldDescriptor(type: .string, unique: true),
            ]
        )
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "u1", values: ["email": .string("a@b.c")])

        let update = CrossPlatformHarness.updateBytes(of: doc)
        let index = try CrossPlatformHarness.runReader(
            update: update,
            arguments: ["read-unique-index", "users_ix", "users_ix_email_unique"]
        ) as? [String: Any]
        XCTAssertEqual(index?["a@b.c"] as? String, "u1",
                       "JS must see Swift's `_uniqueIdx_*` entry verbatim")
    }

    // MARK: - JS writes → Swift reads

    /// JS authors a schema using real `syncModelMeta`; Swift's
    /// `SchemaDiscovery` rebuilds the same `PrimitiveSchema`.
    func testJsWritesSchema_SwiftReadsDiscoverSchema() throws {
        let spec: [String: Any] = [
            "schemas": [[
                "name": "posts",
                "fields": [
                    "id":    ["type": "id", "autoAssign": true,
                              "default": "$generate_ulid"],
                    "title": ["type": "string", "required": true],
                    "views": ["type": "number", "default": 0],
                    "tags":  ["type": "stringset", "maxCount": 5],
                ],
                "relationships": [
                    "author": [
                        "type": "refersTo",
                        "model": "users",
                        "relatedIdField": "userId",
                    ],
                ],
            ]],
        ]
        let update = try CrossPlatformHarness.runWriter(spec: spec)

        let doc = YDocument()
        try CrossPlatformHarness.apply(update: update, to: doc)

        let discovered = SchemaDiscovery.discoverSchema(
            doc: doc, modelNames: ["posts"]
        ).models["posts"]
        XCTAssertNotNil(discovered)
        XCTAssertEqual(discovered?.fields["id"]?.type, .id)
        XCTAssertTrue(discovered?.fields["id"]?.autoAssign == true)
        XCTAssertEqual(discovered?.fields["id"]?.default,
                       .function(name: "generate_ulid"))
        XCTAssertEqual(discovered?.fields["title"]?.type, .string)
        XCTAssertTrue(discovered?.fields["title"]?.required == true)
        XCTAssertEqual(discovered?.fields["views"]?.type, .number)
        XCTAssertEqual(discovered?.fields["views"]?.default,
                       .scalar(.number(0)))
        XCTAssertEqual(discovered?.fields["tags"]?.type, .stringset)
        XCTAssertEqual(discovered?.fields["tags"]?.maxCount, 5)
        XCTAssertEqual(discovered?.relationships["author"]?.type, "refersTo")
        XCTAssertEqual(discovered?.relationships["author"]?.properties["relatedIdField"],
                       "userId")
    }

    /// JS writes a record with every scalar type + a stringset; Swift
    /// reads it via DynamicModel and sees the same values back.
    func testJsWritesRecord_SwiftReadsAllFieldTypes() throws {
        let schema = PrimitiveSchema(
            name: "items",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "title": FieldDescriptor(type: .string),
                "count": FieldDescriptor(type: .number),
                "done":  FieldDescriptor(type: .boolean),
                "at":    FieldDescriptor(type: .date),
                "tags":  FieldDescriptor(type: .stringset),
            ]
        )
        let spec: [String: Any] = [
            "schemas": [[
                "name":   "items",
                "fields": [
                    "id":    ["type": "id"],
                    "title": ["type": "string"],
                    "count": ["type": "number"],
                    "done":  ["type": "boolean"],
                    "at":    ["type": "date"],
                    "tags":  ["type": "stringset"],
                ],
            ]],
            "records": [
                "items": [
                    "r1": [
                        "title": "hi",
                        "count": 7,
                        "done":  false,
                        "at":    "2026-04-22T08:00:00Z",
                        "tags":  ["_type": "stringset", "entries": ["a", "b"]],
                    ],
                ],
            ],
        ]
        let update = try CrossPlatformHarness.runWriter(spec: spec)
        let doc = YDocument()
        try CrossPlatformHarness.apply(update: update, to: doc)

        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)
        let rec = model.find(id: "r1")
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?["title"], .string("hi"))
        XCTAssertEqual(rec?["count"], .number(7))
        XCTAssertEqual(rec?["done"], .boolean(false))
        XCTAssertEqual(rec?["at"], .date("2026-04-22T08:00:00Z"))
        XCTAssertEqual(rec?["tags"], .stringset(["a", "b"]))
    }

    /// JS seeds a `_uniqueIdx_*` entry; Swift's enforcement path
    /// observes the entry and refuses a conflicting create.
    func testJsWritesUniqueIndex_SwiftEnforcesIt() throws {
        let spec: [String: Any] = [
            "schemas": [[
                "name": "users_xu",
                "fields": [
                    "id":    ["type": "id"],
                    "email": ["type": "string", "unique": true],
                ],
            ]],
            "records": [
                "users_xu": [
                    "u1": ["email": "a@b.c"],
                ],
            ],
            "uniqueIndexes": [
                "_uniqueIdx_users_xu_users_xu_email_unique": ["a@b.c": "u1"],
            ],
        ]
        let update = try CrossPlatformHarness.runWriter(spec: spec)
        let doc = YDocument()
        try CrossPlatformHarness.apply(update: update, to: doc)

        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "users_xu",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "email": FieldDescriptor(type: .string, unique: true),
            ]
        ))

        XCTAssertThrowsError(
            try model.create(id: "u2", values: ["email": .string("a@b.c")])
        ) { error in
            guard let v = error as? UniqueConstraintViolationError else {
                return XCTFail("Expected violation, got \(error)")
            }
            XCTAssertEqual(v.existingRecordId, "u1",
                           "Swift must surface the JS-written owning id")
        }
    }

    // MARK: - Byte-level raw-meta snapshot

    /// Structural byte-level check: the JSON js-bao sees inside
    /// `_meta_*` after a Swift write must be shape-equal to what
    /// js-bao's own writer would produce for the same schema.
    func testSwiftMetaMatchesJsMetaShape() throws {
        // Swift writes.
        let doc1 = YDocument()
        SchemaSync.clearCache()
        let schema = PrimitiveSchema(
            name: "shared",
            fields: [
                "id":    FieldDescriptor(type: .id, autoAssign: true,
                                         default: .function(name: "generate_ulid")),
                "email": FieldDescriptor(type: .string, unique: true),
                "tags":  FieldDescriptor(type: .stringset, maxCount: 3),
            ],
            constraints: [
                "uq_email_tags": ConstraintDescriptor(
                    name: "uq_email_tags",
                    fields: ["email", "tags"]
                ),
            ]
        )
        SchemaSync.syncModelMeta(doc: doc1, schema: schema)
        let swiftMeta = try CrossPlatformHarness.runReader(
            update: CrossPlatformHarness.updateBytes(of: doc1),
            arguments: ["raw-meta", "shared"]
        ) as? [String: Any]

        // JS writes the same schema.
        let spec: [String: Any] = [
            "schemas": [[
                "name": "shared",
                "fields": [
                    "id":    ["type": "id", "autoAssign": true,
                              "default": "$generate_ulid"],
                    "email": ["type": "string", "unique": true],
                    "tags":  ["type": "stringset", "maxCount": 3],
                ],
                "uniqueConstraints": [
                    ["name": "uq_email_tags", "fields": ["email", "tags"]],
                ],
            ]],
        ]
        let jsUpdate = try CrossPlatformHarness.runWriter(spec: spec)
        let doc2 = YDocument()
        try CrossPlatformHarness.apply(update: jsUpdate, to: doc2)
        let jsMeta = try CrossPlatformHarness.runReader(
            update: CrossPlatformHarness.updateBytes(of: doc2),
            arguments: ["raw-meta", "shared"]
        ) as? [String: Any]

        // Normalize both sides to JSON strings and compare. This
        // catches any divergence in key names or encoding choices.
        let swiftJson = try JSONSerialization.data(
            withJSONObject: normalize(swiftMeta ?? [:]), options: [.sortedKeys]
        )
        let jsJson = try JSONSerialization.data(
            withJSONObject: normalize(jsMeta ?? [:]), options: [.sortedKeys]
        )
        XCTAssertEqual(
            String(data: swiftJson, encoding: .utf8),
            String(data: jsJson, encoding: .utf8),
            "Swift-written `_meta_*` must match JS-written `_meta_*` byte-level"
        )
    }

    /// Recursively sort arrays for deterministic comparison (js-bao
    /// emits relationship / constraint keys in insertion order; Swift
    /// iteration order is nondeterministic — both are semantically
    /// equivalent after normalization).
    private func normalize(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = normalize(v) }
            return out
        }
        if let arr = value as? [Any] {
            let normalized = arr.map(normalize)
            // Sort by JSON representation for determinism.
            let strings = normalized.compactMap {
                (try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) }
            }
            if strings.count == normalized.count {
                let paired = zip(strings, normalized).sorted { $0.0 < $1.0 }
                return paired.map { $0.1 }
            }
            return normalized
        }
        return value
    }
}
