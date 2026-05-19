import XCTest
@testable import JsBaoClient
import YSwift

/// Cross-language wire-format parity for **codegen-emitted Swift
/// structs** specifically. The existing
/// `CrossPlatformRoundTripTests` exercises the wire contract using
/// hand-built `PrimitiveSchema` literals; this file verifies that
/// what `swift-bao-codegen` actually emits + the runtime path it
/// drives produce wire bytes identical to what js-bao writes for the
/// same schema, and vice versa.
///
/// Why this matters: codegen output is the recommended path for Swift
/// apps. If it ever diverges from js-bao's encoding (e.g. the codegen
/// emits a stringset wrong, or excludes a field that js-bao expects),
/// cross-client docs corrupt silently. These two tests sit on the
/// "must-not-drift" boundary.
///
/// Both tests skip via `XCTSkip` if Node or the harness scripts
/// aren't available — same gating as the rest of the cross-platform
/// suite.
final class CrossPlatformCodegenTests: XCTestCase {

    // MARK: - Swift codegen writes → JS reads

    /// `TypedModel<TaskRecord>` writes a record using the codegen-
    /// emitted struct's `primitiveValues()`; JS reads back through
    /// the standard reader and surfaces every field the way js-bao
    /// would for any other client. Catches:
    ///
    ///   - `id` mirroring (the inner `id` entry the runtime stamps
    ///     for cross-client identity resolution)
    ///   - `string` / `number` / `boolean` / `date` / `stringset`
    ///     wire shapes
    ///   - Optional-field omission semantics (codegen excludes nil
    ///     optionals from `primitiveValues()`; JS shouldn't see them)
    func testCodegenStructWritesRecord_JsReadsAllFieldsCorrectly() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = TypedModel<TaskRecord>(doc: doc)

        // Use the codegen-emitted designated init. Every field type
        // covered: id (required, non-optional String), date (optional
        // String), number (optional Double), stringset (optional
        // Set<String>), string (required, non-optional String).
        _ = try model.create(TaskRecord(
            id: "cgx-1",
            createdAt: "2026-04-27T08:30:00Z",
            priority: 7,
            tags: ["urgent", "ship-blocker"],
            title: "Land cross-platform parity"
        ))

        let update = CrossPlatformHarness.updateBytes(of: doc)
        let rec = try CrossPlatformHarness.runReader(
            update: update, arguments: ["read-record", "tasks", "cgx-1"]
        ) as? [String: Any]
        XCTAssertNotNil(rec, "JS reader returned no record")

