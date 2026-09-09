import XCTest
@testable import JsBaoClient
import YSwift

/// Work skipped because local storage was not bound yet is replayed when it
/// binds (issue #3200, phase 3 — the F1 deferral and review findings F2/F3).
///
/// Two writes can land before `setupStorage()` has bound a provider: a
/// debounced Y.Doc snapshot, and a metadata put — which, since create is
/// metadata-only, is the *only* durable artifact a `documents.create` leaves
/// behind. Both used to be dropped with a warning and never retried. They are
/// now remembered and replayed on storage-ready, through a latch that cannot
/// lose a wakeup: the skip path enqueues or retries under the same lock hold
/// that storage-ready flips.
///
/// Server-free: `DocumentManager` is constructed directly, with the provider
/// bound late.
final class StorageReadyHandoffHermeticTests: XCTestCase {

    private func makeProvider(_ label: String) async throws -> SQLiteStorageProvider {
        let path = NSTemporaryDirectory()
            + "storage-ready-\(label)-\(UUID().uuidString.prefix(6)).sqlite"
        let provider = SQLiteStorageProvider(path: path)
        try await provider.initialize(namespace: "storage-ready-\(label)")
        return provider
    }

    private func makeManager(_ appId: String, store: OfflineStore) -> DocumentManager {
        let manager = DocumentManager(logger: Logger(level: .none, scope: "test"))
        manager.offlineStore = store
        manager.appId = appId
        manager.userId = "storage-ready-user"
        return manager
    }

