import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Tests the inline `upsert(on:)` API on `DynamicModel`, matching
/// js-bao's `save({ upsertOn: "<field>" })` semantics (see
/// `/tmp/js-bao-ref-uniq/BaseModel.ts` save path, lines 2108–2201).
///
/// Contract:
///  - `upsertOn` names a field backed by a single-field unique constraint.
///  - Inside a single transaction, look up the
///    `_uniqueIdx_{model}_{constraint}` map for the built key.
///  - Hit → reassign target id to the existing record's id; write ONLY
///    the caller-provided fields on top.
///  - Miss → insert a new record using the auto-generated or supplied id.
///  - A caller-supplied id that conflicts with the matched existing id
///    throws.
///  - Null/missing/empty-string value on the upsert field throws.
///  - Any unique-constraint violation on OTHER constraints still throws
///    (the upsert doesn't bypass other uniqueness rules).
final class UpsertTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "users_upsert",
        fields: [
            "id":    FieldDescriptor(
                type: .id,
                autoAssign: true,
                default: .function(name: "generate_ulid")
            ),
            "email": FieldDescriptor(type: .string, unique: true),
            "name":  FieldDescriptor(type: .string),
            "age":   FieldDescriptor(type: .number),
        ]
    )

    private func freshModel() -> DynamicModel {
        SchemaSync.clearCache()
        return DynamicModel(doc: YDocument(), schema: schema)
    }

    // MARK: - Insert path (no existing record)

    func testUpsertInsertsWhenNoRecordMatches() throws {
        let model = freshModel()
        let result = try model.upsert(
            ["email": .string("alice@example.com"), "name": .string("Alice")],
            on: "email"
        )
        XCTAssertTrue(result.wasCreated)
        XCTAssertEqual(result.record["email"], .string("alice@example.com"))
        XCTAssertEqual(result.record["name"], .string("Alice"))
        // Auto-assigned id (ULID) — 26 chars.
        XCTAssertEqual(result.record.id.count, 26)
        XCTAssertEqual(model.findAll().count, 1)
    }

    /// A supplied id is honored on the insert path (no existing match).
    func testUpsertUsesSuppliedIdWhenInserting() throws {
        let model = freshModel()
        let result = try model.upsert(
            ["email": .string("a@b.c"), "name": .string("Alice")],
            on: "email",
            id: "u1"
        )
        XCTAssertTrue(result.wasCreated)
        XCTAssertEqual(result.record.id, "u1")
    }

    // MARK: - Update path (record matched by upsertOn value)

    func testUpsertUpdatesWhenRecordAlreadyHasThatValue() throws {
        let model = freshModel()
        _ = try model.create(id: "u1", values: [
            "email": .string("alice@example.com"),
            "name":  .string("Alice"),
            "age":   .number(30),
        ])

        let result = try model.upsert(
            ["email": .string("alice@example.com"), "name": .string("Alice Updated")],
            on: "email"
        )
        XCTAssertFalse(result.wasCreated)
        XCTAssertEqual(result.record.id, "u1")
        XCTAssertEqual(result.record["name"], .string("Alice Updated"))
        // Only one record total — no duplicate inserted.
        XCTAssertEqual(model.findAll().count, 1)
    }

    /// Fields NOT mentioned in the upsert's values dict must stay
    /// untouched on the matched record. This is the load-bearing
    /// "upsert merges, doesn't replace" behavior from js-bao.
    func testUpsertPreservesUnspecifiedFieldsOnMatch() throws {
        let model = freshModel()
        _ = try model.create(id: "u1", values: [
            "email": .string("alice@example.com"),
            "name":  .string("Alice"),
            "age":   .number(30),
        ])

        // Only specify email + name. age must remain 30.
        _ = try model.upsert(
            ["email": .string("alice@example.com"), "name": .string("Alice V2")],
            on: "email"
        )

        let fresh = model.find(id: "u1")
        XCTAssertEqual(fresh?["name"], .string("Alice V2"))
        XCTAssertEqual(fresh?["age"], .number(30),
                       "age must not be wiped by a partial upsert")
    }

    /// When the supplied id matches the existing id, the upsert merges
    /// normally.
    func testUpsertWithMatchingSuppliedIdMerges() throws {
        let model = freshModel()
        _ = try model.create(id: "u1", values: [
            "email": .string("alice@example.com"),
            "name":  .string("Alice"),
        ])
        let result = try model.upsert(
            ["email": .string("alice@example.com"), "name": .string("Alice Updated")],
            on: "email",
            id: "u1"
        )
        XCTAssertFalse(result.wasCreated)
        XCTAssertEqual(result.record.id, "u1")
    }

    // MARK: - ID conflict

    /// Supplied id that doesn't match the existing record's id →
    /// throws UpsertError.idMismatch.
    func testUpsertWithNonMatchingSuppliedIdThrows() throws {
        let model = freshModel()
        _ = try model.create(id: "u1", values: [
            "email": .string("alice@example.com"),
        ])

        XCTAssertThrowsError(
            try model.upsert(
                ["email": .string("alice@example.com")],
                on: "email",
                id: "u_different"
            )
        ) { error in
            guard let e = error as? UpsertError else {
                return XCTFail("Expected UpsertError, got \(error)")
            }
            XCTAssertEqual(e, .idMismatch(supplied: "u_different", existing: "u1"))
        }
    }

    // MARK: - Validation errors

    func testUpsertMissingFieldThrows() throws {
        let model = freshModel()
        XCTAssertThrowsError(
            try model.upsert(["name": .string("Alice")], on: "email")
        ) { error in
            XCTAssertEqual(error as? UpsertError, .missingField(field: "email"))
        }
    }

    func testUpsertEmptyStringFieldThrows() throws {
        let model = freshModel()
        XCTAssertThrowsError(
            try model.upsert(["email": .string("")], on: "email")
        ) { error in
            XCTAssertEqual(error as? UpsertError, .nullOrEmptyField(field: "email"))
        }
    }

    /// Upserting on a field that isn't backed by a single-field unique
    /// constraint must throw.
    func testUpsertOnNonUniqueFieldThrows() throws {
        let model = freshModel()
        XCTAssertThrowsError(
            try model.upsert(["name": .string("alice")], on: "name")
        ) { error in
            XCTAssertEqual(
                error as? UpsertError,
                .noSingleFieldUniqueConstraint(field: "name")
            )
        }
    }

    /// Upserting on an unknown field must throw (not accidentally match
    /// as "no constraint").
    func testUpsertOnUnknownFieldThrows() throws {
        let model = freshModel()
        XCTAssertThrowsError(
            try model.upsert(["nonexistent": .string("x")], on: "nonexistent")
        )
    }

    /// `upsertOn` must be a single-field constraint. A compound-only
    /// field is not a valid target.
    func testUpsertOnCompoundOnlyFieldThrows() throws {
        let compoundSchema = PrimitiveSchema(
            name: "products_u",
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
        SchemaSync.clearCache()
        let model = DynamicModel(doc: YDocument(), schema: compoundSchema)

        XCTAssertThrowsError(
            try model.upsert(
                ["tenantId": .string("t1"), "sku": .string("A")],
                on: "tenantId"
            )
        ) { error in
            XCTAssertEqual(
                error as? UpsertError,
                .noSingleFieldUniqueConstraint(field: "tenantId")
            )
        }
    }

    // MARK: - Cross-constraint enforcement

    /// Upserting must still enforce OTHER unique constraints. If the
    /// upsert would violate a different unique field, it throws.
    func testUpsertStillEnforcesOtherUniqueConstraints() throws {
        let extraSchema = PrimitiveSchema(
            name: "users_multi",
            fields: [
                "id":       FieldDescriptor(type: .id,
                                            autoAssign: true,
                                            default: .function(name: "generate_ulid")),
                "email":    FieldDescriptor(type: .string, unique: true),
                "username": FieldDescriptor(type: .string, unique: true),
            ]
        )
        SchemaSync.clearCache()
        let model = DynamicModel(doc: YDocument(), schema: extraSchema)

        _ = try model.create(id: "u1", values: [
            "email":    .string("alice@example.com"),
            "username": .string("alice"),
        ])
        _ = try model.create(id: "u2", values: [
            "email":    .string("bob@example.com"),
            "username": .string("bob"),
        ])

        // Upsert targeting u1 by email but trying to set username to
        // "bob" (which u2 owns).
        XCTAssertThrowsError(try model.upsert(
            ["email": .string("alice@example.com"),
             "username": .string("bob")],
            on: "email"
        )) { error in
            XCTAssertTrue(error is UniqueConstraintViolationError,
                          "Expected UniqueConstraintViolationError, got \(error)")
        }
    }

    // MARK: - Transaction atomicity

    /// If the upsert fails validation, the doc must be untouched.
    func testUpsertDoesNotMutateOnValidationFailure() throws {
        let model = freshModel()
        let stateBefore: Data = model.doc.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }

        XCTAssertThrowsError(
            try model.upsert(["email": .string("")], on: "email")
        )

        let stateAfter: Data = model.doc.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }
        XCTAssertEqual(stateBefore, stateAfter,
                       "Validation failure must not emit any CRDT updates")
    }

    // MARK: - Wire parity: same _uniqueIdx_* is used

    /// A successful upsert (insert path) registers the record in the
    /// `_uniqueIdx_*` map, identically to how `create` would.
    func testUpsertInsertRegistersInUniqueIndex() throws {
        let model = freshModel()
        _ = try model.upsert(
            ["email": .string("a@b.c")],
            on: "email",
            id: "u1"
        )

        let raw: String? = model.doc.transactSync { txn in
            let m = txn.transactionGetMap(
                name: "_uniqueIdx_users_upsert_users_upsert_email_unique"
            )
            return try? m?.get(tx: txn, key: "a@b.c")
        }
        XCTAssertEqual(raw, "\"u1\"")
    }
}
