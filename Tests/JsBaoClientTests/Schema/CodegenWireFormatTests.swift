import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Pin the **on-document** wire format produced by codegen-emitted
/// structs so a future codec change can't silently drift.
///
/// The wire format is what a JS client opening the same Y.Doc sees in
/// each record's nested Y.Map. `PrimitiveValueTests` covers the unit-
/// level `encodedForYrs()` output, but those tests don't run a real
/// write through `TypedModel<T>` — so a regression in the codegen-
/// emitted `primitiveValues()` (or in the runtime path that calls it)
/// could go un-caught.
///
/// These tests:
///   1. Build a generated record with values for every field type.
///   2. Persist via `TypedModel<T>(doc:).create(...)`.
///   3. Open the underlying `YrsMap` and read each field's raw string.
///   4. Assert the exact wire-encoded bytes against the documented
///      contract in `PrimitiveValue.encodedForYrs()`.
///
/// If a new codec format ever ships, these tests force a deliberate
/// update — silent drift would fail-loud here, not on a customer's
/// doc that someone else's JS client wrote.
final class CodegenWireFormatTests: XCTestCase {

    // MARK: - Per-type wire format

    func testStringField_isJsonEncodedQuotedString() throws {
        let (doc, _) = try persist(TaskRecord(
            id: "wf-string", title: "Ship it"
        ))
        let raw = try readRawField(doc: doc, modelName: "tasks", recordId: "wf-string", field: "title")
        // String fields encode as JSON-encoded strings: `"value"`.
        // The outer quotes are part of the wire bytes.
        XCTAssertEqual(raw, "\"Ship it\"",
                       "string field should be JSON-encoded with literal outer quotes")
    }

    func testIdField_isMirroredInsideRecordMapAsJsonEncodedString() throws {
        // The id appears in TWO places on the wire:
        //   1. As the OUTER key of the record's nested map under
        //      `<modelName>` (this is the canonical lookup path).
        //   2. As an `"id"` entry INSIDE the nested record map,
        //      JSON-encoded the same way as a `string`/`date` field.
        //
        // The double-stamping is intentional and load-bearing for
        // cross-client interop — js-bao's `extractItemData` reads
        // the inner `id`, so records shared cross-client resolve to
        // the same identity even from a snapshot path that doesn't
        // carry the outer key (e.g. iterating root map entries
        // without re-keying).
        //
        // Codegen's `primitiveValues()` deliberately *excludes* `id`
        // because the runtime writes it separately during create —
        // double-writing would be redundant and risk drift.
        let (doc, _) = try persist(TaskRecord(id: "wf-id", title: "x"))
        doc.transactSync { txn in
            guard let root = txn.transactionGetMap(name: "tasks") else {
                XCTFail("missing root tasks map"); return
            }
            guard let rec = root.getMap(tx: txn, key: "wf-id") else {
                XCTFail("missing record map at id 'wf-id'"); return
            }
            let idEntry = try? rec.get(tx: txn, key: "id")
            XCTAssertEqual(idEntry, "\"wf-id\"",
                           "inner 'id' entry should be JSON-encoded string matching the outer key")
        }
    }

    func testNumberField_integerHasNoTrailingZero() throws {
        // Codegen → primitiveValues stores integer-valued Doubles
        // without trailing `.0`. Wire bytes mirror what JS produces
        // for an Int.
        let (doc, _) = try persist(TaskRecord(
            id: "wf-num-int", priority: 3, title: "x"
        ))
        let raw = try readRawField(doc: doc, modelName: "tasks", recordId: "wf-num-int", field: "priority")
        XCTAssertEqual(raw, "3",
                       "integer-valued number should encode without trailing .0")
    }

    func testNumberField_floatPreservesFraction() throws {
        let (doc, _) = try persist(TaskRecord(
            id: "wf-num-float", priority: 2.5, title: "x"
        ))
        let raw = try readRawField(doc: doc, modelName: "tasks", recordId: "wf-num-float", field: "priority")
        XCTAssertEqual(raw, "2.5",
                       "fractional number should encode with the decimal point")
    }

    func testNumberField_negative() throws {
        let (doc, _) = try persist(TaskRecord(
            id: "wf-num-neg", priority: -7.25, title: "x"
        ))
        let raw = try readRawField(doc: doc, modelName: "tasks", recordId: "wf-num-neg", field: "priority")
        XCTAssertEqual(raw, "-7.25",
                       "negative numbers encode with leading minus, no JSON wrapping")
    }

    func testBooleanField_encodesAsBareLiteral() throws {
        let (doc, _) = try persist(CrashTestRecord(
            id: "wf-bool-t", active: true, requiredTags: []
        ))
        let raw = try readRawField(doc: doc, modelName: "crashTest", recordId: "wf-bool-t", field: "active")
        XCTAssertEqual(raw, "true",
                       "boolean true should encode as the bare 'true' literal (no quotes)")

        let (doc2, _) = try persist(CrashTestRecord(
            id: "wf-bool-f", active: false, requiredTags: []
        ))
        let raw2 = try readRawField(doc: doc2, modelName: "crashTest", recordId: "wf-bool-f", field: "active")
        XCTAssertEqual(raw2, "false",
                       "boolean false should encode as the bare 'false' literal (no quotes)")
    }

