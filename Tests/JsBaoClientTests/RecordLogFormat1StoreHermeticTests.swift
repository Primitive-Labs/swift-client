import XCTest
import JsBaoSQLite
@testable import JsBaoClient

/// #4700 behaviour 22, a pin: a client that never binds a db3 stores exactly
/// what it stored before the view path and the storage version. Its database
/// holds no record-log table and no `record_log_meta` row after an open, a
/// write, a close and a reopen, and its schema is the one recorded on the tree
/// before the storage version and the projection's retirement, byte for byte.
final class RecordLogFormat1StoreHermeticTests: XCTestCase {

    /// `sqlite_master` of a format-1 client's database, recorded on the tree
    /// before the storage version: `type|name|tbl_name|sql`.
    private static let recordedSchema = [
        "index|sqlite_autoindex_kv_store_1|kv_store|",
        "table|kv_store|kv_store|CREATE TABLE kv_store (\n    store TEXT NOT NULL,\n    key TEXT NOT NULL,\n    value TEXT,\n"
            + "    metadata TEXT,\n    updated_at TEXT,\n    PRIMARY KEY (store, key)\n)",
    ]

    private static let schema = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    private var directory = ""

    override func setUp() {
        super.setUp()
        directory = NSTemporaryDirectory() + "/format1-store-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    private func makeClient() async -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: "ws://127.0.0.1:1",
            appId: "format1-store-test-app",
            token: makeTestJwt(userId: "user-a"),
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
        _ = await client.waitForStorageReady()
        client.registerModels([Self.schema])
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        return client
    }

    /// `sqlite_master`, read straight off the file through a read-only connection of the test's own.
    private func schemaRows() throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(directory + "/store.sqlite", &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw JsBaoError(code: .unavailable, message: "cannot open the database")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name", -1, &statement, nil)
            == SQLITE_OK
        else { throw JsBaoError(code: .unavailable, message: String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<4).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }.joined(separator: "|"))
        }
        return rows
    }

    func testAFormat1ClientsDatabaseIsTheOneRecordedBeforeTheViewPath() async throws {
        let first = await makeClient()
        let created = try await first.createDocument(options: CreateDocumentOptions(title: "plain"))
        let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        _ = try await first.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false))
        let member = try XCTUnwrap(first.sharedModel("Note")?.member(docId: documentId))
        _ = try member.create(id: "n1", values: ["title": .string("format one")])
        _ = await first.closeDocument(documentId)
        await first.destroy()

        let second = await makeClient()
        _ = try await second.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false))
        XCTAssertEqual(try XCTUnwrap(second.sharedModel("Note")?.member(docId: documentId)).find(id: "n1")?["title"], .string("format one"))
        _ = await second.closeDocument(documentId)
        await second.destroy()

        let schema = try schemaRows()
        XCTAssertFalse(schema.contains { $0.contains("record_log_") }, "no record-log table: \(schema)")
        XCTAssertEqual(schema, Self.recordedSchema)
    }
}
