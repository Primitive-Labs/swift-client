import XCTest
@testable import JsBaoClient
import JsBaoSQLite

/// A large document (`documentFormat: 2`) is no longer served (#4313). The
/// Swift client refuses one with `.documentFormatUnsupported` wherever it
/// meets it — a create that asks for one, an open whose format resolves to 2,
/// a refusal frame from the room — before anything reaches the wire, and it
/// leaves whatever an older build stored for that document where it is.
///
/// No server: clients run over a temporary `.sqlite` directory with
/// `autoNetwork: false`, against a socket URL nothing listens on.
final class DocumentFormatTwoRefusedHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    /// Counts what a test must see happen zero times.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func bump() { lock.withLock { _count += 1 } }
    }

    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "/format2-refused-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    private func makeClient(path: String, remoteCreates: Counter = Counter()) async -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            // Nothing listens on port 1: a request that went out would fail
            // as a network error, never as the refusal.
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "format2-refused-test-app",
            token: makeTestJwt(userId: "user-a"),
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .sqlite(directory: path),
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
        _ = await client.waitForStorageReady()
        client.registerModels([Self.schema])
        client.documentManager.createRemoteDocument = { _ in
            remoteCreates.bump()
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        return client
    }

    private func assertUnsupported(
        _ body: () async throws -> Void, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("\(what) was not refused", file: file, line: line)
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .documentFormatUnsupported, "\(what): \(error.message)", file: file, line: line)
        } catch {
            XCTFail("\(what) failed with \(error), not the refusal", file: file, line: line)
        }
    }

    /// How long a side connection waits for the client's own write to
    /// commit. The client may still be persisting the open's metadata when a
    /// test reaches into the file, and SQLite answers "database is locked" at
    /// once on a connection with no busy handler.
    private static let busyTimeoutMs: Int32 = 5_000

    /// A table a pre-removal build left for a large document, planted
    /// straight into the file.
    private func plantLegacyTables(_ path: String, _ documentId: String) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        let table = "records_f2_" + documentId.replacingOccurrences(of: "-", with: "_")
        let sql = """
            CREATE TABLE IF NOT EXISTS _epoch (doc_id TEXT PRIMARY KEY, epoch INTEGER);
            INSERT OR REPLACE INTO _epoch VALUES ('\(documentId)', 4);
            CREATE TABLE IF NOT EXISTS "\(table)" (id TEXT PRIMARY KEY, data TEXT);
            INSERT OR REPLACE INTO "\(table)" VALUES ('r1', '{"title":"kept"}');
            """
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              sqlite3_busy_timeout(db, Self.busyTimeoutMs) == SQLITE_OK,
              sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
        else { throw JsBaoError(code: .unavailable, message: String(cString: sqlite3_errmsg(db))) }
    }

    private func count(_ path: String, _ sql: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw JsBaoError(code: .unavailable, message: "cannot open \(path)")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, Self.busyTimeoutMs)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw JsBaoError(code: .unavailable, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func legacyRows(_ path: String, _ documentId: String) throws -> Int {
        let table = "records_f2_" + documentId.replacingOccurrences(of: "-", with: "_")
        return try count(path, "SELECT COUNT(*) FROM \"\(table)\"")
            + count(path, "SELECT COUNT(*) FROM _epoch WHERE doc_id = '\(documentId)'")
    }

    // MARK: - Creates (behavior 28)

    func testEveryCreateThatAsksForFormatTwoIsRefusedBeforeAnyRequest() async throws {
        let path = newDatabasePath()
        let remoteCreates = Counter()
        let client = await makeClient(path: path, remoteCreates: remoteCreates)
        defer { Task { await client.destroy() } }
        let before = client.documentManager.getMetadataIndex().count

        await assertUnsupported({
            _ = try await client.documents.create(options: CreateDocumentOptions(documentFormat: 2))
        }, "documents.create")
        await assertUnsupported({
            _ = try await client.createDocument(options: CreateDocumentOptions(title: "Large", documentFormat: 2))
        }, "createDocument")
        await assertUnsupported({
            _ = try await client.documents.createWithAlias(options: CreateWithAliasOptions(
                title: "Large", alias: AliasRef(scope: .user, aliasKey: "large-\(UUID().uuidString.prefix(6))", userId: "user-a"),
                documentFormat: 2
            ))
        }, "documents.createWithAlias")
        await assertUnsupported({
            _ = try await client.documents.getOrCreateWithAlias(options: GetOrCreateWithAliasOptions(
                alias: AliasRef(scope: .user, aliasKey: "large-\(UUID().uuidString.prefix(6))", userId: "user-a"),
                title: "Large", documentFormat: 2
            ))
        }, "documents.getOrCreateWithAlias")

        XCTAssertEqual(remoteCreates.count, 0, "nothing was sent to the server")
        XCTAssertEqual(client.documentManager.getMetadataIndex().count, before, "no local row was written")

        // The formats still served create as before.
        for format in [nil, 1, 3] as [Int?] {
            let created = try await client.createDocument(options: CreateDocumentOptions(documentFormat: format))
            let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
            XCTAssertEqual(client.documentManager.getLocalMetadata(documentId)?.documentFormat, format)
        }
    }

    // MARK: - Opens (behavior 28, edge 045's Swift half)

    func testAnOpenWhoseLocalRowSaysTwoIsRefusedAndLeavesTheDocumentClosedAndItsStoreWhole() async throws {
        let path = newDatabasePath()
        let client = await makeClient(path: path)
        defer { Task { await client.destroy() } }
        let created = try await client.createDocument(options: CreateDocumentOptions())
        let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        // The row a pre-removal session left: it names format 2.
        client.documentManager.noteDocumentFormat(documentId, 2)
        try plantLegacyTables(path, documentId)
        let handshakes = Counter()
        client.onSyncStep1SendForTest = { _ in handshakes.bump() }
        let frames = Counter()
        client.recordLogFrameSentForTest = { _ in frames.bump() }

        await assertUnsupported({
            _ = try await client.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false))
        }, "an open of a row saying 2")
        await assertUnsupported({
            _ = try await client.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .network))
        }, "a second open")

        XCTAssertNil(client.documentManager.getDocument(documentId), "the document is not left open")
        XCTAssertFalse(client.isRecordLogDocument(documentId))
        XCTAssertEqual(handshakes.count, 0, "no syncStep1")
        XCTAssertEqual(frames.count, 0, "no record frame")
        XCTAssertEqual(client.documentManager.getLocalMetadata(documentId)?.documentFormat, 2, "the row is kept")
        XCTAssertEqual(try legacyRows(path, documentId), 2, "what the older build stored is untouched")
    }

    func testAServerAnswerOfTwoBeforeTheHandshakeRefusesTheDocumentAndSendsNothing() async throws {
        let path = newDatabasePath()
        let client = await makeClient(path: path)
        defer { Task { await client.destroy() } }
        let documentId = "legacy-\(UUID().uuidString.prefix(8))"
        let lookups = Counter()
        client.documentFormatLookupForTest = { _ in
            lookups.bump()
            return 2
        }
        let handshakes = Counter()
        client.onSyncStep1SendForTest = { _ in handshakes.bump() }
        // A document nothing local names, opened before the socket is up: its
        // format is asked about before the handshake would go out.
        _ = try await client.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false))
        client.setNetworkMode(.online)

        let proceed = await client.resolveRecordLogBeforeHandshake(documentId)

        XCTAssertFalse(proceed, "the handshake does not go out")
        XCTAssertEqual(lookups.count, 1)
        XCTAssertEqual(client.formatRefusal(documentId)?.code, .documentFormatUnsupported)
        XCTAssertNil(client.documentManager.getDocument(documentId), "closed under the app")
        XCTAssertEqual(handshakes.count, 0)
        await assertUnsupported({
            _ = try await client.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false))
        }, "the next open")
    }

    func testTheRoomsRefusalFrameClosesTheDocumentWithoutTakingItsStore() async throws {
        let path = newDatabasePath()
        let client = await makeClient(path: path)
        defer { Task { await client.destroy() } }
        let created = try await client.createDocument(options: CreateDocumentOptions())
        let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        _ = try await client.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false))
        try plantLegacyTables(path, documentId)

        await client.handleWebSocketMessage(RecordLogJSON.text([
            "type": "error", "code": "DOCUMENT_FORMAT_UNSUPPORTED", "documentId": .string(documentId),
            "messageType": "syncStep1",
            "message": "documentFormat 2 (large document) is no longer served; create a record-log document with documentFormat 3",
        ]))

        XCTAssertEqual(client.formatRefusal(documentId)?.code, .documentFormatUnsupported)
        XCTAssertNil(client.documentManager.getDocument(documentId), "closed under the app")
        XCTAssertNotNil(client.documentManager.getLocalMetadata(documentId), "the row is kept")
        XCTAssertEqual(try legacyRows(path, documentId), 2)
    }

    // MARK: - The account wipe

    func testAnAccountWipeDropsTheTablesAnOlderBuildKeptForLargeDocuments() async throws {
        let path = newDatabasePath()
        let client = await makeClient(path: path)
        defer { Task { await client.destroy() } }
        let documentId = "legacy-\(UUID().uuidString.prefix(8))"
        try plantLegacyTables(path, documentId)
        let table = "records_f2_" + documentId.replacingOccurrences(of: "-", with: "_")

        try await client.logout(wipeLocal: true)

        XCTAssertEqual(try count(path, "SELECT COUNT(*) FROM sqlite_master WHERE name = '\(table)'"), 0,
                       "a previous account's large-document records do not survive the wipe")
        XCTAssertEqual(try count(path, "SELECT COUNT(*) FROM _epoch"), 0)
    }

    // MARK: - The handshake (behavior 29)

    func testSyncStep1DeclaresTheDocumentsFormatAndNothingElse() async throws {
        let client = await makeClient(path: newDatabasePath())
        defer { Task { await client.destroy() } }
        let created = try await client.createDocument(options: CreateDocumentOptions())
        let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        client.documentManager.noteDocumentFormat(documentId, 1)
        _ = try await client.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false))

        let text = try XCTUnwrap(client.documentManager.buildSyncStep1Message(documentId: documentId))
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(frame["type"] as? String, "syncStep1")
        XCTAssertEqual(frame["documentFormat"] as? Int, 1)
        XCTAssertNil(frame["formats"], "the room no longer reads the formats a client can read")
        XCTAssertNil(frame["manifestVersion"])
    }

    // MARK: - The public surface (behavior 29)

    func testTheFormatTwoOnlyCodesAndTheStorageOptionAreGone() {
        for retired in [
            "CLIENT_UPGRADE_REQUIRED", "FORMAT2_RELOAD_REQUIRED",
            "FORMAT2_FOLD_BROKEN", "FORMAT2_SNAPSHOT_LOAD_INCOMPLETE",
        ] {
            XCTAssertNil(JsBaoErrorCode(rawValue: retired), retired)
        }
        // Kept: a record-log store raises these, and the refusal itself.
        for kept in [
            "FORMAT2_STORAGE_UNAVAILABLE", "FORMAT2_QUERY_SCOPE", "FORMAT2_MODEL_NOT_HYDRATED",
            "DOCUMENT_FORMAT_UNSUPPORTED", "DOCUMENT_FORMAT_MISMATCH",
        ] {
            XCTAssertNotNil(JsBaoErrorCode(rawValue: kept), kept)
        }
        let options = JsBaoClientOptions(apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "a")
        let labels = Mirror(reflecting: options).children.compactMap(\.label)
        XCTAssertFalse(labels.contains("largeDocumentStorage"), "\(labels)")
        XCTAssertTrue(labels.contains("storageConfig"))

        // Both initialisers of the write-refused event stay.
        let error = JsBaoError(code: .documentConstraintViolated, message: "taken")
        let plain = DocumentWriteRefusedEvent(documentId: "d", model: "Note", recordId: "r", error: error)
        XCTAssertNil(plain.writes)
        let full = DocumentWriteRefusedEvent(
            documentId: "d", model: "Note", recordId: "r", error: error, writes: [], conflictingRecord: nil
        )
        XCTAssertEqual(full.writes?.count, 0)
    }

    // MARK: - The source tree (behavior 27)

    func testTheLargeDocumentModulesAreGoneAndWhatTheRecordLogUsesHasMoved() {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // JsBaoClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // swift-client
            .appendingPathComponent("Sources/JsBaoClient")
        let files = FileManager.default
        XCTAssertFalse(files.fileExists(atPath: sources.appendingPathComponent("LargeDocuments").path))
        for moved in [
            "Storage/Format2SqlHost.swift",
            "RecordLog/Format2Storage.swift",
            "Schema/DocumentFormatRules.swift",
        ] {
            XCTAssertTrue(files.fileExists(atPath: sources.appendingPathComponent(moved).path), moved)
        }
    }
}
