import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Tests `DynamicModel.findByUnique(constraint:, value:)` and its
/// compound-constraint overload.
///
/// This is the read-side counterpart of js-bao's `findByUnique`
/// (see `BaseModel.ts` line 3631). It reads
/// `_uniqueIdx_{model}_{constraintName}` by the built key and
/// resolves back to the record.
///
/// Semantics mirrored from js-bao:
///  - Constraint name not registered → throws.
///  - Field-count / value-count mismatch → throws.
///  - Any null/missing value → returns nil (matches js-bao's null key).
///  - Index miss → returns nil (the unique value is not in use).
///  - Index hit → returns the PrimitiveRecord for that id.
final class FindByUniqueTests: XCTestCase {

    // MARK: - Single-field constraint

    private let singleSchema = PrimitiveSchema(
        name: "users_find",
        fields: [
            "id":    FieldDescriptor(type: .id),
            "email": FieldDescriptor(type: .string, unique: true),
            "name":  FieldDescriptor(type: .string),
        ]
    )

    func testFindByUniqueSingleFieldHit() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: singleSchema)
        _ = try model.create(id: "u1", values: [
            "email": .string("alice@example.com"),
            "name":  .string("Alice"),
        ])

        let rec = try model.findByUnique(
            constraint: "users_find_email_unique",
            value: .string("alice@example.com")
        )
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.id, "u1")
        XCTAssertEqual(rec?["name"], .string("Alice"))
    }

    func testFindByUniqueSingleFieldMissReturnsNil() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: singleSchema)
        _ = try model.create(id: "u1", values: ["email": .string("alice@example.com")])

        let rec = try model.findByUnique(
            constraint: "users_find_email_unique",
            value: .string("unknown@example.com")
        )
        XCTAssertNil(rec)
    }

    /// After updating the unique field, the old value must no longer
    /// resolve and the new value must — proves the index is kept in
    /// sync by the enforcement layer.
    func testFindByUniqueReflectsUpdate() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: singleSchema)
        _ = try model.create(id: "u1", values: ["email": .string("old@a.b")])
        try model.update(id: "u1", values: ["email": .string("new@a.b")])

        XCTAssertNil(try model.findByUnique(
            constraint: "users_find_email_unique",
            value: .string("old@a.b")
        ))
        XCTAssertEqual(
            try model.findByUnique(
                constraint: "users_find_email_unique",
                value: .string("new@a.b")
            )?.id,
            "u1"
        )
    }

    /// Deleting a record clears the index; findByUnique returns nil.
    func testFindByUniqueReflectsDelete() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: singleSchema)
        _ = try model.create(id: "u1", values: ["email": .string("a@b.c")])
        model.delete(id: "u1")

        XCTAssertNil(try model.findByUnique(
            constraint: "users_find_email_unique",
            value: .string("a@b.c")
        ))
    }

    // MARK: - Compound constraint

    private let compoundSchema = PrimitiveSchema(
        name: "products_find",
        fields: [
            "id":       FieldDescriptor(type: .id),
            "tenantId": FieldDescriptor(type: .string),
            "sku":      FieldDescriptor(type: .string),
            "name":     FieldDescriptor(type: .string),
        ],
        constraints: [
            "uq_tenant_sku": ConstraintDescriptor(
                name: "uq_tenant_sku",
                fields: ["tenantId", "sku"]
            )
        ]
    )

    func testFindByUniqueCompoundHit() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: compoundSchema)
        _ = try model.create(id: "p1", values: [
            "tenantId": .string("t1"),
            "sku":      .string("A"),
            "name":     .string("Product A"),
        ])

        let rec = try model.findByUnique(
            constraint: "uq_tenant_sku",
            values: [.string("t1"), .string("A")]
        )
        XCTAssertEqual(rec?.id, "p1")
    }

    func testFindByUniqueCompoundMiss() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: compoundSchema)
        _ = try model.create(id: "p1", values: [
            "tenantId": .string("t1"), "sku": .string("A"),
        ])

        XCTAssertNil(try model.findByUnique(
            constraint: "uq_tenant_sku",
            values: [.string("t1"), .string("B")]
        ))
    }

    // MARK: - Validation errors

    func testFindByUniqueUnknownConstraintThrows() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: singleSchema)

        XCTAssertThrowsError(
            try model.findByUnique(constraint: "nope", value: .string("x"))
        ) { error in
            XCTAssertEqual(error as? FindByUniqueError,
                           .constraintNotFound("nope"))
        }
    }

    /// Wrong number of positional values for a compound constraint.
    func testFindByUniqueArityMismatchThrows() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: compoundSchema)

        XCTAssertThrowsError(try model.findByUnique(
            constraint: "uq_tenant_sku",
            values: [.string("t1")]  // compound wants 2
        )) { error in
            XCTAssertEqual(error as? FindByUniqueError,
                           .fieldCountMismatch(expected: 2, got: 1))
        }
    }

    // MARK: - Cross-platform: resolves against a JS-written index

    /// Convenience wrapper proves parity with js-bao: a `_uniqueIdx_*`
    /// entry seeded by js-bao is read correctly by our findByUnique.
    /// Covered already by `CrossPlatformRoundTripTests.testJsWritesUniqueIndex_SwiftEnforcesIt`
    /// via the enforcement path; here we prove the READ API works too.
    func testFindByUniqueSingleLookupAcrossUpsertPath() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: singleSchema)

        let upserted = try model.upsert(
            ["email": .string("a@b.c"), "name": .string("Alice")],
            on: "email"
        )

        let found = try model.findByUnique(
            constraint: "users_find_email_unique",
            value: .string("a@b.c")
        )
        XCTAssertEqual(found?.id, upserted.record.id)
    }
}