    func testDateField_isJsonEncodedString() throws {
        // Date fields travel as JSON-encoded ISO-8601 strings — same
        // wire shape as `string` / `id`. The codegen reads them back
        // via `.asDateString` on `PrimitiveValue`.
        let (doc, _) = try persist(TaskRecord(
            id: "wf-date",
            createdAt: "2026-04-27T12:34:56Z",
            title: "x"
        ))
        let raw = try readRawField(doc: doc, modelName: "tasks", recordId: "wf-date", field: "createdAt")
        XCTAssertEqual(raw, "\"2026-04-27T12:34:56Z\"",
                       "date should be JSON-encoded just like string")
    }

    func testStringsetField_isStoredAsNestedYMapKeyedByMember() throws {
        // Stringsets do NOT travel as a delimited string on the parent
        // record. They live in a nested Y.Map at `record[fieldName]`,
        // one key per member, value irrelevant. Iterate the keys to
        // confirm the set.
        let (doc, _) = try persist(CrashTestRecord(
            id: "wf-set", requiredTags: ["alpha", "beta", "gamma"]
        ))
        doc.transactSync { txn in
            guard let root = txn.transactionGetMap(name: "crashTest"),
                  let rec  = root.getMap(tx: txn, key: "wf-set"),
                  let nested = rec.getMap(tx: txn, key: "requiredTags") else {
                XCTFail("expected nested Y.Map for stringset 'requiredTags'"); return
            }
            // Inner-map keys ARE the set members.
            let collector = KeyCollector()
            nested.keys(tx: txn, delegate: collector)
            XCTAssertEqual(Set(collector.keys), ["alpha", "beta", "gamma"],
                           "stringset members should be the keys of the nested map")
        }
    }

    func testStringsetField_emptyDoesNotProduceNestedMap() throws {
        // An empty stringset: codegen-emitted `primitiveValues()`
        // includes the field (it's `Set<String>` type, not optional
        // here — it's required), so the runtime has to handle the
        // empty case. Verify the nested map either exists with zero
        // members or doesn't exist at all — both are fine reads
        // (`init?(record:)` decodes to empty Set either way).
        let (doc, _) = try persist(CrashTestRecord(
            id: "wf-empty-set", requiredTags: []
        ))
        doc.transactSync { txn in
            guard let root = txn.transactionGetMap(name: "crashTest"),
                  let rec  = root.getMap(tx: txn, key: "wf-empty-set") else {
                XCTFail("expected record map"); return
            }
            if let nested = rec.getMap(tx: txn, key: "requiredTags") {
                let collector = KeyCollector()
                nested.keys(tx: txn, delegate: collector)
                XCTAssertEqual(collector.keys.count, 0,
                               "empty stringset's nested map should have no keys")
            }
            // Otherwise nested-map absent — legitimate empty representation.
        }
    }

    // MARK: - Encoding edge cases

    func testStringField_escapesSpecialChars() throws {
        // The wire encoder handles `"`, `\`, `\n`, `\r`, `\t` and
        // control chars per RFC 8259. Pin the most-common cases so a
        // change in the escape table is loud.
        let (doc, _) = try persist(TaskRecord(
            id: "wf-escape", title: "she said \"hi\"\nok"
        ))
        let raw = try readRawField(doc: doc, modelName: "tasks", recordId: "wf-escape", field: "title")
        XCTAssertEqual(raw, "\"she said \\\"hi\\\"\\nok\"",
                       "embedded quotes and newlines should be JSON-escaped")
    }

    func testStringField_unicodeRoundTripsRaw() throws {
        // BMP characters travel as-is inside the JSON string. Pin the
        // contract — emitting `\uXXXX` would break parity with JS,
        // which writes the raw UTF-8 bytes.
        let (doc, _) = try persist(TaskRecord(
            id: "wf-unicode", title: "naïve 日本語 🎉"
        ))
        let raw = try readRawField(doc: doc, modelName: "tasks", recordId: "wf-unicode", field: "title")
        XCTAssertEqual(raw, "\"naïve 日本語 🎉\"",
                       "unicode characters travel raw inside the JSON string envelope")
    }

    // MARK: - Helpers

    /// Persist via the typed wrapper, then return the live doc + the
    /// owning model so callers can drop into a `transactSync` block
    /// to inspect raw Y.Map state.
    private func persist<M: PrimitiveModel>(_ record: M) throws -> (YDocument, TypedModel<M>) {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = TypedModel<M>(doc: doc)
        _ = try model.create(record)
        return (doc, model)
    }

    /// Read one field's raw on-wire string out of the nested record
    /// map. Throws if the model/record/field path doesn't resolve —
    /// that's a test-setup mistake, not a wire-format failure.
    private func readRawField(
        doc: YDocument, modelName: String, recordId: String, field: String
    ) throws -> String {
        var captured: String?
        doc.transactSync { txn in
            guard let root = txn.transactionGetMap(name: modelName) else {
                XCTFail("missing root map '\(modelName)'"); return
            }
            guard let rec = root.getMap(tx: txn, key: recordId) else {
                XCTFail("missing record '\(recordId)' in '\(modelName)'"); return
            }
            captured = try? rec.get(tx: txn, key: field)
        }
        guard let raw = captured else {
            throw NSError(
                domain: "CodegenWireFormatTests",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "field '\(field)' was nil on '\(modelName)#\(recordId)'"
                ]
            )
        }
        return raw
    }

    /// Collects map keys in iteration order. `YrsMap.keys(tx:delegate:)`
    /// pushes each key by calling back into `call(value:)`.
    private final class KeyCollector: YrsMapIteratorDelegate {
        var keys: [String] = []
        func call(value: String) { keys.append(value) }
    }
}
