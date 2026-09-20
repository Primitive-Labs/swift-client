import XCTest
@testable import JsBaoClient
import YSwift

/// A base load is a download that outlives the frame that asked for it
/// (#3436).
///
/// It is however many megabytes the document is, so it cannot run on the
/// socket's receive loop, and everything that can happen to a document while it
/// runs — a reconnect's handshake, a seal, a close — happens under it. What is
/// asserted here is that the load neither blocks the loop nor, having been
/// overtaken, speaks for a document something newer has already decided about.
final class Format2BaseLoadLifecycleHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "/f2-load-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    private func makeCoordinator() async throws -> Format2Coordinator {
        let provider = SQLiteStorageProvider(path: newDatabasePath())
        try await provider.initialize(namespace: "test")
        return Format2Coordinator(
            host: provider, clientId: "me", logger: Logger(level: .none)
        )
    }

    // MARK: - An overtaken load commits nothing (finding 3436-REV-03)

    /// The completion of a base load sets the epoch mark, clears the reload
    /// refusal and releases the outbound hold — three statements about the
    /// CURRENT state of the document. A load that finishes after a reconnect
    /// stopped that document would make all three about a state that is two
    /// decisions old, and the hold it released is the one protecting local
    /// writes from an epoch the room has replaced.
    func testALoadOvertakenByASealReleasesNothing() async throws {
        let coordinator = try await makeCoordinator()
        let documentId = "overtaken-\(UUID().uuidString.prefix(8))"
        let binding = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: YDocument()
        )

        // The load starts, and claims its attempt, as the client's handshake
        // does before it schedules the task that runs it.
        let attempt = coordinator.beginBaseLoad(documentId)
        XCTAssertTrue(coordinator.baseLoadIsCurrent(documentId, attempt: attempt))

        // While it is streaming, the room seals the epoch its base was cut for.
        try coordinator.handleEpochSeal([
            "type": "epoch.seal", "documentId": documentId, "epoch": 4, "next": 5,
        ])
        // #3437's phase B follows a seal rather than stopping on it, so the
        // precondition is no longer a refusal — it is that the seal left this
        // document behind the room, which is what makes the base stale.
        XCTAssertFalse(coordinator.acceptsInbound(documentId))
        XCTAssertTrue(
            coordinator.hold.isHeld(documentId),
            "and nothing of this document's goes out on an epoch the room has "
                + "replaced"
        )

        XCTAssertFalse(
            coordinator.baseLoadIsCurrent(documentId, attempt: attempt),
            "the load in flight has been overtaken and may not complete the handshake"
        )
    }

    /// The same for a reconnect: a second `epoch.info` decides the document's
    /// state from scratch, so the load the first one asked for is stale.
    func testAFreshHandshakeOvertakesTheLoadItsPredecessorStarted() async throws {
        let coordinator = try await makeCoordinator()
        let documentId = "rehandshake-\(UUID().uuidString.prefix(8))"
        _ = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: YDocument()
        )

        let attempt = coordinator.beginBaseLoad(documentId)
        _ = try coordinator.handleEpochInfo([
            "type": "epoch.info", "documentId": documentId,
            "epoch": 0, "sealedEpochs": [], "offlineWindowDays": 14,
        ], now: 1_700_000_000_000)

        XCTAssertFalse(
            coordinator.baseLoadIsCurrent(documentId, attempt: attempt),
            "the newer handshake owns the document now"
        )
    }

    /// And for a close: the Y.Doc the load would fold the open overlay from is
    /// going away, and a reopen binds a new one.
    func testAnUnbindOvertakesALoadInFlight() async throws {
        let coordinator = try await makeCoordinator()
        let documentId = "closed-\(UUID().uuidString.prefix(8))"
        _ = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: YDocument()
        )

        let attempt = coordinator.beginBaseLoad(documentId)
        coordinator.unbind(documentId: documentId)

        XCTAssertFalse(coordinator.baseLoadIsCurrent(documentId, attempt: attempt))
    }

    /// An overtaken attempt does not stop the NEXT one: a document that was
    /// closed and reopened, or re-handshaked, gets its load.
    func testTheAttemptAfterAnOvertakenOneIsCurrent() async throws {
        let coordinator = try await makeCoordinator()
        let documentId = "next-\(UUID().uuidString.prefix(8))"
        _ = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: YDocument()
        )

        let first = coordinator.beginBaseLoad(documentId)
        let second = coordinator.beginBaseLoad(documentId)

        XCTAssertFalse(coordinator.baseLoadIsCurrent(documentId, attempt: first))
        XCTAssertTrue(coordinator.baseLoadIsCurrent(documentId, attempt: second))
    }
}

