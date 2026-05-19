import XCTest
@testable import JsBaoClient
import YSwift

/// Schema-evolution behavior tests. **Documents and pins what
/// happens when an app's TOML changes shape between releases**, so
/// developers know what to expect and the test suite catches any
/// silent change in the runtime.
///
/// All tests share a YDoc and write records via a v1 schema, then
/// open a v2 schema against the same doc and observe how the runtime
/// resolves the mismatch.
///
/// Concrete recommendation summary (also in docs/codegen.md):
///   - **Add an optional field**: safe; existing records read it as nil.
///   - **Remove a field from TOML**: safe-ish; data stays in the Y.Map
///     and remains readable via `PrimitiveRecord[fieldName]` (the
///     subscript doesn't filter on declared fields — that's intentional
///     so migrations can read old data). Never auto-deleted.
///   - **Rename a field**: NOT safe — old data orphaned at the old
///     name, new field reads as nil. Migration: read old via
///     `record[oldName]`, write new via `update(values: [newName: ...])`,
///     then explicitly delete the old key.
///   - **Add `required: true` to existing optional field**: NOT safe
///     for the typed layer — `init?(record:)` on a v1 record returns
///     nil because the field is missing. The dynamic layer keeps the
///     record visible (required is enforced at write time, not read).
///   - **Change a field's type**: NOT safe — decoded value is nil
///     because the existing wire bytes don't match the new type.
///     Migration required.
final class CodegenSchemaEvolutionTests: XCTestCase {

    // MARK: - Add optional field

    func testAddOptionalField_existingRecordsReadNewFieldAsNil() throws {
        let doc = YDocument()
        SchemaSync.clearCache()

        // v1: just id + title
        let v1 = PrimitiveSchema(name: "evo", fields: [
            "id":    FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string, required: true),
        ])
        let modelV1 = DynamicModel(doc: doc, schema: v1)
        try modelV1.create(values: [
            "id":    .id("r1"),
            "title": .string("hello"),
        ])

