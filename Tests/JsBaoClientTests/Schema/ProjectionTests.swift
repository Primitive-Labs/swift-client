import XCTest
@testable import JsBaoClient
import YSwift

/// Query-level projection: pick a subset of fields to return.
/// Mirrors js-bao browser's `options.projection: { field: 1 | 0 }`
/// — 1 = include, 0 = exclude, can't mix include and exclude in one
/// projection. `id` is always returned.
///
/// Projection applies to the base query and, via `Include.projection`,
/// to each included record.
///
/// Closes gap (A) from the browser-vs-Swift audit.
final class ProjectionTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "proj_items",
        fields: [
            "id":    FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string),
            "body":  FieldDescriptor(type: .string),
            "score": FieldDescriptor(type: .number),
            "tags":  FieldDescriptor(type: .stringset),
        ]
    )

    private func seeded() throws -> DynamicModel {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "p1", values: [
            "title": .string("first"),
            "body":  .string("body one"),
            "score": .number(10),
            "tags":  .stringset(["red", "urgent"]),
        ])
        _ = try model.create(id: "p2", values: [
            "title": .string("second"),
            "body":  .string("body two"),
            "score": .number(20),
            "tags":  .stringset(["blue"]),
        ])
        return model
    }

    // MARK: - Include-mode projection

    /// Projection `{ title: 1 }` returns only `id` + `title`.
    func testProjectionIncludeModeReturnsOnlyListedFields() throws {
        let model = try seeded()
        let rows = model.query(
            ["id": "p1"],
            options: QueryOptions(projection: ["title": 1])
        )
        let row = rows.first ?? [:]
        XCTAssertEqual(row["id"] as? String, "p1")
        XCTAssertEqual(row["title"] as? String, "first")
        XCTAssertNil(row["body"], "body should be excluded by projection")
        XCTAssertNil(row["score"], "score should be excluded by projection")
        XCTAssertNil(row["tags"], "stringset tags should be excluded by projection")
    }

    /// `id` is always included, even when not listed in an include-
    /// mode projection.
    func testProjectionAlwaysIncludesId() throws {
        let model = try seeded()
        let rows = model.query(nil, options: QueryOptions(
            sortOrder: [("id", 1)], projection: ["title": 1]
        ))
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }, ["p1", "p2"])
    }

    /// Include-mode projection that names a stringset field gets the
    /// stringset populated as `[String]`, not omitted.
    func testProjectionIncludeModeWithStringsetField() throws {
        let model = try seeded()
        let rows = model.query(
            ["id": "p1"],
            options: QueryOptions(projection: ["tags": 1])
        )
        let row = rows.first ?? [:]
        XCTAssertEqual(row["id"] as? String, "p1")
        XCTAssertEqual(Set(row["tags"] as? [String] ?? []), ["red", "urgent"])
        XCTAssertNil(row["title"])
    }

    // MARK: - Exclude-mode projection

    /// Projection `{ body: 0 }` returns every field EXCEPT body.
    func testProjectionExcludeModeOmitsListedFields() throws {
        let model = try seeded()
        let rows = model.query(
            ["id": "p1"],
            options: QueryOptions(projection: ["body": 0])
        )
        let row = rows.first ?? [:]
        XCTAssertEqual(row["id"] as? String, "p1")
        XCTAssertEqual(row["title"] as? String, "first")
        XCTAssertEqual(row["score"] as? Double, 10)
        XCTAssertNil(row["body"])
        // Stringset still populated (not excluded).
        XCTAssertEqual(Set(row["tags"] as? [String] ?? []), ["red", "urgent"])
    }

    /// Exclude-mode projection that names a stringset field omits it.
    func testProjectionExcludeModeOmitsStringsetField() throws {
        let model = try seeded()
        let rows = model.query(
            ["id": "p1"],
            options: QueryOptions(projection: ["tags": 0])
        )
        let row = rows.first ?? [:]
        XCTAssertEqual(row["title"] as? String, "first")
        XCTAssertNil(row["tags"])
    }

    // MARK: - Include resolver projection

    /// Include spec with `projection` narrows the fields on related
    /// records. User's `name` only; `role` is excluded.
    func testRefersToIncludeWithProjection() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let users = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "proj_users",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "name": FieldDescriptor(type: .string),
                "role": FieldDescriptor(type: .string),
            ]
        ))
        let posts = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "proj_posts",
            fields: [
                "id":     FieldDescriptor(type: .id),
                "userId": FieldDescriptor(type: .string),
                "title":  FieldDescriptor(type: .string),
            ]
        ))
        _ = try users.create(id: "u1", values: [
            "name": .string("Alice"), "role": .string("admin"),
        ])
        _ = try posts.create(id: "p1", values: [
            "userId": .string("u1"), "title": .string("one"),
        ])

        let rows = try posts.query(["id": "p1"], options: nil, include: [
            Include(type: .refersTo, target: users,
                    sourceField: "userId",
                    projection: ["name": 1],
                    resultKey: "author")
        ])
        let author = (rows[0]["_related"] as? [String: Any])?["author"]
            as? [String: Any] ?? [:]
        XCTAssertEqual(author["id"] as? String, "u1")
        XCTAssertEqual(author["name"] as? String, "Alice")
        XCTAssertNil(author["role"],
                     "role should be excluded by include projection")
    }

    // MARK: - Paged queries

    /// `queryPaged` must honor `projection` the same way `query` does.
    /// Previously the paged path rebuilt QueryOptions internally for
    /// the over-limit fetch and dropped `projection`, so paged results
    /// leaked every field.
    func testPagedQueryHonorsProjection() throws {
        let model = try seeded()
        let page = try model.queryPaged(
            nil,
            options: QueryOptions(
                sortOrder: [("id", 1)], limit: 1, projection: ["title": 1]
            )
        )
        XCTAssertEqual(page.data.count, 1)
        let row = page.data[0]
        XCTAssertEqual(row["id"] as? String, "p1")
        XCTAssertEqual(row["title"] as? String, "first")
        XCTAssertNil(row["body"], "body should be excluded in paged result")
        XCTAssertNil(row["score"])
        XCTAssertNil(row["tags"])
    }

    /// Exclude-mode projection on a paged query.
    func testPagedQueryHonorsExcludeProjection() throws {
        let model = try seeded()
        let page = try model.queryPaged(
            nil,
            options: QueryOptions(
                sortOrder: [("id", 1)], limit: 1, projection: ["body": 0]
            )
        )
        let row = page.data.first ?? [:]
        XCTAssertEqual(row["title"] as? String, "first")
        XCTAssertNil(row["body"])
        XCTAssertEqual(row["score"] as? Double, 10)
    }
}
