import XCTest
@testable import JsBaoClient
import YSwift

/// A record-log store belongs to the user it was written for (intent decision
/// 18). User A writes offline and logs out without wiping; user B signs in on
/// the same client — in this process, and on a relaunch over the same
/// directory — and opens the same document as a new writer: A's unsent writes
/// are not sent, are gone from the store, and raise nothing for B, and B's
/// writes land. A returning to their own store keeps it, and its unsent writes
/// are resubmitted.
final class RecordLogPrincipalLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var testApp: TestApp!
    private var userB: TestUser!
    private var directory: String!
    private var clients: [JsBaoClient] = []

    private static let note = PrimitiveSchema(
        name: "Note",
        fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-record-log-principal")
        userB = try await ctx.createTestUser(appId: testApp.appId)
        directory = NSTemporaryDirectory() + "rl-principal-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        try? FileManager.default.removeItem(atPath: directory)
        await ctx?.cleanup()
    }

    private var sharedPath: String { directory + "/device.sqlite" }

    private func makeClient(path: String, token: String, connect: Bool = true) async throws -> JsBaoClient {
        let client = createTestClient(appId: testApp.appId, token: token, storageConfig: .sqlite(directory: path), autoNetwork: connect)
        client.registerModels([Self.note])
        clients.append(client)
        _ = await client.waitForStorageReady()
        if connect {
            try await client.connect()
            try await waitForConnection(client: client, timeout: 10)
        }
        return client
    }

    private func notes(_ client: JsBaoClient, _ documentId: String) throws -> DynamicModel {
        try XCTUnwrap(client.sharedModel("Note")?.member(docId: documentId))
    }

    private func unacknowledged(_ client: JsBaoClient, _ documentId: String) throws -> Int {
        let binding = try XCTUnwrap(client.recordLogBinding(documentId))
        return try binding.store.pendingOf(binding.writer).filter { $0.acked == nil }.count
    }

    private func pendingRows(_ client: JsBaoClient) async throws -> Int {
        let provider = await client.offlineStore.getStorageProvider()
        let host = try XCTUnwrap(provider as? any Format2SqlHost)
        return try host.withConnection { connection in
            try connection.query("SELECT COUNT(*) AS n FROM record_log_pending").first?["n"].intValue ?? -1
        }
    }

    /// A's document with one acknowledged write and one unsent one; A logged
    /// out without wiping. Answers the document and A's writer.
    private func documentWithAnUnsentWriteOfA(_ client: JsBaoClient) async throws -> (String, String) {
        let created = try await client.createDocument(options: CreateDocumentOptions(title: "shared", documentFormat: 3))
        let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        try await eventually(timeout: 20, description: "the create to commit") {
            client.documentManager.getLocalMetadata(documentId)?.pendingCreate != true
        }
        try await ctx.grantPermission(
            appId: testApp.appId, documentId: documentId, userId: userB.userId, permission: "read-write", jwt: testApp.ownerJWT
        )
        _ = try await client.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: documentId, timeout: 20)
        let writerA = try XCTUnwrap(client.recordLogBinding(documentId)?.writer)
        _ = try notes(client, documentId).create(id: "a1", values: ["title": .string("sent by a")])
        try await eventually(timeout: 20, description: "a1 acknowledged") { try unacknowledged(client, documentId) == 0 }
        await client.goOffline()
        _ = try notes(client, documentId).create(id: "a2", values: ["title": .string("never sent by a")])
        XCTAssertEqual(try unacknowledged(client, documentId), 1)
        try await client.logout()
        return (documentId, writerA)
    }

    private func observerSees(_ documentId: String, _ id: String) async throws -> Bool {
        let observer = try await makeClient(path: directory + "/observer-\(UUID().uuidString.prefix(4)).sqlite", token: testApp.ownerJWT)
        _ = try await observer.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: observer, documentId: documentId, timeout: 20)
        return try notes(observer, documentId).find(id: id) != nil
    }

    func testAnotherUserSigningInOnTheSameClientGetsANewWriterAndNoneOfTheFirstUsersWrites() async throws {
        let client = try await makeClient(path: sharedPath, token: testApp.ownerJWT)
        let (documentId, writerA) = try await documentWithAnUnsentWriteOfA(client)
        let refusals = LockedBox(0)
        let subscription = client.eventEmitter.subscribe(DocumentWriteRefusedEvent.self) { _ in refusals.withValue { $0 += 1 } }
        defer { subscription.cancel() }

        client.updateToken(userB.jwt)
        await client.rebindUserScopedStorage()
        let rowsClient0 = try await pendingRows(client)
        XCTAssertEqual(rowsClient0, 0, "the store was reset for user B")
        client.setNetworkMode(.online)
        try await client.connect()
        try await waitForConnection(client: client, timeout: 10)
        _ = try await client.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: documentId, timeout: 20)
        let writerB = try XCTUnwrap(client.recordLogBinding(documentId)?.writer)
        XCTAssertNotEqual(writerB, writerA, "B opens as a new writer, never A's")
        XCTAssertEqual(try notes(client, documentId).find(id: "a1")?["title"], .string("sent by a"), "the room's rows, caught up")
        XCTAssertNil(try notes(client, documentId).find(id: "a2"), "A's unsent write is gone")
        _ = try notes(client, documentId).create(id: "b1", values: ["title": .string("by b")])
        try await eventually(timeout: 20, description: "b1 acknowledged") { try unacknowledged(client, documentId) == 0 }
        XCTAssertEqual(refusals.value, 0, "nothing of A's was handed to B")
        let observer = try await observerSees(documentId, "b1")
        XCTAssertTrue(observer, "B's write landed")
        let leaked = try await observerSees(documentId, "a2")
        XCTAssertFalse(leaked, "A's unsent write never reached the room")
    }

    func testARelaunchAsAnotherUserResetsAndTheSameUserKeepsAndResubmits() async throws {
        let first = try await makeClient(path: sharedPath, token: testApp.ownerJWT)
        let (documentId, _) = try await documentWithAnUnsentWriteOfA(first)
        await first.destroy()

        // A relaunches and signs in again: the store and its unsent write survive and are resubmitted.
        let again = try await makeClient(path: sharedPath, token: testApp.ownerJWT)
        let rowsAgain1 = try await pendingRows(again)
        XCTAssertEqual(rowsAgain1, 1)
        _ = try await again.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: again, documentId: documentId, timeout: 20)
        let delivered = try await observerSees(documentId, "a2")
        XCTAssertTrue(delivered, "the returning user's unsent write was resubmitted and landed")

        await again.goOffline()
        _ = try notes(again, documentId).create(id: "a3", values: ["title": .string("unsent again")])
        try await again.logout()
        await again.destroy()

        // B relaunches over the same directory: reset before anything opens.
        let other = try await makeClient(path: sharedPath, token: userB.jwt)
        let rowsOther0 = try await pendingRows(other)
        XCTAssertEqual(rowsOther0, 0)
        _ = try await other.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: other, documentId: documentId, timeout: 20)
        XCTAssertNil(try notes(other, documentId).find(id: "a3"))
        XCTAssertNotNil(try notes(other, documentId).find(id: "a2"))
    }
}
