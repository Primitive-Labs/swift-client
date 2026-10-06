import XCTest
@testable import JsBaoClient
import YSwift

/// A large document reports itself synced only once the state its sync
/// delivered is in the merged view (#4190).
///
/// A large document's rows are folded from the overlay on the binding's fold
/// queue, after the update that carried them has been applied. The
/// `syncComplete` that ends the cycle is handled on the receive loop as soon
/// as the `syncStep2` before it has been applied, so without a barrier the
/// document read as synced — and an open parked on `.sync` resolved — while
/// the fold was still owed. The JS client awaits its query projection on the
/// same path.
///
/// The fold is held back by holding the document's operation lock, which the
/// fold queue takes, so the window is deterministic. Server-free: frames are
/// fed straight into `handleWebSocketMessage`.
final class Format2SyncCompleteFoldHermeticTests: XCTestCase {

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
        let directory = NSTemporaryDirectory() + "/f2-sync-fold-\(UUID().uuidString)"
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
            appId: "format2-sync-fold-test-app",
            token: makeTestJwt(userId: "format2-sync-fold-user"),
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .sqlite(directory: newDatabasePath()),
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
        _ = await client.waitForStorageReady()
        client.registerModels([Self.schema])
        return client
    }

    private func openLargeDocument(
        _ client: JsBaoClient, _ documentId: String
    ) async throws -> Format2DocumentBinding {
        client.documentManager.createRemoteDocument = { (_: [String: Any]) in
            ["documentId": documentId]
        }
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId, title: "sync fold", localOnly: false, documentFormat: 2
        )
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        await client.handleWebSocketMessage("""
        {"type":"epoch.info","documentId":"\(documentId)","documentFormat":2,\
        "epoch":1,"sealedEpochs":[],"offlineWindowDays":7}
        """)
        return try XCTUnwrap(client.format2?.binding(documentId))
    }

    /// The room's diff for a client that has never held the document: one
    /// record of `Note`, as the room's overlay holds it.
    private func roomDiff(recordId: String, title: String) -> String {
        let overlay = OverlayDocument()
        overlay.applyRawEntries(
            [(OverlayKeys.fieldKey(recordId: recordId, field: "title"), .string(title))],
            model: "Note"
        )
        return Data(overlay.encodeStateAsUpdate()).base64EncodedString()
    }

    /// Wait for the holder thread to take the operation. Synchronous: the
    /// semaphore is signalled from a plain thread, not a task.
    private static func block(on semaphore: DispatchSemaphore) { semaphore.wait() }

    func testSyncCompleteWaitsForTheFoldOfTheStateItsCycleDelivered() async throws {
        let client = await makeClient()
        defer { Task { await client.destroy() } }
        let documentId = "f2-sync-fold-\(UUID().uuidString.prefix(8))"
        let binding = try await openLargeDocument(client, documentId)
        XCTAssertFalse(
            client.documentManager.isSynced(documentId),
            "precondition: no cycle has completed"
        )

        // Hold the document's operation, which the fold queue takes: the
        // update below is applied and its keys captured, and the fold that
        // turns them into rows waits here.
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let holder = Thread {
            _ = try? binding.writePath.withOperation {
                held.signal()
                release.wait()
            }
        }
        holder.start()
        Self.block(on: held)

        await client.handleWebSocketMessage("""
        {"type":"syncStep2","documentId":"\(documentId)",\
        "update":"\(roomDiff(recordId: "r1", title: "held by the room"))"}
        """)
        let completion = Task {
            await client.handleWebSocketMessage("""
            {"type":"syncComplete","documentId":"\(documentId)"}
            """)
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        let syncedWhileFoldOwed = client.documentManager.isSynced(documentId)

        release.signal()
        await completion.value

        XCTAssertFalse(
            syncedWhileFoldOwed,
            "the document must not read synced while the fold of the state its "
                + "sync delivered is still owed"
        )
        XCTAssertTrue(client.documentManager.isSynced(documentId))
        XCTAssertEqual(
            try binding.store.read(model: "Note", recordId: "r1")?["title"]?.stringValue,
            "held by the room",
            "once synced, the row is in the merged view without another settle"
        )
    }

    /// A close during the fold wait cancels the receive loop handling the
    /// `syncComplete`; when the fold then lands, that completion belongs to
    /// the dead connection and reports nothing.
    func testSyncCompleteCancelledDuringTheFoldReportsNothing() async throws {
        let client = await makeClient()
        defer { Task { await client.destroy() } }
        let documentId = "f2-sync-fold-\(UUID().uuidString.prefix(8))"
        let binding = try await openLargeDocument(client, documentId)

        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let holder = Thread {
            _ = try? binding.writePath.withOperation {
                held.signal()
                release.wait()
            }
        }
        holder.start()
        Self.block(on: held)

        await client.handleWebSocketMessage("""
        {"type":"syncStep2","documentId":"\(documentId)",\
        "update":"\(roomDiff(recordId: "r1", title: "held by the room"))"}
        """)
        let syncEvents = LockedBox<[Bool]>([])
        let subscription = client.eventEmitter.subscribe(SyncEvent.self) { event in
            guard event.documentId == documentId else { return }
            syncEvents.withValue { $0.append(event.synced) }
        }
        defer { subscription.cancel() }
        let completion = Task {
            await client.handleWebSocketMessage("""
            {"type":"syncComplete","documentId":"\(documentId)"}
            """)
        }
        try await Task.sleep(nanoseconds: 400_000_000)

        // What the transport's close does to the receive loop and the client.
        completion.cancel()
        client.webSocketManagerOnClose(code: 1006, reason: "closed during the fold")

        release.signal()
        await completion.value

        XCTAssertFalse(
            client.documentManager.isSynced(documentId),
            "a completion from the closed connection must not mark the document synced"
        )
        XCTAssertFalse(
            syncEvents.value.contains(true),
            "a completion from the closed connection must not emit a successful sync event"
        )
    }
}
