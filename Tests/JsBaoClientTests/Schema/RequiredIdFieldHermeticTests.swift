import XCTest
@testable import JsBaoClient
import YSwift

/// A model whose `id` field is declared `required = true` (#2885).
///
/// The primary key never travels in the caller's `values`: the generated
/// `primitiveValues()` omits it and it reaches the write path as the
/// separate `id:` argument. The required-field validator checks the merged
/// `oldData + values` view, so on an insert `id` looked missing and EVERY
/// insert of such a model threw `requiredFieldMissing(field: "id", …)` —
/// the model could never be created from Swift, while the same
/// `models.toml` worked from the JS client.
///
/// js-bao's `validateBeforeSave` reads the key off the instance rather than
/// the field data for exactly this reason (`BaseModel.ts`: `fieldKey ===
/// "id" ? this.id : this.getValue(fieldKey)`, issue #613). This suite holds
/// the Swift runtime to the same rule — an id the runtime guarantees
/// (auto-assigned, or passed as `id:`) satisfies the requirement — without
/// loosening the check for any other field.
///
/// Server-free: a plain `YDocument` plus `DynamicModel`.
final class RequiredIdFieldHermeticTests: XCTestCase {

    /// The reported shape: `auto_assign = true`, `indexed = true`,
    /// `required = true` on `id`, and no `default` — so the
    /// default-materialization loop can't supply the value either.
    private func householdSchema(_ name: String = "household") -> PrimitiveSchema {
        PrimitiveSchema(
            name: name,
            fields: [
                "id":   FieldDescriptor(type: .id, indexed: true,
                                        required: true, autoAssign: true),
                "name": FieldDescriptor(type: .string),
            ]
        )
    }

    private func freshModel(_ schema: PrimitiveSchema) -> DynamicModel {
        SchemaSync.clearCache()
        return DynamicModel(doc: YDocument(), schema: schema)
    }

    /// `Household(name: "Household")` — id auto-assigned by the init, then
    /// handed to the write path as the `id:` argument while `values` carries
    /// only `name`. This is the exact call the generated `save(in:)` makes.
    func testSuppliedIdSatisfiesRequiredOnInsert() throws {
        let model = freshModel(householdSchema())

        let rec = try model.save(
            id: "hh_1",
            values: ["name": .string("Household")],
            changedFields: ["name"]
        )

        XCTAssertEqual(rec["name"], .string("Household"))
        XCTAssertEqual(model.find(id: "hh_1")?["id"], .id("hh_1"),
                       "the record must persist under the id it was saved with")
    }

    /// The auto-assign convenience path: no id anywhere in the call, the
    /// runtime generates one. `auto_assign` carries no `default`, so this is
    /// the case the default-materialization loop never covered.
    func testAutoAssignedIdSatisfiesRequiredOnCreate() throws {
        let model = freshModel(householdSchema("household_auto"))

        let rec = try model.create(values: ["name": .string("Household")])

        XCTAssertEqual(rec.id.count, 26, "id should be an auto-assigned ULID")
        XCTAssertEqual(model.findAll().count, 1)
    }

    /// The upsert insert path resolves the id the same way and must reach the
    /// same verdict.
    func testUpsertInsertWithRequiredIdSucceeds() throws {
        let schema = PrimitiveSchema(
            name: "household_upsert",
            fields: [
                "id":    FieldDescriptor(type: .id, required: true, autoAssign: true),
                "email": FieldDescriptor(type: .string, unique: true),
                "name":  FieldDescriptor(type: .string),
            ]
        )
        let model = freshModel(schema)

        let result = try model.upsert(
            ["email": .string("a@b.c"), "name": .string("Household")],
            on: "email"
        )

        XCTAssertTrue(result.wasCreated)
        XCTAssertEqual(result.record["name"], .string("Household"))
    }

    /// The narrowing is `id`-only: every other required field is still
    /// enforced on the same insert.
    func testOtherRequiredFieldsStillEnforced() throws {
        let schema = PrimitiveSchema(
            name: "household_strict",
            fields: [
                "id":   FieldDescriptor(type: .id, required: true, autoAssign: true),
                "name": FieldDescriptor(type: .string, required: true),
            ]
        )
        let model = freshModel(schema)

        XCTAssertThrowsError(try model.create(id: "hh_1", values: [:])) { error in
            XCTAssertEqual(
                error as? FieldValidationError,
                .requiredFieldMissing(field: "name", modelName: "household_strict")
            )
        }
        XCTAssertEqual(model.findAll().count, 0,
                       "a failed create must not persist a record")
    }

