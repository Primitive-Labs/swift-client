import XCTest
@testable import JsBaoClient

/// Opening a large document through the client's own front door (#3436,
/// behaviors 3, 14, 16 and 17, edge E14).
///
/// The engine these behaviors drive — the record store, the fold, the
/// coordinator — is verified component by component elsewhere in this suite.
/// What is asserted here is the WIRING: that `createDocument` carries the
/// option, that `openDocument` resolves the document's format, raises the
/// socket's receive limit while it still can, refuses storage that cannot hold
/// a large document before a single frame goes out, and binds the document so
/// everything downstream knows what it is.
///
/// Server-free: the client is built against an in-process loopback WebSocket
/// server (or an unreachable URL where no socket is wanted), and frames are
/// fed straight into `handleWebSocketMessage`.
final class Format2ClientOpenHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    /// A fresh database file path. `.sqlite(directory:)` takes the FILE path
    /// its own callers pass; the enclosing directory is what gets cleaned up.
    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "/f2-open-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    private func newDocId() -> String { "f2-open-\(UUID().uuidString.prefix(8))" }

    private func makeClient(
        storage: StorageConfig,
        wsUrl: String = "ws://127.0.0.1:1",
        appId: String = "format2-client-open-test-app",
        offline: Bool = false
    ) -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: wsUrl,
            appId: appId,
            token: makeTestJwt(userId: "format2-open-user"),
            offline: offline,
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: storage,
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
    }

    private func sqliteClient(
        databasePath: String? = nil,
        wsUrl: String = "ws://127.0.0.1:1",
        appId: String = "format2-client-open-test-app",
        offline: Bool = false
    ) async -> JsBaoClient {
        let client = makeClient(
            storage: .sqlite(directory: databasePath ?? newDatabasePath()),
            wsUrl: wsUrl,
            appId: appId,
            offline: offline
        )
        _ = await client.waitForStorageReady()
        return client
    }

    /// Create a document locally with the format a previous session would
    /// have recorded for it.
    private func createLocal(
        _ client: JsBaoClient, _ documentId: String, format: Int?
    ) async throws {
        client.documentManager.createRemoteDocument = { _ in ["documentId": documentId] }
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId,
            title: "open",
            localOnly: false,
            documentFormat: format
        )
    }

    /// Wait (bounded) for `condition`, which the background create commit
    /// satisfies on its own thread.
    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(description)")
    }

    private func wsBase(_ url: URL) -> String {
        let s = url.absoluteString
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    // MARK: - Behavior 17 — the create option

    func testCreateWithDocumentFormatRidesTheLocalRowAndTheCommitBody() async throws {
        let client = await sqliteClient()
        defer { Task { await client.destroy() } }

        let bodies = LockedBox<[[String: Any]]>([])
        client.documentManager.createRemoteDocument = { body in
            bodies.withValue { $0.append(body) }
            return ["documentId": body["documentId"] as? String ?? ""]
        }

        let result = try await client.createDocument(
            options: CreateDocumentOptions(title: "big", documentFormat: 2)
        )
        let documentId = try XCTUnwrap(
            result.metadata?.objectValue?["documentId"]?.stringValue
        )

        XCTAssertEqual(
            client.documentManager.getLocalMetadata(documentId)?.documentFormat, 2,
            "the local row has to record the format, or the next open cannot resolve it "
            + "before the handshake"
        )

        try await waitFor("the background create commit") { !bodies.value.isEmpty }
        let body = try XCTUnwrap(bodies.value.first)
        XCTAssertEqual(
            body["documentFormat"] as? Int, 2,
            "the server decides the document's format from the create; body: \(body)"
        )
    }

    func testAnOrdinaryCreateCarriesNoDocumentFormatAnywhere() async throws {
        let client = await sqliteClient()
        defer { Task { await client.destroy() } }

        let bodies = LockedBox<[[String: Any]]>([])
        client.documentManager.createRemoteDocument = { body in
            bodies.withValue { $0.append(body) }
            return ["documentId": body["documentId"] as? String ?? ""]
        }

        let result = try await client.createDocument(
            options: CreateDocumentOptions(title: "ordinary")
        )
        let documentId = try XCTUnwrap(
            result.metadata?.objectValue?["documentId"]?.stringValue
        )
        XCTAssertNil(client.documentManager.getLocalMetadata(documentId)?.documentFormat)

        try await waitFor("the background create commit") { !bodies.value.isEmpty }
        let body = try XCTUnwrap(bodies.value.first)
        XCTAssertNil(
            body["documentFormat"],
            "an ordinary create's request body must be exactly what it was before the "
            + "option existed; body: \(body)"
        )
    }

    // MARK: - Behavior 3 / edge E14 — the socket's receive limit

    /// A first open has no local row, so the format can only come from
    /// `epoch.info` — the frame the limit protects, and the one
    /// `URLSessionWebSocketTask` fails at the RECEIVE rather than in the
    /// handler. The limit therefore goes up before the frame that would have
    /// answered the question can be asked for.
    func testAnOpenWithNoKnownFormatRaisesTheLimitBeforeItsSyncStep1() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = await sqliteClient(wsUrl: wsBase(url))
        defer { Task { await client.destroy() } }
        try await client.connect()

        let documentId = newDocId()
        try await createLocal(client, documentId, format: nil)
        XCTAssertNil(
            client.documentManager.getLocalMetadata(documentId)?.documentFormat,
            "precondition: nothing knows this document's format yet"
        )
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        // The order, on a real socket: the limit is already raised, and this
        // document has not yet put a syncStep1 on the wire. Two separate
        // facts — "it was raised" and "a frame went out" — would not say which
        // came first; the pair of assertions taken HERE does.
        let afterOpen = await client.wsManager.configuredMaximumMessageSize
        XCTAssertEqual(
            afterOpen, Format2Transport.maximumMessageSize,
            "a document whose format is not locally known raises the limit at open"
        )
        XCTAssertEqual(
            self.syncStep1Frames(server, documentId).count, 0,
            "precondition: nothing has gone out for this document yet"
        )

        await client.startNetworkSync(documentId: documentId)
        try await waitFor("the syncStep1 frame to reach the socket") {
            !self.syncStep1Frames(server, documentId).isEmpty
        }
    }

    /// Every `syncStep1` frame the loopback server received for `documentId`.
    private func syncStep1Frames(
        _ server: LoopbackWebSocketServer, _ documentId: String
    ) -> [String] {
        server.receivedFrames.filter {
            $0.contains("\"syncStep1\"") && $0.contains(documentId)
        }
    }

    /// The intent's decision: the format-1 limit does not change.
    ///
    /// A LATER session is where that is observable, and the spec says so —
    /// "a client whose documents all resolve locally as format 1 keeps
    /// Foundation's default on every later session". A first session has no
    /// rows to resolve, so its next open would learn the format from
    /// `epoch.info`, the frame the limit protects, and it raises.
    func testALaterSessionWhoseDocumentsAreAllFormat1KeepsFoundationsDefault() async throws {
        let databasePath = newDatabasePath()
        let documentId = newDocId()

        let first = await sqliteClient(databasePath: databasePath)
        try await createLocal(first, documentId, format: 1)
        _ = try await first.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        await first.destroy()

        let second = await sqliteClient(databasePath: databasePath)
        defer { Task { await second.destroy() } }
        XCTAssertEqual(
            second.documentManager.getLocalMetadata(documentId)?.documentFormat, 1,
            "precondition: the row survived, so this session can resolve the format"
        )
        _ = try await second.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        let limit = await second.wsManager.configuredMaximumMessageSize
        XCTAssertNil(
            limit,
            "a session whose documents all resolve locally as format 1 keeps the default, "
            + "got \(String(describing: limit))"
        )
    }

    /// And the other half of the same rule: a session that knows of no
    /// document, or of one that is not format 1, settles the raised limit
    /// before its socket is built — so no open has to rebuild one.
    func testASessionWithNothingKnownToBeFormat1RaisesBeforeItsSocket() async throws {
        let client = await sqliteClient()
        defer { Task { await client.destroy() } }
        let limit = await client.wsManager.configuredMaximumMessageSize
        XCTAssertEqual(limit, Format2Transport.maximumMessageSize)
    }

    func testAKnownLargeDocumentRaisesTheLimitOnOpen() async throws {
        let client = await sqliteClient()
        defer { Task { await client.destroy() } }

        let documentId = newDocId()
        try await createLocal(client, documentId, format: 2)

        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        let limit = await client.wsManager.configuredMaximumMessageSize
        XCTAssertEqual(limit, Format2Transport.maximumMessageSize)
    }


    /// The claim the limit exists for, on a real socket: an `epoch.info`
    /// bigger than Foundation's default does not arrive on a socket that kept
    /// the default, and does arrive on one that raised it.
    ///
    /// `URLSessionWebSocketTask` fails an oversized message at the RECEIVE, so
    /// there is nothing in the handler to observe — the observable is what the
    /// frame would have CHANGED. Each frame carries a distinct
    /// `offlineWindowDays`, so "the frame arrived" and "the frame did not" are
    /// two values of one durable mark rather than a timeout.
    ///
    /// Two clients on one server, not one client twice: the refused receive
    /// takes the socket down with it, which is precisely the failure the raise
    /// prevents, and a test that then had to nurse that socket back would be
    /// measuring the reconnect policy instead of the limit.
    func testAnEpochInfoOverTheDefaultLimitArrivesOnlyOnASocketThatRaisedIt() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        // A session that knows its only document is ordinary keeps
        // Foundation's default, which is what the intent's format-1 rule asks
        // for. A later session, because that is where the row exists.
        let ordinaryPath = newDatabasePath()
        let ordinary = newDocId()
        let firstSession = await sqliteClient(databasePath: ordinaryPath, appId: "f2-unraised")
        try await createLocal(firstSession, ordinary, format: 1)
        await firstSession.destroy()

        let unraisedClient = await sqliteClient(
            databasePath: ordinaryPath, wsUrl: wsBase(url), appId: "f2-unraised"
        )
        defer { Task { await unraisedClient.destroy() } }
        try await unraisedClient.connect()
        _ = try await unraisedClient.openDocument(
            ordinary,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        let unraised = await unraisedClient.wsManager.configuredMaximumMessageSize
        XCTAssertNil(unraised, "precondition: nothing has raised this socket's limit")

        // A client whose document's format is not locally known raises it.
        let raisedClient = await sqliteClient(wsUrl: wsBase(url), appId: "f2-raised")
        defer { Task { await raisedClient.destroy() } }
        try await raisedClient.connect()
        let socketsAfterConnecting = server.acceptedCount
        let unknown = newDocId()
        try await createLocal(raisedClient, unknown, format: nil)
        _ = try await raisedClient.openDocument(
            unknown,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        let raised = await raisedClient.wsManager.configuredMaximumMessageSize
        XCTAssertEqual(raised, Format2Transport.maximumMessageSize)
        XCTAssertEqual(
            server.acceptedCount, socketsAfterConnecting,
            "the limit was settled before this session's socket was built, so the open "
            + "had nothing to rebuild"
        )

        // Positive control: small frames arrive on both sockets, so a frame
        // that does not arrive below says something about its SIZE.
        XCTAssertTrue(server.push(epochInfoFrame(ordinary, windowDays: 14)))
        try await waitFor("the small epoch.info on the unraised socket") {
            unraisedClient.format2?.isLargeDocument(ordinary) == true
        }
        XCTAssertTrue(server.push(epochInfoFrame(unknown, windowDays: 14)))
        try await waitFor("the small epoch.info on the raised socket") {
            raisedClient.format2?.isLargeDocument(unknown) == true
        }
        let unraisedBinding = try XCTUnwrap(unraisedClient.format2?.binding(ordinary))
        let raisedBinding = try XCTUnwrap(raisedClient.format2?.binding(unknown))
        XCTAssertEqual(try unraisedBinding.store.offlineWindowDays(), 14)
        XCTAssertEqual(try raisedBinding.store.offlineWindowDays(), 14)

        // Now the same frames, padded past the default. The window they carry
        // is the marker that says which frames were HANDLED, so it has to be a
        // second value inside the 1–14 range the client clamps to (#3437,
        // behavior 1) — a number outside it would arrive as 14 and be
        // indistinguishable from the small frames above.
        let overOrdinary = epochInfoFrame(
            ordinary, windowDays: 3, padToBytes: 2 * 1024 * 1024
        )
        XCTAssertGreaterThan(
            overOrdinary.utf8.count, 1024 * 1024,
            "precondition: the frame has to exceed Foundation's 1 MiB default"
        )
        server.push(overOrdinary)
        server.push(epochInfoFrame(unknown, windowDays: 3, padToBytes: 2 * 1024 * 1024))

        try await waitFor("the oversized frame to be handled on the raised socket") {
            (try? raisedBinding.store.offlineWindowDays()) == 3
        }
        XCTAssertEqual(
            try unraisedBinding.store.offlineWindowDays(), 14,
            "an oversized frame reached the handler on a socket at Foundation's default — "
            + "which is the receive the raise exists to make possible"
        )
    }

    /// An `epoch.info` frame, optionally padded to a given size with a field
    /// no reader looks at.
    private func epochInfoFrame(
        _ documentId: String, windowDays: Int, padToBytes: Int? = nil
    ) -> String {
        var frame = """
        {"type":"epoch.info","documentId":"\(documentId)","documentFormat":2,\
        "epoch":0,"sealedEpochs":[],"offlineWindowDays":\(windowDays)
        """
        if let padToBytes {
            let padding = max(0, padToBytes - frame.utf8.count - 16)
            frame += ",\"padding\":\"" + String(repeating: "x", count: padding) + "\""
        }
        return frame + "}"
    }

    // MARK: - Behavior 14 — the storage refusal

    func testMemoryStorageRefusesAKnownLargeDocumentBeforeAnyFrame() async throws {
        let client = makeClient(storage: .memory)
        defer { Task { await client.destroy() } }
        _ = await client.waitForStorageReady()

        let sent = LockedBox<[String]>([])
        client.documentManager.sendWebSocketMessage = { frame in
            sent.withValue { $0.append(frame) }
        }

        let documentId = newDocId()
        try await createLocal(client, documentId, format: 2)

        do {
            _ = try await client.openDocument(
                documentId,
                options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
            )
            XCTFail("an in-memory provider cannot hold a large document; the open must refuse")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .format2StorageUnavailable)
            XCTAssertEqual(error.details?["reason"]?.stringValue, "not-persistent")
        }

        XCTAssertTrue(
            sent.value.isEmpty,
            "the refusal is decided before any frame goes out; sent: \(sent.value)"
        )
        XCTAssertFalse(
            client.documentManager.isOpen(documentId),
            "a refused open must not leave the document half-open"
        )
    }

    func testMemoryStorageStillOpensAnOrdinaryDocument() async throws {
        let client = makeClient(storage: .memory)
        defer { Task { await client.destroy() } }
        _ = await client.waitForStorageReady()

        let documentId = newDocId()
        try await createLocal(client, documentId, format: nil)

        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        XCTAssertTrue(client.documentManager.isOpen(documentId))
        XCTAssertNil(
            client.format2,
            "an ordinary document must not build a format-2 coordinator at all"
        )
    }

    // MARK: - Behavior 16 — format resolution

    func testAStoredFormat2BindsBeforeTheFirstSyncStep1() async throws {
        let client = await sqliteClient()
        defer { Task { await client.destroy() } }

        let documentId = newDocId()
        try await createLocal(client, documentId, format: 2)

        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        let coordinator = try XCTUnwrap(client.format2)
        XCTAssertTrue(
            coordinator.isLargeDocument(documentId),
            "a document the local row already calls large binds at open, not at handshake"
        )
        XCTAssertTrue(
            coordinator.hold.isHeld(documentId),
            "and it binds HELD: nothing local may go out before the room says which epoch "
            + "this client is on"
        )
    }

    func testADocumentWithNoStoredFormatBindsOnItsFirstEpochInfo() async throws {
        let client = await sqliteClient()
        defer { Task { await client.destroy() } }

        let documentId = newDocId()
        try await createLocal(client, documentId, format: nil)
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        XCTAssertNil(
            client.format2?.binding(documentId),
            "precondition: nothing has said this is a large document yet"
        )

        await client.handleWebSocketMessage("""
        {"type":"epoch.info","documentId":"\(documentId)","documentFormat":2,\
        "epoch":0,"sealedEpochs":[],"offlineWindowDays":14}
        """)

        let coordinator = try XCTUnwrap(client.format2)
        XCTAssertTrue(
            coordinator.isLargeDocument(documentId),
            "the room's answer is where a first open learns the format"
        )
        XCTAssertEqual(
            client.documentManager.getLocalMetadata(documentId)?.documentFormat, 2,
            "and it is persisted, so the NEXT open binds before the handshake"
        )
    }

    func testAFormat1HandshakePersistsTheFormatOnADocumentWithNoStoredFormat() async throws {
        let client = await sqliteClient()
        defer { Task { await client.destroy() } }

        let documentId = newDocId()
        try await createLocal(client, documentId, format: nil)
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        // A format-1 handshake is one that completes with no `epoch.info` in it.
        await client.handleWebSocketMessage("""
        {"type":"syncComplete","documentId":"\(documentId)"}
        """)

        XCTAssertEqual(
            client.documentManager.getLocalMetadata(documentId)?.documentFormat, 1,
            "a completed handshake that carried no epoch.info is the answer `format 1`, "
            + "and recording it is what lets a later session keep Foundation's default"
        )
        XCTAssertNil(
            client.format2?.binding(documentId),
            "nothing about a format-1 document may bind"
        )
    }

    /// The other half of the same rule: a handshake that DID carry
    /// `epoch.info` must not then be overwritten by the `syncComplete` that
    /// ends it.
    func testTheSyncCompleteAfterAnEpochInfoDoesNotDemoteTheDocument() async throws {
        let client = await sqliteClient()
        defer { Task { await client.destroy() } }

        let documentId = newDocId()
        try await createLocal(client, documentId, format: nil)
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        await client.handleWebSocketMessage("""
        {"type":"epoch.info","documentId":"\(documentId)","documentFormat":2,\
        "epoch":0,"sealedEpochs":[],"offlineWindowDays":14}
        """)
        await client.handleWebSocketMessage("""
        {"type":"syncComplete","documentId":"\(documentId)"}
        """)

        XCTAssertEqual(client.documentManager.getLocalMetadata(documentId)?.documentFormat, 2)
        XCTAssertTrue(client.format2?.isLargeDocument(documentId) ?? false)
    }
}
