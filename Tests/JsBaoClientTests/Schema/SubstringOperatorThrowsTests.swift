import XCTest
@testable import JsBaoClient
import YSwift

/// #1119 — substring operators (`$startsWith` / `$endsWith` /
/// `$containsText`) must THROW where js-bao throws instead of silently
/// no-matching. js-bao raises `InvalidOperatorError` on a non-string/
/// -stringset field, a non-string value, an oversize (>1024) value, and
/// more than one substring op per field; the Swift client now throws
/// `JsBaoError(.invalidArgument)` carrying `field` / `operator` /
/// `fieldType` in `details`, matching the #1118 projection precedent.
///
/// Whitespace-only input is the one non-throw edge: js-bao's
/// `buildLikePattern` returns `null` (no condition), so the op must
/// contribute nothing — not a false `0` clause.
final class SubstringOperatorThrowsTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "throw_items",
        fields: [
            "id":       FieldDescriptor(type: .id),
            "title":    FieldDescriptor(type: .string),
            "priority": FieldDescriptor(type: .number, indexed: true),
            "tags":     FieldDescriptor(type: .stringset),
        ]
    )

    private func seeded() throws -> DynamicModel {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "a", values: [
            "title": .string("Alpha widget"), "priority": .number(5),
            "tags": .stringset(["draft-1", "approved"]),
        ])
        _ = try model.create(id: "b", values: [
            "title": .string("Beta gadget"), "priority": .number(10),
            "tags": .stringset(["published"]),
        ])
        return model
    }

    /// Assert the closure throws a `JsBaoError(.invalidArgument)` whose
    /// `details` carry the expected `fieldType`.
    private func assertSubstringThrows(
        expectedFieldType: String,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> Any
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let jbe = error as? JsBaoError else {
                XCTFail("expected JsBaoError, got \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(jbe.code, .invalidArgument, file: file, line: line)
            XCTAssertEqual(
                jbe.details?["field"].flatMap { if case let .string(s) = $0 { return s } else { return nil } } != nil,
                true, "details should carry `field`", file: file, line: line
            )
            XCTAssertEqual(
                jbe.details?["fieldType"],
                .string(expectedFieldType),
                "details.fieldType should be \(expectedFieldType): \(String(describing: jbe.details))",
                file: file, line: line
            )
        }
    }

    // MARK: - Non-string field throws (replaces WireFormatGapFixes C/D/E)

    func testStartsWithOnNumberFieldThrows() throws {
        let model = try seeded()
        assertSubstringThrows(expectedFieldType: "number") {
            try model.query(["priority": ["$startsWith": "1"]])
        }
    }

    func testEndsWithOnNumberFieldThrows() throws {
        let model = try seeded()
        assertSubstringThrows(expectedFieldType: "number") {
            try model.query(["priority": ["$endsWith": "5"]])
        }
    }

    func testContainsTextOnNumberFieldThrows() throws {
        let model = try seeded()
        assertSubstringThrows(expectedFieldType: "number") {
            try model.query(["priority": ["$containsText": "1"]])
        }
    }

    // MARK: - Non-string value throws

    func testNonStringValueThrows() throws {
        let model = try seeded()
        assertSubstringThrows(expectedFieldType: "string") {
            try model.query(["title": ["$startsWith": 5]])
        }
    }

    func testNonStringValueOnStringsetThrows() throws {
        let model = try seeded()
        assertSubstringThrows(expectedFieldType: "stringset") {
            try model.query(["tags": ["$containsText": 7]])
        }
    }

    // MARK: - Oversize value: throws strictly over 1024, not at 1024

    func testOversizeValueThrows() throws {
        let model = try seeded()
        let oversize = String(repeating: "x", count: 1025)
        assertSubstringThrows(expectedFieldType: "string") {
            try model.query(["title": ["$containsText": .string(oversize)]])
        }
    }

    func testExactly1024DoesNotThrow() throws {
        let model = try seeded()
        let exact = String(repeating: "x", count: 1024)
        // Exactly 1024 is allowed (js-bao throws only on > 1024). No match
        // is expected, but the call must NOT throw.
        let rows = try model.query(["title": ["$containsText": .string(exact)]])
        XCTAssertEqual(rows.count, 0)
    }

    // MARK: - More than one substring op per field throws

    func testMultipleSubstringOpsPerFieldThrows() throws {
        let model = try seeded()
        assertSubstringThrows(expectedFieldType: "string") {
            try model.query(["title": ["$startsWith": "a", "$endsWith": "b"]])
        }
    }

    // MARK: - Whitespace-only value is a no-op (no throw, contributes no condition)

    func testWhitespaceOnlyValueDoesNotThrow() throws {
        let model = try seeded()
        // js-bao's buildLikePattern returns null for whitespace-only → the
        // op adds no condition, so every row matches (not "no rows").
        let rows = try model.query(["title": ["$containsText": "   "]])
        XCTAssertEqual(
            Set(rows.compactMap { $0["id"]?.stringValue }), ["a", "b"],
            "whitespace-only substring op contributes no condition (js-bao no-op)"
        )
    }

    // MARK: - Valid input still works (with `try`)

    func testValidSubstringOnStringFieldStillReturnsRows() throws {
        let model = try seeded()
        let rows = try model.query(["title": ["$startsWith": "Alpha"]])
        XCTAssertEqual(rows.compactMap { $0["id"]?.stringValue }, ["a"])
    }

    func testValidSubstringOnStringsetFieldStillReturnsRows() throws {
        let model = try seeded()
        let rows = try model.query(["tags": ["$startsWith": "draft-"]])
        XCTAssertEqual(rows.compactMap { $0["id"]?.stringValue }, ["a"])
    }

    // MARK: - Throws propagate through count / aggregate

    func testCountThrowsOnBadSubstringInput() throws {
        let model = try seeded()
        assertSubstringThrows(expectedFieldType: "number") {
            try model.count(["priority": ["$startsWith": "1"]])
        }
    }

    func testAggregateThrowsOnBadSubstringInput() throws {
        let model = try seeded()
        assertSubstringThrows(expectedFieldType: "number") {
            try model.aggregate(AggregateOptions(
                operations: [AggregateOperation(type: .count)],
                filter: ["priority": ["$startsWith": "1"]]
            ))
        }
    }

    // MARK: - Throws inside $and / $or nesting

    func testThrowsInsideAndNesting() throws {
        let model = try seeded()
        assertSubstringThrows(expectedFieldType: "number") {
            try model.query([
                "$and": [["priority": ["$startsWith": "1"]]]
            ])
        }
    }

    // MARK: - Cross-doc via MultiDocModel throws identically

    func testThrowsAcrossDocsViaMultiDocModel() throws {
        SchemaSync.clearCache()
        let multi = MultiDocModel(schema: schema)
        let a = multi.connect(docId: "docA", doc: YDocument())
        _ = try a.create(id: "a1", values: ["title": .string("A"), "priority": .number(3)])
        assertSubstringThrows(expectedFieldType: "number") {
            try multi.query(["priority": ["$startsWith": "3"]])
        }
    }
}
