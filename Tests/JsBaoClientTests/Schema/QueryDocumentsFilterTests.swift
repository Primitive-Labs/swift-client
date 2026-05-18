import XCTest
@testable import JsBaoClient
import YSwift

/// Tests for `QueryOptions.documents` — a scoping shortcut that
/// restricts a cross-doc query to records owned by the listed doc
/// ids. Matches js-bao browser's `options.documents` (browser.js:1146).
///
/// Equivalent to adding `["_meta_doc_id": ["$in": [...]]]` to the
/// filter manually, but more ergonomic and matches the js-bao API.
final class QueryDocumentsFilterTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "docf_items",
        fields: [
            "id":    FieldDescriptor(type: .id),
            "label": FieldDescriptor(type: .string),
            "rank":  FieldDescriptor(type: .number),
        ]
    )

    private func seededTrio() throws -> MultiDocModel {
        SchemaSync.clearCache()
        let multi = MultiDocModel(schema: schema)

        let a = multi.connect(docId: "docA", doc: YDocument())
        _ = try a.create(id: "a1", values: [
            "label": .string("alpha"), "rank": .number(1),
        ])

        SchemaSync.clearCache()
        let b = multi.connect(docId: "docB", doc: YDocument())
        _ = try b.create(id: "b1", values: [
            "label": .string("beta"), "rank": .number(2),
        ])

        SchemaSync.clearCache()
        let c = multi.connect(docId: "docC", doc: YDocument())
        _ = try c.create(id: "c1", values: [
            "label": .string("gamma"), "rank": .number(3),
        ])
        return multi
    }

    func testDocumentsSingleScopeReturnsOnlyThatDoc() throws {
        let multi = try seededTrio()
        let rows = multi.query(nil, options: QueryOptions(documents: ["docA"]))
        let ids = Set(rows.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, ["a1"])
    }

    func testDocumentsMultipleScopeUnionsMatches() throws {
        let multi = try seededTrio()
        let rows = multi.query(nil, options: QueryOptions(documents: ["docA", "docC"]))
        let ids = Set(rows.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, ["a1", "c1"])
    }

    /// Matches js-bao's behavior: an explicit empty list matches
    /// nothing (`WHERE 1 = 0`) rather than everything.
    func testDocumentsEmptyListMatchesNothing() throws {
        let multi = try seededTrio()
        let rows = multi.query(nil, options: QueryOptions(documents: []))
        XCTAssertTrue(rows.isEmpty)
    }

    func testDocumentsNilActsLikeNoScope() throws {
        let multi = try seededTrio()
        let rows = multi.query(nil, options: QueryOptions(documents: nil))
        XCTAssertEqual(rows.count, 3)
    }

    /// Combines with an existing filter — results satisfy BOTH
    /// the filter and the documents scope.
    func testDocumentsCombinesWithFilter() throws {
        let multi = try seededTrio()
        let rows = multi.query(
            ["rank": ["$gte": 2]],
            options: QueryOptions(documents: ["docB"])
        )
        // rank >= 2 matches b1 (rank 2) and c1 (rank 3); documents
        // scope keeps only b1.
        let ids = Set(rows.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, ["b1"])
    }

    /// Count honors the documents scope.
    func testCountRespectsDocumentsScope() throws {
        let multi = try seededTrio()
        let c = multi.count(options: QueryOptions(documents: ["docA", "docB"]))
        XCTAssertEqual(c, 2)
    }

    /// Paged query respects documents scope.
    func testQueryPagedRespectsDocumentsScope() throws {
        let multi = try seededTrio()
        let page = try multi.queryPaged(
            nil,
            options: QueryOptions(
                sortOrder: [("rank", 1)],
                limit: 10,
                documents: ["docA", "docC"]
            )
        )
        XCTAssertEqual(page.data.map { $0["id"] as? String }, ["a1", "c1"])
    }
}
