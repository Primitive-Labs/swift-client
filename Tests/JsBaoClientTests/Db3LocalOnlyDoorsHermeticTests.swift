import XCTest
@testable import JsBaoClient

/// #5155 behaviours 29 to 31 — the doors of a db3 that lives only on this
/// device, with no server.
///
/// Every server-facing `client.db3` and `client.documents` member naming it
/// throws `.db3LocalOnly` before the transport is asked, its local metadata
/// unchanged. The eviction doors (`client.db3.evict`, with and without
/// `force`, and `client.documents.evict`) throw `.db3LocalOnly`, and the
/// sweeps (`evictAllLocal()`, `documents.evictAll`, in either form) keep it.
/// `client.db3.delete` removes it with nothing sent: its subscriptions end as
/// evicted, `Db3EvictedEvent` fires once, and its row and copy are gone.
@available(*, deprecated)
final class Db3LocalOnlyDoorsHermeticTests: XCTestCase {

    private let world = Db3LocalOnlyWorld()

    override func tearDown() async throws {
        await world.tearDown()
        try await super.tearDown()
    }

    private func assertLocalOnly(
        _ call: String, _ db3Id: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void
    ) async {
        let error = await db3LocalOnlyThrown(file: file, line: line, body)
        XCTAssertEqual(error?.code, .db3LocalOnly, call, file: file, line: line)
        XCTAssertEqual(error?.details?["db3Id"], .string(db3Id), call, file: file, line: line)
    }

    // MARK: - Behaviour 29

    func testEveryServerFacingMemberRefusesBeforeTheTransportIsAsked() async throws {
        let client = try await world.client(directory: world.directory())
        let transport = RecordingTransport(status: 200, json: "{}")
        let info = try await world.createLocalOnly(client, transport: transport)
        let id = info.id
        let db3 = Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
        let documents = DocumentsAPI(
            transport: transport, blobManager: BlobManager(logger: createLogger(level: .error, scope: "test"), transport: transport),
            documentManager: client.documentManager, client: client
        )
        let before = client.documentManager.getLocalMetadata(id)

        await assertLocalOnly("db3.get", id) { _ = try await db3.get(id) }
        await assertLocalOnly("db3.getSync", id) { _ = try await db3.getSync(id) }
        await assertLocalOnly("db3.setSync", id) { _ = try await db3.setSync(id, sync: true) }
        await assertLocalOnly("db3.getType", id) { _ = try await db3.getType(id) }
        await assertLocalOnly("db3.setType", id) { _ = try await db3.setType(id, type: "orders") }
        await assertLocalOnly("db3.getAppAccess", id) { _ = try await db3.getAppAccess(id) }
        await assertLocalOnly("db3.setAppAccess", id) { _ = try await db3.setAppAccess(id, level: nil) }
        await assertLocalOnly("db3.transfer", id) { _ = try await db3.transfer(id, to: "app") }
        await assertLocalOnly("db3.setOwnerRow", id) { _ = try await db3.setOwnerRow(id, present: false) }
        await assertLocalOnly("db3.permissions.list", id) { _ = try await db3.permissions(id).list() }
        await assertLocalOnly("db3.blobs.list", id) { _ = try await db3.blobs(id).list() }
        await assertLocalOnly("db3.blobs.upload", id) { _ = try await db3.blobs(id).upload(data: Data("x".utf8)) }
        await assertLocalOnly("db3.ingests.create", id) { _ = try await db3.ingests.create(db3Id: id, options: nil) }
        await assertLocalOnly("db3.ingests.list", id) { _ = try await db3.ingests.list(db3Id: id) }

        await assertLocalOnly("documents.get", id) { _ = try await documents.get(documentId: id) }
        await assertLocalOnly("documents.update", id) {
            _ = try await documents.update(documentId: id, data: UpdateDocumentData(title: "Renamed"))
        }
        await assertLocalOnly("documents.delete", id) { try await documents.delete(documentId: id) }
        await assertLocalOnly("documents.addTag", id) { _ = try await documents.addTag(documentId: id, tag: "x") }
        await assertLocalOnly("documents.removeTag", id) { _ = try await documents.removeTag(documentId: id, tag: "t") }
        await assertLocalOnly("documents.schema", id) { _ = try await documents.schema(id) }
        await assertLocalOnly("documents.getPermissions", id) { _ = try await documents.getPermissions(documentId: id) }
        await assertLocalOnly("documents.aliases.set", id) {
            _ = try await documents.aliases.set(SetAliasParams(scope: .user, aliasKey: "k", documentId: id))
        }
        await assertLocalOnly("documents.blobs.list", id) { _ = try await documents.blobs(documentId: id).list() }

        XCTAssertEqual(transport.calls.map(\.path), [], "no request")
        let after = client.documentManager.getLocalMetadata(id)
        XCTAssertEqual(after?.title, before?.title, "the refused update changed nothing here")
        XCTAssertEqual(after?.tags, before?.tags, "nor the refused tags")

        // The client's own members, through its own transport, refuse as well.
        await assertLocalOnly("client.db3.get", id) { _ = try await client.db3.get(id) }
        await assertLocalOnly("client.documents.update", id) {
            _ = try await client.documents.update(documentId: id, data: UpdateDocumentData(title: "Renamed"))
        }
    }

