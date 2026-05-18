import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Tests `SchemaSync.syncInferredMeta` — writes a minimal `_meta_*`
/// map by inferring each field's type from a sample record value.
/// Mirrors js-bao's `syncInferredMeta` (see `/tmp/js-bao-ref/metaSync.ts`).
///
/// Key semantics:
///  - Skips field names starting with `_` (internal).
///  - Only writes `type` if the field's map doesn't already have one
///    (doesn't override explicit schema metadata).
///  - Unknown / unsupported values produce no type entry (no crash).
///  - Idempotent across repeated calls.
final class SyncInferredMetaTests: XCTestCase {

    private func rawType(
        in doc: YDocument,
        model: String,
        field: String
    ) -> String? {
        return doc.transactSync { txn in
            guard let meta = txn.transactionGetMap(name: "_meta_\(model)"),
                  let fieldMap = meta.getMap(tx: txn, key: field) else { return nil }
            return try? fieldMap.get(tx: txn, key: "type")
        }
    }

    func testInferStringNumberBoolean() {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncInferredMeta(doc: doc, modelName: "m1", recordData: [
            "title":    .string("hi"),
            "priority": .number(3),
            "done":     .boolean(false),
        ])
        XCTAssertEqual(rawType(in: doc, model: "m1", field: "title"),    "\"string\"")
        XCTAssertEqual(rawType(in: doc, model: "m1", field: "priority"), "\"number\"")
        XCTAssertEqual(rawType(in: doc, model: "m1", field: "done"),     "\"boolean\"")
    }

    /// `.stringset` values infer as the `stringset` wire type — matches
    /// js-bao's `value instanceof Y.Map → "stringset"` rule.
    func testInferStringSet() {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncInferredMeta(doc: doc, modelName: "m2", recordData: [
            "tags": .stringset(["a", "b"]),
        ])
        XCTAssertEqual(rawType(in: doc, model: "m2", field: "tags"), "\"stringset\"")
    }

    /// `.date`, `.id`, `.json` aren't in js-bao's inferFieldType table,
    /// so no `type` key is written for them. js-bao still creates the
    /// nested field Y.Map itself (empty) — metaSync.ts lines 232-236:
    /// `fieldMeta = new Y.Map(); meta.set(fieldName, fieldMeta);`
    /// runs unconditionally. Swift must match so the `_meta_` shape is
    /// byte-compatible.
    func testUnsupportedValueTypesCreateEmptyFieldMap() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncInferredMeta(doc: doc, modelName: "m3", recordData: [
            "dateField": .date("2026-04-22T00:00:00Z"),
            "idField":   .id("01H"),
            "jsonField": .json(Data("{}".utf8)),
        ])
        // No `type` is inferred for these runtime shapes.
        XCTAssertNil(rawType(in: doc, model: "m3", field: "dateField"))
        XCTAssertNil(rawType(in: doc, model: "m3", field: "idField"))
        XCTAssertNil(rawType(in: doc, model: "m3", field: "jsonField"))

        // BUT the empty nested field map must exist, matching js-bao.
        let present: (String) -> Bool = { name in
            doc.transactSync { txn in
                txn.transactionGetMap(name: "_meta_m3")?
                    .getMap(tx: txn, key: name) != nil
            }
        }
        XCTAssertTrue(present("dateField"),
                      "Empty field map for unknown-type field must be created")
        XCTAssertTrue(present("idField"))
        XCTAssertTrue(present("jsonField"))
    }

    /// Underscore-prefixed keys are ignored entirely — matches js-bao's
    /// `if (fieldName.startsWith("_")) continue;` guard.
    func testSkipsUnderscorePrefixedKeys() {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncInferredMeta(doc: doc, modelName: "m4", recordData: [
            "title":     .string("x"),
            "_internal": .string("skip me"),
        ])
        XCTAssertNotNil(rawType(in: doc, model: "m4", field: "title"))
        XCTAssertNil(rawType(in: doc, model: "m4", field: "_internal"))
    }

    /// Doesn't override a field's existing `type`. Mirrors js-bao's
    /// `if (!fieldMeta.has("type"))` guard.
    func testDoesNotOverrideExistingType() {
        let doc = YDocument()
        SchemaSync.clearCache()

        // Seed an explicit schema first.
        SchemaSync.syncModelMeta(doc: doc, schema: PrimitiveSchema(
            name: "m5",
            fields: ["views": FieldDescriptor(type: .number)]
        ))
        XCTAssertEqual(rawType(in: doc, model: "m5", field: "views"), "\"number\"")

        // Now try to infer a string into the same field — should be a no-op.
        SchemaSync.syncInferredMeta(doc: doc, modelName: "m5", recordData: [
            "views": .string("this-is-a-string"),
        ])
        XCTAssertEqual(rawType(in: doc, model: "m5", field: "views"),
                       "\"number\"",
                       "Existing type must not be clobbered by inference")
    }

    /// Two consecutive calls are idempotent — no extra CRDT updates.
    func testIdempotentAcrossRepeatedCalls() {
        let doc = YDocument()
        SchemaSync.clearCache()
        let sample: [String: PrimitiveValue] = [
            "title": .string("hi"),
            "count": .number(1),
        ]
        SchemaSync.syncInferredMeta(doc: doc, modelName: "m6", recordData: sample)
        let first = doc.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }
        SchemaSync.syncInferredMeta(doc: doc, modelName: "m6", recordData: sample)
        let second = doc.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }
        XCTAssertEqual(first, second)
    }

    /// An inferred doc is readable by `SchemaDiscovery` exactly like an
    /// explicitly-schema'd doc.
    func testInferredMetaIsDiscoverable() {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncInferredMeta(doc: doc, modelName: "m7", recordData: [
            "title": .string("hi"),
            "count": .number(1),
            "tags":  .stringset(["a"]),
        ])
        let discovered = SchemaDiscovery.discoverSchema(
            doc: doc, modelNames: ["m7"]
        ).models["m7"]
        XCTAssertEqual(discovered?.fields["title"]?.type, .string)
        XCTAssertEqual(discovered?.fields["count"]?.type, .number)
        XCTAssertEqual(discovered?.fields["tags"]?.type, .stringset)
    }
}
