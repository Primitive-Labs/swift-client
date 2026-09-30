import XCTest
@testable import JsBaoClient
import YSwift

/// A Swift app opens a large document against a real room (#3436,
/// behavior 19; criterion 12).
///
/// Every other case in this child is hermetic: a real SQLite, a real Yjs
/// document, frames driven by hand. None of them can say whether the ROOM
/// accepts what this client sends — and the room refuses a client whose
/// `syncStep1` does not declare format 2 by closing the socket with 4426, so
/// "the unit tests pass" says nothing about whether a Swift app can open one
/// of these documents at all.
///
/// The shape: create with `documentFormat: 2`, open it, take the `epoch.info`
/// handshake, write through the generated facade, have the write acknowledged,
/// and then read it back on a SECOND client instance over the same database
/// with the network off — which is the relaunch an app actually performs — and
/// on a THIRD over the network.
final class Format2LargeDocumentLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var testApp: TestApp!
    private var directory: String!
    private var clients: [JsBaoClient] = []

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string, required: true),
            "views": FieldDescriptor(type: .number, indexed: true),
        ]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-format2")
        directory = NSTemporaryDirectory() + "f2-live-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        try? FileManager.default.removeItem(atPath: directory)
        await ctx?.cleanup()
    }

    /// A client over this test's own on-disk database. `.sqlite` and not
    /// `.memory`: a large document's records are SQL rows in the storage
    /// provider's own file, and a provider that cannot host them refuses the
    /// open by type.
    private func makeClient(databasePath: String, autoNetwork: Bool) async -> JsBaoClient {
        let client = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            storageConfig: .sqlite(directory: databasePath),
            autoNetwork: autoNetwork
        )
        client.registerModels([Self.schema])
        clients.append(client)
        _ = await client.waitForStorageReady()
        return client
    }

    /// This test's own database file — the one an app would carry across a
    /// relaunch.
    private var databasePath: String { directory + "/store.sqlite" }

    func testALargeDocumentIsCreatedOpenedWrittenAndSurvivesARelaunch() async throws {
        // ---- A fresh client creates one, and the room agrees it is large.
        let author = await makeClient(databasePath: databasePath, autoNetwork: true)
        try await author.connect()
        try await waitForConnection(client: author)

        let created = try await author.createDocument(options: CreateDocumentOptions(
            title: "swift large document", documentFormat: 2
        ))
        let documentId = try XCTUnwrap(
            created.metadata?["documentId"]?.stringValue,
            "the create returned no document id"
        )
        try await eventually(
            timeout: 20, description: "the create to commit to the server"
        ) {
            author.documentManager.getLocalMetadata(documentId)?.pendingCreate != true
        }

        _ = try await author.openDocument(documentId, options: OpenDocumentOptions(
            waitForLoad: .localIfAvailableElseNetwork, enableNetworkSync: true
        ))

        // ---- The handshake: the room answered `epoch.info`, and this client
        // joined its epoch rather than being closed with 4426.
        XCTAssertTrue(
            author.isLargeDocument(documentId),
            "the client did not bind the document as a large one"
        )
        let binding = try XCTUnwrap(author.format2?.binding(documentId))
        try await eventually(
            timeout: 20, description: "the epoch.info handshake to release the hold"
        ) {
            author.format2?.hold.isHeld(documentId) == false
        }
        XCTAssertGreaterThan(
            try binding.store.epoch(), 0,
            "the join recorded the room's epoch, so a reopen knows where it stands"
        )
        XCTAssertFalse(
            binding.reloadRequired,
            "a fresh large document must be joinable, not stopped"
        )

        // ---- A write through the facade the app actually uses, acknowledged
        // by the room.
        let model = try XCTUnwrap(author.sharedModel("Note")?.member(docId: documentId))
        _ = try model.create(id: "n1", values: [
            "title": .string("written by swift"), "views": .number(7),
        ])
        XCTAssertEqual(
            try binding.store.pendingOps().count, 1,
            "the write is owed until the room acknowledges it"
        )
        try await eventually(
            timeout: 20, description: "the room to acknowledge the write"
        ) {
            try binding.store.pendingOps().isEmpty
        }

        // The merged view answers, through `find` and through a filtered read.
        XCTAssertEqual(model.find(id: "n1")?["title"], .string("written by swift"))
        XCTAssertEqual(try model.count(["views": .number(7)]), 1)

        await author.destroy()

        // ---- The relaunch: a second instance over the SAME database, with no
        // network at all, reads the record from its own store.
        let relaunched = await makeClient(databasePath: databasePath, autoNetwork: false)
        try await eventually(timeout: 20, description: "the relaunched client's storage") {
            relaunched.documentManager.getLocalMetadata(documentId) != nil
        }
        XCTAssertEqual(
            relaunched.documentManager.documentFormat(documentId), 2,
            "the local row remembers the format, so the next open binds before a frame"
        )
        _ = try await relaunched.openDocument(documentId, options: OpenDocumentOptions(
            waitForLoad: .local, enableNetworkSync: false
        ))
        let localModel = try XCTUnwrap(
            relaunched.sharedModel("Note")?.member(docId: documentId)
        )
        XCTAssertEqual(
            localModel.find(id: "n1")?["title"], .string("written by swift"),
            "a relaunched client reads the record from its own store, offline"
        )
        XCTAssertEqual(
            try localModel.count(["views": .number(7)]), 1,
            "and a filtered read answers from the projected rows, offline"
        )
        await relaunched.destroy()

        // ---- And a THIRD client, with its own empty database, reads it over
        // the network — the record really reached the room.
        let reader = await makeClient(
            databasePath: directory + "/reader.sqlite", autoNetwork: true
        )
        try await reader.connect()
        try await waitForConnection(client: reader)
        _ = try await reader.openDocument(documentId, options: OpenDocumentOptions(
            waitForLoad: .network, enableNetworkSync: true
        ))
        let remoteModel = try XCTUnwrap(reader.sharedModel("Note")?.member(docId: documentId))
        try await eventually(
            timeout: 20, description: "the record to arrive over the network"
        ) {
            remoteModel.find(id: "n1") != nil
        }
        XCTAssertEqual(remoteModel.find(id: "n1")?["title"], .string("written by swift"))
    }
}
