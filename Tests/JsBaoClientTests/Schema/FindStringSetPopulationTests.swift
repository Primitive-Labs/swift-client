import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// #2485 — `MultiDocModel.find(id:)` and `findByUnique(constraint:…)` used to
/// return rows whose stringset fields were missing: `find` ran the engine query
/// without `stringsetFields:`, so the post-query junction-table population pass
/// never ran, and `findByUnique` built its row by hand and rendered the
/// stringset as a comma-joined `String` the row decoder can't read.
///
/// Both paths must return the same row shape `query` does — stringset members
/// as `[String]`, and `[]` for a record with no members — so `Model.find(_:)`
/// and `Model.findByUnique(_:_:)` return the record `Model.query` returns.
/// That matches js-bao, where `find` and `query` yield equivalent records.
final class FindStringSetPopulationTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "fss_docs",
        fields: [
            "id":    FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string),
            "email": FieldDescriptor(type: .string, unique: true),
            "tags":  FieldDescriptor(type: .stringset),
        ]
    )

    override func setUp() {
        super.setUp()
        SchemaSync.clearCache()
        JsBaoClient.clearDefault()
    }

    override func tearDown() {
        JsBaoClient.clearDefault()
        super.tearDown()
    }

    // MARK: - find

    func testFindPopulatesStringsetMembers() throws {
        let multi = MultiDocModel(schema: schema)
        let model = multi.connect(docId: "docA", doc: YDocument())
        _ = try model.create(id: "d1", values: [
            "title": .string("first"),
            "tags":  .stringset(["a", "b"]),
        ])

        let located = try XCTUnwrap(multi.find(id: "d1"))
        let tags = try XCTUnwrap(
            located.row["tags"]?.stringArrayValue,
            "find must return stringset members as [String], the same shape query returns"
        )
        XCTAssertEqual(Set(tags), ["a", "b"])
    }

    /// The population pass gives every row a stringset key even when the
    /// record has no members, so callers get one shape rather than
    /// "absent means empty, sometimes".
    func testFindReturnsEmptyArrayWhenTheRecordHasNoMembers() throws {
        let multi = MultiDocModel(schema: schema)
        let model = multi.connect(docId: "docA", doc: YDocument())
        _ = try model.create(id: "d1", values: ["title": .string("no tags")])

        let located = try XCTUnwrap(multi.find(id: "d1"))
        let tags = try XCTUnwrap(located.row["tags"]?.stringArrayValue)
        XCTAssertTrue(tags.isEmpty)
    }

    /// `find` and `query` must agree field for field — the whole point of
    /// #2485 is that they didn't.
    func testFindAndQueryReturnTheSameStringset() throws {
        let multi = MultiDocModel(schema: schema)
        let model = multi.connect(docId: "docA", doc: YDocument())
        _ = try model.create(id: "d1", values: [
            "title": .string("parity"),
            "tags":  .stringset(["x", "y", "z"]),
        ])

        let viaFind = try XCTUnwrap(multi.find(id: "d1")).row
        let viaQuery = try XCTUnwrap(try multi.query(["id": "d1"]).first)
        XCTAssertEqual(
            Set(viaFind["tags"]?.stringArrayValue ?? []),
            Set(viaQuery["tags"]?.stringArrayValue ?? [])
        )
        XCTAssertEqual(viaFind["title"]?.stringValue, viaQuery["title"]?.stringValue)
    }

    /// The junction tables are keyed by `(docId, parentId)`, so a record id
    /// that repeats across docs must not merge members. `find` is
    /// first-match-wins in connect order, so it returns docA's members only.
    func testFindStringsetIsScopedToTheMatchedDoc() throws {
        let multi = MultiDocModel(schema: schema)

        let modelA = multi.connect(docId: "docA", doc: YDocument())
        _ = try modelA.create(id: "shared", values: [
            "title": .string("in A"), "tags": .stringset(["a-only"]),
        ])

        SchemaSync.clearCache()
        let modelB = multi.connect(docId: "docB", doc: YDocument())
        _ = try modelB.create(id: "shared", values: [
            "title": .string("in B"), "tags": .stringset(["b-only"]),
        ])

        let located = try XCTUnwrap(multi.find(id: "shared"))
        XCTAssertEqual(located.docId, "docA", "first-match-wins in connect order")
        XCTAssertEqual(Set(located.row["tags"]?.stringArrayValue ?? []), ["a-only"],
                       "members must not merge across docs that share a record id")
    }

    /// A disconnected doc's junction rows are swept, so a later `find` that
    /// resolves to a still-connected doc sees only that doc's members.
    func testFindAfterDisconnectDropsTheGoneDocsMembers() throws {
        let multi = MultiDocModel(schema: schema)

        let modelA = multi.connect(docId: "docA", doc: YDocument())
        _ = try modelA.create(id: "shared", values: [
            "title": .string("in A"), "tags": .stringset(["a-only"]),
        ])

        SchemaSync.clearCache()
        let modelB = multi.connect(docId: "docB", doc: YDocument())
        _ = try modelB.create(id: "shared", values: [
            "title": .string("in B"), "tags": .stringset(["b-only"]),
        ])

        multi.disconnect(docId: "docA")

        let located = try XCTUnwrap(multi.find(id: "shared"))
        XCTAssertEqual(located.docId, "docB")
        XCTAssertEqual(Set(located.row["tags"]?.stringArrayValue ?? []), ["b-only"])
    }

    // MARK: - findByUnique

    /// `findByUnique` builds its row from the record snapshot rather than the
    /// engine, and rendered the stringset as a comma-joined `String` — a shape
    /// the generated row decoder (`.stringArrayValue`) can't read, so the field
    /// silently vanished there too.
    func testFindByUniquePopulatesStringsetMembers() throws {
        let multi = MultiDocModel(schema: schema)
        let model = multi.connect(docId: "docA", doc: YDocument())
        _ = try model.create(id: "d1", values: [
            "title": .string("unique"),
            "email": .string("alice@example.com"),
            "tags":  .stringset(["a", "b"]),
        ])

        let located = try XCTUnwrap(try multi.findByUnique(
            constraint: "fss_docs_email_unique", value: .string("alice@example.com")
        ))
        let tags = try XCTUnwrap(
            located.row["tags"]?.stringArrayValue,
            "findByUnique must return stringset members as [String], like query"
        )
        XCTAssertEqual(Set(tags), ["a", "b"])
    }

    func testFindByUniqueReturnsEmptyArrayWhenTheRecordHasNoMembers() throws {
        let multi = MultiDocModel(schema: schema)
        let model = multi.connect(docId: "docA", doc: YDocument())
        _ = try model.create(id: "d1", values: [
            "title": .string("unique"),
            "email": .string("bob@example.com"),
        ])

        let located = try XCTUnwrap(try multi.findByUnique(
            constraint: "fss_docs_email_unique", value: .string("bob@example.com")
        ))
        let tags = try XCTUnwrap(located.row["tags"]?.stringArrayValue)
        XCTAssertTrue(tags.isEmpty)
    }

    // MARK: - Through the generated facade

    /// The end-to-end repro from the issue: `TaskRecord.find("t1")` used to
    /// come back with `tags == nil` while `TaskRecord.query(["id": "t1"])`
    /// returned them.
    func testTypedFindReturnsStringsetMembers() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([TaskRecord.self])

        let (docId, _) = try await client.createDocumentForTest(
            options: CreateDocumentOptions(localOnly: true)
        )
        try TaskRecord(id: "t1", title: "x", priority: 1, tags: ["a", "b"]).save(in: docId)

        let viaFind = try XCTUnwrap(try TaskRecord.find("t1"))
        let viaQuery = try XCTUnwrap(try TaskRecord.query(["id": "t1"]).first)
        XCTAssertEqual(viaFind.tags, ["a", "b"])
        XCTAssertEqual(viaFind.tags, viaQuery.tags)
    }

    /// A record with no members decodes as an empty set, not `nil` — same as
    /// the `query` path, so round-tripping a found record through `save(in:)`
    /// doesn't turn "no tags" into "field absent".
    func testTypedFindReturnsEmptySetWhenTheRecordHasNoMembers() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([TaskRecord.self])

        let (docId, _) = try await client.createDocumentForTest(
            options: CreateDocumentOptions(localOnly: true)
        )
        try TaskRecord(id: "t1", title: "x", priority: 1).save(in: docId)

        let viaFind = try XCTUnwrap(try TaskRecord.find("t1"))
        let viaQuery = try XCTUnwrap(try TaskRecord.query(["id": "t1"]).first)
        XCTAssertEqual(viaFind.tags, [])
        XCTAssertEqual(viaFind.tags, viaQuery.tags)
    }
}
