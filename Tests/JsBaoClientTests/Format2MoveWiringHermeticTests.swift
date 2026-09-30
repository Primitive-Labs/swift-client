import XCTest
@testable import JsBaoClient
import YSwift

/// The two wirings the live rows drove out (#3437, behaviors 7 and 10).
///
/// Both were missing from a move and a join that looked complete in every
/// hermetic case built around the coordinator alone, because both are about
/// what the CLIENT does with the coordinator's answer:
///
/// 1. **A join with owed writes has to STATE them.** The room answers
///    `syncStep1` once per connection, and adoption runs inside the bind — so
///    the only frame that could have claimed an adopted sequence went out
///    before this instance owned it, and every later `update.ack` names a
///    CONTIGUOUS mark that stops at the gap it leaves. The write is then owed
///    for ever. #3431 found this on the JS client through a browser hand-run.
/// 2. **A move has to drop the queued update BYTES, not only the ledger's
///    claimed places.** Every queued update is a Yjs delta built on the
///    overlay the room has just archived; the room PARKS such a frame instead
///    of integrating it and then answers every later update from that
///    connection with a resync request rather than an acknowledgement,
///    permanently. Measured live: the flush sent one after the move and the
///    document was never acknowledged again.
///
/// Where a claim about the WIRE is made it is made against what the
/// in-process loopback RECEIVED, never against a recorder wrapped around one
/// send path: the client puts frames on the wire from several places, and a
/// recorder on one of them answers "nothing escaped" for every frame that
/// left by another door (#3436's lesson). The loopback answers no
/// `syncStep2`, so a client here never reaches the state its transport sends
/// a local update from — the end-to-end halves of both wirings are the live
/// rows in `Format2EpochMoveLiveTests`, against a real room.
final class Format2MoveWiringHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string),
        ]
    )

    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "/f2-wiring-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    private func makeClient(
        path: String, wsUrl: String, outboundDebounce: TimeInterval = 0
    ) async -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: wsUrl,
            appId: "format2-wiring-test-app",
            token: makeTestJwt(userId: "format2-wiring-user"),
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .sqlite(directory: path),
            sync: SyncConfig(outboundDebounce: outboundDebounce),
            autoNetwork: false
        ))
        _ = await client.waitForStorageReady()
        client.registerModels([Self.schema])
        return client
    }

    private func wsBase(_ url: URL) -> String {
        let text = url.absoluteString
        return text.hasSuffix("/") ? String(text.dropLast()) : text
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

    /// The `update` frames the loopback received, decoded.
    private func updateFrames(_ server: LoopbackWebSocketServer) -> [[String: Any]] {
        server.receivedFrames.compactMap { frame in
            guard let data = frame.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let type = json["type"] as? String,
                  type == "update" || type == "syncStep2"
            else { return nil }
            return json
        }
    }

    private func openLargeDocument(
        _ client: JsBaoClient, _ documentId: String, epoch: Int
    ) async throws -> Format2DocumentBinding {
        client.documentManager.createRemoteDocument = { (_: [String: Any]) in
            ["documentId": documentId]
        }
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId, title: "wiring", localOnly: false, documentFormat: 2
        )
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: true, deferNetworkSync: false)
        )
        await client.handleWebSocketMessage("""
        {"type":"epoch.info","documentId":"\(documentId)","documentFormat":2,\
        "epoch":\(epoch),"sealedEpochs":[],"offlineWindowDays":7}
        """)
        try await waitFor("the handshake to release the hold") {
            client.format2?.hold.isHeld(documentId) == false
        }
        return try XCTUnwrap(client.format2?.binding(documentId))
    }

    // MARK: - Behavior 7's wiring — a join states what it owes

    func testAJoinWithAnAdoptedWriteHasAClaimToStateItWith() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let path = newDatabasePath()
        let documentId = "wiring-adopt"

        // A previous instance's unacknowledged write, left in the log under
        // ITS client id — which is what a relaunch finds.
        let first = await makeClient(path: path, wsUrl: wsBase(url))
        let firstBinding = try await openLargeDocument(first, documentId, epoch: 3)
        _ = try firstBinding.writePath.write(
            model: "Note",
            mutation: OverlayMutation(
                id: "orphan", kind: .create, fields: ["title": .string("owed")]
            ),
            fields: ["title"]
        )
        let overlayBytes = firstBinding.overlay.encodeStateAsUpdate()
        await first.destroy()

        // The relaunch, over the same database and the same socket.
        let second = await makeClient(path: path, wsUrl: wsBase(url))
        defer { Task { await second.destroy() } }
        try await second.connect()
        _ = try await second.documentManager.createLocalDocument(
            documentId: documentId, title: "wiring", localOnly: false, documentFormat: 2
        )
        _ = try await second.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: true, deferNetworkSync: false)
        )
        // The overlay local persistence would have restored.
        if let binding = second.format2?.binding(documentId) {
            try binding.overlay.applyUpdate(overlayBytes)
        }

        await second.handleWebSocketMessage("""
        {"type":"epoch.info","documentId":"\(documentId)","documentFormat":2,\
        "epoch":3,"sealedEpochs":[],"offlineWindowDays":7}
        """)
        let binding = try XCTUnwrap(second.format2?.binding(documentId))

        // Adopted: the previous instance's write is this one's to deliver.
        XCTAssertEqual(
            try binding.store.pendingOps().map(\.recordId), ["orphan"],
            "the bind did not adopt the previous instance's write"
        )

        // And the frame the join states it with claims exactly the span above
        // the durable acked mark. Built here rather than read off the socket:
        // the loopback answers no `syncStep2`, so this client never reaches
        // the state its transport will send a local update from — that half is
        // the live row's (`Format2EpochMoveLiveTests`), which asserts the room
        // acknowledges the adopted write and `pendingOps()` reaches zero.
        let resend = try XCTUnwrap(
            try second.format2?.wholeStateResend(documentId: documentId),
            "the join has nothing to state, so the adopted write would never be claimed"
        )
        let stamps = try XCTUnwrap(
            resend.claim.stamps,
            "the frame claims no sequence, so the room would never hear of the "
            + "adopted write and every later ack would stop below it"
        )
        XCTAssertEqual(
            stamps.seqFrom, 1,
            "claimed from the durable acked mark + 1"
        )
        XCTAssertEqual(stamps.seq, 1)
        XCTAssertEqual(stamps.ackedSeq, 0)
        XCTAssertFalse(
            resend.update.isEmpty,
            "a whole-state frame has to carry the overlay it claims"
        )
    }

    func testAJoinWithNothingOwedStatesNothing() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let client = await makeClient(path: newDatabasePath(), wsUrl: wsBase(url))
        defer { Task { await client.destroy() } }
        try await client.connect()

        _ = try await openLargeDocument(client, "wiring-quiet", epoch: 2)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(
            updateFrames(server).filter { ($0["documentId"] as? String) == "wiring-quiet" }
                .isEmpty,
            "an ordinary open owes nothing and must put nothing on the wire"
        )
    }

    // MARK: - Behavior 10's wiring — the move drops the queued bytes

    func testAMoveAsksForTheQueuedUpdatesToBeDiscarded() async throws {
        let directory = NSTemporaryDirectory() + "/f2-wiring-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")

        let coordinator = Format2Coordinator(
            host: provider, clientId: "me", logger: Logger(level: .none)
        )
        let discarded = LockedBox<[String]>([])
        coordinator.replaceDocument = { _, _ in }
        coordinator.discardQueuedUpdates = { documentId in
            discarded.withValue { $0.append(documentId) }
        }
        let documentId = "wiring-move"
        let binding = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: YDocument()
        )
        _ = try coordinator.handleEpochInfo(
            ["documentId": documentId, "epoch": 4, "sealedEpochs": []],
            now: Int(Date().timeIntervalSince1970 * 1000)
        )
        _ = try binding.writePath.write(
            model: "Note",
            mutation: OverlayMutation(
                id: "queued", kind: .create, fields: ["title": .string("owed")]
            ),
            fields: ["title"]
        )

        _ = try await coordinator.runEpochMove(
            documentId: documentId, next: 5,
            now: Int(Date().timeIntervalSince1970 * 1000)
        )

        // The move asks for the document's QUEUED update bytes to be dropped.
        // Every one of them is a Yjs delta built on the overlay the room has
        // just archived; the room parks such a frame instead of integrating
        // it, and from then on answers every later update from that connection
        // with a resync request rather than an acknowledgement — permanently.
        // Measured live: without this the flush sent one after the move and
        // the document was never acknowledged again.
        XCTAssertEqual(
            discarded.value, [documentId],
            "the move did not ask for the queued updates to be discarded"
        )

        // And dropping them does not drop the WRITE: the carry put its content
        // on the fresh overlay, and it is still owed and still claimable.
        XCTAssertEqual(try binding.store.pendingOps().map(\.recordId), ["queued"])
        XCTAssertEqual(
            binding.overlay.value(model: "Note", key: "queued/title"),
            .string("owed")
        )
    }

    /// And the third thing a move has to drop, which neither the ledger's
    /// places nor the queued bytes can reach: a payload already taken off that
    /// queue and waiting on an R2 upload to finish before its frame goes out
    /// (#3559, finding 3559-SO-002).
    ///
    /// The move cannot cancel that upload — the send path detaches it from
    /// cancellation on purpose, so the next local edit cannot strand a batch
    /// mid-flight — so it invalidates it instead. The generation is what the
    /// dispatch at the far end checks, and a move is the only thing that moves
    /// it: an ordinary local write must leave an upload in flight alone.
    func testAMoveInvalidatesAPayloadAlreadyWaitingOnItsUpload() async throws {
        let directory = NSTemporaryDirectory() + "/f2-wiring-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")

        let coordinator = Format2Coordinator(
            host: provider, clientId: "me", logger: Logger(level: .none)
        )
        coordinator.replaceDocument = { _, _ in }
        coordinator.discardQueuedUpdates = { _ in }
        let documentId = "wiring-generation"
        let binding = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: YDocument()
        )
        _ = try coordinator.handleEpochInfo(
            ["documentId": documentId, "epoch": 4, "sealedEpochs": []],
            now: Int(Date().timeIntervalSince1970 * 1000)
        )

        let atRest = coordinator.outboundGeneration(documentId)
        _ = try binding.writePath.write(
            model: "Note",
            mutation: OverlayMutation(
                id: "queued", kind: .create, fields: ["title": .string("owed")]
            ),
            fields: ["title"]
        )
        XCTAssertEqual(
            coordinator.outboundGeneration(documentId), atRest,
            "a local edit is not a reason to abandon a frame already going out"
        )

        _ = try await coordinator.runEpochMove(
            documentId: documentId, next: 5,
            now: Int(Date().timeIntervalSince1970 * 1000)
        )

        XCTAssertNotEqual(
            coordinator.outboundGeneration(documentId), atRest,
            "a payload built against the archived overlay is stale from the move on"
        )
    }
}
