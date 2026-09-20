import XCTest
@testable import JsBaoClient
import YSwift

/// No local state escapes a large document's hold, and what does escape says
/// exactly what it carries (#3436, behaviors 11, 15 and 33, edge E16).
///
/// The hold itself — set, kept, released in order, released once — is proven
/// over the ledger elsewhere in this suite. What is asserted here is that the
/// client's three outbound paths actually CONSULT it: the debounced update
/// queue, the ws-open flush, and the `syncStep2` answer built from the local
/// document. Each of those carries state the server would take as the truth of
/// an epoch this client has not yet been told it is on.
///
/// Server-free, but not socket-free: the client is CONNECTED to an in-process
/// loopback WebSocket server, and every assertion about what escaped is made
/// against the bytes that server actually received. A recorder in front of one
/// of the client's several send paths would answer "nothing escaped" for every
/// frame that leaves by another; the socket sees them all.
///
/// Inbound frames are fed straight into `handleWebSocketMessage`.
final class Format2ClientHoldHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "/f2-hold-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    private func newDocId() -> String { "f2-hold-\(UUID().uuidString.prefix(8))" }

    private func makeClient(wsUrl: String) async -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: wsUrl,
            appId: "format2-client-hold-test-app",
            token: "test-token",
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

    /// Open `documentId`, recording the format the caller wants first so the
    /// open resolves it the way a second session would.
    @discardableResult
    private func openDocument(
        _ client: JsBaoClient, _ documentId: String, format: Int?
    ) async throws -> YDocument {
        client.documentManager.createRemoteDocument = { _ in ["documentId": documentId] }
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId,
            title: "hold",
            localOnly: false,
            documentFormat: format
        )
        // Not a pending create for the purposes of this suite: an unfinished
        // create holds every outbound update on its own, which would make the
        // format-2 hold untestable and a format-1 control vacuous.
        client.documentManager.handlePendingCreateCommitted(documentId)
        return try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
    }

    /// One plain Y.Doc write, the way an ordinary document's caller makes one.
    ///
    /// The map is taken OUTSIDE the transaction deliberately: `getOrCreateMap`
    /// opens a write transaction of its own, and yrs blocks a second writer on
    /// the same document — calling it from inside `transactSync` deadlocks the
    /// thread against itself.
    private func writeOrdinaryKey(_ doc: YDocument, value: String) {
        let map: YMap<JSONValue> = doc.getOrCreateMap(named: "Note")
        doc.transactSync { transaction in
            map.updateValue(.string(value), forKey: "n1/title", transaction: transaction)
        }
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

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

    /// Every frame of `type` the server received for `documentId`, decoded.
    private func frames(
        _ server: LoopbackWebSocketServer, type: String, for documentId: String
    ) -> [[String: Any]] {
        server.receivedFrames.compactMap { frame in
            guard let data = frame.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == type,
                  json["documentId"] as? String == documentId
            else { return nil }
            return json
        }
    }

    private func epochInfo(_ documentId: String, epoch: Int = 0) -> String {
        """
        {"type":"epoch.info","documentId":"\(documentId)","documentFormat":2,\
        "epoch":\(epoch),"sealedEpochs":[],"offlineWindowDays":14}
        """
    }

    /// Commit one local write through the document's own write path, which is
    /// what puts a row and a pending op in the store and the overlay keys in
    /// the Y.Doc — and so is what the client's update observer forwards.
    @discardableResult
    private func commitWrite(
        _ binding: Format2DocumentBinding, id: String, title: String
    ) throws -> Int {
        try binding.writePath.write(
            model: "Note",
            mutation: OverlayMutation(
                id: id, kind: .create, fields: ["title": .string(title)]
            ),
            fields: ["title"]
        )
    }


    // MARK: - A connected client with one document open

    /// A client connected to a fresh loopback server, and one document opened
    /// with the format a previous session would have recorded for it.
    private func connectedClient(
        format: Int?
    ) async throws -> (JsBaoClient, LoopbackWebSocketServer, String, YDocument) {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let base = url.absoluteString
        let client = await makeClient(
            wsUrl: base.hasSuffix("/") ? String(base.dropLast()) : base
        )
        try await client.connect()
        let documentId = newDocId()
        let doc = try await openDocument(client, documentId, format: format)
        return (client, server, documentId, doc)
    }

    // MARK: - Behavior 33 — the debounced update queue

    func testAWriteQueuedWhileHeldReachesTheSocketOnlyAfterTheHandshake() async throws {
        let (client, server, documentId, _) = try await connectedClient(format: 2)
        defer { server.stop(); Task { await client.destroy() } }

        let binding = try XCTUnwrap(client.format2?.binding(documentId))
        XCTAssertTrue(
            client.format2?.hold.isHeld(documentId) ?? false,
            "precondition: a large document binds held"
        )

        _ = try commitWrite(binding, id: "n1", title: "held")
        await settle()

        XCTAssertTrue(
            frames(server, type: "update", for: documentId).isEmpty,
            "a write made before the room said which epoch this client is on must not "
            + "escape; frames: \(server.receivedFrames)"
        )
        XCTAssertTrue(
            client.documentManager.hasUnsyncedLocalChanges(documentId),
            "held is kept, not dropped — the document still owes the write"
        )

        await client.handleWebSocketMessage(epochInfo(documentId))
        try await waitFor("the held update to go out after the handshake") {
            !self.frames(server, type: "update", for: documentId).isEmpty
        }
    }

    /// The control: an ordinary document on the same client is never held.
    func testAnOrdinaryDocumentIsNotHeld() async throws {
        let (client, server, documentId, doc) = try await connectedClient(format: nil)
        defer { server.stop(); Task { await client.destroy() } }

        XCTAssertNil(client.format2?.binding(documentId))
        writeOrdinaryKey(doc, value: "ordinary")
        try await waitFor("the ordinary document's update to go out") {
            !self.frames(server, type: "update", for: documentId).isEmpty
        }
    }

    // MARK: - Behavior 33 — the ws-open flush

    /// The reconnect flush is a second door onto the same queue: it drains
    /// everything queued while the transport was down, before any handshake
    /// frame exists. A large document has to be held there too.
    func testTheWsOpenFlushDoesNotDrainAHeldDocument() async throws {
        let (client, server, documentId, _) = try await connectedClient(format: 2)
        defer { server.stop(); Task { await client.destroy() } }

        let binding = try XCTUnwrap(client.format2?.binding(documentId))
        _ = try commitWrite(binding, id: "n1", title: "queued while away")
        await settle()
        XCTAssertTrue(
            frames(server, type: "update", for: documentId).isEmpty, "precondition: held"
        )

        await client.flushAllLocalUpdates("ws-open")
        await settle()

        XCTAssertTrue(
            frames(server, type: "update", for: documentId).isEmpty,
            "the ws-open flush runs before any handshake; nothing may escape through it; "
            + "frames: \(server.receivedFrames)"
        )

        await client.handleWebSocketMessage(epochInfo(documentId))
        try await waitFor("the flush to carry the write after the handshake") {
            !self.frames(server, type: "update", for: documentId).isEmpty
        }
    }

    /// The hold has to come BACK on a new connection, and this is the case
    /// that says so: a document that already joined once is not held any more,
    /// so without a re-hold the very next socket open drains its offline edits
    /// in `flushAllLocalUpdates("ws-open")` — before the room has said a word
    /// about which epoch this connection is on. Those edits were made against
    /// an epoch the room may have rotated, sealed or replaced by a bulk load
    /// while this client was away, which is the whole reason the hold exists.
    func testAJoinedDocumentIsHeldAgainOnTheNextConnection() async throws {
        let (client, server, documentId, _) = try await connectedClient(format: 2)
        defer { server.stop(); Task { await client.destroy() } }

        let binding = try XCTUnwrap(client.format2?.binding(documentId))

        // This connection's handshake: the document joins and the hold goes.
        await client.handleWebSocketMessage(epochInfo(documentId))
        try await waitFor("the document to join") {
            !(client.format2?.hold.isHeld(documentId) ?? true)
        }
        _ = try commitWrite(binding, id: "n1", title: "while connected")
        try await waitFor("a write on a joined document to go out at once") {
            !self.frames(server, type: "update", for: documentId).isEmpty
        }
        // The server's frame log is append-only, so the baseline is a count.
        let beforeReconnect = frames(server, type: "update", for: documentId).count

        // The transport goes and comes back, with an edit made in between.
        client.webSocketManagerOnConnected()
        XCTAssertTrue(
            client.format2?.hold.isHeld(documentId) ?? false,
            "a new socket is a new handshake: held until THIS connection's epoch.info"
        )

        _ = try commitWrite(binding, id: "n2", title: "made while away")
        await settle()
        await client.flushAllLocalUpdates("ws-open")
        await settle()

        XCTAssertEqual(
            frames(server, type: "update", for: documentId).count, beforeReconnect,
            "an edit made against the old epoch escaped on the new connection before "
            + "epoch.info; frames: \(server.receivedFrames)"
        )

        await client.handleWebSocketMessage(epochInfo(documentId))
        try await waitFor("the kept edit to go out after the new handshake") {
            self.frames(server, type: "update", for: documentId).count > beforeReconnect
        }
    }

    /// The control: an ordinary document on the same client is not held by a
    /// reconnect either.
    func testAnOrdinaryDocumentIsNotHeldByAReconnect() async throws {
        let (client, server, documentId, doc) = try await connectedClient(format: nil)
        defer { server.stop(); Task { await client.destroy() } }

        client.webSocketManagerOnConnected()
        writeOrdinaryKey(doc, value: "after the reconnect")
        try await waitFor("the ordinary document's update to go out") {
            !self.frames(server, type: "update", for: documentId).isEmpty
        }
    }

    // MARK: - Behavior 33 — the syncStep2 answer

    func testTheSyncStep2AnswerIsHeldAndGoesOutOnTheJoin() async throws {
        let (client, server, documentId, _) = try await connectedClient(format: 2)
        defer { server.stop(); Task { await client.destroy() } }

        let binding = try XCTUnwrap(client.format2?.binding(documentId))
        _ = try commitWrite(binding, id: "n1", title: "local state")
        await settle()

        // The room asks what this client has. The answer is built from the
        // local document, so it carries exactly the state the hold exists to
        // keep back.
        let emptyStateVector = Data([0]).base64EncodedString()
        await client.handleWebSocketMessage("""
        {"type":"syncStep1","documentId":"\(documentId)","stateVector":"\(emptyStateVector)"}
        """)
        await settle()

        XCTAssertTrue(
            frames(server, type: "syncStep2", for: documentId).isEmpty,
            "the syncStep2 answer is local state under another name; frames: \(server.receivedFrames)"
        )
        XCTAssertEqual(
            client.format2?.hold.queuedCount(documentId), 1,
            "and it is KEPT — the room asked, and it is owed an answer"
        )

        await client.handleWebSocketMessage(epochInfo(documentId))
        try await waitFor("the kept syncStep2 answer to go out") {
            !self.frames(server, type: "syncStep2", for: documentId).isEmpty
        }
    }

    /// The control: an ordinary document answers the room at once.
    func testAnOrdinaryDocumentAnswersSyncStep1AtOnce() async throws {
        let (client, server, documentId, doc) = try await connectedClient(format: nil)
        defer { server.stop(); Task { await client.destroy() } }

        writeOrdinaryKey(doc, value: "ordinary")
        let emptyStateVector = Data([0]).base64EncodedString()
        await client.handleWebSocketMessage("""
        {"type":"syncStep1","documentId":"\(documentId)","stateVector":"\(emptyStateVector)"}
        """)
        try await waitFor("the ordinary document's syncStep2 answer") {
            !self.frames(server, type: "syncStep2", for: documentId).isEmpty
        }
    }

    // MARK: - Behavior 15 — the join

    func testTheJoinWritesTheMarksAndPersistsTheFormat() async throws {
        let (client, server, documentId, _) = try await connectedClient(format: 2)
        defer { server.stop(); Task { await client.destroy() } }

        let binding = try XCTUnwrap(client.format2?.binding(documentId))
        // A client already on the room's epoch — the ordinary steady state.
        // (A client BEHIND the room is stopped rather than joined; that seam
        // is #3437's and is asserted over the coordinator.)
        try binding.store.setEpoch(7)

        await client.handleWebSocketMessage("""
        {"type":"epoch.info","documentId":"\(documentId)","documentFormat":2,\
        "epoch":7,"sealedEpochs":[],"offlineWindowDays":10,\
        "serverTime":\(Int(Date().timeIntervalSince1970 * 1000))}
        """)

        XCTAssertEqual(try binding.store.epoch(), 7, "the epoch mark is the room's")
        // The window the frame reported, inside the 1–14 range the client
        // clamps to (#3437, behavior 1).
        XCTAssertEqual(try binding.store.offlineWindowDays(), 10)
        XCTAssertNotNil(try binding.store.lastSyncAt())
        XCTAssertTrue(try binding.store.clockOffsetKnown())
        XCTAssertFalse(client.format2?.hold.isHeld(documentId) ?? true)
        XCTAssertEqual(client.documentManager.getLocalMetadata(documentId)?.documentFormat, 2)
    }

    // MARK: - Behavior 11 — what an outbound frame claims

    func testAnOutboundUpdateForALargeDocumentCarriesItsSequences() async throws {
        let (client, server, documentId, _) = try await connectedClient(format: 2)
        defer { server.stop(); Task { await client.destroy() } }

        let binding = try XCTUnwrap(client.format2?.binding(documentId))
        await client.handleWebSocketMessage(epochInfo(documentId))
        try await waitFor("the hold to release") {
            !(client.format2?.hold.isHeld(documentId) ?? true)
        }

        XCTAssertEqual(try commitWrite(binding, id: "n1", title: "first"), 1)
        try await waitFor("the first update frame") {
            !self.frames(server, type: "update", for: documentId).isEmpty
        }

        let frame = try XCTUnwrap(frames(server, type: "update", for: documentId).first)
        XCTAssertEqual(frame["seq"] as? Int, 1, "frame: \(frame)")
        XCTAssertEqual(frame["seqFrom"] as? Int, 1, "frame: \(frame)")
        XCTAssertEqual(
            frame["ackedSeq"] as? Int, 0,
            "nothing has been acknowledged yet; frame: \(frame)"
        )
    }

    func testAnOrdinaryDocumentsUpdateCarriesNoneOfThem() async throws {
        let (client, server, documentId, doc) = try await connectedClient(format: nil)
        defer { server.stop(); Task { await client.destroy() } }

        writeOrdinaryKey(doc, value: "ordinary")
        try await waitFor("the ordinary document's update") {
            !self.frames(server, type: "update", for: documentId).isEmpty
        }

        let frame = try XCTUnwrap(frames(server, type: "update", for: documentId).first)
        XCTAssertNil(frame["seq"], "frame: \(frame)")
        XCTAssertNil(frame["seqFrom"], "frame: \(frame)")
        XCTAssertNil(frame["ackedSeq"], "frame: \(frame)")
    }
}