    /// An id the runtime guarantees satisfies the requirement — an id it
    /// does NOT have does not. js-bao rejects an empty/absent key in
    /// `save()` before `validateBeforeSave` runs (`Cannot save item without
    /// an id. Ensure id is set.`, `BaseModel.ts`); the Swift write path owes
    /// the same verdict, on every entry point rather than just `save`.
    func testEmptyIdIsRejectedOnEveryWriteEntryPointOfARequiredIdModel() throws {
        let model = freshModel(householdSchema("household_empty"))
        let values: [String: PrimitiveValue] = ["name": .string("Household")]

        assertRejectsEmptyId(model, modelName: "household_empty") {
            try model.save(id: "", values: values)
        }
        assertRejectsEmptyId(model, modelName: "household_empty") {
            try model.create(id: "", values: values)
        }
        assertRejectsEmptyId(model, modelName: "household_empty") {
            try model.create(values: values.merging(["id": .string("")]) { _, new in new })
        }
        assertRejectsEmptyId(model, modelName: "household_empty") {
            try model.update(id: "", values: values)
        }
    }

    /// The same guard on a model that does NOT declare `required` on its id
    /// — an empty key was accepted here even before #2885, and js-bao's
    /// falsy `!this.id` check never depended on the `required` declaration.
    func testEmptyIdIsRejectedWhenTheIdFieldIsNotRequired() throws {
        let schema = PrimitiveSchema(
            name: "household_optional_id",
            fields: [
                "id":   FieldDescriptor(type: .id, autoAssign: true),
                "name": FieldDescriptor(type: .string),
            ]
        )
        let model = freshModel(schema)

        assertRejectsEmptyId(model, modelName: "household_optional_id") {
            try model.save(id: "", values: ["name": .string("Household")])
        }
        assertRejectsEmptyId(model, modelName: "household_optional_id") {
            try model.create(id: "", values: ["name": .string("Household")])
        }
    }

    /// The upsert insert path resolves the id itself, so an explicitly
    /// pinned empty one has to be caught there too.
    func testEmptyIdIsRejectedOnTheUpsertInsertPath() throws {
        let schema = PrimitiveSchema(
            name: "household_empty_upsert",
            fields: [
                "id":    FieldDescriptor(type: .id, required: true, autoAssign: true),
                "email": FieldDescriptor(type: .string, unique: true),
                "name":  FieldDescriptor(type: .string),
            ]
        )
        let model = freshModel(schema)

        assertRejectsEmptyId(model, modelName: "household_empty_upsert") {
            try model.upsert(
                ["email": .string("a@b.c"), "name": .string("Household")],
                on: "email", id: "", explicitId: true
            )
        }
    }

    /// The MERGE path is where the caller's key stops being the one that
    /// gets written: with no match the empty id reaches the write path and
    /// is caught there, but a match substitutes the existing record's id
    /// (JS auto-id parity discards a non-explicit one), so the write-path
    /// guard only ever sees a valid key. js-bao runs its `!this.id` check
    /// before the deferred `upsertOn` lookup, so the empty key is rejected
    /// either way — and it never reaches the explicit-id conflict check.
    func testEmptyIdIsRejectedOnTheUpsertMergePath() throws {
        let model = freshModel(uniqueEmailSchema("household_merge_upsert"))
        _ = try model.upsert(
            ["email": .string("a@b.c"), "name": .string("Household")],
            on: "email", id: "hh_1", explicitId: true
        )

        for explicitId in [false, true] {
            assertRejectsEmptyId(
                model, modelName: "household_merge_upsert", survivingRecords: 1
            ) {
                try model.upsert(
                    ["email": .string("a@b.c"), "name": .string("Renamed")],
                    on: "email", id: "", explicitId: explicitId
                )
            }
        }
        XCTAssertEqual(model.find(id: "hh_1")?["name"], .string("Household"),
                       "a rejected merge must not touch the matched record")
    }

