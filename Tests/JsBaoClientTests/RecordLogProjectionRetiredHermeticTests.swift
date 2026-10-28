import XCTest
@testable import JsBaoClient

/// #4700 behaviour 23: the query projection is retired. A db3's rows live in
/// its view only: no store command takes a projection, no table with a
/// `_meta_doc_id` column is written however a row arrives (a save, a catch-up
/// page, a bulk load's chunk, a segment's chunk), and `Model.find`,
/// `Model.query` and the model-free records agree on every row.
final class RecordLogProjectionRetiredHermeticTests: XCTestCase {

    private static let schema = PrimitiveSchema(name: "Item", fields: [
        "id": FieldDescriptor(type: .id),
        "title": FieldDescriptor(type: .string),
        "n": FieldDescriptor(type: .number, indexed: true),
        "tags": FieldDescriptor(type: .stringset),
    ])

    private var fixture: RecordLogViewFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try await RecordLogViewFixture.make("projection-retired")
    }

    override func tearDown() async throws {
        fixture?.remove()
        try await super.tearDown()
    }

    func testTheProjectionTypesAndEveryProjectParameterAreGone() throws {
        var mentions: [String] = []
        for file in try ClientSourceText.packageSwiftFiles() where file.hasPrefix("Sources/JsBaoClient/") {
            let code = ClientSourceText.stripComments(try ClientSourceText.packageFile(file))
            for symbol in ["RecordLogQueryProjection", "RecordLogProjectionSpec", "projectionSpecs", "isProjected"]
            where code.contains(symbol) {
                mentions.append("\(file): \(symbol)")
            }
        }
        XCTAssertEqual(mentions, [], "the projection is retired")
        let store = ClientSourceText.stripComments(try ClientSourceText.clientSource("RecordLog/RecordLogStore.swift"))
        XCTAssertFalse(store.contains("project:"), "no store command takes a projection")
    }

    /// Every table of the provider's file that carries `_meta_doc_id`.
    private func projectionTables() throws -> [String] {
        try fixture.provider.withConnection {
            try $0.query("""
                SELECT m.name AS name FROM sqlite_master m WHERE m.type = 'table'
                  AND EXISTS (SELECT 1 FROM pragma_table_info(m.name) WHERE name = '_meta_doc_id')
                """)
        }.compactMap { $0["name"].stringValue }
    }

    func testNoRowArrivalWritesAProjectionTableAndEveryReadAgrees() async throws {
        let binding = try fixture.open("db3-a")
        let member = try fixture.member(Self.schema, "db3-a")
        XCTAssertEqual(try projectionTables(), [], "binding a model writes no query table")

        // A save.
        _ = try member.create(id: "s1", values: ["title": .string("saved"), "n": .number(1), "tags": .stringset(["b", "a"])])
        try binding.store.flush()
        XCTAssertEqual(try projectionTables(), [], "after a save")

        let store = binding.store
        let writer = binding.writer
        // A catch-up page.
        _ = try store.applyCatchUpPage(writer: writer, rows: [
            RecordLogCatchUpRow(model: "Item", id: "c1", row: ["id": "c1", "title": "caught up", "n": 2]),
        ])
        XCTAssertEqual(try projectionTables(), [], "after a catch-up page")

        // A bulk load's chunk.
        let load = try store.beginReceipt(writer: writer, kind: .load, id: "load-1").attempt
        _ = try store.applyLoadChunk(writer: writer, sessionId: "load-1", attempt: load, model: "Item", lines: [
            RecordLogLoadLine(id: "l1", patch: ["title": "loaded", "n": 3]),
        ])
        XCTAssertEqual(try projectionTables(), [], "after a load chunk")

        // A segment's chunk under a full replacement.
        let generation = try XCTUnwrap(try store.beginSegmentReplacement(writer: writer).generation)
        _ = try store.applySegmentChunk(writer: writer, generation: generation, rows: [
            RecordLogCatchUpRow(model: "Item", id: "g1", row: ["id": "g1", "title": "segment", "n": 4]),
        ])
        XCTAssertEqual(try projectionTables(), [], "after a segment chunk")

        // find, query and the model-free records answer every row alike.
        let records = try fixture.records("db3-a")
        let queried = try member.query(nil, options: QueryOptions(sort: ["id": 1]))
        let free = try records.query("Item", options: QueryOptions(sort: ["id": 1])).data.map(\.raw)
        XCTAssertEqual(queried.compactMap { $0["id"]?.stringValue }, free.compactMap { $0["id"]?.stringValue })
        XCTAssertGreaterThanOrEqual(queried.count, 3)
        for row in queried {
            let id = try XCTUnwrap(row["id"]?.stringValue)
            let found = try XCTUnwrap(member.find(id: id), "find \(id)")
            let stored = try XCTUnwrap(try records.get("Item", id: id)?.raw, "get \(id)")
            XCTAssertEqual(row["title"], stored["title"], "\(id): query and get")
            XCTAssertEqual(found["title"].flatMap { if case .string(let text) = $0 { return JSONValue.string(text) } else { return nil } },
                           stored["title"], "\(id): find and get")
            XCTAssertEqual(row["n"], stored["n"], "\(id): query and get on n")
        }
    }
}
