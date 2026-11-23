import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Tests runtime enforcement of unique constraints via `_uniqueIdx_*`
/// Y.Maps in the doc, matching js-bao's `BaseModel.save` mechanism.
///
/// Mechanism (from `js-bao/src/models/BaseModel.ts` save path):
/// 1. Each constraint gets a top-level Y.Map named
///    `_uniqueIdx_{modelName}_{constraintName}`.
/// 2. Each entry maps a unique key → the record id that owns it.
/// 3. On save, build the new unique key; look it up in the index map; if
///    an entry exists for a DIFFERENT record id, throw.
/// 4. On update (unique field changed), delete the old key.
/// 5. On delete, remove all `_uniqueIdx_*` entries that point to this
///    record.
/// 6. Null/undefined in ANY field of a compound constraint → key is nil
///    → no index entry is written and no enforcement is applied. This is
///    the intentional SQL-style "NULL != NULL" behavior js-bao uses.
/// 7. Single-field key is `String(value)`; compound is `JSON.stringify`.
///
/// Resolved constraints include both synthetic single-field (from
/// `unique: true`) and the explicit compound constraints. Only compound
/// go into `_meta_*._constraints`; both are enforced at runtime.
///
/// Server-free (every case is an in-memory `YDocument`), so it is named into
/// the `*HermeticTests` lane `swift test --filter HermeticTests` runs.
final class UniqueConstraintEnforcementHermeticTests: XCTestCase {

    // MARK: - Single-field uniqueness

