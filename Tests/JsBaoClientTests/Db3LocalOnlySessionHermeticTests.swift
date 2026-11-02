import XCTest
@testable import JsBaoClient

/// #5155 — a db3 that lives only on this device, across a session's start,
/// its closes and its socket (the code second opinion's CR-006 to CR-009).
///
/// - A store written at storage version 3 whose owner signs in again lists
///   and reads its synced db3s: the reads of the local-only columns bring the
///   store to the version first.
/// - No close removes its only copy: not an evicting close, not a close its
///   open's `retainLocal: false` makes evicting, not the client's destroy.
/// - Nothing on the socket names it: a connected client's ordinary close of
///   it, opened through the deprecated local open, and its delete while open,
///   send no frame naming the id.
/// - A request naming it is refused `.db3LocalOnly` before anything is sent,
///   also when made before storage setup has loaded its row or bound its
///   store, and when its row is lost and its store unbound.
final class Db3LocalOnlySessionHermeticTests: XCTestCase {

    private let world = Db3LocalOnlyWorld()
    private let extra = LockedBox<[JsBaoClient]>([])

    private static let appId = "db3-local-only-5155"
    private static let synced = "01JD5155SYNCEDBBBBBBBBBBBB"
    private static let localOpen = OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)

    override func tearDown() async throws {
        for client in extra.value { await client.destroy() }
        extra.value = []
        await world.tearDown()
        try await super.tearDown()
    }

    private func options(_ directory: String, wsUrl: String = "ws://127.0.0.1:1") -> JsBaoClientOptions {
        JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: wsUrl,
            appId: Self.appId,
            token: makeTestJwt(userId: "user-a"),
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        )
    }

    private func tracked(_ client: JsBaoClient) -> JsBaoClient {
        extra.withValue { $0.append(client) }
        return client
    }

    /// Every request `client` sends from now on, as its path and body.
    private func observeSent(_ client: JsBaoClient) -> LockedBox<[String]> {
        let sent = LockedBox<[String]>([])
        client.gatedTransportForTest.observeSentForTest { _, path, body in
            sent.withValue { $0.append(path + " " + (body.flatMap { String(data: $0, encoding: .utf8) } ?? "")) }
        }
        return sent
    }

    private static let chunk = DocumentIngestChunk(
        model: "Note", index: 0, rows: 1, bytes: 1, rawBytes: 1, sha256: "00", firstId: "n1", lastId: "n1", body: Data("x".utf8)
    )

    private func refusal(_ body: @escaping @Sendable () async throws -> Void) -> Task<JsBaoError?, Never> {
        Task {
            do {
                try await body()
                return nil
            } catch {
                return error as? JsBaoError
            }
        }
    }

    // MARK: - The store's upgrade at sign-in

    func testAVersion3StoreOfTheSameUserListsItsSyncedDb3sAfterTheUpgrade() async throws {
        let directory = world.directory()
        let first = try await world.client(directory: directory)
        let firstHost = await first.db3Host()
        let host = try XCTUnwrap(firstHost)
        let store = RecordLogStore(host: host, documentId: Self.synced, clientId: "client-1")
        try store.initialize()
        let writer = try store.mintWriter()
        _ = try store.commitEntries(writer: writer, writes: [RecordLogWrite(mutations: [
            RecordLogMutation(model: "Note", id: "r1", kind: .create, fields: ["title": "kept"]),
        ])])
        try store.flush()
        _ = try store.receive(writer: writer, items: [.result(RecordLogResult(l: 1, e: 1, changes: nil, w: writer, seq: 1))])
        try RecordLogStore.setOwner(host: host, userId: "user-a")
        // The store as storage version 3 left it, its owner the user signing in again.
        try host.withConnection { connection in
            try connection.executeScript("ALTER TABLE record_log_state DROP COLUMN local_only")
            try connection.executeScript("ALTER TABLE record_log_state DROP COLUMN local_indexes")
            try connection.execute("UPDATE record_log_meta SET value = '3' WHERE key = 'storage_version'", [])
        }
        await world.destroy(first)

        let second = try await world.client(directory: directory)
        let stored = try await second.db3.stored()
        XCTAssertEqual(stored.map(\.id), [Self.synced])
        XCTAssertEqual(stored.first?.localOnly, false)
        XCTAssertEqual(stored.first?.rows, 1)
        XCTAssertEqual(stored.first?.cursor, 1)
        let state = try await second.db3.state(Self.synced)
        XCTAssertFalse(state.localOnly)
        let secondHost = await second.db3Host()
        let upgraded = try XCTUnwrap(secondHost)
        let version = try upgraded.withConnection {
            try $0.query("SELECT value FROM record_log_meta WHERE key = 'storage_version'", []).first?["value"].stringValue
        }
        XCTAssertEqual(version, "4")
    }

    // MARK: - No close removes it

    func testNoCloseRemovesItsOnlyCopy() async throws {
        let directory = world.directory()
        let client = try await world.client(directory: directory)
        let info = try await world.createLocalOnly(client, transport: RecordingTransport(status: 500, json: "{}"))
        _ = try world.notes(client, info.id).save(id: "n1", values: ["slug": .string("a")])

        let closes: [(String, OpenDocumentOptions, CloseDocumentOptions)] = [
            ("an evicting close", Self.localOpen, CloseDocumentOptions(evictLocal: true)),
            (
                "a close of an open with retainLocal: false",
                OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false, retainLocal: false), CloseDocumentOptions()
            ),
        ]
        for (name, open, close) in closes {
            _ = try await client.documents.open(info.id, options: open)
            let closed = await client.documents.close(info.id, options: close)
            XCTAssertFalse(closed.evicted, name)
            let stored = try await client.db3.stored()
            XCTAssertEqual(stored.map(\.id), [info.id], name)
            XCTAssertEqual(stored.first?.rows, 1, name)
            XCTAssertEqual(client.documentManager.getLocalMetadata(info.id)?.localOnly, true, "\(name): the row is intact")
            XCTAssertEqual(try world.notes(client, info.id).find(id: "n1")?.id, "n1", "\(name): the rows are still readable")
        }

        // Open with retainLocal: false when the client is destroyed.
        _ = try await client.documents.open(
            info.id, options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false, retainLocal: false)
        )
        await world.destroy(client)
        let again = try await world.client(directory: directory)
        let stored = try await again.db3.stored()
        XCTAssertEqual(stored.map(\.id), [info.id], "the destroy kept it")
        XCTAssertEqual(stored.first?.rows, 1)
        XCTAssertEqual(again.documentManager.getLocalMetadata(info.id)?.localOnly, true)
    }

    // MARK: - Nothing on the socket names it

    func testAConnectedClientsClosesAndDeleteSendNoFrameNamingIt() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let base = url.absoluteString.hasSuffix("/") ? String(url.absoluteString.dropLast()) : url.absoluteString
        let client = tracked(JsBaoClient(options: options(world.directory(), wsUrl: base)))
        _ = await client.waitForStorageReady()
        client.registerModels([Db3LocalOnlyWorld.note])
        try await client.connect()
        XCTAssertTrue(client.isConnected)

        let info = try await world.createLocalOnly(client, transport: RecordingTransport(status: 500, json: "{}"))
        _ = try world.notes(client, info.id).save(id: "n1", values: ["slug": .string("a")])
        _ = try await client.documents.open(info.id, options: Self.localOpen)
        _ = await client.documents.close(info.id)
        _ = try await client.documents.open(info.id, options: Self.localOpen)
        _ = try await client.db3.delete(info.id)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(client.isConnected, "the socket stayed up, so a frame would have reached the server")
        XCTAssertEqual(server.receivedFrames.filter { $0.contains(info.id) }, [], "no frame names it")
        let stored = try await client.db3.stored()
        XCTAssertEqual(stored.filter { $0.id == info.id }, [], "the delete removed it")
    }

    // MARK: - A request naming it is checked against the store

    func testARequestMadeBeforeStorageSetupFinishesIsRefused() async throws {
        let directory = world.directory()
        let first = try await world.client(directory: directory)
        let info = try await world.createLocalOnly(first, transport: RecordingTransport(status: 500, json: "{}"))
        await world.destroy(first)

        let hold = Hold()
        let client = tracked(JsBaoClient(
            options: options(directory), connectivityMonitor: nil, storageSetupHoldForTest: { await hold.wait() }
        ))
        let sent = observeSent(client)
        let id = info.id
        let ingest = refusal { _ = try await client.documents.ingests.create(documentId: id) }
        let upload = refusal { _ = try await client.documents.ingests.uploadChunk(documentId: id, sessionId: "s1", chunk: Self.chunk) }
        try await Task.sleep(nanoseconds: 100_000_000)
        hold.release()

        let refused = [await ingest.value, await upload.value]
        XCTAssertEqual(refused.map { $0?.code }, [.db3LocalOnly, .db3LocalOnly], "\(refused)")
        XCTAssertEqual(refused.map { $0?.details?["db3Id"] }, [.string(id), .string(id)])
        XCTAssertEqual(sent.value.filter { $0.contains(id) }, [], "nothing naming it was sent")
    }

    func testARequestNamingItWithItsRowLostAndItsStoreUnboundIsRefused() async throws {
        let directory = world.directory()
        let first = try await world.client(directory: directory)
        let info = try await world.createLocalOnly(first, transport: RecordingTransport(status: 500, json: "{}"))
        try await first.offlineStore.deleteMetadata(appId: Self.appId, userId: "user-a", documentId: info.id)
        await world.destroy(first)

        let client = try await world.client(directory: directory)
        await client.unbindRecordLogDocument(info.id)
        XCTAssertNil(client.documentManager.getLocalMetadata(info.id), "its row is lost")
        XCTAssertNil(client.recordLogBinding(info.id), "its store is not bound")
        let sent = observeSent(client)

        let ingest = await db3LocalOnlyThrown { _ = try await client.documents.ingests.create(documentId: info.id) }
        XCTAssertEqual(ingest?.code, .db3LocalOnly)
        let upload = await db3LocalOnlyThrown {
            _ = try await client.documents.ingests.uploadChunk(documentId: info.id, sessionId: "s1", chunk: Self.chunk)
        }
        XCTAssertEqual(upload?.code, .db3LocalOnly)
        XCTAssertEqual(sent.value.filter { $0.contains(info.id) }, [], "nothing naming it was sent")
    }
}

/// Holds a client's storage setup until released.
private final class Hold: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func wait() async {
        for await _ in stream {}
    }

    func release() {
        continuation.finish()
    }
}