        // v2: same shape PLUS optional `priority`
        SchemaSync.clearCache()
        let v2 = PrimitiveSchema(name: "evo", fields: [
            "id":       FieldDescriptor(type: .id),
            "title":    FieldDescriptor(type: .string, required: true),
            "priority": FieldDescriptor(type: .number),
        ])
        let modelV2 = DynamicModel(doc: doc, schema: v2)
        let read = try XCTUnwrap(modelV2.find(id: "r1"))
        XCTAssertEqual(read["title"]?.asString, "hello",
                       "existing field should still read fine")
        XCTAssertNil(read["priority"]?.asNumber,
                     "newly-added optional field should read as nil on existing records")
    }

    // MARK: - Remove field from schema

    func testRemoveField_orphanDataStillReadableViaPrimitiveRecord() throws {
        // Useful behavior: `PrimitiveRecord[fieldName]` reads from the
        // raw Y.Map regardless of whether the field is currently
        // declared. So a v2 schema that removed `tagline` can still
        // read v1's `tagline` — handy for migrations: read the old,
        // write the new, delete the old in one transaction.
        let doc = YDocument()
        SchemaSync.clearCache()

        // v1: id + title + tagline
        let v1 = PrimitiveSchema(name: "evo", fields: [
            "id":      FieldDescriptor(type: .id),
            "title":   FieldDescriptor(type: .string, required: true),
            "tagline": FieldDescriptor(type: .string),
        ])
        let modelV1 = DynamicModel(doc: doc, schema: v1)
        try modelV1.create(values: [
            "id":      .id("r2"),
            "title":   .string("v1-title"),
            "tagline": .string("v1-tagline"),
        ])

        // v2: drop `tagline`
        SchemaSync.clearCache()
        let v2 = PrimitiveSchema(name: "evo", fields: [
            "id":    FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string, required: true),
        ])
        let modelV2 = DynamicModel(doc: doc, schema: v2)
        let read = try XCTUnwrap(modelV2.find(id: "r2"))
        XCTAssertEqual(read["title"]?.asString, "v1-title",
                       "still-declared fields read normally")
        // PrimitiveRecord intentionally surfaces every key in the
        // raw record map, not just the schema-declared ones — that's
        // what makes a "read old, write new, delete old" migration
        // possible without dropping into the raw YrsMap layer.
        XCTAssertEqual(read["tagline"]?.asString, "v1-tagline",
                       "removed field should still be readable via PrimitiveRecord — useful for migrations")
    }

    func testRemoveField_orphanDataSurvivesInRawYMap() throws {
        // Companion to the test above: the orphan IS still in the
        // Y.Map. Read it via the raw YrsMap path to confirm — this
        // matters if a future schema re-introduces the field name
        // with a different type (the orphan would then "come back"
        // wearing the new type, which usually decodes to nil but is
        // worth being aware of).
        let doc = YDocument()
        SchemaSync.clearCache()
        let v1 = PrimitiveSchema(name: "evo", fields: [
            "id":      FieldDescriptor(type: .id),
            "tagline": FieldDescriptor(type: .string),
        ])
        let modelV1 = DynamicModel(doc: doc, schema: v1)
        try modelV1.create(values: [
            "id":      .id("r3"),
            "tagline": .string("orphan-me"),
        ])

        // Drop `tagline` from the schema; orphan data stays in Y.Map.
        SchemaSync.clearCache()
        let v2 = PrimitiveSchema(name: "evo", fields: [
            "id": FieldDescriptor(type: .id),
        ])
        _ = DynamicModel(doc: doc, schema: v2)

        // Inspect the raw record map.
        doc.transactSync { txn in
            guard let root = txn.transactionGetMap(name: "evo"),
                  let rec = root.getMap(tx: txn, key: "r3") else {
                XCTFail("missing record map"); return
            }
            let raw = try? rec.get(tx: txn, key: "tagline")
            XCTAssertEqual(raw, "\"orphan-me\"",
                           "removed-field data persists in the raw Y.Map; not auto-deleted")
        }
    }

    // MARK: - Rename field

    func testRenameField_oldDataOrphans_newFieldReadsNil() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let v1 = PrimitiveSchema(name: "evo", fields: [
            "id":   FieldDescriptor(type: .id),
            "name": FieldDescriptor(type: .string),
        ])
        let modelV1 = DynamicModel(doc: doc, schema: v1)
        try modelV1.create(values: [
            "id":   .id("r4"),
            "name": .string("Old Name"),
        ])

        // v2 renames `name` → `displayName`. There's no automatic
        // migration — the old data orphans under the old key, and
        // `displayName` reads as nil because nothing wrote there.
        SchemaSync.clearCache()
        let v2 = PrimitiveSchema(name: "evo", fields: [
            "id":          FieldDescriptor(type: .id),
            "displayName": FieldDescriptor(type: .string),
        ])
        let modelV2 = DynamicModel(doc: doc, schema: v2)
        let read = try XCTUnwrap(modelV2.find(id: "r4"))
        XCTAssertNil(read["displayName"]?.asString,
                     "renamed field reads as nil; migration is on the developer")
        // The old `name` data is still readable through PrimitiveRecord
        // (subscript reads the raw map, doesn't filter on the current
        // schema) — that's how a migration would access the old value
        // before re-writing it under the new field name.
        XCTAssertEqual(read["name"]?.asString, "Old Name",
                       "old field's data is still readable through PrimitiveRecord — read old, write new, delete old to migrate")
    }

    // MARK: - Add `required: true` to existing optional field

    func testAddRequiredToExistingOptional_v1RecordsBecomeUnreadableTyped() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let v1 = PrimitiveSchema(name: "evo", fields: [
            "id":   FieldDescriptor(type: .id),
            "name": FieldDescriptor(type: .string),
        ])
        let modelV1 = DynamicModel(doc: doc, schema: v1)
        // Note: NO `name` written.
        try modelV1.create(values: [
            "id": .id("r5"),
        ])

        // v2 marks `name` as required. v1 records that didn't write
        // it have no `name` entry. The DYNAMIC layer still surfaces
        // them (PrimitiveRecord doesn't enforce required-at-read).
        // A typed init?(record:) WOULD fail.
        SchemaSync.clearCache()
        let v2 = PrimitiveSchema(name: "evo", fields: [
            "id":   FieldDescriptor(type: .id),
            "name": FieldDescriptor(type: .string, required: true),
        ])
        let modelV2 = DynamicModel(doc: doc, schema: v2)

        let dynamicRead = modelV2.find(id: "r5")
        XCTAssertNotNil(dynamicRead,
                        "DynamicModel surfaces records even when required-at-schema fields are missing — required is enforced at write time, not at read time")
        XCTAssertNil(dynamicRead?["name"]?.asString,
                     "missing field reads back as nil; the typed init?(record:) layer is what would fail")
    }

    // MARK: - Change field type

    func testChangeFieldType_oldStringDecodesAsNilUnderNewNumberType() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let v1 = PrimitiveSchema(name: "evo", fields: [
            "id":   FieldDescriptor(type: .id),
            "size": FieldDescriptor(type: .string),
        ])
        let modelV1 = DynamicModel(doc: doc, schema: v1)
        try modelV1.create(values: [
            "id":   .id("r6"),
            "size": .string("medium"),
        ])

        // v2 declares `size` as a number. The wire bytes `"medium"`
        // are valid JSON-encoded string but not a valid Double when
        // `PrimitiveValue.decode(yrsString:as: .number)` parses them.
        SchemaSync.clearCache()
        let v2 = PrimitiveSchema(name: "evo", fields: [
            "id":   FieldDescriptor(type: .id),
            "size": FieldDescriptor(type: .number),
        ])
        let modelV2 = DynamicModel(doc: doc, schema: v2)
        let read = try XCTUnwrap(modelV2.find(id: "r6"))
        XCTAssertNil(read["size"]?.asNumber,
                     "string under a number-typed schema decodes to nil; record-level data preserved")
    }

    func testChangeFieldType_newWriteUnderNewType_readsCorrectly() throws {
        // Sanity: after a type change, fresh writes use the new type
        // and round-trip cleanly. Only old records written under the
        // previous type are affected.
        let doc = YDocument()
        SchemaSync.clearCache()
        let v2 = PrimitiveSchema(name: "evo", fields: [
            "id":   FieldDescriptor(type: .id),
            "size": FieldDescriptor(type: .number),
        ])
        let modelV2 = DynamicModel(doc: doc, schema: v2)
        try modelV2.create(values: [
            "id":   .id("r7"),
            "size": .number(42),
        ])
        let read = try XCTUnwrap(modelV2.find(id: "r7"))
        XCTAssertEqual(read["size"]?.asNumber, 42,
                       "new writes under the new schema round-trip cleanly")
    }
}
