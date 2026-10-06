import XCTest
@testable import JsBaoClient

/// The Swift store's `upsertOn` and unique-check lookups are index searches
/// (#3879, behaviors 16 and 17).
///
/// `findIdByFields` used to bind its JSON paths, and the per-document
/// `records_f2_<hex>` table had no field index, so every lookup parsed every
/// record of the model. The store now inlines the paths where they are
/// identifiers and builds, per document, one partial expression index per
/// declared `indexed`/`unique` scalar field and one per compound unique
/// constraint, each ending in `_id` so the lookup's `ORDER BY _id LIMIT 1` is
/// served by the same index — the same shape and names as js-bao's store.
///
/// Plans are taken on the statement the store itself issues
/// (``Format2RecordStore/lookupStatement(model:fields:values:)``, which
/// `findIdByFields` runs), and matched on `SEARCH`, the index name and the
/// absence of a temp b-tree — never on the exact wording (edge E8 of #3688).
final class Format2FieldIndexHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/f2-fidx-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func makeStore(
        _ provider: SQLiteStorageProvider, documentId: String = "doc1"
    ) throws -> Format2RecordStore {
        let store = Format2RecordStore(
            host: provider, documentId: documentId, clientId: "harness-client"
        )
        try store.initialize()
        return store
    }

    private func fold(
        _ store: Format2RecordStore, model: String, _ rows: [(String, [String: JSONValue])]
    ) throws {
        try store.transaction {
            for (id, fields) in rows {
                try store.applyRemote(
                    model: model, entry: OverlayRecordEntry(id: id, fields: fields)
                )
            }
        }
    }

    private func notes(_ count: Int) -> [(String, [String: JSONValue])] {
        (0..<count).map { (String(format: "n%05d", $0), ["title": .string("t\($0)")]) }
    }

    private func plan(
        _ provider: SQLiteStorageProvider,
        _ statement: (sql: String, bindings: [Format2SqlValue])
    ) throws -> String {
        try provider.withConnection { connection in
            try connection.query("EXPLAIN QUERY PLAN \(statement.sql)", statement.bindings)
        }
        .compactMap { $0["detail"].stringValue }
        .joined(separator: " | ")
    }

    private func indexNames(
        _ provider: SQLiteStorageProvider, table: String
    ) throws -> [String] {
        try provider.withConnection { connection in
            try connection.query(
                """
                SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ? \
                AND sql IS NOT NULL ORDER BY name
                """,
                [.text(table)]
            )
        }
        .compactMap { $0["name"].stringValue }
    }

    // MARK: - Behavior 16 — the ordered lookup searches the field index

    func testTheCompleteOrderedLookupSearchesTheFieldIndex() async throws {
        let provider = try await makeProvider()
        let store = try makeStore(provider)
        let records = store.tableNames.records
        try fold(store, model: "Note", notes(5_000))
        XCTAssertEqual(
            try store.findIdByFields(model: "Note", fields: ["title"], values: [.string("t42")]),
            "n00042", "the scan answers before the index exists"
        )

        let report = store.ensureFieldIndexes(model: "Note", fields: ["title"], constraints: [])
        XCTAssertEqual(report.created, 1)
        let index = Format2RecordStore.fieldIndexName(
            records: records, kind: .field, model: "Note", name: "title"
        )
        XCTAssertEqual(index, "idx_\(records)_f4_note_title")
        XCTAssertTrue(try indexNames(provider, table: records).contains(index))

        for (value, expected) in [("t42", "n00042" as String?), ("nope", nil)] {
            XCTAssertEqual(
                try store.findIdByFields(model: "Note", fields: ["title"], values: [.string(value)]),
                expected
            )
            let statement = store.lookupStatement(
                model: "Note", fields: ["title"], values: [.string(value)]
            )
            XCTAssertTrue(statement.sql.hasSuffix("ORDER BY _id LIMIT 1"), statement.sql)
            XCTAssertTrue(statement.sql.contains("_type = 'Note'"), statement.sql)
            XCTAssertTrue(statement.sql.contains("json_extract(_data, '$.title') IS ?"), statement.sql)
            let detail = try plan(provider, statement)
            XCTAssertTrue(detail.contains("SEARCH"), detail)
            XCTAssertTrue(detail.contains(index), detail)
            XCTAssertFalse(detail.contains("TEMP B-TREE"), detail)
        }
    }

    func testACompoundConstraintPlansThroughItsCompositeIndex() async throws {
        let provider = try await makeProvider()
        let store = try makeStore(provider)
        let records = store.tableNames.records
        try fold(store, model: "Seat", (0..<2_000).map {
            (String(format: "s%05d", $0), ["holder": .string("h\($0 % 50)"), "seat": .number(Double($0))])
        })
        let report = store.ensureFieldIndexes(
            model: "Seat", fields: [],
            constraints: [ConstraintDescriptor(name: "holderSeat", fields: ["holder", "seat"])]
        )
        XCTAssertEqual(report.created, 1)
        let index = Format2RecordStore.fieldIndexName(
            records: records, kind: .constraint, model: "Seat", name: "holderSeat"
        )
        XCTAssertEqual(index, "idx_\(records)_u4_seat_holderseat")

        let values: [JSONValue] = [.string("h7"), .number(107)]
        XCTAssertEqual(
            try store.findIdByFields(model: "Seat", fields: ["holder", "seat"], values: values),
            "s00107"
        )
        let detail = try plan(
            provider, store.lookupStatement(model: "Seat", fields: ["holder", "seat"], values: values)
        )
        XCTAssertTrue(detail.contains("SEARCH"), detail)
        XCTAssertTrue(detail.contains(index), detail)
        XCTAssertFalse(detail.contains("TEMP B-TREE"), detail)
    }

    /// The answers the bound statement gave, with the index and without it.
    func testAnswersAreUnchangedWithAndWithoutTheIndex() async throws {
        for indexed in [false, true] {
            let provider = try await makeProvider()
            let store = try makeStore(provider)
            try fold(store, model: "User", [
                // Absent `flag`; another field so the fold creates the row.
                ("a1", ["other": .string("x")]),
                ("b0", ["flag": .bool(false)]),
                ("b1", ["flag": .bool(true)]),
                ("s1", ["flag": .string("1")]),
                ("num", ["flag": .number(2)]),
                ("str", ["flag": .string("2")]),
                ("m2", ["flag": .string("same")]),
                ("m1", ["flag": .string("same")]),
            ])
            if indexed {
                XCTAssertEqual(
                    store.ensureFieldIndexes(model: "User", fields: ["flag"], constraints: []).created, 1
                )
            }
            let cases: [(JSONValue, String?)] = [
                (.null, "a1"),
                (.bool(true), "b1"),
                (.bool(false), "b0"),
                (.string("1"), "s1"),
                (.number(2), "num"),
                (.string("2"), "str"),
                (.number(3), nil),
                (.string("same"), "m1"),
            ]
            for (value, expected) in cases {
                XCTAssertEqual(
                    try store.findIdByFields(model: "User", fields: ["flag"], values: [value]),
                    expected, "\(value) (indexed: \(indexed))"
                )
            }
        }
    }

    func testAStoredJSONNullMatchesNull() async throws {
        let provider = try await makeProvider()
        let store = try makeStore(provider)
        try provider.withConnection { connection in
            try connection.execute(
                "INSERT INTO \(store.tableNames.records) (_id, _type, _data) VALUES (?, ?, ?)",
                [.text("n1"), .text("User"), .text("{\"flag\":null}")]
            )
        }
        try fold(store, model: "User", [("x", ["flag": .string("v")])])
        store.ensureFieldIndexes(model: "User", fields: ["flag"], constraints: [])
        XCTAssertEqual(
            try store.findIdByFields(model: "User", fields: ["flag"], values: [.null]), "n1"
        )
    }

    func testANonIdentifierFieldResolvesThroughTheBoundStatement() async throws {
        let provider = try await makeProvider()
        let store = try makeStore(provider)
        try fold(store, model: "User", [
            ("u1", ["bad-name": .string("v")]), ("u2", ["bad-name": .string("w")]),
        ])
        XCTAssertEqual(
            try store.findIdByFields(model: "User", fields: ["bad-name"], values: [.string("w")]),
            "u2"
        )
        let statement = store.lookupStatement(
            model: "User", fields: ["bad-name"], values: [.string("w")]
        )
        XCTAssertTrue(statement.sql.contains("'$.' ||"), statement.sql)
        XCTAssertEqual(statement.bindings.count, 3)
        XCTAssertEqual(
            store.ensureFieldIndexes(model: "User", fields: ["bad-name"], constraints: []).created, 0
        )
    }

    /// Edge E11 — each document's indexes are named after its own table.
    func testTwoDocumentsGetSeparatelyNamedIndexes() async throws {
        let provider = try await makeProvider()
        let a = try makeStore(provider, documentId: "doc-a")
        let b = try makeStore(provider, documentId: "doc-b")
        try fold(a, model: "Note", notes(300))
        try fold(b, model: "Note", notes(300))
        a.ensureFieldIndexes(model: "Note", fields: ["title"], constraints: [])
        b.ensureFieldIndexes(model: "Note", fields: ["title"], constraints: [])
        let indexA = "idx_\(a.tableNames.records)_f4_note_title"
        let indexB = "idx_\(b.tableNames.records)_f4_note_title"
        XCTAssertNotEqual(indexA, indexB)
        XCTAssertTrue(try indexNames(provider, table: a.tableNames.records).contains(indexA))
        XCTAssertTrue(try indexNames(provider, table: b.tableNames.records).contains(indexB))
        let detail = try plan(
            provider, a.lookupStatement(model: "Note", fields: ["title"], values: [.string("t5")])
        )
        XCTAssertTrue(detail.contains(indexA), detail)
        XCTAssertFalse(detail.contains(b.tableNames.records), detail)
    }

    // MARK: - Behavior 17 — the projection builds them, idempotently

    private static let indexedSchema = PrimitiveSchema(
        name: "Seat",
        fields: [
            "id": FieldDescriptor(type: .id, indexed: true),
            "holder": FieldDescriptor(type: .string, indexed: true),
            "room": FieldDescriptor(type: .string),
            "seat": FieldDescriptor(type: .string),
            "tags": FieldDescriptor(type: .stringset, indexed: true),
        ],
        constraints: [
            "roomSeat": ConstraintDescriptor(name: "roomSeat", fields: ["room", "seat"]),
        ]
    )

    func testEnsureProjectedBuildsTheFieldAndConstraintIndexesOnce() async throws {
        let provider = try await makeProvider()
        let store = try makeStore(provider)
        let records = store.tableNames.records
        let projection = Format2QueryProjection(host: provider, logger: Logger(level: .none))

        try projection.ensureProjected(schema: Self.indexedSchema, store: store)
        let once = try indexNames(provider, table: records)
        XCTAssertTrue(once.contains("idx_\(records)_f4_seat_holder"), "\(once)")
        XCTAssertTrue(once.contains("idx_\(records)_u4_seat_roomseat"), "\(once)")
        // No index for the row key or for a stringset.
        XCTAssertFalse(once.contains("idx_\(records)_f4_seat_id"), "\(once)")
        XCTAssertFalse(once.contains("idx_\(records)_f4_seat_tags"), "\(once)")

        try projection.ensureProjected(schema: Self.indexedSchema, store: store)
        XCTAssertEqual(try indexNames(provider, table: records), once)
    }

    func testANonIdentifierFieldProjectsWithoutAnIndex() async throws {
        let provider = try await makeProvider()
        let store = try makeStore(provider)
        let records = store.tableNames.records
        let before = try indexNames(provider, table: records)
        let projection = Format2QueryProjection(host: provider, logger: Logger(level: .none))
        let schema = PrimitiveSchema(
            name: "Note",
            fields: [
                "id": FieldDescriptor(type: .id),
                "bad-name": FieldDescriptor(type: .string, indexed: true),
            ]
        )
        XCTAssertNoThrow(try projection.ensureProjected(schema: schema, store: store))
        XCTAssertEqual(try indexNames(provider, table: records), before)
    }

    func testOrderLineCodeAndOrderLineCodeGetDistinctIndexes() async throws {
        let provider = try await makeProvider()
        let store = try makeStore(provider)
        let records = store.tableNames.records
        try fold(store, model: "Order_Line", (0..<300).map { ("l\($0)", ["code": .string("c\($0)")]) })
        try fold(store, model: "Order", (0..<300).map { ("o\($0)", ["line_code": .string("c\($0)")]) })
        let projection = Format2QueryProjection(host: provider, logger: Logger(level: .none))
        try projection.ensureProjected(
            schema: PrimitiveSchema(name: "Order_Line", fields: [
                "id": FieldDescriptor(type: .id), "code": FieldDescriptor(type: .string, unique: true),
            ]),
            store: store
        )
        try projection.ensureProjected(
            schema: PrimitiveSchema(name: "Order", fields: [
                "id": FieldDescriptor(type: .id), "line_code": FieldDescriptor(type: .string, indexed: true),
            ]),
            store: store
        )
        let lineIndex = "idx_\(records)_f10_order_line_code"
        let orderIndex = "idx_\(records)_f5_order_line_code"
        let names = try indexNames(provider, table: records)
        XCTAssertTrue(names.contains(lineIndex), "\(names)")
        XCTAssertTrue(names.contains(orderIndex), "\(names)")

        XCTAssertEqual(
            try store.findIdByFields(model: "Order_Line", fields: ["code"], values: [.string("c9")]), "l9"
        )
        XCTAssertTrue(try plan(provider, store.lookupStatement(
            model: "Order_Line", fields: ["code"], values: [.string("c9")]
        )).contains(lineIndex))
        XCTAssertEqual(
            try store.findIdByFields(model: "Order", fields: ["line_code"], values: [.string("c9")]), "o9"
        )
        XCTAssertTrue(try plan(provider, store.lookupStatement(
            model: "Order", fields: ["line_code"], values: [.string("c9")]
        )).contains(orderIndex))
    }

    /// A field typed `id` that is not the row key lives in `_data` like any
    /// other, so an `indexed` or `unique` one gets its lookup index
    /// (3879-CR-01) — the `unique` case is what `upsertOn` and the save's
    /// unique check resolve through.
    func testIdTypedFieldsOtherThanTheKeyGetLookupIndexes() async throws {
        let provider = try await makeProvider()
        let store = try makeStore(provider)
        let records = store.tableNames.records
        try fold(store, model: "Link", (0..<5_000).map {
            (String(format: "k%05d", $0), [
                "ref": .string("r\($0)"), "externalId": .string("e\($0)"),
            ])
        })
        let projection = Format2QueryProjection(host: provider, logger: Logger(level: .none))
        try projection.ensureProjected(
            schema: PrimitiveSchema(name: "Link", fields: [
                "id": FieldDescriptor(type: .id, indexed: true),
                "ref": FieldDescriptor(type: .id, indexed: true),
                "externalId": FieldDescriptor(type: .id, unique: true),
            ]),
            store: store
        )
        let names = try indexNames(provider, table: records)
        let refIndex = "idx_\(records)_f4_link_ref"
        let externalIndex = "idx_\(records)_f4_link_externalid"
        XCTAssertTrue(names.contains(refIndex), "\(names)")
        XCTAssertTrue(names.contains(externalIndex), "\(names)")
        // The row key is `_id`, not a `_data` field.
        XCTAssertFalse(names.contains("idx_\(records)_f4_link_id"), "\(names)")

        for (field, value, index) in [
            ("ref", "r42", refIndex), ("externalId", "e42", externalIndex),
        ] {
            XCTAssertEqual(
                try store.findIdByFields(model: "Link", fields: [field], values: [.string(value)]),
                "k00042"
            )
            let detail = try plan(provider, store.lookupStatement(
                model: "Link", fields: [field], values: [.string(value)]
            ))
            XCTAssertTrue(detail.contains("SEARCH"), detail)
            XCTAssertTrue(detail.contains(index), detail)
            XCTAssertFalse(detail.contains("TEMP B-TREE"), detail)
        }
    }
}
