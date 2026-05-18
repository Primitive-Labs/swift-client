import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Tests `DynamicModel.upsertByUnique(constraint:, data:, mode:)` —
/// the explicit find-by-constraint-or-create primitive. Mirrors
/// js-bao's `upsertByUnique` static (BaseModel.ts line 3768).
///
/// Modes:
///  - `.either` (default): insert if missing, update (merge) if exists.
///  - `.mustExist`: update existing; throw `.recordNotFound` if missing.
///  - `.mustNotExist`: insert; throw (surface existing id) if found.
///
/// Works with single-field AND compound unique constraints. The lookup
/// values come from the `data` dict itself, under the constraint's
/// field names (matches js-bao's "data must contain the constraint
/// fields and they determine the lookup key" contract).
final class UpsertByUniqueTests: XCTestCase {

    private let singleSchema = PrimitiveSchema(
        name: "users_ubu",
        fields: [
            "id":    FieldDescriptor(type: .id, autoAssign: true,
                                      default: .function(name: "generate_ulid")),
            "email": FieldDescriptor(type: .string, unique: true),
            "name":  FieldDescriptor(type: .string),
            "age":   FieldDescriptor(type: .number),
        ]
    )

    private let compoundSchema = PrimitiveSchema(
        name: "products_ubu",
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

    // MARK: - Default mode (.either)

    func testDefaultModeInsertsWhenMissing() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: singleSchema)
        let result = try model.upsertByUnique(
            constraint: "users_ubu_email_unique",
            data: ["email": .string("a@b.c"), "name": .string("Alice")]
        )
        XCTAssertTrue(result.wasCreated)
        XCTAssertEqual(result.record["name"], .string("Alice"))
    }

    func testDefaultModeUpdatesWhenExisting() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: singleSchema)
        _ = try model.create(id: "u1", values: [
            "email": .string("a@b.c"), "name": .string("Alice"), "age": .number(30),
        ])

        let result = try model.upsertByUnique(
            constraint: "users_ubu_email_unique",
            data: ["email": .string("a@b.c"), "name": .string("Alice V2")]
        )
        XCTAssertFalse(result.wasCreated)
        XCTAssertEqual(result.record.id, "u1")
        XCTAssertEqual(result.record["name"], .string("Alice V2"))
        XCTAssertEqual(result.record["age"], .number(30),
                       "Unspecified fields must not be wiped on merge")
    }

    // MARK: - .mustExist

    func testMustExistThrowsWhenMissing() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: singleSchema)
        XCTAssertThrowsError(try model.upsertByUnique(
            constraint: "users_ubu_email_unique",
            data: ["email": .string("nobody@x.c"), "name": .string("Alice")],
            mode: .mustExist
        )) { error in
            XCTAssertEqual(
                error as? UpsertByUniqueError,
                .recordNotFound(constraint: "users_ubu_email_unique")
            )
        }
        XCTAssertEqual(model.findAll().count, 0)
    }

    func testMustExistUpdatesWhenExisting() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: singleSchema)
        _ = try model.create(id: "u1", values: [
            "email": .string("a@b.c"), "name": .string("Alice"),
        ])
        let result = try model.upsertByUnique(
            constraint: "users_ubu_email_unique",
            data: ["email": .string("a@b.c"), "age": .number(25)],
            mode: .mustExist
        )
        XCTAssertFalse(result.wasCreated)
        XCTAssertEqual(result.record.id, "u1")
        XCTAssertEqual(result.record["age"], .number(25))
    }

    // MARK: - .mustNotExist

    func testMustNotExistThrowsWhenExisting() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: singleSchema)
        _ = try model.create(id: "u1", values: ["email": .string("a@b.c")])
        XCTAssertThrowsError(try model.upsertByUnique(
            constraint: "users_ubu_email_unique",
            data: ["email": .string("a@b.c"), "name": .string("Alice")],
            mode: .mustNotExist
        )) { error in
            guard let e = error as? UniqueConstraintViolationError else {
                return XCTFail("Expected UniqueConstraintViolationError, got \(error)")
            }
            XCTAssertEqual(e.existingRecordId, "u1")
        }
    }

    func testMustNotExistInsertsWhenMissing() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: singleSchema)
        let result = try model.upsertByUnique(
            constraint: "users_ubu_email_unique",
            data: ["email": .string("a@b.c"), "name": .string("Alice")],
            mode: .mustNotExist
        )
        XCTAssertTrue(result.wasCreated)
    }

    // MARK: - Compound constraints

    func testCompoundConstraintUpsertInsert() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: compoundSchema)
        let result = try model.upsertByUnique(
            constraint: "uq_tenant_sku",
            data: [
                "tenantId": .string("t1"), "sku": .string("A"),
                "name": .string("Product A"),
            ]
        )
        XCTAssertTrue(result.wasCreated)
    }

    func testCompoundConstraintUpsertMatchesExisting() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: compoundSchema)
        _ = try model.create(id: "p1", values: [
            "tenantId": .string("t1"), "sku": .string("A"),
            "name": .string("Old"),
        ])
        let result = try model.upsertByUnique(
            constraint: "uq_tenant_sku",
            data: [
                "tenantId": .string("t1"), "sku": .string("A"),
                "name": .string("New"),
            ]
        )
        XCTAssertFalse(result.wasCreated)
        XCTAssertEqual(result.record.id, "p1")
        XCTAssertEqual(result.record["name"], .string("New"))
    }

    // MARK: - Validation errors

    func testUnknownConstraintThrows() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: singleSchema)
        XCTAssertThrowsError(try model.upsertByUnique(
            constraint: "not_a_real_constraint",
            data: ["email": .string("a@b.c")]
        )) { error in
            XCTAssertEqual(
                error as? FindByUniqueError,
                .constraintNotFound("not_a_real_constraint")
            )
        }
    }

    /// `data` must contain every field of the constraint. Partial
    /// identification is ambiguous and rejected.
    func testDataMissingConstraintFieldThrows() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: compoundSchema)
        XCTAssertThrowsError(try model.upsertByUnique(
            constraint: "uq_tenant_sku",
            data: ["tenantId": .string("t1")]  // sku missing
        )) { error in
            XCTAssertEqual(
                error as? UpsertByUniqueError,
                .missingConstraintField(field: "sku")
            )
        }
    }

    // MARK: - Id supplied on insert

    /// Caller-supplied id is honored on the insert path.
    func testSuppliedIdOnInsert() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: singleSchema)
        let result = try model.upsertByUnique(
            constraint: "users_ubu_email_unique",
            data: ["email": .string("a@b.c")],
            id: "u_custom"
        )
        XCTAssertTrue(result.wasCreated)
        XCTAssertEqual(result.record.id, "u_custom")
    }
}
