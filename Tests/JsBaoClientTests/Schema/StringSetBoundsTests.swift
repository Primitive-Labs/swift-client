import XCTest
@testable import JsBaoClient
import YSwift

/// Enforcement of `maxCount` and `maxLength` on stringset fields.
///
/// Mirrors js-bao browser.js:3016-3030:
/// - `maxCount` caps the number of members in the set; exceeding it
///   throws before the write commits.
/// - `maxLength` caps the per-member string length; any single member
///   longer than the limit throws.
///
/// Both are declared at schema time and already round-trip through
/// `_meta_*` and TOML. This test closes the last remaining parity
/// gap — enforcement at write time.
final class StringSetBoundsTests: XCTestCase {

    // MARK: - maxCount

    func testCreateThrowsWhenMaxCountExceeded() {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "bounds_mc",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "tags": FieldDescriptor(type: .stringset, maxCount: 2),
            ]
        ))
        XCTAssertThrowsError(try model.create(id: "r1", values: [
            "tags": .stringset(["a", "b", "c"]),
        ])) { err in
            guard case let FieldValidationError.stringsetMaxCountExceeded(
                field, modelName, limit, got
            ) = err else {
                return XCTFail("Expected stringsetMaxCountExceeded, got \(err)")
            }
            XCTAssertEqual(field, "tags")
            XCTAssertEqual(modelName, "bounds_mc")
            XCTAssertEqual(limit, 2)
            XCTAssertEqual(got, 3)
        }
    }

    func testUpdateThrowsWhenMaxCountExceeded() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "bounds_mc_u",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "tags": FieldDescriptor(type: .stringset, maxCount: 2),
            ]
        ))
        _ = try model.create(id: "r1", values: [
            "tags": .stringset(["a"]),
        ])
        XCTAssertThrowsError(try model.update(id: "r1", values: [
            "tags": .stringset(["a", "b", "c"]),
        ]))
    }

    /// Exactly at the cap is allowed — `>` not `>=`.
    func testMaxCountExactlyAtLimitAllowed() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "bounds_mc_edge",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "tags": FieldDescriptor(type: .stringset, maxCount: 2),
            ]
        ))
        XCTAssertNoThrow(try model.create(id: "r1", values: [
            "tags": .stringset(["a", "b"]),
        ]))
    }

    /// A field without `maxCount` declared accepts any count.
    func testUnboundedStringsetAcceptsLargeSets() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "bounds_mc_free",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "tags": FieldDescriptor(type: .stringset), // no maxCount
            ]
        ))
        let big = (0..<100).map { "m\($0)" }
        XCTAssertNoThrow(try model.create(id: "r1", values: [
            "tags": .stringset(Set(big)),
        ]))
    }

    // MARK: - maxLength

    func testCreateThrowsWhenMemberExceedsMaxLength() {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "bounds_ml",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "tags": FieldDescriptor(type: .stringset, maxLength: 4),
            ]
        ))
        XCTAssertThrowsError(try model.create(id: "r1", values: [
            "tags": .stringset(["ok", "way-too-long"]),
        ])) { err in
            guard case let FieldValidationError.stringsetMemberTooLong(
                field, modelName, limit, member
            ) = err else {
                return XCTFail("Expected stringsetMemberTooLong, got \(err)")
            }
            XCTAssertEqual(field, "tags")
            XCTAssertEqual(modelName, "bounds_ml")
            XCTAssertEqual(limit, 4)
            XCTAssertEqual(member, "way-too-long")
        }
    }

    /// Exactly at the limit is allowed.
    func testMaxLengthExactlyAtLimitAllowed() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "bounds_ml_edge",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "tags": FieldDescriptor(type: .stringset, maxLength: 5),
            ]
        ))
        XCTAssertNoThrow(try model.create(id: "r1", values: [
            "tags": .stringset(["12345"]), // exactly 5
        ]))
    }

    // MARK: - maxLength + maxCount together

    func testBothBoundsActiveSimultaneously() {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "bounds_both",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "tags": FieldDescriptor(
                    type: .stringset, maxLength: 3, maxCount: 2
                ),
            ]
        ))
        // Violates maxLength — one member is 4 chars.
        XCTAssertThrowsError(try model.create(id: "r1", values: [
            "tags": .stringset(["ok", "fail"]),
        ]))
        // Violates maxCount — three members.
        XCTAssertThrowsError(try model.create(id: "r2", values: [
            "tags": .stringset(["a", "b", "c"]),
        ]))
        // Valid — within both bounds.
        XCTAssertNoThrow(try model.create(id: "r3", values: [
            "tags": .stringset(["a", "b"]),
        ]))
    }

    // MARK: - Failed validation leaves no partial record

    /// A failed stringset validation must not leak an empty record
    /// into the Y.Map (same no-partial-write contract as required
    /// field validation).
    func testFailedStringsetValidationLeavesNoPartialRecord() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "bounds_clean",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "tags": FieldDescriptor(type: .stringset, maxCount: 1),
            ]
        ))
        _ = try? model.create(id: "r_bad", values: [
            "tags": .stringset(["a", "b", "c"]),
        ])
        XCTAssertNil(model.find(id: "r_bad"),
                     "Rejected write must not leave a record behind")
    }
}
