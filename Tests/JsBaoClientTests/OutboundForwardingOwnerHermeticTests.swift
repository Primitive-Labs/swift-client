import XCTest
@testable import JsBaoClient
import YSwift

/// One forwarding owner for local updates, with no window in which a document
/// is observable but unobserved (issue #3200, phase 2).
///
/// The per-document update observer is the single owner: `transactAndSync` and
/// `transactAndSyncAsync` no longer compute their own diff and enqueue it, so
/// one write produces exactly one outbound update whichever way it was made.
/// That is only sound if every reachable open document has an observer, which
/// is why `_openDocumentImpl` registers it before publishing the document in
/// `openDocs` and before emitting `DocumentOpenedEvent` — and why the local
/// hydration apply is suppressed from forwarding.
///
/// Server-free: unreachable URLs, memory storage, and a large outbound debounce
/// so nothing flushes while the enqueues are being counted.
final class OutboundForwardingOwnerHermeticTests: XCTestCase {

    /// Counts `queueOutboundUpdate` calls per document, from whichever thread
    /// the write ran on.
    private final class EnqueueCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _ids: [String] = []
        func append(_ documentId: String) { lock.withLock { _ids.append(documentId) } }
        func count(_ documentId: String) -> Int {
            lock.withLock { _ids.filter { $0 == documentId }.count }
        }
        var all: [String] { lock.withLock { _ids } }
    }

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

    /// A client that never talks to a server. The outbound debounce is long on
    /// purpose: the subject is how many updates are *enqueued*, so no flush may
    /// drain the queue mid-count.
    private func makeClient(_ appId: String) -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: appId,
            offline: true,
            logLevel: .none,
            storageConfig: .memory,
            sync: SyncConfig(outboundDebounce: 30),
            autoNetwork: false
        ))
    }

    private func openLocalDoc(
        _ client: JsBaoClient,
        _ documentId: String
    ) async throws -> YDocument {
        try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    // MARK: - Behavior 11: `transactAndSync` enqueues exactly once

    func testTransactAndSyncEnqueuesExactlyOneUpdate() async throws {
        let client = makeClient("forwarding-owner-sync")
        defer { Task { await client.destroy() } }
        let counter = EnqueueCounter()
        client.onOutboundQueuedForTest = { counter.append($0) }
        _ = await client.waitForStorageReady()

        let documentId = "owner-sync-doc"
        let doc = try await openLocalDoc(client, documentId)
        let map: YMap<String> = doc.getOrCreateMap(named: "m")

        try client.transactAndSync(documentId) { txn in
            map.updateValue("v", forKey: "k", transaction: txn)
        }
        await settle()

        XCTAssertEqual(
            counter.count(documentId), 1,
            "the observer is the single forwarding owner — the wrapper must not enqueue a second copy"
        )
    }

    // MARK: - Behavior 12: `transactAndSyncAsync` enqueues exactly once

    func testTransactAndSyncAsyncEnqueuesExactlyOneUpdate() async throws {
        let client = makeClient("forwarding-owner-async")
        defer { Task { await client.destroy() } }
        let counter = EnqueueCounter()
        client.onOutboundQueuedForTest = { counter.append($0) }
        _ = await client.waitForStorageReady()

        let documentId = "owner-async-doc"
        let doc = try await openLocalDoc(client, documentId)
        let map: YMap<String> = doc.getOrCreateMap(named: "m")

        _ = try await client.transactAndSyncAsync(documentId) { txn in
            map.updateValue("v", forKey: "k", transaction: txn)
        }
        await settle()

        XCTAssertEqual(
            counter.count(documentId), 1,
            "a raw-transaction write is forwarded once, by the observer"
        )
    }

    // MARK: - Behavior 13: a plain write enqueues exactly once

    func testPlainTransactSyncEnqueuesExactlyOneUpdate() async throws {
        let client = makeClient("forwarding-owner-plain")
        defer { Task { await client.destroy() } }
        let counter = EnqueueCounter()
        client.onOutboundQueuedForTest = { counter.append($0) }
        _ = await client.waitForStorageReady()

        let documentId = "owner-plain-doc"
        let doc = try await openLocalDoc(client, documentId)
        let map: YMap<String> = doc.getOrCreateMap(named: "m")

        doc.transactSync { txn in map.updateValue("v", forKey: "k", transaction: txn) }
        await settle()

        XCTAssertEqual(
            counter.count(documentId), 1,
            "a plain write on an open document still reaches the outbound funnel exactly once"
        )
    }

    // MARK: - Behavior 18: no window where the document is open but unobserved

    func testWriteFromAnOpenedEventHandlerIsForwarded() async throws {
        // `DocumentOpenedEvent` is emitted from inside the open, and the
        // document is reachable through `getDoc` at that moment. A write made
        // there must be forwarded and must schedule a persist — otherwise the
        // observer-as-sole-owner design has a hole exactly the size of the
        // open.
        let client = makeClient("forwarding-owner-open-window")
        defer { Task { await client.destroy() } }
        let counter = EnqueueCounter()
        client.onOutboundQueuedForTest = { counter.append($0) }
        _ = await client.waitForStorageReady()

        let documentId = "owner-open-window-doc"
        let sub = client.eventEmitter.subscribe(DocumentOpenedEvent.self) { [weak client] event in
            guard event.documentId == documentId, let doc = client?.getDoc(documentId) else { return }
            let map: YMap<String> = doc.getOrCreateMap(named: "m")
            doc.transactSync { txn in
                map.updateValue("written from the opened event", forKey: "k", transaction: txn)
            }
        }
        defer { sub.cancel() }

        _ = try await openLocalDoc(client, documentId)
        await settle()

        XCTAssertEqual(
            counter.count(documentId), 1,
            "a document that reports open has an observer: the event handler's write is forwarded"
        )
    }

    // MARK: - A remote apply suppresses its own transaction, not whatever else commits

    func testALocalWriteCommittingDuringARemoteApplyIsStillForwarded() async throws {
        // The sole owner drops an update while `applyingRemoteUpdate` is set for
        // the document. That flag therefore has to cover the remote
        // transaction and nothing else: raising it before taking the
        // document's FFI lock — as the apply path used to — suppressed
        // whatever a concurrent local write happened to commit in the window,
        // and with the wrappers no longer forwarding on their own, that write
        // was simply dropped: not sent, not marked unsynced, on a document
        // still reporting itself synced.
        let manager = DocumentManager(logger: Logger(level: .none, scope: "test"))
        manager.appId = "forwarding-owner-suppression"
        manager.userId = "forwarding-user"
        let documentId = "suppression-scope-doc"

        let counter = EnqueueCounter()
        manager.onLocalUpdate = { docId, _ in counter.append(docId) }

        let doc = try await manager.openDocument(
            documentId: documentId,
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )

        // A real server frame, encoded from a second document.
        let server = YDocument()
        let serverMap: YMap<String> = server.getOrCreateMap(named: "m")
        server.transactSync { txn in
            serverMap.updateValue("from the server", forKey: "remote", transaction: txn)
        }
        let remoteFrame: Data = server.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }
        XCTAssertFalse(remoteFrame.isEmpty, "precondition: the server frame carries something")

        // The apply is started from another thread while the local transaction
        // below is open, and cannot finish until that transaction commits.
        let localTransactionOpen = DispatchSemaphore(value: 0)
        let remoteApplyStarted = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            localTransactionOpen.wait()
            remoteApplyStarted.signal()
            manager.handleRemoteUpdate(documentId: documentId, updateData: remoteFrame)
        }

        let map: YMap<String> = doc.getOrCreateMap(named: "m")
        doc.transactSync { txn in
            map.updateValue("local", forKey: "local", transaction: txn)
            localTransactionOpen.signal()
            _ = remoteApplyStarted.wait(timeout: .now() + 2)
            // Room for the apply to reach the point where it used to raise the
            // flag — ahead of this transaction's commit.
            Thread.sleep(forTimeInterval: 0.3)
        }
        await settle()

        XCTAssertEqual(
            counter.count(documentId), 1,
            "the local write commits during the remote apply and is still forwarded exactly once"
        )
        let applied: String? = doc.transactSync { txn in map.get(key: "remote", transaction: txn) }
        XCTAssertEqual(
            applied, "from the server",
            "precondition: the remote apply really did run against this document"
        )

        await manager.closeDocument(documentId: documentId)
    }

    // MARK: - Behavior 19: the hydration apply is not forwarded

    func testHydratingPersistedStateForwardsNothingAndMarksNothingUnsynced() async throws {
        // With the observer registered before the restore, the hydration apply
        // now runs *through* it — so it has to be suppressed explicitly, the
        // same way a remote update is.
        let storagePath = NSTemporaryDirectory()
            + "forwarding-owner-hydration-\(UUID().uuidString.prefix(6)).sqlite"
        let storageProvider = SQLiteStorageProvider(path: storagePath)
        try await storageProvider.initialize(namespace: "forwarding-owner")
        let offlineStore = OfflineStore()
        await offlineStore.setStorageProvider(storageProvider)

        let documentId = "hydrated-owner-doc"

        let writer = DocumentManager(logger: Logger(level: .none, scope: "test"))
        writer.offlineStore = offlineStore
        writer.appId = "forwarding-owner"
        writer.userId = "forwarding-user"
        let written = try await writer.openDocument(
            documentId: documentId,
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        let map: YMap<String> = written.getOrCreateMap(named: "hydration")
        written.transactSync { txn in map.updateValue("v", forKey: "k", transaction: txn) }
        await writer.closeDocument(documentId: documentId)

        let reader = DocumentManager(logger: Logger(level: .none, scope: "test"))
        reader.offlineStore = offlineStore
        reader.appId = "forwarding-owner"
        reader.userId = "forwarding-user"
        let counter = EnqueueCounter()
        let marks = MarkSink()
        reader.onLocalUpdate = { docId, _ in counter.append(docId) }
        reader.onMarkUnsyncedForTest = { marks.append($0, $1) }

        let restored = try await reader.openDocument(
            documentId: documentId,
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        await settle()

        let restoredMap: YMap<String> = restored.getOrCreateMap(named: "hydration")
        let value: String? = restored.transactSync { txn in
            restoredMap.get(key: "k", transaction: txn)
        }
        XCTAssertEqual(value, "v", "precondition: the persisted state really was restored")
        XCTAssertTrue(
            counter.all.isEmpty,
            "hydrating persisted state must not look like a local edit; observed: \(counter.all)"
        )
        XCTAssertFalse(
            marks.markedUnsynced(documentId),
            "the restored state is not an unsent local change"
        )

        await reader.closeDocument(documentId: documentId)
        await storageProvider.close()
    }
}