/// The client's side of the same lifecycle: what an `epoch.info` frame does
/// with a load, and what a failed open leaves behind (#3436).
final class Format2BaseLoadClientHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "/f2-load-client-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    private func makeClient(apiUrl: String = TestConfig.httpUrl) async -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: apiUrl,
            // Nothing answers here: this suite never wants a socket.
            wsUrl: "ws://127.0.0.1:1",
            appId: "format2-base-load-test-app",
            token: makeTestJwt(userId: "format2-load-user"),
            offline: false,
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .sqlite(directory: newDatabasePath()),
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
        _ = await client.waitForStorageReady()
        return client
    }

    private func createLocal(
        _ client: JsBaoClient, _ documentId: String, format: Int?
    ) async throws {
        client.documentManager.createRemoteDocument = { _ in ["documentId": documentId] }
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId, title: "load", localOnly: false, documentFormat: format
        )
    }

    // MARK: - The frame handler does not wait for the download (3436-REV-01)

    /// `handleWebSocketMessage` is awaited by the socket's receive loop, which
    /// takes one complete frame before it asks for the next. A load awaited
    /// inside a frame handler therefore stalls every frame for every document
    /// on that socket for the whole download — including the `epoch.grants`
    /// reply the loader itself waits for when a signature expires mid-stream,
    /// which is then the one recovery it has and cannot get.
    ///
    /// The API URL here is TEST-NET-1 (RFC 5737), which is guaranteed not to
    /// route: the manifest read hangs until URLSession's own timeout, tens of
    /// seconds away. So a handler that returned only when the load was done
    /// would take that long; one that hands the load to a task of its own
    /// returns in milliseconds.
    func testAnEpochInfoThatStartsAColdLoadReturnsImmediately() async throws {
        let client = await makeClient(apiUrl: "http://192.0.2.1")
        defer { Task { await client.destroy() } }

        let documentId = "coldload-\(UUID().uuidString.prefix(8))"
        try await createLocal(client, documentId, format: 2)
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        // A COLD client (no epoch mark) whose offered base covers the epoch the
        // room reports: the one plan this child loads on. The sealed chain is
        // non-empty, or "nothing was ever archived" makes it a plain join.
        let started = Date()
        await client.handleWebSocketMessage("""
        {"type":"epoch.info","documentId":"\(documentId)","documentFormat":2,\
        "epoch":7,"offlineWindowDays":14,\
        "sealedEpochs":[{"epoch":6,"sealedAt":1,\
        "download":{"path":"/artifact/six","expiresAt":9999999999999}}],\
        "snapshot":{"epoch":7,"buildId":"b1","rows":10,"manifestVersion":3,\
        "download":{"path":"/artifact/token","expiresAt":9999999999999}}}
        """)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed, 5,
            "the frame handler has to hand the download to a task of its own — the "
            + "receive loop is blocked for exactly as long as it does not"
        )
        // And the document is still held, because the load that would release
        // it has not finished (and, on this unroutable host, never will).
        XCTAssertTrue(
            try XCTUnwrap(client.format2).hold.isHeld(documentId),
            "a cold start releases the hold when the base is IN, not when it is asked for"
        )
    }

    // MARK: - And so does the chain a deferred judgement needs (REVIEW-009)

    /// Finding 3437-REVIEW-009: #3437 added two more downloads to this handler
    /// and both take the rule above.
    ///
    /// A judgement a restart interrupted is weighed against the sealed
    /// archives below the epoch it joined, and those archives are READ — over
    /// the same socket-adjacent HTTP path, with the same `epoch.grants`
    /// refresh when a signature expires mid-read. Awaited inside the frame
    /// handler it is not a slow handshake but a deadlock: the reply the
    /// refresh waits for can only be delivered by the loop the read is
    /// standing on.
    ///
    /// Unroutable host again, so the read hangs for tens of seconds. A handler
    /// that waits for it takes that long; one that hands it to a task returns
    /// in milliseconds with the note still owed.
    func testAnEpochInfoThatOwesADeferredJudgementReturnsImmediately() async throws {
        let client = await makeClient(apiUrl: "http://192.0.2.1")
        defer { Task { await client.destroy() } }

        let documentId = "deferred-\(UUID().uuidString.prefix(8))"
        try await createLocal(client, documentId, format: 2)
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        // What a restart between an epoch move and its judgement leaves: the
        // mark is the epoch the move joined, and the note names the span below
        // it whose archives are the evidence.
        let binding = try XCTUnwrap(client.format2?.binding(documentId))
        try binding.store.setEpoch(5)
        try binding.store.noteDeferredReplay(
            throughSeq: 1, fromEpoch: 3, toEpoch: 5, kind: .ordinary
        )

        let started = Date()
        await client.handleWebSocketMessage("""
        {"type":"epoch.info","documentId":"\(documentId)","documentFormat":2,\
        "epoch":5,"offlineWindowDays":14,\
        "sealedEpochs":[\
        {"epoch":3,"sealedAt":1,\
        "download":{"path":"/artifact/three","expiresAt":9999999999999}},\
        {"epoch":4,"sealedAt":2,\
        "download":{"path":"/artifact/four","expiresAt":9999999999999}}]}
        """)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed, 5,
            "the frame handler has to hand the archive reads to a task of its "
            + "own — the receive loop is blocked for exactly as long as it does not"
        )
        XCTAssertNotNil(
            try binding.store.deferredReplay(),
            "and the debt still stands: the evidence is being read, and the "
            + "judgement itself waits for the joined epoch's `syncComplete`"
        )
    }

    // MARK: - A failed open leaves no binding behind (3436-REV-02)

    /// `openDocument` binds a known large document before it decides whether
    /// the network can satisfy the open, and drops the document again when it
    /// cannot. A binding left behind is handed straight back by the next
    /// `bindLargeDocument`, so a retry would point every model at the overlay
    /// of a document whose update observer and persistence are already gone:
    /// writes published where nothing sends them, updates arriving elsewhere.
    func testAFailedOpenReleasesTheBindingSoARetryRebinds() async throws {
        let client = await makeClient()
        defer { Task { await client.destroy() } }

        let documentId = "failedopen-\(UUID().uuidString.prefix(8))"
        try await createLocal(client, documentId, format: 2)

        // A `.network` open with sync disabled cannot be satisfied, and the
        // open throws after the bind.
        do {
            _ = try await client.openDocument(
                documentId,
                options: OpenDocumentOptions(
                    waitForLoad: .network, enableNetworkSync: false
                )
            )
            XCTFail("precondition: this open cannot be satisfied")
        } catch {
            // The typed refusal is `checkAvailabilityPreconditions`'; which one
            // it is does not matter here, only that the open did not complete.
        }

        XCTAssertNil(
            client.format2?.binding(documentId),
            "the binding goes with the document the open dropped"
        )

        // And the retry binds over the Y.Doc the retry opened.
        let document = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        let binding = try XCTUnwrap(client.format2?.binding(documentId))
        binding.overlay.apply(
            OverlayMutation(id: "r1", kind: .create, fields: ["title": .string("x")]),
            model: "Note"
        )
        let overlayKeys = document.transactSync { transaction -> [String] in
            guard let map = transaction.transactionGetMap(name: "Note") else { return [] }
            let collector = DynamicModel.KeyCollector()
            map.keys(tx: transaction, delegate: collector)
            return collector.keys
        }
        XCTAssertFalse(
            overlayKeys.isEmpty,
            "the binding has to publish into the document THIS open returned, not the "
            + "one the failed open left behind"
        )
    }
}
