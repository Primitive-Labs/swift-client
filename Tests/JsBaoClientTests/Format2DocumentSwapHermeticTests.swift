import XCTest
@testable import JsBaoClient
import YSwift

/// Replacing an open document's Y.Doc at an epoch move (#3437, behavior 9,
/// edge E12, finding 3437-SO-06).
///
/// For a LARGE document the Y.Doc IS the current epoch's overlay, not the
/// document — so following a seal means putting a FRESH one in its place, with
/// the owed writes carried onto it. `DocumentManager` holds one instance per
/// document id in `openDocs`, with its `YProtocol` and its update
/// subscription beside it, and #3436 left no way to swap the trio: only
/// `closeDocument` tears it down.
///
/// The persist is the hard part. `persistDocumentToLocal` encodes the
/// document's bytes and saves them SEVERAL suspension points later, and the
/// debounce's cancellation is only checked before a persist starts — so an
/// in-flight persist of the OLD overlay can land after the fresh one was
/// saved, restarting the client with a SEALED overlay under the NEW epoch mark
/// and resending it whole into the new epoch. That is exactly the corruption
/// the re-seeding rotation exists to prevent, arriving by a different door
/// (finding 3437-SO-06). A per-document persist generation is the fence: the
/// bytes carry the generation they were encoded under, and a save whose
/// generation has moved writes nothing.
///
/// Step 0b's vehicle smoke proved a persist can be held at that seam and
/// released; this is the behavior built on it.
final class Format2DocumentSwapHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "/f2-swap-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    private func makeClient(path: String) async -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: "ws://127.0.0.1:1",
            appId: "format2-swap-test-app",
            token: makeTestJwt(userId: "format2-swap-user"),
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .sqlite(directory: path),
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
        _ = await client.waitForStorageReady()
        return client
    }

    private func openLocal(
        _ client: JsBaoClient, _ documentId: String, format: Int?
    ) async throws -> YDocument {
        client.documentManager.createRemoteDocument = { (_: [String: Any]) in
            ["documentId": documentId]
        }
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId, title: "swap", localOnly: false,
            documentFormat: format
        )
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        return try XCTUnwrap(client.documentManager.getDocument(documentId))
    }

    private func write(_ doc: YDocument, _ key: String, _ value: String) {
        OverlayDocument(document: doc).applyRawEntries(
            [(key, .string(value))], model: "Note"
        )
    }

    /// What the stored snapshot decodes to, read back through a fresh document.
    ///
    /// `nil` while nothing has been persisted yet. Deliberately NOT asserting:
    /// it is polled, and an `XCTUnwrap` in here would record a failure for
    /// every attempt that arrived before the debounce.
    private func storedOverlay(
        _ client: JsBaoClient, _ documentId: String
    ) async -> OverlayDocument? {
        guard let provider = await client.offlineStore.getStorageProvider()
        else { return nil }
        let persistence = YjsSQLitePersistence(
            storageProvider: provider, documentId: documentId
        )
        guard let data = try? await persistence.loadDocument() else { return nil }
        let overlay = OverlayDocument()
        guard (try? overlay.applyUpdate([UInt8](data))) != nil else { return nil }
        return overlay
    }

    /// The stored snapshot once it exists, polled — the persist is debounced
    /// by 250 ms and then saves, so a fixed wait is a guess about a machine.
    private func storedOverlayEventually(
        _ client: JsBaoClient, _ documentId: String, timeout: TimeInterval = 10
    ) async throws -> OverlayDocument {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let overlay = await storedOverlay(client, documentId) {
                return overlay
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("nothing was persisted for \(documentId) within \(timeout)s")
        return OverlayDocument()
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

    // MARK: - Behavior 9 — the swap

    func testTheSwapReplacesTheDocumentItsProtocolAndItsSubscription() async throws {
        let client = await makeClient(path: newDatabasePath())
        defer { Task { await client.destroy() } }
        let documentId = "swap-1"
        let old = try await openLocal(client, documentId, format: 2)
        write(old, "r1/title", "sealed")

        let forwarded = LockedBox<[String]>([])
        client.documentManager.onLocalUpdate = { id, _ in
            forwarded.withValue { $0.append(id) }
        }

        let fresh = YDocument()
        await client.documentManager.replaceOpenDocument(
            documentId: documentId, with: fresh
        )

        XCTAssertTrue(
            client.documentManager.getDocument(documentId) === fresh,
            "`getDocument` answers the fresh overlay — this is the handle the "
            + "facade and every later frame work against"
        )
        XCTAssertNotNil(
            client.documentManager.buildSyncStep1Message(documentId: documentId),
            "a fresh document needs a fresh protocol, or the next handshake "
            + "would diff against the sealed overlay's state vector"
        )

        // Edge E12: the app may still be holding the OLD handle. Writes on it
        // are not forwarded — it is detached.
        forwarded.value = []
        write(old, "r1/title", "on the stale handle")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(
            forwarded.value, [],
            "a write on the handle from before the move is not forwarded"
        )

        // And a write on the NEW one is.
        write(fresh, "r2/title", "on the fresh overlay")
        try await waitFor("the fresh document's write to be forwarded") {
            !forwarded.value.isEmpty
        }
        XCTAssertEqual(forwarded.value, [documentId])
    }

    func testTheFreshDocumentIsPersistedBeforeTheSwapReturns() async throws {
        let client = await makeClient(path: newDatabasePath())
        defer { Task { await client.destroy() } }
        let documentId = "swap-2"
        _ = try await openLocal(client, documentId, format: 2)

        let fresh = YDocument()
        write(fresh, "carried/title", "owed")
        await client.documentManager.replaceOpenDocument(
            documentId: documentId, with: fresh
        )

        // Awaited, not scheduled: the epoch mark moves after this returns, and
        // a crash in between must restart with the FRESH overlay under the old
        // mark — which the next handshake's catch-up repairs idempotently —
        // rather than the sealed one under the new mark, which would be
        // resent whole into the new epoch (edge E7, finding 3437-R05).
        let stored = try await storedOverlayEventually(client, documentId)
        XCTAssertEqual(
            stored.value(model: "Note", key: "carried/title"), .string("owed")
        )
    }

    /// Finding 3437-SO-06: the interleaving the fence exists for.
    func testAPersistOfTheOldDocumentInFlightAcrossTheSwapSavesNothing()
        async throws
    {
        let client = await makeClient(path: newDatabasePath())
        defer { Task { await client.destroy() } }
        let documentId = "swap-3"
        let old = try await openLocal(client, documentId, format: 2)

        // Hold the FIRST persist after its encode. Its bytes are the sealed
        // overlay's.
        let reached = LockedBox<Int>(0)
        let gate = LockedBox<Bool>(false)
        client.documentManager.onPersistEncodedForTest = { (_: String) in
            let first = reached.withValue { value -> Bool in
                value += 1
                return value == 1
            }
            guard first else { return }
            while !gate.value { try? await Task.sleep(nanoseconds: 5_000_000) }
        }

        write(old, "sealed/title", "the old epoch")
        try await waitFor("the old document's persist to reach the seam") {
            reached.value > 0
        }

        // The move, with the old persist still holding its encoded bytes.
        let fresh = YDocument()
        write(fresh, "carried/title", "the new epoch")
        await client.documentManager.replaceOpenDocument(
            documentId: documentId, with: fresh
        )

        // Now let the stale persist run to its save.
        gate.value = true
        try await Task.sleep(nanoseconds: 500_000_000)

        let stored = try await storedOverlayEventually(client, documentId)
        XCTAssertEqual(
            stored.value(model: "Note", key: "carried/title"), .string("the new epoch"),
            "the fresh overlay is what is on disk"
        )
        XCTAssertNil(
            stored.value(model: "Note", key: "sealed/title"),
            "the stale persist wrote nothing: its bytes were encoded under a "
            + "generation the move has left behind, and saving them would "
            + "restart the client with a SEALED overlay under the new epoch mark"
        )
    }

    /// Finding 3437-REVIEW-006: the window the generation check cannot cover.
    ///
    /// The check is a read-then-act — it is taken under the lock, the lock is
    /// given back, and the save is awaited afterwards. A stale persist
    /// preempted between the two passes the check (its generation is still
    /// current at that instant), watches the swap bump the generation and save
    /// the fresh overlay, and then writes its own old-epoch bytes on top. The
    /// fence is intact and the corruption happens anyway, through a door the
    /// fence does not stand in.
    ///
    /// One fence-and-save turn per document closes it: the stale persist
    /// either takes its turn first — and the swap's save lands after it — or
    /// takes it afterwards and finds its generation moved.
    func testAPersistPausedBetweenTheFenceAndItsSaveDoesNotOutliveTheSwap()
        async throws
    {
        let client = await makeClient(path: newDatabasePath())
        defer { Task { await client.destroy() } }
        let documentId = "swap-4"
        let old = try await openLocal(client, documentId, format: 2)

        // Hold the first persist PAST its generation check, in the window
        // between the fence and the save it guards.
        let reached = LockedBox<Int>(0)
        let gate = LockedBox<Bool>(false)
        client.documentManager.onPersistFencedForTest = { (_: String) in
            let first = reached.withValue { value -> Bool in
                value += 1
                return value == 1
            }
            guard first else { return }
            while !gate.value { try? await Task.sleep(nanoseconds: 5_000_000) }
        }

        write(old, "sealed/title", "the old epoch")
        try await waitFor("the old document's persist to pass the fence") {
            reached.value > 0
        }

        // The move, with that persist still holding its turn. It cannot be
        // awaited here: its own persist queues behind the paused one, which is
        // the whole point — so it runs as a task and the gate opens under it.
        let fresh = YDocument()
        write(fresh, "carried/title", "the new epoch")
        let swapped = LockedBox<Bool>(false)
        Task {
            await client.documentManager.replaceOpenDocument(
                documentId: documentId, with: fresh
            )
            swapped.value = true
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(
            swapped.value,
            "the swap's own persist waits for the turn the paused one holds"
        )

        gate.value = true
        try await waitFor("the swap to finish", timeout: 10) { swapped.value }
        try await Task.sleep(nanoseconds: 300_000_000)

        let stored = try await storedOverlayEventually(client, documentId)
        XCTAssertEqual(
            stored.value(model: "Note", key: "carried/title"), .string("the new epoch"),
            "the fresh overlay is the last thing written, whatever the "
            + "interleaving: the stale persist's save is ordered BEFORE the "
            + "swap's rather than racing it"
        )
        XCTAssertNil(
            stored.value(model: "Note", key: "sealed/title"),
            "and the sealed overlay is not underneath it"
        )
    }

    // MARK: - Behavior 9 — ordinary documents

    func testAFormat1DocumentNeverSeesAGenerationBump() async throws {
        let client = await makeClient(path: newDatabasePath())
        defer { Task { await client.destroy() } }
        let documentId = "swap-ordinary"
        let doc = try await openLocal(client, documentId, format: 1)

        XCTAssertEqual(
            client.documentManager.persistGenerationForTest(documentId), 0,
            "an ordinary document's open bumps nothing"
        )

        write(doc, "r1/title", "ordinary")

        // And the persist still lands, which is the claim that matters: the
        // fence must be invisible to a format-1 document rather than merely
        // unbumped. Polled rather than slept on — the persist is debounced by
        // 250 ms and then saves, so a fixed wait is a guess about a machine.
        let ordinary = try await storedOverlayEventually(client, documentId)
        XCTAssertEqual(
            ordinary.value(model: "Note", key: "r1/title"), .string("ordinary"),
            "an ordinary document's persist still lands"
        )
        XCTAssertEqual(
            client.documentManager.persistGenerationForTest(documentId), 0,
            "nor does a write, nor the persist it schedules"
        )

        await client.documentManager.closeDocument(documentId: documentId)
        XCTAssertEqual(
            client.documentManager.persistGenerationForTest(documentId), 0,
            "nor does a close"
        )
    }
}
