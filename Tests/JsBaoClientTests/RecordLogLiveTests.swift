import XCTest
@testable import JsBaoClient
import YSwift

/// A Swift app uses a record-log (`documentFormat: 3`) document against a real
/// room: create, open, write through the model facade, have the room
/// acknowledge, read it back on a relaunched client offline and on a third
/// client over the network; a second client's writes arrive as results; the
/// format is resolved before the handshake on a device that never saw the
/// document; no Yjs frame is ever sent; eviction and a wiping logout purge.
final class RecordLogLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var testApp: TestApp!
    private var directory: String!
    private var clients: [JsBaoClient] = []

    private static let note = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string, required: true),
            "slug": FieldDescriptor(type: .string, unique: true),
            "views": FieldDescriptor(type: .number, indexed: true),
            "tags": FieldDescriptor(type: .stringset),
        ]
    )

    private static let tag = PrimitiveSchema(
        name: "Tag",
        fields: ["id": FieldDescriptor(type: .id), "label": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-record-log")
        directory = NSTemporaryDirectory() + "rl-live-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        try? FileManager.default.removeItem(atPath: directory)
        await ctx?.cleanup()
    }

    private func makeClient(_ name: String, autoNetwork: Bool = true, models: [PrimitiveSchema] = [note, tag]) async throws -> JsBaoClient {
        let client = createTestClient(
            appId: testApp.appId, token: testApp.ownerJWT,
            storageConfig: .sqlite(directory: directory + "/\(name).sqlite"), autoNetwork: autoNetwork
        )
        client.registerModels(models)
        clients.append(client)
        _ = await client.waitForStorageReady()
        if autoNetwork {
            try await client.connect()
            try await waitForConnection(client: client, timeout: 10)
        }
        return client
    }

    private func createDocument(_ client: JsBaoClient) async throws -> String {
        let created = try await client.createDocument(options: CreateDocumentOptions(title: "swift record log", documentFormat: 3))
        let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        try await waitForCreateCommit(client, documentId)
        return documentId
    }

    private func open(_ client: JsBaoClient, _ documentId: String, wait: WaitForLoadMode = .network) async throws {
        _ = try await client.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: wait, enableNetworkSync: true))
    }

    private func member(_ client: JsBaoClient, _ documentId: String, _ model: String = "Note") throws -> DynamicModel {
        try XCTUnwrap(client.sharedModel(model)?.member(docId: documentId))
    }

    private func unacknowledged(_ client: JsBaoClient, _ documentId: String) throws -> Int {
        let binding = try XCTUnwrap(client.recordLogBinding(documentId))
        return try binding.store.pendingOf(binding.writer).filter { $0.acked == nil }.count
    }

    // MARK: - Behavior 20

    func testCreateOpenWriteAcknowledgeRelaunchOfflineAndReadOverTheNetwork() async throws {
        let author = try await makeClient("author")
        let documentId = try await createDocument(author)
        try await open(author, documentId)
        XCTAssertTrue(author.isRecordLogDocument(documentId), "the open bound the document as format 3")
        try await waitForSync(client: author, documentId: documentId, timeout: 20)

        let notes = try member(author, documentId)
        _ = try notes.create(id: "n1", values: [
            "title": .string("first"), "slug": .string("one"), "views": .number(3), "tags": .stringset(["a"]),
        ])
        try notes.update(id: "n1", values: ["title": .string("patched")])
        try notes.addStringsetMember(id: "n1", fieldName: "tags", member: "b")
        _ = try notes.create(id: "n2", values: ["title": .string("second"), "views": .number(10)])
        _ = try notes.create(id: "n3", values: ["title": .string("gone")])
        notes.delete(id: "n3")
        let binding = try XCTUnwrap(author.recordLogBinding(documentId))
        XCTAssertEqual(binding.syncState(model: "Note", id: "n1", lastSeq: nil), .pending)
        try await eventually(timeout: 20, description: "the room to acknowledge every entry") {
            try unacknowledged(author, documentId) == 0
        }
        XCTAssertEqual(binding.syncState(model: "Note", id: "n1", lastSeq: nil), .confirmed)

        XCTAssertEqual(notes.find(id: "n1")?["title"], .string("patched"))
        XCTAssertEqual(notes.find(id: "n1")?["tags"], .stringset(["a", "b"]))
        XCTAssertNil(notes.find(id: "n3"))
        XCTAssertEqual(notes.findAll().map(\.id).sorted(), ["n1", "n2"])
        XCTAssertEqual(try notes.query(["views": .object(["$gt": 5])]).compactMap { $0["id"]?.stringValue }, ["n2"])
        XCTAssertEqual(try notes.count(), 2)
        XCTAssertEqual(try notes.aggregate(AggregateOptions(operations: [AggregateOperation(type: .sum, field: "views")]))
            .first?["sum_views"]?.numberValue, 13)
        let slug = try XCTUnwrap(Self.note.resolvedUniqueConstraints.first?.name)
        XCTAssertEqual(try notes.findByUnique(constraint: slug, values: [.string("one")])?.id, "n1")

        // A write made while offline stays pending through the relaunch.
        await author.goOffline()
        _ = try notes.create(id: "n4", values: ["title": .string("offline")])
        XCTAssertEqual(try unacknowledged(author, documentId), 1)
        await author.destroy()

        // The relaunch: a second instance over the SAME database, network off.
        let relaunched = createTestClient(
            appId: testApp.appId, token: testApp.ownerJWT,
            storageConfig: .sqlite(directory: directory + "/author.sqlite"), autoNetwork: false
        )
        relaunched.registerModels([Self.note, Self.tag])
        clients.append(relaunched)
        _ = await relaunched.waitForStorageReady()
        try await open(relaunched, documentId, wait: .local)
        let offlineNotes = try member(relaunched, documentId)
        XCTAssertEqual(offlineNotes.find(id: "n1")?["title"], .string("patched"), "read offline from the store")
        XCTAssertEqual(offlineNotes.find(id: "n4")?["title"], .string("offline"))
        XCTAssertEqual(try offlineNotes.count(), 3)

        // Back online, the earlier instance's entry is drained and lands.
        try await relaunched.connect()
        try await waitForConnection(client: relaunched, timeout: 10)
        await relaunched.startNetworkSync(documentId: documentId)
        let third = try await makeClient("third")
        try await open(third, documentId)
        try await eventually(timeout: 30, description: "the offline write to reach a third client over the network") {
            (try? member(third, documentId).find(id: "n4")?["title"]) == .string("offline")
        }
        let thirdNotes = try member(third, documentId)
        XCTAssertEqual(thirdNotes.find(id: "n1")?["title"], .string("patched"))
        XCTAssertEqual(thirdNotes.find(id: "n1")?["tags"], .stringset(["a", "b"]))
        XCTAssertEqual(try thirdNotes.count(), 3)
    }

    // MARK: - Behavior 21

    func testASecondClientsWritesArriveAsResultsAndMoveSubscribers() async throws {
        let first = try await makeClient("first")
        let documentId = try await createDocument(first)
        try await open(first, documentId)
        let second = try await makeClient("second")
        try await open(second, documentId)
        try await waitForSync(client: first, documentId: documentId, timeout: 20)
        try await waitForSync(client: second, documentId: documentId, timeout: 20)

        let heard = LockedBox(0)
        let unsubscribe = try member(first, documentId).subscribe { heard.withValue { $0 += 1 } }
        defer { unsubscribe() }
        _ = try member(second, documentId).create(id: "s1", values: ["title": .string("from second"), "views": .number(1)])
        try await eventually(timeout: 20, description: "the second client's write to arrive") {
            (try? member(first, documentId).find(id: "s1")?["title"]) == .string("from second")
        }
        XCTAssertGreaterThan(heard.value, 0, "subscribe heard the result")

        // Different fields of one record both keep their change.
        try member(first, documentId).update(id: "s1", values: ["title": .string("title by first")])
        try member(second, documentId).update(id: "s1", values: ["views": .number(42)])
        try await eventually(timeout: 20, description: "both changes on both clients") {
            let a = try member(first, documentId).find(id: "s1")
            let b = try member(second, documentId).find(id: "s1")
            return a?["title"] == .string("title by first") && a?["views"] == .number(42)
                && b?["title"] == .string("title by first") && b?["views"] == .number(42)
        }
        // The same field converges on the later log number.
        try member(first, documentId).update(id: "s1", values: ["title": .string("one")])
        try await eventually(timeout: 20, description: "the first write acknowledged") { try unacknowledged(first, documentId) == 0 }
        try member(second, documentId).update(id: "s1", values: ["title": .string("two")])
        try await eventually(timeout: 20, description: "both converge on the later write") {
            try member(first, documentId).find(id: "s1")?["title"] == .string("two")
                && member(second, documentId).find(id: "s1")?["title"] == .string("two")
        }
    }

    // MARK: - Behavior 29 and edge 53

    func testADocumentThisDeviceNeverSawIsResolvedBeforeTheHandshakeAndNeverSendsYjs() async throws {
        let author = try await makeClient("author")
        let documentId = try await createDocument(author)
        try await open(author, documentId)
        try await waitForSync(client: author, documentId: documentId, timeout: 20)
        _ = try member(author, documentId).create(id: "a1", values: ["title": .string("by the author")])
        try await eventually(timeout: 20, description: "the write acknowledged") { try unacknowledged(author, documentId) == 0 }

        let fresh = try await makeClient("fresh")
        XCTAssertNil(fresh.documentManager.documentFormat(documentId), "this device never saw the document")
        let syncStep1s = LockedBox(0)
        fresh.onSyncStep1SendForTest = { _ in syncStep1s.withValue { $0 += 1 } }
        try await open(fresh, documentId)
        XCTAssertTrue(fresh.isRecordLogDocument(documentId), "resolved through the documents API before the handshake")
        XCTAssertEqual(fresh.documentManager.documentFormat(documentId), 3, "and remembered on its row")
        try await waitForSync(client: fresh, documentId: documentId, timeout: 20)
        XCTAssertEqual(try member(fresh, documentId).find(id: "a1")?["title"], .string("by the author"))

        // Writes, a late model, and the Y.Doc stays empty: no Yjs frame at all.
        let notes = try member(fresh, documentId)
        _ = try notes.create(id: "f1", values: ["title": .string("fresh")])
        let late = PrimitiveSchema(name: "Late", fields: ["id": FieldDescriptor(type: .id), "x": FieldDescriptor(type: .string)])
        fresh.registerModels([late])
        _ = try XCTUnwrap(fresh.sharedModel("Late")?.member(docId: documentId)).create(id: "l1", values: ["x": .string("late")])
        try await eventually(timeout: 20, description: "the writes acknowledged") { try unacknowledged(fresh, documentId) == 0 }
        XCTAssertEqual(syncStep1s.value, 0, "a format-3 document never sends syncStep1")
        XCTAssertEqual(fresh.pendingOutboundUpdateCountForTest(documentId), 0, "no Yjs update was queued")
        let doc = try XCTUnwrap(fresh.documentManager.getDocument(documentId))
        let meta = doc.transactSync { transaction -> Int in
            guard let map = transaction.transactionGetMap(name: "_meta_Note") else { return 0 }
            let collector = DynamicModel.KeyCollector()
            map.keys(tx: transaction, delegate: collector)
            return collector.keys.count
        }
        XCTAssertEqual(meta, 0, "the declaration went in record.declare, never into the Y.Doc")
        XCTAssertTrue(fresh.isSynced(documentId), "the room never tore the document down")
        try await eventually(timeout: 20, description: "the late model's write to reach the author") {
            (try? XCTUnwrap(author.sharedModel("Note")?.member(docId: documentId)).find(id: "f1")) != nil
        }
    }

    /// 4309-C2-01: the open itself brings the socket up (`autoNetwork: false`,
    /// never connected), so it could not ask the documents API; the handshake
    /// asks before it goes out, and it is `record.open`, never a `syncStep1`.
    func testAnOpenThatConnectsTheSocketResolvesTheFormatBeforeItsHandshake() async throws {
        let author = try await makeClient("author")
        let documentId = try await createDocument(author)
        try await open(author, documentId)
        try await waitForSync(client: author, documentId: documentId, timeout: 20)
        _ = try member(author, documentId).create(id: "a1", values: ["title": .string("by the author")])
        try await eventually(timeout: 20, description: "the write acknowledged") { try unacknowledged(author, documentId) == 0 }

        let cold = try await makeClient("cold", autoNetwork: false)
        XCTAssertFalse(cold.isConnected, "not connected before the open")
        XCTAssertNil(cold.documentManager.documentFormat(documentId))
        let syncStep1s = LockedBox(0)
        cold.onSyncStep1SendForTest = { _ in syncStep1s.withValue { $0 += 1 } }
        try await open(cold, documentId)
        XCTAssertTrue(cold.isRecordLogDocument(documentId), "bound before its handshake")
        XCTAssertEqual(cold.documentManager.documentFormat(documentId), 3)
        XCTAssertEqual(try member(cold, documentId).find(id: "a1")?["title"], .string("by the author"))
        XCTAssertEqual(syncStep1s.value, 0, "the handshake was record.open")
        XCTAssertNil(cold.formatRefusal(documentId), "the room never refused the document")
    }

    func testALocalOnlyFormatThreeCreateIsRefusedBeforeAnyLocalState() async throws {
        let offline = try await makeClient("offline", autoNetwork: false)
        do {
            _ = try await offline.createDocument(options: CreateDocumentOptions(localOnly: true, documentFormat: 3))
            XCTFail("a local-only format-3 document is refused")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .localOnlyUnsupportedOption)
        }
        XCTAssertTrue(offline.documentManager.getMetadataIndex().isEmpty, "before any local state")
    }

    // MARK: - Behavior 31

    func testCloseKeepsTheStoreAndEvictPurgesItHandingBackUnsentWrites() async throws {
        let client = try await makeClient("evicting")
        let documentId = try await createDocument(client)
        try await open(client, documentId)
        try await waitForSync(client: client, documentId: documentId, timeout: 20)
        _ = try member(client, documentId).create(id: "k1", values: ["title": .string("kept")])
        try await eventually(timeout: 20, description: "acknowledged") { try unacknowledged(client, documentId) == 0 }

        _ = await client.closeDocument(documentId)
        XCTAssertTrue(client.isRecordLogDocument(documentId), "a db3's close keeps its store bound (#4701)")
        try await open(client, documentId, wait: .local)
        XCTAssertEqual(try member(client, documentId).find(id: "k1")?["title"], .string("kept"), "an ordinary close keeps everything")
        try await waitForSync(client: client, documentId: documentId, timeout: 20)

        await client.goOffline()
        _ = try member(client, documentId).create(id: "lost", values: ["title": .string("never sent")])
        let refusals = LockedBox<[DocumentWriteRefusedEvent]>([])
        let subscription = client.eventEmitter.subscribe(DocumentWriteRefusedEvent.self) { event in
            refusals.withValue { $0.append(event) }
        }
        defer { subscription.cancel() }
        await client.evictLocalDocument(documentId)
        try await eventually(timeout: 10, description: "the purge's refusal event") { !refusals.value.isEmpty }
        XCTAssertEqual(refusals.value.count, 1)
        XCTAssertEqual(refusals.value.first?.error.code, .documentStorePurged)
        XCTAssertEqual(refusals.value.first?.writes?.map(\.recordId), ["lost"])
        let provider = await client.offlineStore.getStorageProvider()
        let host = try XCTUnwrap(provider as? any Format2SqlHost)
        try host.withConnection { connection in
            for table in RecordLogSchema.clientTables {
                let n = try connection.query("SELECT COUNT(*) AS n FROM \(table) WHERE doc_id = ?", [.text(documentId)]).first?["n"].intValue
                XCTAssertEqual(n, 0, table)
            }
        }
    }
}