    func testCreateDuplicateSingleFieldUniqueThrows() throws {
        let schema = PrimitiveSchema(
            name: "users_uq_s",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "email": FieldDescriptor(type: .string, unique: true),
            ]
        )
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)

        _ = try model.create(id: "u1", values: ["email": .string("a@b.c")])
        XCTAssertThrowsError(
            try model.create(id: "u2", values: ["email": .string("a@b.c")])
        ) { error in
            guard let violation = error as? UniqueConstraintViolationError else {
                return XCTFail("Expected UniqueConstraintViolationError, got \(error)")
            }
            XCTAssertEqual(violation.modelName, "users_uq_s")
            XCTAssertEqual(violation.fields, ["email"])
            XCTAssertEqual(violation.existingRecordId, "u1")
            XCTAssertEqual(violation.attemptedRecordId, "u2")
        }
    }

    /// The same record re-saving its own unique value is NOT a violation.
    func testUpdateKeepingSameUniqueValueIsOk() throws {
        let schema = PrimitiveSchema(
            name: "users_uq_self",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "email": FieldDescriptor(type: .string, unique: true),
            ]
        )
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)

        _ = try model.create(id: "u1", values: ["email": .string("a@b.c")])
        XCTAssertNoThrow(
            try model.update(id: "u1", values: ["email": .string("a@b.c")])
        )
    }

    /// Changing a unique field to a value held by a different record throws.
    func testUpdateToDuplicateUniqueThrows() throws {
        let schema = PrimitiveSchema(
            name: "users_uq_upd",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "email": FieldDescriptor(type: .string, unique: true),
            ]
        )
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "u1", values: ["email": .string("a@b.c")])
        _ = try model.create(id: "u2", values: ["email": .string("x@y.z")])

        XCTAssertThrowsError(
            try model.update(id: "u2", values: ["email": .string("a@b.c")])
        )
    }

    /// Changing a unique field releases the OLD key for reuse.
    func testUpdateReleasesOldUniqueKey() throws {
        let schema = PrimitiveSchema(
            name: "users_uq_rel",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "email": FieldDescriptor(type: .string, unique: true),
            ]
        )
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "u1", values: ["email": .string("old@a.b")])
        _ = try model.update(id: "u1", values: ["email": .string("new@a.b")])

        // u1 no longer holds "old@a.b" → creating u2 with it is fine.
        XCTAssertNoThrow(
            try model.create(id: "u2", values: ["email": .string("old@a.b")])
        )
    }

    /// Deleting a record frees its unique keys.
    func testDeleteClearsUniqueIndex() throws {
        let schema = PrimitiveSchema(
            name: "users_uq_del",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "email": FieldDescriptor(type: .string, unique: true),
            ]
        )
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "u1", values: ["email": .string("a@b.c")])
        model.delete(id: "u1")

        XCTAssertNoThrow(
            try model.create(id: "u2", values: ["email": .string("a@b.c")])
        )
    }

    // MARK: - Compound uniqueness

    func testCompoundUniqueEnforcesAllFieldsCombined() throws {
        let schema = PrimitiveSchema(
            name: "products_c",
            fields: [
                "id":       FieldDescriptor(type: .id),
                "tenantId": FieldDescriptor(type: .string),
                "sku":      FieldDescriptor(type: .string),
            ],
            constraints: [
                "uq_tenant_sku": ConstraintDescriptor(
                    name: "uq_tenant_sku",
                    fields: ["tenantId", "sku"]
                )
            ]
        )
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)

        _ = try model.create(id: "p1", values: [
            "tenantId": .string("t1"), "sku": .string("A"),
        ])

        // Same tenantId with different sku: OK.
        XCTAssertNoThrow(try model.create(id: "p2", values: [
            "tenantId": .string("t1"), "sku": .string("B"),
        ]))
        // Different tenantId with same sku: OK.
        XCTAssertNoThrow(try model.create(id: "p3", values: [
            "tenantId": .string("t2"), "sku": .string("A"),
        ]))
        // Same tenantId+sku: throws.
        XCTAssertThrowsError(try model.create(id: "p4", values: [
            "tenantId": .string("t1"), "sku": .string("A"),
        ]))
    }

    // MARK: - Wire format: `_uniqueIdx_*` map structure

    /// Each enforced constraint gets a top-level Y.Map named
    /// `_uniqueIdx_{modelName}_{constraintName}`. Single-field keys are
    /// the value stringified; compound keys are JSON-encoded arrays.
    func testUniqueIndexMapHasCorrectNameAndKeyShape() throws {
        let schema = PrimitiveSchema(
            name: "products_ix",
            fields: [
                "id":       FieldDescriptor(type: .id),
                "tenantId": FieldDescriptor(type: .string),
                "sku":      FieldDescriptor(type: .string),
                "slug":     FieldDescriptor(type: .string, unique: true),
            ],
            constraints: [
                "uq_tenant_sku": ConstraintDescriptor(
                    name: "uq_tenant_sku",
                    fields: ["tenantId", "sku"]
                )
            ]
        )
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "p1", values: [
            "tenantId": .string("t1"),
            "sku":      .string("A"),
            "slug":     .string("hello"),
        ])

        // _uniqueIdx_products_ix_uq_tenant_sku has key JSON.stringify(["t1","A"])
        let compoundVal: String? = doc.transactSync { txn in
            let m = txn.transactionGetMap(name: "_uniqueIdx_products_ix_uq_tenant_sku")
            return try? m?.get(tx: txn, key: "[\"t1\",\"A\"]")
        }
        XCTAssertEqual(compoundVal, "\"p1\"",
                       "Compound index must store JSON-encoded record id")

        // Single-field unique (slug) lives at
        // _uniqueIdx_products_ix_products_ix_slug_unique per
        // resolveUniqueConstraints naming: "{modelName}_{fieldName}_unique".
        let singleVal: String? = doc.transactSync { txn in
            let m = txn.transactionGetMap(name: "_uniqueIdx_products_ix_products_ix_slug_unique")
            return try? m?.get(tx: txn, key: "hello")
        }
        XCTAssertEqual(singleVal, "\"p1\"",
                       "Single-field index must store record id at raw-String key")
    }

    // MARK: - Null semantics: no enforcement over nulls

    /// Per js-bao: if any field of a compound constraint is null/missing,
    /// the key is null and no index entry is written. Two records both
    /// missing the same field are NOT a conflict.
    func testMissingFieldDisablesEnforcement() throws {
        let schema = PrimitiveSchema(
            name: "opt_unique",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "slug": FieldDescriptor(type: .string, unique: true),
            ]
        )
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)

        // Neither supplies `slug`.
        XCTAssertNoThrow(try model.create(id: "a", values: [:]))
        XCTAssertNoThrow(try model.create(id: "b", values: [:]))
    }

    /// Compound: one field missing on both records — not a conflict.
    func testCompoundWithMissingFieldDisablesEnforcement() throws {
        let schema = PrimitiveSchema(
            name: "opt_compound",
            fields: [
                "id": FieldDescriptor(type: .id),
                "a":  FieldDescriptor(type: .string),
                "b":  FieldDescriptor(type: .string),
            ],
            constraints: [
                "uq_ab": ConstraintDescriptor(name: "uq_ab", fields: ["a", "b"])
            ]
        )
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)

        // Both records omit "b" — compound key is null → no enforcement.
        XCTAssertNoThrow(try model.create(id: "r1", values: ["a": .string("x")]))
        XCTAssertNoThrow(try model.create(id: "r2", values: ["a": .string("x")]))
    }

    // MARK: - Cross-language compound keys (#3720)

    /// values → key. The same rows, as literals, as
    /// `tests/client/js-bao-unique-compound-key-3720.test.ts` asserts against
    /// `JSON.stringify` and the shared `buildUniqueKey` the server uses. A row
    /// that differs here is a pair the server and the JS client cannot see.
    private static let compoundKeyFixtures: [([PrimitiveValue], String)] = [
        ([.string("acme"), .string("billing")], #"["acme","billing"]"#),
        ([.string("a|b"), .string("c")], #"["a|b","c"]"#),
        ([.string("q\"uote"), .string("back\\slash")], #"["q\"uote","back\\slash"]"#),
        ([.string("[x"), .string("y]")], #"["[x","y]"]"#),
        ([.string("n\nl"), .string("t\tb")], #"["n\nl","t\tb"]"#),
        ([.string("a\u{08}b"), .string("c\u{0C}d")], #"["a\bb","c\fd"]"#),
        ([.string("\u{01}"), .string("é")], #"["\u0001","é"]"#),
        ([.number(1), .boolean(true)], "[1,true]"),
        ([.number(1.5), .string("x")], #"[1.5,"x"]"#),
    ]

    private static func fieldType(of value: PrimitiveValue) -> PrimitiveFieldType {
        switch value {
        case .number: return .number
        case .boolean: return .boolean
        default: return .string
        }
    }

    func testCompoundKeyEscapesMatchJsonStringify() throws {
        for (row, (values, expected)) in Self.compoundKeyFixtures.enumerated() {
            let fields = ["a", "b"]
            let byField = Dictionary(uniqueKeysWithValues: zip(fields, values))
            XCTAssertEqual(UniqueIndex.buildKey(fields: fields, values: byField), expected,
                           "row \(row): buildKey")

            let schema = PrimitiveSchema(
                name: "fixture_3720_\(row)",
                fields: [
                    "id": FieldDescriptor(type: .id),
                    "a":  FieldDescriptor(type: Self.fieldType(of: values[0])),
                    "b":  FieldDescriptor(type: Self.fieldType(of: values[1])),
                ],
                constraints: [
                    "uq_ab": ConstraintDescriptor(name: "uq_ab", fields: fields)
                ]
            )
            let doc = YDocument()
            SchemaSync.clearCache()
            let model = DynamicModel(doc: doc, schema: schema)
            _ = try model.create(id: "r\(row)", values: byField)
            let owner: String? = doc.transactSync { txn in
                let m = txn.transactionGetMap(name: "_uniqueIdx_fixture_3720_\(row)_uq_ab")
                return try? m?.get(tx: txn, key: expected)
            }
            XCTAssertEqual(owner, "\"r\(row)\"", "row \(row): the index entry DynamicModel wrote")
        }
    }

    /// `jsonEncodeString` spells every control character as `JSON.stringify`
    /// does, and its inverse still reads the older `\u0008` / `\u000c`
    /// spelling it wrote before.
    func testJsonEncodeStringControlCharacters() {
        XCTAssertEqual(PrimitiveValue.jsonEncodeString("\u{08}"), #""\b""#)
        XCTAssertEqual(PrimitiveValue.jsonEncodeString("\u{0C}"), #""\f""#)
        XCTAssertEqual(PrimitiveValue.jsonEncodeString("\u{01}"), #""\u0001""#)
        XCTAssertEqual(PrimitiveValue.jsonEncodeString("\u{1F}"), #""\u001f""#)
        XCTAssertEqual(PrimitiveValue.jsonEncodeString("\n\r\t"), #""\n\r\t""#)
        let all = String(String.UnicodeScalarView((0..<0x20).compactMap(Unicode.Scalar.init)))
        XCTAssertEqual(PrimitiveValue.decodeJsonString(PrimitiveValue.jsonEncodeString(all)), all)
        XCTAssertEqual(PrimitiveValue.decodeJsonString(#""\u0008\u000c""#), "\u{08}\u{0C}")
    }
}
