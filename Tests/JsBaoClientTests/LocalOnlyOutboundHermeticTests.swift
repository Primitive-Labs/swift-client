import XCTest
@testable import JsBaoClient
import YSwift

/// A `localOnly` document never puts its content on the wire (issue #2691).
///
/// `documents.create(localOnly: true)` promises a document that is never
/// committed to the server, and the client deliberately does *not* mark it
/// pending-create — so the pending-create hold in `queueOutboundUpdate` never
/// sees it and, before this fix, every edit was serialized into an `update`
/// frame addressed to a document the server has no row for.
///
/// JS is the reference; the same behaviors are pinned on the JS side in
/// `tests/client/js-bao-client-localonly-outbound.test.ts`.
///
/// Server-free: the client is built with unreachable URLs and never connects.
/// Outbound frames are intercepted by replacing
/// `DocumentManager.sendWebSocketMessage`.
final class LocalOnlyOutboundHermeticTests: XCTestCase {

    /// Collects outbound frames from whichever thread the flush runs on.
    private final class FrameSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _frames: [String] = []
        func append(_ frame: String) { lock.withLock { _frames.append(frame) } }
        var all: [String] { lock.withLock { _frames } }
    }

    /// Records every `markUnsyncedLocalChanges` call. `hasUnsyncedLocalChanges`
    /// can't stand in for this: a drop and a hold both leave it false once the
    /// flag is cleared elsewhere, and only the call log shows a mark was made.
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

    /// Give a zero-debounce flush time to reach the intercepted socket. Used
    /// only for the negative assertions, where there is no event to await.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    func testLocalOnlyDocumentCreatedThisSessionDoesNotTransmitLocalUpdate() async throws {
        let client = makeClient(appId: "local-only-outbound-created")
        defer { Task { await client.destroy() } }
        let sink = FrameSink()
        let marks = MarkSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }
        client.documentManager.onMarkUnsyncedForTest = { marks.append($0, $1) }

        let documentId = "local-only-created-doc"
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId,
            title: "local only",
            localOnly: true
        )
        XCTAssertTrue(client.documentManager.isLocalOnly(documentId))
        XCTAssertFalse(
            client.documentManager.isPendingCreate(documentId),
            "a local-only document is never pending-create, so that hold cannot be what stops the send"
        )

        client.queueOutboundUpdate(documentId: documentId, update: [1, 2, 3])
        await settle()

        XCTAssertTrue(
            sink.all.isEmpty,
            "a local-only document must never transmit its content; sent: \(sink.all)"
        )
        XCTAssertFalse(
            marks.markedUnsynced(documentId),
            "nothing ever sends a local-only edit, so a mark here is one nothing could clear"
        )
    }

    func testLocalOnlyDocumentKnownFromStoredMetadataDoesNotTransmitLocalUpdate() async throws {
        // The same document in a later session: its metadata was loaded from
        // local storage, so `localOnly` is known only from the metadata row.
        let client = makeClient(appId: "local-only-outbound-stored")
        defer { Task { await client.destroy() } }
        let sink = FrameSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }

        let documentId = "local-only-stored-doc"
        client.documentManager.setMetadata(
            documentId,
            entry: LocalMetadataEntry(
                documentId: documentId,
                pendingCreate: false,
                localOnly: true
            )
        )

        client.queueOutboundUpdate(documentId: documentId, update: [1, 2, 3])
        await settle()

        XCTAssertTrue(
            sink.all.isEmpty,
            "local-only is a property of the document, not of the session that created it; sent: \(sink.all)"
        )
    }

    func testLocalOnlyDocumentEvictedWhileOpenDoesNotTransmitLocalUpdate() async throws {
        // Eviction deletes the metadata row — and, before this fix, the marker
        // set with it — while deliberately leaving the open document alive and
        // editable. Retention enforcement evicts through the same path, so an
        // open local-only document could quietly become an ordinary outbound
        // one. Mirrors the JS pin of the same name.
        let client = makeClient(appId: "local-only-outbound-evicted")
        defer { Task { await client.destroy() } }
        let sink = FrameSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }

        let documentId = "local-only-evicted-doc"
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId,
            title: "local only",
            localOnly: true
        )
        _ = try await client.documentManager.openDocument(
            documentId: documentId,
            options: OpenDocumentOptions(
                waitForLoad: .localIfAvailableElseNetwork,
                enableNetworkSync: false
            )
        )

        await client.documentManager.evictLocalData(documentId: documentId)
        XCTAssertTrue(
            client.documentManager.isLocalOnly(documentId),
            "an evicted document that is still open is still local-only"
        )

        client.queueOutboundUpdate(documentId: documentId, update: [1, 2, 3])
        await settle()

        XCTAssertTrue(
            sink.all.isEmpty,
            "an evicted-while-open local-only document must still keep its content off the wire; sent: \(sink.all)"
        )
    }

    func testLocalOnlyFromStoredMetadataEvictedWhileOpenDoesNotTransmitLocalUpdate() async throws {
        // The document was not created in this session: `localOnly` arrived
        // with its metadata row, and eviction then deletes that row. Opening it
        // has to pin what the row said, or the still-open document turns into
        // an ordinary outbound one. Mirrors the JS pin of the same name.
        let client = makeClient(appId: "local-only-outbound-evicted-stored")
        defer { Task { await client.destroy() } }
        let sink = FrameSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }

        let documentId = "local-only-stored-evicted-doc"
        client.documentManager.setMetadata(
            documentId,
            entry: LocalMetadataEntry(
                documentId: documentId,
                pendingCreate: false,
                localOnly: true
            )
        )
        _ = try await client.documentManager.openDocument(
            documentId: documentId,
            options: OpenDocumentOptions(
                waitForLoad: .localIfAvailableElseNetwork,
                enableNetworkSync: false
            )
        )

        await client.documentManager.evictLocalData(documentId: documentId)

        client.queueOutboundUpdate(documentId: documentId, update: [1, 2, 3])
        await settle()

        XCTAssertTrue(
            sink.all.isEmpty,
            "an evicted-while-open local-only document must still keep its content off the wire; sent: \(sink.all)"
        )
    }

    func testUpdateQueuedBeforeClassificationIsDroppedAtFlush() async throws {
        // The classification can arrive after the enqueue: on a cold start
        // `openDocument` can run before the storage provider is bound, read no
        // metadata row, and only learn the document is local-only when
        // `loadLocalMetadata` lands. A debounced batch queued in that window
        // must be dropped at the flush rather than sent, and must leave no
        // unsynced flag behind.
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "local-only-outbound-late-classification",
            offline: true,
            logLevel: .none,
            storageConfig: .memory,
            // Long enough to classify the document between the enqueue and the
            // flush it schedules.
            sync: SyncConfig(outboundDebounce: 0.3),
            autoNetwork: false
        ))
        defer { Task { await client.destroy() } }
        let sink = FrameSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }

        let documentId = "local-only-late-classification-doc"
        client.queueOutboundUpdate(documentId: documentId, update: [1, 2, 3])

        // What `loadLocalMetadata` does once storage is ready.
        client.documentManager.setMetadata(
            documentId,
            entry: LocalMetadataEntry(
                documentId: documentId,
                pendingCreate: false,
                localOnly: true
            )
        )
        try? await Task.sleep(nanoseconds: 900_000_000)

        XCTAssertTrue(
            sink.all.isEmpty,
            "a batch queued before the document was known local-only must be dropped, not sent; sent: \(sink.all)"
        )
        XCTAssertFalse(
            client.documentManager.hasUnsyncedLocalChanges(documentId),
            "the dropped batch leaves nothing to send, so nothing is left to clear the unsynced flag"
        )
    }

    func testLocalOnlyDocumentStillObservedAfterEvictAllDoesNotTransmitLocalUpdate() async throws {
        // `evictAllLocalData` clears the open-document map and the metadata
        // index but does not cancel the update observers, so a `YDocument` the
        // app still holds keeps forwarding its edits. Mirrors the JS pin for
        // the per-document evict, which JS reaches for its bulk evict too.
        let client = makeClient(appId: "local-only-outbound-evict-all")
        defer { Task { await client.destroy() } }
        let sink = FrameSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }

        let documentId = "local-only-evict-all-doc"
        client.documentManager.setMetadata(
            documentId,
            entry: LocalMetadataEntry(
                documentId: documentId,
                pendingCreate: false,
                localOnly: true
            )
        )
        let doc = try await client.documentManager.openDocument(
            documentId: documentId,
            options: OpenDocumentOptions(
                waitForLoad: .localIfAvailableElseNetwork,
                enableNetworkSync: false
            )
        )

        await client.documentManager.evictAllLocalData()
        XCTAssertTrue(
            client.documentManager.isLocalOnly(documentId),
            "a document whose observer is still attached is still local-only after a bulk evict"
        )

        let notes: YMap<String> = doc.getOrCreateMap(named: "notes")
        doc.transactSync { txn in
            notes.updateValue("stays here", forKey: "secret", transaction: txn)
        }
        await settle()

        XCTAssertTrue(
            sink.all.isEmpty,
            "a retained local-only document must keep its content off the wire after a bulk evict; sent: \(sink.all)"
        )
    }

    func testUpdateIsHeldWhileClassificationIsUnknownAndDroppedWhenItArrives() async throws {
        // A document opened before the storage provider is bound has no
        // classification at all: `isLocalOnly` answers false out of ignorance,
        // and the flush's own drop cannot save it — with a short debounce the
        // send happens before `loadLocalMetadata` lands. So the batch is held
        // at the flush instead, and released only once the answer is in.
        let client = makeClient(appId: "local-only-outbound-unclassified")
        defer { Task { await client.destroy() } }
        let sink = FrameSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }

        // The startup bind releases every held classification once, so let it
        // finish before pinning one — otherwise the seam below is cleared by a
        // release that belongs to the client's own initialization.
        _ = await client.waitForStorageReady()

        let documentId = "local-only-unclassified-doc"
        client.documentManager.markLocalOnlyClassificationPendingForTest(documentId)

        client.queueOutboundUpdate(documentId: documentId, update: [1, 2, 3])
        await settle()

        XCTAssertTrue(
            sink.all.isEmpty,
            "an unclassified document's content must not go on the wire on the chance that it is ordinary; sent: \(sink.all)"
        )
        XCTAssertTrue(
            client.documentManager.hasUnsyncedLocalChanges(documentId),
            "the batch is held, not dropped — an ordinary document's edit still has to reach the socket"
        )

        // What `loadLocalMetadata` does once storage is ready, followed by the
        // release that the storage bind performs.
        client.documentManager.setMetadata(
            documentId,
            entry: LocalMetadataEntry(
                documentId: documentId,
                pendingCreate: false,
                localOnly: true
            )
        )
        client.releaseHeldOutboundClassifications()
        await settle()

        XCTAssertTrue(
            sink.all.isEmpty,
            "the held batch belongs to a local-only document and must be dropped, not sent; sent: \(sink.all)"
        )
        XCTAssertFalse(
            client.documentManager.hasUnsyncedLocalChanges(documentId),
            "the dropped batch leaves nothing to send, so nothing is left to clear the unsynced flag"
        )
    }

    func testHeldUpdateForOrdinaryDocumentTransmitsOnceClassificationArrives() async throws {
        // The control for the hold: a document that turns out to be ordinary
        // must not have its edit stranded by it.
        let client = makeClient(appId: "local-only-outbound-unclassified-control")
        defer { Task { await client.destroy() } }
        let sink = FrameSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }

        _ = await client.waitForStorageReady()

        let documentId = "unclassified-ordinary-doc"
        client.documentManager.markLocalOnlyClassificationPendingForTest(documentId)

        client.queueOutboundUpdate(documentId: documentId, update: [1, 2, 3])
        await settle()
        XCTAssertTrue(sink.all.isEmpty, "held until classified; sent: \(sink.all)")

        client.releaseHeldOutboundClassifications()
        await settle()

        XCTAssertFalse(
            sink.all.isEmpty,
            "an ordinary document's held edit must reach the socket once the classification lands"
        )
    }

    func testLocalOnlyDocumentStillOpenAfterIdentityRebindDoesNotTransmitLocalUpdate() async throws {
        // A sign-in re-scopes the in-memory user state — the metadata index and
        // the local-only markers go with it — but closes no document and
        // cancels no update observer. A local-only document opened before the
        // sign-in stays editable, and its edits must stay off the newly
        // authenticated socket too. JS pins the same behavior
        // (`clearLocalOnlyMarkers`).
        let client = makeClient(appId: "local-only-outbound-rebind")
        defer { Task { await client.destroy() } }
        let sink = FrameSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }

        let documentId = "local-only-rebind-doc"
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId,
            title: "local only",
            localOnly: true
        )
        _ = try await client.documentManager.openDocument(
            documentId: documentId,
            options: OpenDocumentOptions(
                waitForLoad: .localIfAvailableElseNetwork,
                enableNetworkSync: false
            )
        )

        await client.documentManager.resetInMemoryUserState(userId: "someone-else")
        XCTAssertTrue(
            client.documentManager.isLocalOnly(documentId),
            "a document still open after the rebind is still local-only"
        )

        client.queueOutboundUpdate(documentId: documentId, update: [1, 2, 3])
        await settle()

        XCTAssertTrue(
            sink.all.isEmpty,
            "a local-only document left open across a sign-in must keep its content off the wire; sent: \(sink.all)"
        )
    }

    func testClosingAnEvictedLocalOnlyDocumentStopsClaimingALocalCopy() async throws {
        // The marker outlives the evicted document's metadata row only because
        // the document is still open and editable. Once it is closed there is
        // nothing left to filter — and a marker kept past that would go on
        // reporting a local copy eviction deleted.
        let client = makeClient(appId: "local-only-outbound-evict-then-close")
        defer { Task { await client.destroy() } }

        let documentId = "local-only-evict-then-close-doc"
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId,
            title: "local only",
            localOnly: true
        )
        _ = try await client.documentManager.openDocument(
            documentId: documentId,
            options: OpenDocumentOptions(
                waitForLoad: .localIfAvailableElseNetwork,
                enableNetworkSync: false
            )
        )

        await client.documentManager.evictLocalData(documentId: documentId)
        XCTAssertTrue(client.documentManager.hasLocalCopy(documentId))

        await client.documentManager.closeDocument(documentId: documentId)

        XCTAssertFalse(
            client.documentManager.isLocalOnly(documentId),
            "nothing is left to filter once the evicted document is closed"
        )
        XCTAssertFalse(
            client.documentManager.hasLocalCopy(documentId),
            "the local copy was evicted; the marker must not keep claiming it"
        )
    }

    func testOrdinaryWritableDocumentStillTransmitsLocalUpdate() async throws {
        let client = makeClient(appId: "local-only-outbound-control")
        defer { Task { await client.destroy() } }
        let sink = FrameSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }

        let documentId = "writable-doc"
        _ = try await client.documentManager.openDocument(
            documentId: documentId,
            options: OpenDocumentOptions(
                waitForLoad: .localIfAvailableElseNetwork,
                enableNetworkSync: false
            )
        )

        client.queueOutboundUpdate(documentId: documentId, update: [1, 2, 3])
        await settle()

        XCTAssertFalse(
            sink.all.isEmpty,
            "an ordinary writable document must still transmit its local updates"
        )
    }
}