    private let localOpen = OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)

    /// Longer than the 250ms persist debounce, so the skipped persist has
    /// really run before storage binds.
    private func awaitPersistDebounce() async {
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    // MARK: - Behavior 16: a snapshot skipped before the bind is replayed

    func testWritePersistedBeforeStorageBoundIsReplayedOnReady() async throws {
        let store = OfflineStore()
        let manager = makeManager("storage-ready-persist", store: store)
        let documentId = "persist-before-bind-doc"

        let doc = try await manager.openDocument(documentId: documentId, options: localOpen)
        let map: YMap<String> = doc.getOrCreateMap(named: "m")
        doc.transactSync { txn in map.updateValue("survives", forKey: "k", transaction: txn) }
        await awaitPersistDebounce()

        // Nothing could have been written: there was no provider.
        let provider = try await makeProvider("persist")
        let probe = YjsSQLitePersistence(storageProvider: provider, documentId: documentId)
        let beforeBind = try await probe.loadDocument()
        XCTAssertNil(
            beforeBind,
            "precondition: the debounced persist ran with no provider and wrote nothing"
        )

        await store.setStorageProvider(provider)
        await manager.storageDidBecomeReady()

        let restored = try await probe.loadDocument()
        XCTAssertFalse(
            (restored ?? Data()).isEmpty,
            "the skipped snapshot must be replayed when storage binds — with no further write, sync or close"
        )

        await manager.closeDocument(documentId: documentId)
        await provider.close()
    }

    // MARK: - Behavior 20: a create's metadata row survives the same gap

    func testCreateMetadataWrittenBeforeStorageBoundIsReplayedOnReady() async throws {
        for localOnly in [false, true] {
            let store = OfflineStore()
            let manager = makeManager("storage-ready-metadata", store: store)
            let documentId = localOnly ? "create-before-bind-local" : "create-before-bind-doc"

            try await manager.createLocalDocument(
                documentId: documentId,
                title: "T",
                localOnly: localOnly,
                tags: ["x"],
                docMetadata: .object(["kind": .string("note")])
            )

            let provider = try await makeProvider("metadata-\(localOnly)")
            await store.setStorageProvider(provider)
            await manager.storageDidBecomeReady()

            // A fresh store over the same provider: nothing in-memory can
            // answer this read.
            let fresh = OfflineStore()
            await fresh.setStorageProvider(provider)
            let row = try await fresh.getMetadata(
                appId: manager.appId, userId: manager.userId, documentId: documentId
            )
            let entry = try XCTUnwrap(
                row,
                "a create's metadata row is its only durable artifact — it must survive the bind"
            )
            XCTAssertEqual(entry.title, "T")
            XCTAssertEqual(entry.tags, ["x"])
            XCTAssertEqual(entry.localOnly, localOnly)
            XCTAssertEqual(entry.pendingCreate, !localOnly)

            await provider.close()
        }
    }

    // MARK: - Behavior 21: the latch cannot lose a wakeup

    func testStorageBindingBetweenTheProviderReadAndTheLatchStillPersists() async throws {
        // The interleaving the one-shot sweep could not survive: the provider
        // binds and the drain runs *after* the persist saw a nil provider and
        // *before* it recorded itself. The latch has to notice and retry.
        let store = OfflineStore()
        let manager = makeManager("storage-ready-race", store: store)
        let documentId = "lost-wakeup-doc"

        let doc = try await manager.openDocument(documentId: documentId, options: localOpen)
        let provider = try await makeProvider("race")

        let fired = LockedBox<Bool>(false)
        manager.onPersistProviderMissingForTest = { [weak manager] in
            // One shot: the retry below must not re-enter this hook.
            let alreadyFired: Bool = fired.withValue { was in
                let previous = was
                was = true
                return previous
            }
            guard !alreadyFired else { return }
            await store.setStorageProvider(provider)
            await manager?.storageDidBecomeReady()
        }

        let map: YMap<String> = doc.getOrCreateMap(named: "m")
        doc.transactSync { txn in map.updateValue("not lost", forKey: "k", transaction: txn) }
        await awaitPersistDebounce()
        try? await Task.sleep(nanoseconds: 400_000_000)

        let probe = YjsSQLitePersistence(storageProvider: provider, documentId: documentId)
        let restored = try await probe.loadDocument()
        XCTAssertFalse(
            (restored ?? Data()).isEmpty,
            "storage became ready between the nil read and the latch — the persist must retry, not enqueue into a drained set"
        )

        await manager.closeDocument(documentId: documentId)
        await provider.close()
    }

    // MARK: - Edge case: drain hygiene

    func testDrainSkipsADocumentClosedBeforeItRuns() async throws {
        let store = OfflineStore()
        let manager = makeManager("storage-ready-hygiene", store: store)
        let documentId = "closed-before-drain-doc"

        let doc = try await manager.openDocument(documentId: documentId, options: localOpen)
        let map: YMap<String> = doc.getOrCreateMap(named: "m")
        doc.transactSync { txn in map.updateValue("v", forKey: "k", transaction: txn) }
        await awaitPersistDebounce()

        await manager.closeDocument(documentId: documentId)

        let provider = try await makeProvider("hygiene")
        await store.setStorageProvider(provider)
        await manager.storageDidBecomeReady()

        let probe = YjsSQLitePersistence(storageProvider: provider, documentId: documentId)
        let afterDrain = try await probe.loadDocument()
        XCTAssertNil(
            afterDrain,
            "a document closed before the drain is skipped — the drain must not resurrect its state"
        )
        await provider.close()
    }

    /// Both of the next two pin the *outcome* — the drain resurrects nothing an
    /// eviction removed — rather than one particular guard. Each is protected
    /// twice over: the drain skips a suspended document and a deleted metadata
    /// id, and behind that the persist path re-checks suspension and the
    /// eviction has already dropped the row from the metadata index. Removing
    /// either of the drain's own guards leaves these green; what they would
    /// catch is a resurrection through any of those layers.
    func testDrainSkipsAPersistenceSuspendedDocument() async throws {
        let store = OfflineStore()
        let manager = makeManager("storage-ready-suspended", store: store)
        let documentId = "suspended-before-drain-doc"

        let doc = try await manager.openDocument(documentId: documentId, options: localOpen)
        let map: YMap<String> = doc.getOrCreateMap(named: "m")
        doc.transactSync { txn in map.updateValue("v", forKey: "k", transaction: txn) }
        await awaitPersistDebounce()

        // Evicting a document that is still open suspends its persistence:
        // "don't keep this on this device" outlives the eviction, so neither
        // the next edit nor the drain may write it back.
        await manager.evictLocalData(documentId: documentId)

        let provider = try await makeProvider("suspended")
        await store.setStorageProvider(provider)
        await manager.storageDidBecomeReady()

        let probe = YjsSQLitePersistence(storageProvider: provider, documentId: documentId)
        let afterDrain = try await probe.loadDocument()
        XCTAssertNil(
            afterDrain,
            "a persistence-suspended document is skipped — the drain must not write back what an eviction removed"
        )

        await manager.closeDocument(documentId: documentId)
        await provider.close()
    }

    func testDrainDoesNotReplayMetadataForADocumentTheServerReportedGone() async throws {
        let store = OfflineStore()
        let manager = makeManager("storage-ready-deleted", store: store)
        let documentId = "deleted-before-drain-doc"

        // The open's own metadata put is skipped (no provider) and waits for
        // the drain; then the server says the document is gone.
        _ = try await manager.openDocument(documentId: documentId, options: localOpen)
        await manager.handleServerDocumentAbsent(documentId)

        let provider = try await makeProvider("deleted")
        await store.setStorageProvider(provider)
        await manager.storageDidBecomeReady()

        let fresh = OfflineStore()
        await fresh.setStorageProvider(provider)
        let row = try await fresh.getMetadata(
            appId: manager.appId, userId: manager.userId, documentId: documentId
        )
        XCTAssertNil(
            row,
            "metadata replay skips a row deleted while it waited — the drain must not resurrect it"
        )
        await provider.close()
    }

    func testImmediateMetadataRetryDoesNotResurrectARowEvictedInTheGap() async throws {
        // The latch's other branch: storage binds (and the drain runs) between
        // the put that found no provider and the latch check, so the write is
        // retried on the spot rather than enqueued. The retry has to honour a
        // deletion that landed in the same gap — neither the delete nor the
        // original write ever reached the disk, so replaying the stale record
        // would write back a row nothing should be able to read again.
        let store = OfflineStore()
        let manager = makeManager("storage-ready-evicted-gap", store: store)
        let documentId = "evicted-in-the-gap-doc"
        let provider = try await makeProvider("evicted-gap")

        let fired = LockedBox<Bool>(false)
        manager.onMetadataProviderMissingForTest = { [weak manager] in
            // One shot: the work below writes metadata of its own.
            let alreadyFired: Bool = fired.withValue { was in
                let previous = was
                was = true
                return previous
            }
            guard !alreadyFired else { return }
            guard let manager else { return }
            await manager.evictLocalData(documentId: documentId)
            await store.setStorageProvider(provider)
            await manager.storageDidBecomeReady()
        }

        try await manager.createLocalDocument(
            documentId: documentId,
            title: "T",
            localOnly: false,
            tags: [],
            docMetadata: nil
        )

        let fresh = OfflineStore()
        await fresh.setStorageProvider(provider)
        let row = try await fresh.getMetadata(
            appId: manager.appId, userId: manager.userId, documentId: documentId
        )
        XCTAssertNil(
            row,
            "the immediate retry must write the surviving row, not the one an eviction removed"
        )
        await provider.close()
    }

    func testEmptyDrainIsANoOpAndStillReportsItRan() async throws {
        let store = OfflineStore()
        let manager = makeManager("storage-ready-empty", store: store)
        let ran = LockedBox<Int>(0)
        manager.onStorageReadyDrainForTest = { ran.withValue { $0 += 1 } }

        let provider = try await makeProvider("empty")
        await store.setStorageProvider(provider)
        await manager.storageDidBecomeReady()

        XCTAssertEqual(ran.value, 1, "the drain reports itself even with nothing to replay")
        await provider.close()
    }

    // MARK: - Behavior 17: the client wires the drain to storage setup

    func testClientRunsTheDrainOnceStorageSetupCompletes() async throws {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "storage-ready-client",
            offline: true,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
        defer { Task { await client.destroy() } }

        let ran = LockedBox<Int>(0)
        client.documentManager.onStorageReadyDrainForTest = { ran.withValue { $0 += 1 } }

        _ = await client.waitForStorageReady()
        // The drain is dispatched from `setupStorage` right after the
        // storage-ready signal; give that hop room to land.
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertGreaterThanOrEqual(
            ran.value, 1,
            "storage setup must hand off to the drain, or nothing ever replays what it skipped"
        )
    }
}
