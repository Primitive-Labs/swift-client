import XCTest
@testable import JsBaoClient
import YSwift

/// Ordinary documents are untouched by everything #3437 added (S10,
/// behavior 37).
///
/// The claim is not "the format-1 suites still pass" — they do, and that is a
/// gate rather than a test. It is that the machinery this child built is
/// unreachable from a format-1 path: a client that never opens a large
/// document builds no coordinator at all, a format-1 document's inbound frames
/// are never gated by one, its persist never consults a generation, and the
/// refusal event the non-throwing mutation verbs gained is never emitted for
/// it.
///
/// Held as PROPERTIES rather than as a list of call sites, so the guard
/// survives the next child adding one.
final class Format2OrdinaryDocumentsGuardHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "/f2-guard-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    private func makeClient() async -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: "ws://127.0.0.1:1",
            appId: "format2-guard-test-app",
            token: makeTestJwt(userId: "format2-guard-user"),
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .sqlite(directory: newDatabasePath()),
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
        _ = await client.waitForStorageReady()
        return client
    }

    private func openOrdinary(
        _ client: JsBaoClient, _ documentId: String
    ) async throws -> YDocument {
        client.documentManager.createRemoteDocument = { (_: [String: Any]) in
            ["documentId": documentId]
        }
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId, title: "ordinary", localOnly: false,
            documentFormat: 1
        )
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        return try XCTUnwrap(client.documentManager.getDocument(documentId))
    }

    // MARK: - Nothing format-1 reaches the coordinator

    func testAClientThatOpensOnlyOrdinaryDocumentsBuildsNoCoordinatorAtAll()
        async throws
    {
        let client = await makeClient()
        XCTAssertNil(
            client.format2,
            "the precondition: a fresh client has no large-document state"
        )
        let documentId = "guard-\(UUID().uuidString.prefix(8))"
        _ = try await openOrdinary(client, documentId)

        XCTAssertNil(
            client.format2,
            "opening an ordinary document builds no coordinator, no client id, "
                + "no record store and no format-2 table — which is what makes "
                + "'ordinary documents are untouched' a property of "
                + "construction rather than of review"
        )
        XCTAssertFalse(client.isLargeDocument(documentId))
        await client.documentManager.closeDocument(documentId: documentId)
    }

    func testAnUnboundDocumentsInboundFramesAreNeverGated() async throws {
        let provider = SQLiteStorageProvider(path: newDatabasePath())
        try await provider.initialize(namespace: "test")
        let coordinator = Format2Coordinator(
            host: provider, clientId: "me", logger: Logger(level: .none)
        )
        // Even with a coordinator in existence — a client that DOES hold a
        // large document — a document it has not bound is not its business.
        _ = try coordinator.bind(
            documentId: "large", models: ["Note"], document: YDocument()
        )
        XCTAssertTrue(coordinator.admitInbound("an-ordinary-document"))
        XCTAssertTrue(coordinator.acceptsInbound("an-ordinary-document"))
        XCTAssertFalse(coordinator.isLargeDocument("an-ordinary-document"))
        XCTAssertEqual(
            coordinator.inboundDropLogCount("an-ordinary-document"), 0,
            "and nothing about it is even logged: a frame for a document this "
                + "coordinator does not hold was never a decision it took"
        )
        XCTAssertNil(coordinator.binding("an-ordinary-document"))
    }

    // MARK: - The refusal event is a large document's alone

    func testTheWriteRefusedEventIsNeverEmittedForAnOrdinaryDocument()
        async throws
    {
        let client = await makeClient()
        let refusals = LockedBox<[DocumentWriteRefusedEvent]>([])
        let subscription = client.eventEmitter.subscribe(DocumentWriteRefusedEvent.self) { event in
            refusals.withValue { $0.append(event) }
        }
        let documentId = "guard-\(UUID().uuidString.prefix(8))"
        let doc = try await openOrdinary(client, documentId)

        let schema = PrimitiveSchema(
            name: "Note",
            fields: [
                "id": FieldDescriptor(type: .id),
                "title": FieldDescriptor(type: .string),
            ]
        )
        let model = MultiDocModel(schema: schema).connect(docId: documentId, doc: doc)
        let record = try model.create(id: "n1", values: ["title": .string("one")])
        // Every door the window gate sits on, driven on a document that has no
        // window because it has no epoch: the throwing ones and the two that
        // cannot throw and report through the event instead.
        try model.update(id: "n1", values: ["title": .string("two")])
        record["title"] = .string("three")
        model.delete(id: "n1")

        XCTAssertTrue(
            refusals.value.isEmpty,
            "an ordinary document has no offline window and no gate: the event "
                + "#3437 added is a large document's alone"
        )
        XCTAssertNil(client.format2)
        subscription.cancel()
        await client.documentManager.closeDocument(documentId: documentId)
    }
}