    /// The same hole in the constraint-name form: it resolves the match
    /// first and then merges into it, so the supplied key is never the one
    /// written. js-bao's `upsertByUnique` assigns `dataToUpsert` onto the
    /// matched record, so an empty id trips `save()`'s guard there too.
    func testEmptyIdIsRejectedOnTheUpsertByUniqueMergePath() throws {
        let model = freshModel(uniqueEmailSchema("household_merge_ubu"))
        _ = try model.create(id: "hh_1", values: [
            "email": .string("a@b.c"), "name": .string("Household"),
        ])

        assertRejectsEmptyId(
            model, modelName: "household_merge_ubu", survivingRecords: 1
        ) {
            _ = try model.upsertByUnique(
                constraint: "household_merge_ubu_email_unique",
                data: ["email": .string("a@b.c"), "name": .string("Renamed")],
                id: ""
            )
        }
        XCTAssertEqual(model.find(id: "hh_1")?["name"], .string("Household"),
                       "a rejected merge must not touch the matched record")
    }

    /// The cross-doc form searches every connected doc before deciding, so
    /// a match in ANOTHER doc supplies the id just the same. The verdict on
    /// an empty caller key doesn't depend on where the match lives.
    func testEmptyIdIsRejectedOnTheCrossDocUpsertByUniqueMergePath() throws {
        let schema = uniqueEmailSchema("household_multi_ubu")
        SchemaSync.clearCache()
        let multi = MultiDocModel(schema: schema)
        _ = multi.connect(docId: "docA", doc: YDocument())
        SchemaSync.clearCache()
        let modelB = multi.connect(docId: "docB", doc: YDocument())
        _ = try modelB.create(id: "hh_1", values: [
            "email": .string("a@b.c"), "name": .string("Household"),
        ])

        for explicitId in [false, true] {
            XCTAssertThrowsError(try multi.upsertByUnique(
                constraint: "household_multi_ubu_email_unique",
                data: ["email": .string("a@b.c"), "name": .string("Renamed")],
                id: "",
                explicitId: explicitId,
                targetDocId: "docA"
            )) { error in
                XCTAssertEqual(
                    error as? FieldValidationError,
                    .requiredFieldMissing(field: "id",
                                          modelName: "household_multi_ubu")
                )
            }
        }
        XCTAssertEqual(multi.findAll().count, 1,
                       "a rejected write must persist no record")
        XCTAssertEqual(multi.find(id: "hh_1")?.row["name"]?.stringValue,
                       "Household",
                       "a rejected merge must not touch the matched record")
    }

    /// `id` (required, auto-assigned, no default) plus a unique `email` to
    /// upsert on — the shape both merge paths need.
    private func uniqueEmailSchema(_ name: String) -> PrimitiveSchema {
        PrimitiveSchema(
            name: name,
            fields: [
                "id":    FieldDescriptor(type: .id, required: true, autoAssign: true),
                "email": FieldDescriptor(type: .string, unique: true),
                "name":  FieldDescriptor(type: .string),
            ]
        )
    }

    /// Shared verdict: the write throws `requiredFieldMissing` naming `id`,
    /// and nothing is persisted under the empty key. `survivingRecords` is
    /// what the model held BEFORE the rejected write — a rejected write
    /// adds nothing.
    private func assertRejectsEmptyId(
        _ model: DynamicModel,
        modelName: String,
        survivingRecords: Int = 0,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ write: () throws -> Void
    ) {
        XCTAssertThrowsError(try write(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? FieldValidationError,
                .requiredFieldMissing(field: "id", modelName: modelName),
                file: file, line: line
            )
        }
        XCTAssertNil(model.find(id: ""), "no record may be keyed by an empty id",
                     file: file, line: line)
        XCTAssertEqual(model.findAll().count, survivingRecords,
                       "a rejected write must persist no record of its own",
                       file: file, line: line)
    }

    /// Updating a record of a required-id model keeps working — the id is
    /// still there, and the update path never sees it in `values` either.
    func testUpdateOfRequiredIdRecordSucceeds() throws {
        let model = freshModel(householdSchema("household_update"))
        try model.save(id: "hh_1", values: ["name": .string("Household")])

        try model.update(id: "hh_1", values: ["name": .string("Renamed")])

        XCTAssertEqual(model.find(id: "hh_1")?["name"], .string("Renamed"))
    }
}