    // MARK: - Behaviour 30, the eviction doors

    func testTheEvictionDoorsRefuseAndTheSweepsKeepIt() async throws {
        let client = try await world.client(directory: world.directory())
        let info = try await world.createLocalOnly(client, transport: RecordingTransport(status: 500, json: "{}"))
        let notes = try world.notes(client, info.id)
        _ = try notes.save(id: "n1", values: ["slug": .string("a")])

        await assertLocalOnly("db3.evict", info.id) { try await client.db3.evict(info.id) }
        await assertLocalOnly("db3.evict(force)", info.id) { try await client.db3.evict(info.id, options: Db3EvictOptions(force: true)) }
        await assertLocalOnly("documents.evict", info.id) { try await client.documents.evict(documentId: info.id) }
        await assertLocalOnly("documents.evict(force)", info.id) {
            try await client.documents.evict(documentId: info.id, options: EvictDocumentOptions(force: true))
        }
        await client.evictLocalDocument(info.id)
        XCTAssertEqual(notes.find(id: "n1")?.id, "n1", "the rows are still readable")

        await client.documents.evictAll(options: EvictAllDocumentsOptions(onlySynced: true))
        await client.documents.evictAll()
        await client.evictAllLocal()
        await client.evictAllLocal(force: true)

        XCTAssertEqual(notes.find(id: "n1")?.id, "n1", "the rows are still readable")
        let stored = try await client.db3.stored()
        XCTAssertEqual(stored.map(\.id), [info.id])
        XCTAssertEqual(stored.first?.localOnly, true)
        XCTAssertEqual(stored.first?.rows, 1)
        let meta = client.documentManager.getLocalMetadata(info.id)
        XCTAssertEqual(meta?.localOnly, true, "the metadata row is intact")
        XCTAssertEqual(meta?.title, "Mine")
        let state = try await client.db3.state(info.id)
        XCTAssertTrue(state.resident)
        XCTAssertTrue(state.localOnly)
    }

    // MARK: - Behaviour 31, the client half

    func testDeleteRemovesItHereWithNothingSent() async throws {
        let client = try await world.client(directory: world.directory())
        let transport = RecordingTransport(status: 200, json: #"{"success":true}"#)
        let info = try await world.createLocalOnly(client, transport: transport)
        let db3 = Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
        let notes = try world.notes(client, info.id)
        _ = try notes.save(id: "n1", values: ["slug": .string("a")])
        let evicted = LockedBox<[Db3EvictedEvent]>([])
        let gone = LockedBox(0)
        let subs = [
            client.eventEmitter.subscribe(Db3EvictedEvent.self) { event in evicted.withValue { $0.append(event) } },
            client.eventEmitter.subscribe(Db3GoneEvent.self) { _ in gone.withValue { $0 += 1 } },
        ]
        defer { subs.forEach { $0.cancel() } }
        let sub = try client.db3.subscribe(info.id)
        try await sub.ready()
        let heardEvicted = LockedBox(false)
        let watching = sub.observe { event in if case .evicted = event { heardEvicted.value = true } }
        defer { watching.cancel() }

        let result = try await db3.delete(info.id)
        XCTAssertTrue(result.success)
        XCTAssertEqual(transport.calls.count, 0, "nothing is sent")
        XCTAssertTrue(heardEvicted.value, "the subscription heard evicted")
        XCTAssertFalse(client._db3Lifecycle.isSubscribed(info.id), "its subscriptions ended")
        try await db3LocalOnlyEventually("Db3EvictedEvent") { !evicted.value.isEmpty }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(evicted.value.map(\.reason), [.explicit], "fires once, explicit")
        XCTAssertEqual(gone.value, 0, "no Db3GoneEvent")
        let stored = try await client.db3.stored()
        XCTAssertEqual(stored.filter { $0.id == info.id }, [])
        XCTAssertNil(client.documentManager.getLocalMetadata(info.id), "the metadata row is gone")
        let state = try await client.db3.state(info.id)
        XCTAssertFalse(state.resident)
        XCTAssertEqual(state.rows, 0)
    }
}