        // Identity: id stamped both as outer key and inner mirror.
        XCTAssertEqual(rec?["id"] as? String, "cgx-1")
        // Scalars.
        XCTAssertEqual(rec?["title"] as? String, "Land cross-platform parity")
        XCTAssertEqual(rec?["priority"] as? Int, 7,
                       "integer-valued Double should surface in JS as a plain integer (no .0)")
        XCTAssertEqual(rec?["createdAt"] as? String, "2026-04-27T08:30:00Z")
        // Stringset.
        let tags = rec?["tags"] as? [String: Any]
        XCTAssertEqual(tags?["_type"] as? String, "stringset")
        XCTAssertEqual(
            (tags?["entries"] as? [String])?.sorted(),
            ["ship-blocker", "urgent"],
            "stringset members should round-trip in any order"
        )
    }

    /// Optional fields that codegen leaves nil in `primitiveValues()`
    /// must NOT appear in the JS-side record. Catches a regression
    /// where the emitter accidentally writes nil-as-something.
    func testCodegenStructOmitsNilOptionals_JsReadsSparseRecord() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = TypedModel<TaskRecord>(doc: doc)

        // Only the required `title` is set; everything else stays nil.
        _ = try model.create(TaskRecord(
            id: "cgx-sparse",
            title: "Bare bones"
        ))

        let update = CrossPlatformHarness.updateBytes(of: doc)
        let rec = try CrossPlatformHarness.runReader(
            update: update, arguments: ["read-record", "tasks", "cgx-sparse"]
        ) as? [String: Any]
        XCTAssertNotNil(rec)

        XCTAssertEqual(rec?["id"] as? String, "cgx-sparse")
        XCTAssertEqual(rec?["title"] as? String, "Bare bones")
        // The optional fields should be absent from the JS-side
        // dict. We assert nil rather than equality because js-bao
        // may surface missing keys as either `undefined` (JSON `null`)
        // or absent — either is acceptable.
        XCTAssertNil(rec?["priority"], "nil optional should not appear in JS readout")
        XCTAssertNil(rec?["createdAt"], "nil optional should not appear in JS readout")
        XCTAssertNil(rec?["tags"], "nil stringset should not appear in JS readout")
    }

    // MARK: - JS writes → Swift codegen reads

    /// JS authors a `tasks` record using its standard write path;
    /// Swift opens the same doc and reads back via the codegen-
    /// emitted `TypedModel<TaskRecord>.find(id:)`. Catches:
    ///
    ///   - The codegen-emitted `init?(record:)` decoding js-bao's
    ///     wire format correctly for every field type
    ///   - Required-field guards firing as expected when js-bao
    ///     writes records that satisfy the codegen schema's required
    ///     fields
    func testJsWritesRecord_CodegenStructDecodesAllFields() throws {
        // Spec format mirrors what `writer.cjs` accepts (see existing
        // CrossPlatformRoundTripTests for the schema shape).
        // Spec format: see harness/writer.cjs — records are nested
        // dict (modelName → id → fields), stringsets are tagged
        // dicts with `_type` and `entries`.
        let spec: [String: Any] = [
            "schemas": [[
                "name": "tasks",
                "fields": [
                    "id":        ["type": "id"],
                    "createdAt": ["type": "date"],
                    "priority":  ["type": "number", "indexed": true],
                    "tags":      ["type": "stringset"],
                    "title":     ["type": "string", "required": true],
                ],
            ]],
            "records": [
                "tasks": [
                    "js-side-1": [
                        "title":     "Authored by JS",
                        "priority":  3,
                        "createdAt": "2026-04-27T18:00:00Z",
                        "tags":      ["_type": "stringset", "entries": ["alpha", "beta"]],
                    ],
                ],
            ],
        ]
        let update = try CrossPlatformHarness.runWriter(spec: spec)

        let doc = YDocument()
        SchemaSync.clearCache()
        try CrossPlatformHarness.apply(update: update, to: doc)

        let model = TypedModel<TaskRecord>(doc: doc)
        let read = try XCTUnwrap(model.find(id: "js-side-1"),
                                 "codegen TypedModel.find returned nil for JS-authored record")

        XCTAssertEqual(read.id,        "js-side-1")
        XCTAssertEqual(read.title,     "Authored by JS")
        XCTAssertEqual(read.priority,  3,
                       "JS-authored number should decode through codegen-emitted Double cast")
        XCTAssertEqual(read.createdAt, "2026-04-27T18:00:00Z")
        XCTAssertEqual(read.tags,      ["alpha", "beta"],
                       "JS-authored stringset should decode through codegen-emitted Set<String>")
    }

    /// JS writes a record missing the required `title`. The codegen-
    /// emitted `init?(record:)` should return nil — the typed find
    /// surfaces that as a nil result. Pins required-field semantics
    /// across the language boundary.
    func testJsWritesRecordMissingRequired_CodegenInitReturnsNil() throws {
        let spec: [String: Any] = [
            "schemas": [[
                "name": "tasks",
                "fields": [
                    "id":    ["type": "id"],
                    "title": ["type": "string", "required": true],
                ],
            ]],
            "records": [
                "tasks": [
                    "js-missing-req": [String: Any]()
                    // No `title` written.
                ],
            ],
        ]
        let update = try CrossPlatformHarness.runWriter(spec: spec)

        let doc = YDocument()
        SchemaSync.clearCache()
        try CrossPlatformHarness.apply(update: update, to: doc)

        let model = TypedModel<TaskRecord>(doc: doc)
        let read = model.find(id: "js-missing-req")
        XCTAssertNil(read,
                     "codegen-emitted init?(record:) should return nil when a required field is missing — typed find surfaces that as nil")
    }
}
