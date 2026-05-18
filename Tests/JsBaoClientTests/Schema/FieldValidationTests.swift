import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Tests declarative `required: true` validation on writes. Mirrors
/// js-bao's `validateBeforeSave` enforcement (BaseModel.ts line 849).
///
/// Rules:
///  - `create` with a required field missing or null-typed throws
///    `FieldValidationError.requiredFieldMissing`.
///  - A default value (scalar or function) satisfies the requirement
///    even if the caller doesn't supply the field.
///  - `update` does NOT enforce required — js-bao only requires
///    on insert/full-save, since update is partial by definition.
///    Same here: `update` only validates the fields the caller
///    explicitly touches.
///  - Upsert follows the same split: insert path validates required;
///    merge path doesn't.
final class FieldValidationTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "validated_docs",
        fields: [
            "id":       FieldDescriptor(type: .id),
            "title":    FieldDescriptor(type: .string, required: true),
            "priority": FieldDescriptor(type: .number), // not required
        ]
    )

    func testCreateWithMissingRequiredFieldThrows() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)

        XCTAssertThrowsError(
            try model.create(id: "d1", values: ["priority": .number(1)])
        ) { error in
            guard let e = error as? FieldValidationError else {
                return XCTFail("Expected FieldValidationError, got \(error)")
            }
            XCTAssertEqual(e, .requiredFieldMissing(field: "title",
                                                    modelName: "validated_docs"))
        }
        XCTAssertEqual(model.findAll().count, 0,
                       "Failed create must not persist a record")
    }

    func testCreateWithRequiredFieldPresentSucceeds() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)

        let rec = try model.create(id: "d1", values: ["title": .string("hi")])
        XCTAssertEqual(rec["title"], .string("hi"))
    }

    /// A default satisfies the requirement even if the caller doesn't
    /// supply it — the value is materialized into the nested map before
    /// the validation check runs.
    func testCreateUsesDefaultForRequiredField() throws {
        let s = PrimitiveSchema(
            name: "defaulted_docs",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "state": FieldDescriptor(type: .string, required: true,
                                          default: .scalar(.string("pending"))),
            ]
        )
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: s)
        XCTAssertNoThrow(try model.create(id: "d1", values: [:]))
        XCTAssertEqual(model.find(id: "d1")?["state"], .string("pending"))
    }

    /// Function defaults ($generate_ulid) satisfy required for id fields.
    func testCreateWithFunctionDefaultSatisfiesRequired() throws {
        let s = PrimitiveSchema(
            name: "func_defaults",
            fields: [
                "id": FieldDescriptor(type: .id, required: true,
                                       autoAssign: true,
                                       default: .function(name: "generate_ulid")),
            ]
        )
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: s)
        let rec = try model.create(values: [:])
        XCTAssertEqual(rec.id.count, 26)
    }

    /// Upsert insert path validates required fields.
    func testUpsertInsertMissingRequiredThrows() throws {
        let s = PrimitiveSchema(
            name: "upsert_validated",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "email": FieldDescriptor(type: .string, unique: true),
                "name":  FieldDescriptor(type: .string, required: true),
            ]
        )
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: s)

        // email present, name missing — should throw on the insert path.
        XCTAssertThrowsError(
            try model.upsert(["email": .string("a@b.c")], on: "email")
        ) { error in
            XCTAssertEqual(
                error as? FieldValidationError,
                .requiredFieldMissing(field: "name", modelName: "upsert_validated")
            )
        }
    }

    /// Upsert merge path does NOT validate: the existing record already
    /// has the required fields. Caller can submit a partial update.
    func testUpsertMergePathSkipsRequiredCheck() throws {
        let s = PrimitiveSchema(
            name: "upsert_merge_validated",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "email": FieldDescriptor(type: .string, unique: true),
                "name":  FieldDescriptor(type: .string, required: true),
            ]
        )
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: s)

        _ = try model.create(id: "u1", values: [
            "email": .string("a@b.c"), "name": .string("Alice"),
        ])
        // Upsert without supplying `name`. Merge path must succeed —
        // existing record has it.
        XCTAssertNoThrow(
            try model.upsert(["email": .string("a@b.c")], on: "email")
        )
    }

    /// `update` validates required fields too — js-bao runs
    /// `validateBeforeSave` on every save (BaseModel.ts line 2159),
    /// insert or update. An update that leaves a required field
    /// already-populated is fine (merged-state view); but an update
    /// that clears a required field would fail at enforcement time.
    /// Key behavior: an update that DOESN'T touch a required field
    /// is accepted because the merged state still has the value.
    func testUpdateWithRequiredFieldUntouchedIsAllowed() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "d1", values: ["title": .string("ok")])

        // Update touches only `priority`; title remains set in the
        // merged state → no violation.
        XCTAssertNoThrow(
            try model.update(id: "d1", values: ["priority": .number(5)])
        )
    }

    /// Empty string is a VALID value for a required field — matches
    /// js-bao BaseModel.ts line 844: only `null || undefined` triggers
    /// the required-field error. Empty string is present.
    func testEmptyStringForRequiredFieldIsAccepted() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)
        XCTAssertNoThrow(
            try model.create(id: "d1", values: ["title": .string("")])
        )
    }
}
