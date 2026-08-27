import XCTest
@testable import JsBaoClient
import YSwift

/// Swift↔JS parity for issue #2665 (audit items C9 and C12).
///
/// JS is the reference; the same behaviors are pinned on the JS side in
/// `tests/client/js-bao-client-outbound-and-syncstep1-parity.test.ts`.
///
///   C9  — `updateHandler` drops local updates for read-only documents and
///         holds them for pending-create documents
///         (`src/client/JsBaoClient.ts:6228-6258`).
///   C12 — a server-initiated `syncStep1` is answered with a diff only when
///         the server's `docHash` differs AND the document is writable; the
///         hash-match and read-only cases mark the document synced locally and
///         send nothing (`src/client/JsBaoClient.ts:6883-7001`).
///
/// Server-free: the client is built with unreachable URLs and never connects.
/// Outbound update frames are intercepted by replacing
/// `DocumentManager.sendWebSocketMessage`; the `syncStep1` arm is driven
/// through the real message router (`handleWebSocketMessage`).
final class OutboundFilterAndSyncStep1ParityTests: XCTestCase {

    /// Collects outbound frames from whichever thread the flush runs on.
    private final class FrameSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _frames: [String] = []
        func append(_ frame: String) { lock.withLock { _frames.append(frame) } }
        var all: [String] { lock.withLock { _frames } }
    }

    /// Records every `markUnsyncedLocalChanges` call, so a "held" update can be
    /// distinguished from a dropped one. `hasUnsyncedLocalChanges` can't do
    /// that on its own: it already returns `true` for any pending create.
    private final class MarkSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _marks: [(String, Bool)] = []
        func append(_ documentId: String, _ value: Bool) {
            lock.withLock { _marks.append((documentId, value)) }
        }
        func markedUnsynced(_ documentId: String) -> Bool {
            lock.withLock { _marks.contains { $0.0 == documentId && $0.1 } }
        }
    }

    /// A client that never talks to a server, with zero outbound debounce so a
    /// queued update reaches the (intercepted) socket promptly.
    private func makeClient(appId: String) -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: appId,
            offline: true,
            logLevel: .none,
            storageConfig: .memory,
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
    }

    private func openLocalDoc(
        _ client: JsBaoClient,
        _ documentId: String
    ) async throws -> YDocument {
        try await client.documentManager.openDocument(
            documentId: documentId,
            options: OpenDocumentOptions(
                waitForLoad: .localIfAvailableElseNetwork,
                enableNetworkSync: false
            )
        )
    }

    /// Give a zero-debounce flush time to reach the intercepted socket. Used
    /// only for the negative assertions, where there is no event to await.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    // MARK: - C9: outbound update filter

    func testWritableDocumentTransmitsLocalUpdate() async throws {
        let client = makeClient(appId: "outbound-filter-writable")
        defer { Task { await client.destroy() } }
        let sink = FrameSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }

        let documentId = "writable-doc"
        _ = try await openLocalDoc(client, documentId)

        client.queueOutboundUpdate(documentId: documentId, update: [1, 2, 3])
        await settle()

        XCTAssertFalse(
            sink.all.isEmpty,
            "a writable, committed document must still transmit its local updates"
        )
    }

    func testReadOnlyDocumentDoesNotTransmitLocalUpdate() async throws {
        let client = makeClient(appId: "outbound-filter-readonly")
        defer { Task { await client.destroy() } }
        let sink = FrameSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }

        let documentId = "read-only-doc"
        _ = try await openLocalDoc(client, documentId)
        client.documentManager.setPermission(documentId, permission: .reader)

        client.queueOutboundUpdate(documentId: documentId, update: [1, 2, 3])
        await settle()

        XCTAssertTrue(
            sink.all.isEmpty,
            "read-only documents must not transmit local updates (JS drops them client-side); sent: \(sink.all)"
        )
    }

    func testPendingCreateDocumentHoldsLocalUpdateAndMarksUnsynced() async throws {
        let client = makeClient(appId: "outbound-filter-pending-create")
        defer { Task { await client.destroy() } }
        let sink = FrameSink()
        let marks = MarkSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }
        client.documentManager.onMarkUnsyncedForTest = { marks.append($0, $1) }

        let documentId = "pending-create-doc"
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId,
            title: "pending",
            localOnly: false
        )
        XCTAssertTrue(client.documentManager.isPendingCreate(documentId))

        client.queueOutboundUpdate(documentId: documentId, update: [1, 2, 3])
        await settle()

        XCTAssertTrue(
            sink.all.isEmpty,
            "updates for a document that does not exist server-side yet must be held; sent: \(sink.all)"
        )
        XCTAssertTrue(
            marks.markedUnsynced(documentId),
            "a held update must still mark the document as carrying unsynced local changes"
        )
    }

    func testHydrationFromLocalStorageQueuesNoOutboundUpdate() async throws {
        // JS holds outbound updates while IndexedDB replays into the Y.Doc.
        // Swift has no such flag because the hydration apply happens *before*
        // the update observer is registered (`DocumentManager.openDocument`),
        // so replay can never reach `onLocalUpdate`. This pins that ordering.
        let storagePath = NSTemporaryDirectory()
            + "parity-2665-hydration-\(UUID().uuidString.prefix(6)).sqlite"
        let storageProvider = SQLiteStorageProvider(path: storagePath)
        try await storageProvider.initialize(namespace: "parity-2665")
        let offlineStore = OfflineStore()
        await offlineStore.setStorageProvider(storageProvider)

        let documentId = "hydrated-doc"

        let writer = DocumentManager(logger: Logger(level: .none, scope: "test"))
        writer.offlineStore = offlineStore
        writer.appId = "parity-2665"
        writer.userId = "parity-user"
        let written = try await writer.openDocument(
            documentId: documentId,
            options: OpenDocumentOptions(
                waitForLoad: .localIfAvailableElseNetwork,
                enableNetworkSync: false
            )
        )
        let map: YMap<String> = written.getOrCreateMap(named: "hydration")
        written.transactSync { txn in
            map.updateValue("v", forKey: "k", transaction: txn)
        }
        await writer.closeDocument(documentId: documentId)

        let reader = DocumentManager(logger: Logger(level: .none, scope: "test"))
        reader.offlineStore = offlineStore
        reader.appId = "parity-2665"
        reader.userId = "parity-user"
        let sink = FrameSink()
        reader.onLocalUpdate = { docId, _ in sink.append(docId) }

        _ = try await reader.openDocument(
            documentId: documentId,
            options: OpenDocumentOptions(
                waitForLoad: .localIfAvailableElseNetwork,
                enableNetworkSync: false
            )
        )
        await settle()

        XCTAssertTrue(
            sink.all.isEmpty,
            "hydrating persisted state must not look like a local edit; observed: \(sink.all)"
        )

        await reader.closeDocument(documentId: documentId)
        await storageProvider.close()
    }

    // MARK: - C12: server-initiated syncStep1

    /// Build the frame a server sends to start a sync, with `docHash` set by
    /// the caller and a state vector taken from an empty document (so the
    /// client's diff is non-empty whenever it holds any content).
    private func syncStep1Frame(
        documentId: String,
        docHash: String?,
        stateVector: String
    ) -> String {
        var payload: [String: Any] = [
            "type": "syncStep1",
            "documentId": documentId,
            "stateVector": stateVector,
        ]
        if let docHash { payload["docHash"] = docHash }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8)!
    }

    /// State vector of a document holding nothing — what a server that has
    /// never seen this document would send.
    private func emptyStateVector(_ client: JsBaoClient) async throws -> String {
        let emptyId = "empty-sv-source"
        _ = try await openLocalDoc(client, emptyId)
        return client.documentManager.encodeStateVectorBase64(emptyId)!
    }

    func testSyncStep1WithMatchingHashMarksDocumentSynced() async throws {
        let client = makeClient(appId: "syncstep1-hash-match")
        defer { Task { await client.destroy() } }

        let documentId = "hash-match-doc"
        let doc = try await openLocalDoc(client, documentId)
        let map: YMap<String> = doc.getOrCreateMap(named: "m")
        doc.transactSync { txn in map.updateValue("v", forKey: "k", transaction: txn) }

        let stateVector = try await emptyStateVector(client)
        let docHash = client.documentManager.getContentDocHash(documentId: documentId)
        XCTAssertNotNil(docHash)

        await client.handleWebSocketMessage(
            syncStep1Frame(documentId: documentId, docHash: docHash, stateVector: stateVector)
        )

        XCTAssertTrue(
            client.documentManager.isSynced(documentId),
            "a docHash that matches the server's means there is nothing to send — the document is already in sync"
        )
        XCTAssertNil(
            client.documentManager.syncStep2ResponseForServerSyncStep1(
                documentId: documentId,
                serverDocHash: docHash,
                serverStateVectorBase64: stateVector
            ),
            "no syncStep2 may go on the wire when the hashes match"
        )
    }

    func testSyncStep1OnReadOnlyDocumentMarksDocumentSynced() async throws {
        let client = makeClient(appId: "syncstep1-read-only")
        defer { Task { await client.destroy() } }

        let documentId = "read-only-sync-doc"
        let doc = try await openLocalDoc(client, documentId)
        let map: YMap<String> = doc.getOrCreateMap(named: "m")
        doc.transactSync { txn in map.updateValue("v", forKey: "k", transaction: txn) }
        client.documentManager.setPermission(documentId, permission: .reader)

        let stateVector = try await emptyStateVector(client)

        await client.handleWebSocketMessage(
            syncStep1Frame(documentId: documentId, docHash: String(repeating: "0", count: 64), stateVector: stateVector)
        )

        XCTAssertTrue(
            client.documentManager.isSynced(documentId),
            "a read-only document cannot push its diff, so the sync ends locally and the document is marked synced"
        )
        XCTAssertNil(
            client.documentManager.syncStep2ResponseForServerSyncStep1(
                documentId: documentId,
                serverDocHash: String(repeating: "0", count: 64),
                serverStateVectorBase64: stateVector
            ),
            "no syncStep2 may go on the wire for a read-only document"
        )
    }

    func testSyncStep1WithDifferingHashOnWritableDocumentDoesNotMarkSynced() async throws {
        let client = makeClient(appId: "syncstep1-writable")
        defer { Task { await client.destroy() } }

        let documentId = "writable-sync-doc"
        let doc = try await openLocalDoc(client, documentId)
        let map: YMap<String> = doc.getOrCreateMap(named: "m")
        doc.transactSync { txn in map.updateValue("v", forKey: "k", transaction: txn) }

        let stateVector = try await emptyStateVector(client)

        await client.handleWebSocketMessage(
            syncStep1Frame(documentId: documentId, docHash: String(repeating: "0", count: 64), stateVector: stateVector)
        )

        XCTAssertFalse(
            client.documentManager.isSynced(documentId),
            "a writable document with a differing hash owes the server a diff — only syncComplete may mark it synced"
        )

        let response = client.documentManager.syncStep2ResponseForServerSyncStep1(
            documentId: documentId,
            serverDocHash: String(repeating: "0", count: 64),
            serverStateVectorBase64: stateVector
        )
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(response).utf8)) as? [String: Any]
        )
        XCTAssertEqual(decoded["type"] as? String, "syncStep2")
        XCTAssertEqual(decoded["documentId"] as? String, documentId)
    }

    func testSuppressedSyncStep1RunsTheNormalCompletionSideEffects() async throws {
        // Suppressing the answer replaces the `syncComplete` that would
        // otherwise have ended this sync, so it has to carry the same
        // completion side effects — otherwise a subscriber waiting on
        // `DocumentLoadedEvent` waits forever for a document that is, as far
        // as the client is concerned, fully synced.
        let client = makeClient(appId: "syncstep1-completion-events")
        defer { Task { await client.destroy() } }

        let documentId = "completion-events-doc"
        let doc = try await openLocalDoc(client, documentId)
        let map: YMap<String> = doc.getOrCreateMap(named: "m")
        doc.transactSync { txn in map.updateValue("v", forKey: "k", transaction: txn) }

        let stateVector = try await emptyStateVector(client)
        let docHash = client.documentManager.getContentDocHash(documentId: documentId)

        let loaded = Task {
            try await client.nextEvent(DocumentLoadedEvent.self, timeout: 5) {
                $0.documentId == documentId && $0.source == "server"
            }
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        await client.handleWebSocketMessage(
            syncStep1Frame(documentId: documentId, docHash: docHash, stateVector: stateVector)
        )

        let event = try await loaded.value
        XCTAssertEqual(event.hadData, false, "nothing came from the server on a hash match")
    }

    func testSyncStep1WithoutDocHashIsAnsweredWithTheDiff() async throws {
        // An older server sends no `docHash`. A missing hash must not read as
        // a match — the client still owes it the diff.
        let client = makeClient(appId: "syncstep1-no-hash")
        defer { Task { await client.destroy() } }

        let documentId = "no-hash-doc"
        let doc = try await openLocalDoc(client, documentId)
        let map: YMap<String> = doc.getOrCreateMap(named: "m")
        doc.transactSync { txn in map.updateValue("v", forKey: "k", transaction: txn) }

        let stateVector = try await emptyStateVector(client)

        let response = client.documentManager.syncStep2ResponseForServerSyncStep1(
            documentId: documentId,
            serverDocHash: nil,
            serverStateVectorBase64: stateVector
        )

        XCTAssertNotNil(response, "a syncStep1 carrying no docHash must still be answered with the diff")
        XCTAssertFalse(client.documentManager.isSynced(documentId))
    }
}
