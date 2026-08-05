import XCTest
@testable import JsBaoClient

/// Regression tests for issue #2004.
///
/// `JsBaoClient.queueOutboundUpdate` appended the update to `pendingUpdates` and
/// scheduled the debounce `Task` under `lock`, then marked the document unsynced
/// *after* the lock was released. With `SyncConfig(outboundDebounceMs: 0)` the
/// scheduled flush can run to completion inside that window: it removes the
/// pending update, sends it, and clears the unsynced flag — and only then does
/// the late `markUnsyncedLocalChanges(_, true)` run, setting the flag back with
/// nothing pending left to ever clear it. The document stays flagged unsynced
/// forever, so `documents.evict` / `evictAll` keep rejecting it without `force`
/// even though the write reached the server.
///
/// The fix marks the document unsynced *before* the `lock.withLock` block, so the
/// flag is set before the flush task can exist.
///
/// Server-free: the client is built with unreachable URLs and never connects; the
/// outbound send is intercepted by replacing `DocumentManager.sendWebSocketMessage`.
final class OutboundUnsyncedFlagRaceTests: XCTestCase {

    /// A client that never talks to a server: no `connect()`, in-memory storage,
    /// and zero outbound debounce so the flush races the queue call.
    private func makeZeroDebounceClient() -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "outbound-unsynced-race-test",
            offline: true,
            logLevel: .none,
            storageConfig: .memory,
            sync: SyncConfig(outboundDebounceMs: 0),
            autoNetwork: false
        ))
    }

    /// Runs `queueOutboundUpdate` off the cooperative thread pool: the test holds
    /// that thread inside the `onOutboundQueuedForTest` hook, and blocking a
    /// cooperative thread could starve the flush task it is waiting for.
    private func queueOutboundUpdateOffPool(
        client: JsBaoClient,
        documentId: String,
        update: [UInt8]
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                client.queueOutboundUpdate(documentId: documentId, update: update)
                continuation.resume()
            }
        }
    }

    /// Drives the exact #2004 interleaving deterministically: the tail of
    /// `queueOutboundUpdate` is held until the zero-debounce flush has sent the
    /// update and cleared the unsynced flag. Once the call returns, the document
    /// must not be flagged unsynced — its only write already reached the socket,
    /// and nothing is left pending that could ever clear a late mark.
    ///
    /// Pre-fix this fails: the mark ran after the held tail resumed, so the flag
    /// was set with an empty `pendingUpdates` behind it.
    func testFlushCompletingBeforeQueueReturns_leavesDocumentSynced() async throws {
        let client = makeZeroDebounceClient()
        let documentManager = client.documentManager
        let documentId = "unsynced-ordering-doc"

        let sent = DispatchSemaphore(value: 0)
        documentManager.sendWebSocketMessage = { _ in sent.signal() }

        client.onOutboundQueuedForTest = { _ in
            // Hold here until the flush has sent the update, then give it a
            // moment to finish clearing the flag. This is the window the bug
            // needed: everything the flush does completes before the queue call
            // returns.
            XCTAssertEqual(sent.wait(timeout: .now() + 5), .success, "flush never sent the update")
            Thread.sleep(forTimeInterval: 0.2)
        }

        await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [1, 2, 3])

        XCTAssertFalse(
            documentManager.hasUnsyncedLocalChanges(documentId),
            "the document is still flagged unsynced after its only queued update was sent — "
                + "the unsynced mark ran after the zero-debounce flush had already cleared the "
                + "flag, leaving nothing pending to clear it again and `documents.evict` "
                + "rejecting the document indefinitely (issue #2004)"
        )

        await client.destroy()
    }

    /// The mark must be in place before the update can be sent, so no observer of
    /// an in-flight write ever sees the document as fully synced. Checked from
    /// inside the send closure, which runs after the update has already left
    /// `pendingUpdates`.
    func testDocumentIsFlaggedUnsyncedWhileTheUpdateIsBeingSent() async throws {
        let client = makeZeroDebounceClient()
        let documentManager = client.documentManager
        let documentId = "unsynced-during-send-doc"

        let observed = expectation(description: "send observed the unsynced flag")
        documentManager.sendWebSocketMessage = { [weak documentManager] _ in
            XCTAssertEqual(documentManager?.hasUnsyncedLocalChanges(documentId), true,
                           "the document must already be flagged unsynced when its update is sent")
            observed.fulfill()
        }

        await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [1, 2, 3])
        await fulfillment(of: [observed], timeout: 5)

        // And once the send has landed and nothing is pending, the flag clears.
        try await eventually(timeout: 5, description: "unsynced flag cleared after send") {
            !documentManager.hasUnsyncedLocalChanges(documentId)
        }

        await client.destroy()
    }

    /// The opposite interleaving, flagged by the Codex review of PR #2104:
    /// an edit is queued while a *previous* flush is already in flight, sitting
    /// between its `pendingUpdates.removeValue` and its final "everything
    /// drained" check.
    ///
    /// The new edit marks the document unsynced before its update reaches
    /// `pendingUpdates`. With only a `pendingUpdates`-emptiness check the older
    /// flush sees an empty queue in that window and clears the flag the new edit
    /// just set — leaving `hasUnsyncedLocalChanges` false with an unsent local
    /// edit behind it, so `documents.evict` would silently discard it (and a
    /// later send failure would leave the flag false indefinitely).
    ///
    /// The fix tracks enqueues that are mid-flight (`outboundEnqueuesInProgress`)
    /// and refuses the clear while one is registered, so the flag stays true.
    func testEditQueuedDuringAnInFlightFlush_keepsDocumentFlaggedUnsynced() async throws {
        let client = makeZeroDebounceClient()
        let documentManager = client.documentManager
        let documentId = "unsynced-inflight-flush-doc"

        // Hold the first send, which runs after the flush has already drained
        // `pendingUpdates` and before it decides whether to clear the flag.
        let firstSendReached = DispatchSemaphore(value: 0)
        let releaseFirstSend = DispatchSemaphore(value: 0)
        let firstSend = OneShotGate()
        documentManager.sendWebSocketMessage = { _ in
            if firstSend.claim() {
                firstSendReached.signal()
                XCTAssertEqual(releaseFirstSend.wait(timeout: .now() + 10), .success,
                               "the test never released the held send")
            }
        }

        // Hold the *second* edit right after it marks the document unsynced,
        // before its update lands in `pendingUpdates`.
        let secondMarkReached = DispatchSemaphore(value: 0)
        let releaseSecondMark = DispatchSemaphore(value: 0)
        let trueMarks = ThreadSafeBox(0)
        documentManager.onMarkUnsyncedForTest = { doc, value in
            guard doc == documentId, value else { return }
            var marks = 0
            trueMarks.mutate {
                $0 += 1
                marks = $0
            }
            guard marks == 2 else { return }
            secondMarkReached.signal()
            XCTAssertEqual(releaseSecondMark.wait(timeout: .now() + 10), .success,
                           "the test never released the held mark")
        }

        let flushFinished = DispatchSemaphore(value: 0)
        client.onOutboundFlushedForTest = { _ in flushFinished.signal() }

        // 1. First edit. Its zero-debounce flush drains the queue and blocks in
        //    the send — the window this test is about.
        await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [1, 2, 3])
        XCTAssertEqual(firstSendReached.wait(timeout: .now() + 5), .success,
                       "the first flush never reached its send")

        // 2. Second edit, on another thread, stalled between its unsynced mark
        //    and its insert into `pendingUpdates`.
        DispatchQueue.global().async {
            client.queueOutboundUpdate(documentId: documentId, update: [4, 5, 6])
        }
        XCTAssertEqual(secondMarkReached.wait(timeout: .now() + 5), .success,
                       "the second edit never marked the document unsynced")

        // 3. Let the in-flight flush run its clear check inside that window.
        releaseFirstSend.signal()
        XCTAssertEqual(flushFinished.wait(timeout: .now() + 5), .success,
                       "the first flush never completed")

        // 4. The second edit exists and has reached neither the queue nor the
        //    socket. Reporting the document as synced here is what lets
        //    `documents.evict` discard it.
        XCTAssertTrue(
            documentManager.hasUnsyncedLocalChanges(documentId),
            "the document reports no unsynced local changes while an edit is mid-enqueue — "
                + "the in-flight flush cleared the flag that edit had just set, so "
                + "`documents.evict` would discard an unsent local edit (PR #2104 review)"
        )

        // 5. Release everything; the second edit's own flush drains it and the
        //    flag settles clear.
        releaseSecondMark.signal()
        try await eventually(timeout: 5, description: "unsynced flag cleared once both edits drained") {
            !documentManager.hasUnsyncedLocalChanges(documentId)
        }

        documentManager.onMarkUnsyncedForTest = nil
        await client.destroy()
    }

    /// The flag's normal lifecycle is unchanged by the reordering: a failing send
    /// must leave the document flagged unsynced so the evict guard keeps
    /// protecting it.
    func testFailedSend_leavesDocumentFlaggedUnsynced() async throws {
        let client = makeZeroDebounceClient()
        let documentManager = client.documentManager
        let documentId = "unsynced-failed-send-doc"

        struct SendFailure: Error {}
        let attempted = expectation(description: "send attempted")
        documentManager.sendWebSocketMessage = { _ in
            attempted.fulfill()
            throw SendFailure()
        }

        await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [1, 2, 3])
        await fulfillment(of: [attempted], timeout: 5)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(
            documentManager.hasUnsyncedLocalChanges(documentId),
            "a document whose update never reached the socket must stay flagged unsynced"
        )

        await client.destroy()
    }

    // MARK: - #2105: overlapping flushes over a drained-but-unsent batch

    /// A client with the shipped 50 ms outbound debounce, for the
    /// "no permanently-stuck flag" check.
    private func makeDefaultDebounceClient() -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "outbound-unsynced-race-test",
            offline: true,
            logLevel: .none,
            storageConfig: .memory,
            sync: SyncConfig(),
            autoNetwork: false
        ))
    }

    /// Behaviors 1 and 4. The issue's exact interleaving: a flush is held
    /// mid-send while a second edit is queued behind it. Pre-fix the second
    /// edit's own flush removed it from `pendingUpdates` and blocked in its own
    /// send, so when the first flush resumed both its guards read "nothing
    /// pending" and it cleared the flag over an unsent edit.
    ///
    /// Post-fix the first flush owns the drain: the second edit stays queued
    /// until the owner confirms its send, so the flag can't clear early — and
    /// each update is still transmitted exactly once.
    func testOverlappingFlush_doesNotClearFlagOverADrainedButUnsentBatch() async throws {
        let client = makeZeroDebounceClient()
        let documentManager = client.documentManager
        let documentId = "unsynced-overlapping-flush-doc"

        let firstSendReached = DispatchSemaphore(value: 0)
        let releaseFirstSend = DispatchSemaphore(value: 0)
        let secondSendReached = DispatchSemaphore(value: 0)
        let releaseSecondSend = DispatchSemaphore(value: 0)
        let sends = ThreadSafeBox<[String]>([])

        documentManager.sendWebSocketMessage = { message in
            var index = 0
            sends.mutate {
                $0.append(outboundUpdateBase64(from: message) ?? "")
                index = $0.count
            }
            if index == 1 {
                firstSendReached.signal()
                XCTAssertEqual(releaseFirstSend.wait(timeout: .now() + 10), .success,
                               "the test never released the first send")
            } else if index == 2 {
                secondSendReached.signal()
                XCTAssertEqual(releaseSecondSend.wait(timeout: .now() + 10), .success,
                               "the test never released the second send")
            }
        }

        // E1 — its zero-debounce flush drains U1 and blocks in the send.
        await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [1, 2, 3])
        XCTAssertEqual(firstSendReached.wait(timeout: .now() + 5), .success,
                       "the first flush never reached its send")

        // E2 — queued while that send is in flight.
        await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [4, 5, 6])

        // The first flush resumes and evaluates its clear guard. U2 has not
        // reached the socket, so the flag must stay set.
        releaseFirstSend.signal()
        XCTAssertEqual(secondSendReached.wait(timeout: .now() + 5), .success,
                       "the second update was never sent")
        // Pre-fix the first flush clears the flag in this window.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(
            documentManager.hasUnsyncedLocalChanges(documentId),
            "the document reports no unsynced local changes while a second edit is drained but "
                + "unsent — an overlapping flush cleared the flag over an in-flight batch, so "
                + "`documents.evict` would discard that edit (#2105)"
        )

        releaseSecondSend.signal()
        try await eventually(timeout: 5, description: "flag cleared once both updates were sent") {
            !documentManager.hasUnsyncedLocalChanges(documentId)
        }

        XCTAssertEqual(
            sends.value,
            [Data([1, 2, 3]).base64EncodedString(), Data([4, 5, 6]).base64EncodedString()],
            "each queued update must be transmitted exactly once, in order"
        )
        XCTAssertFalse(client.isOutboundFlushInProgressForTest(documentId),
                       "flush ownership must be released once the drain completes")

        await client.destroy()
    }

    /// Behavior 2. The same interleaving with the second send failing: the flag
    /// stays set and the update stays queued — it is the only copy of the user's
    /// edit, so dropping it is the data loss this issue is about.
    func testOverlappingFlushWithFailingSend_keepsFlagSetAndRetainsTheUpdate() async throws {
        let client = makeZeroDebounceClient()
        let documentManager = client.documentManager
        let documentId = "unsynced-overlapping-failure-doc"

        struct SendFailure: Error {}
        let firstSendReached = DispatchSemaphore(value: 0)
        let releaseFirstSend = DispatchSemaphore(value: 0)
        let sendCount = ThreadSafeBox(0)

        documentManager.sendWebSocketMessage = { _ in
            var index = 0
            sendCount.mutate {
                $0 += 1
                index = $0
            }
            if index == 1 {
                firstSendReached.signal()
                XCTAssertEqual(releaseFirstSend.wait(timeout: .now() + 10), .success,
                               "the test never released the first send")
                return
            }
            throw SendFailure()
        }

        await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [1, 2, 3])
        XCTAssertEqual(firstSendReached.wait(timeout: .now() + 5), .success,
                       "the first flush never reached its send")
        await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [4, 5, 6])

        releaseFirstSend.signal()
        // Let both the failing send and every flush's clear check run.
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(
            documentManager.hasUnsyncedLocalChanges(documentId),
            "a document whose second edit failed to send must stay flagged unsynced (#2105)"
        )
        XCTAssertEqual(
            client.pendingOutboundUpdateCountForTest(documentId), 1,
            "the update whose send failed must stay queued — it is the only copy of that edit"
        )
        XCTAssertFalse(client.isOutboundFlushInProgressForTest(documentId),
                       "flush ownership must be released after a failed send")

        await client.destroy()
    }

    /// Behavior 3. A failed send is retried by the next flush, ahead of the edit
    /// that triggered it, and the flag clears only once both have landed.
    func testRetainedUpdateIsResentByTheNextFlushBeforeTheFlagClears() async throws {
        let client = makeZeroDebounceClient()
        let documentManager = client.documentManager
        let documentId = "unsynced-retained-resend-doc"

        struct SendFailure: Error {}
        let sends = ThreadSafeBox<[String]>([])
        let firstSend = OneShotGate()
        documentManager.sendWebSocketMessage = { message in
            sends.mutate { $0.append(outboundUpdateBase64(from: message) ?? "") }
            if firstSend.claim() { throw SendFailure() }
        }
        let flushFinished = DispatchSemaphore(value: 0)
        client.onOutboundFlushedForTest = { _ in flushFinished.signal() }

        await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [1, 2, 3])
        XCTAssertEqual(flushFinished.wait(timeout: .now() + 5), .success,
                       "the flush never finished after the failed send")
        XCTAssertEqual(client.pendingOutboundUpdateCountForTest(documentId), 1,
                       "the failed send must leave its update queued")
        XCTAssertTrue(documentManager.hasUnsyncedLocalChanges(documentId))

        // A later edit's flush carries both updates, oldest first.
        await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [4, 5, 6])
        try await eventually(timeout: 5, description: "flag cleared after both updates were sent") {
            !documentManager.hasUnsyncedLocalChanges(documentId)
        }

        let u1 = Data([1, 2, 3]).base64EncodedString()
        let u2 = Data([4, 5, 6]).base64EncodedString()
        XCTAssertEqual(
            sends.value, [u1, u1, u2],
            "the update whose send failed must be re-sent before the flag clears — clearing over "
                + "a dropped edit is the lost-write this issue is about"
        )
        XCTAssertEqual(client.pendingOutboundUpdateCountForTest(documentId), 0)

        await client.destroy()
    }

    /// Behavior 5. `reconcileUnsyncedAfterSync` shares the flush's clear guard,
    /// so a sync completing while a send is in flight must not clear the flag —
    /// pre-fix that batch was invisible to it (the queue read empty).
    func testReconcileDuringAnInFlightSend_doesNotClearTheFlag() async throws {
        let client = makeZeroDebounceClient()
        let documentManager = client.documentManager
        let documentId = "unsynced-reconcile-inflight-doc"

        let sendReached = DispatchSemaphore(value: 0)
        let releaseSend = DispatchSemaphore(value: 0)
        let firstSend = OneShotGate()
        documentManager.sendWebSocketMessage = { _ in
            if firstSend.claim() {
                sendReached.signal()
                XCTAssertEqual(releaseSend.wait(timeout: .now() + 10), .success,
                               "the test never released the send")
            }
        }

        await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [1, 2, 3])
        XCTAssertEqual(sendReached.wait(timeout: .now() + 5), .success,
                       "the flush never reached its send")

        client.reconcileUnsyncedAfterSync(documentId: documentId)
        XCTAssertTrue(
            documentManager.hasUnsyncedLocalChanges(documentId),
            "a sync completing while an update is mid-send must not clear the flag — that update "
                + "has not reached the socket yet (#2105)"
        )

        releaseSend.signal()
        try await eventually(timeout: 5, description: "flag cleared once the send confirmed") {
            !documentManager.hasUnsyncedLocalChanges(documentId)
        }

        await client.destroy()
    }

    /// Behavior 6. The #2004 failure mode must not return in either debounce
    /// configuration: once every queued update has been confirmed sent, the flag
    /// clears — it never sticks.
    func testFlagClearsAfterAllUpdatesAreSent_withZeroAndDefaultDebounce() async throws {
        for (label, client) in [("zero debounce", makeZeroDebounceClient()),
                                ("default debounce", makeDefaultDebounceClient())] {
            let documentManager = client.documentManager
            let documentId = "unsynced-clears-\(label.replacingOccurrences(of: " ", with: "-"))-doc"
            documentManager.sendWebSocketMessage = { _ in }

            await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [1, 2, 3])
            await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [4, 5, 6])

            try await eventually(timeout: 5, description: "flag cleared (\(label))") {
                !documentManager.hasUnsyncedLocalChanges(documentId)
            }
            XCTAssertEqual(client.pendingOutboundUpdateCountForTest(documentId), 0,
                           "queue drained (\(label))")
            XCTAssertFalse(client.isOutboundFlushInProgressForTest(documentId),
                           "flush ownership released (\(label))")

            await client.destroy()
        }
    }

    /// Behavior 7 — the user-visible symptom. `documents.evict` without `force`
    /// must refuse a document whose batch is drained but unsent, and accept it
    /// once the drain confirms.
    func testEvictRefusesWhileABatchIsDrainedButUnsent() async throws {
        let client = makeZeroDebounceClient()
        let documentManager = client.documentManager
        let documentId = "unsynced-evict-guard-doc"

        let firstSendReached = DispatchSemaphore(value: 0)
        let releaseFirstSend = DispatchSemaphore(value: 0)
        let secondSendReached = DispatchSemaphore(value: 0)
        let releaseSecondSend = DispatchSemaphore(value: 0)
        let sendCount = ThreadSafeBox(0)

        documentManager.sendWebSocketMessage = { _ in
            var index = 0
            sendCount.mutate {
                $0 += 1
                index = $0
            }
            if index == 1 {
                firstSendReached.signal()
                XCTAssertEqual(releaseFirstSend.wait(timeout: .now() + 10), .success,
                               "the test never released the first send")
            } else if index == 2 {
                secondSendReached.signal()
                XCTAssertEqual(releaseSecondSend.wait(timeout: .now() + 10), .success,
                               "the test never released the second send")
            }
        }

        await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [1, 2, 3])
        XCTAssertEqual(firstSendReached.wait(timeout: .now() + 5), .success,
                       "the first flush never reached its send")
        await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [4, 5, 6])
        releaseFirstSend.signal()
        XCTAssertEqual(secondSendReached.wait(timeout: .now() + 5), .success,
                       "the second update was never sent")
        try await Task.sleep(nanoseconds: 300_000_000)

        do {
            try await client.documents.evict(documentId: documentId)
            XCTFail("evict discarded a document holding an unsent local edit (#2105)")
        } catch {
            // Expected: unsynced local changes.
        }

        releaseSecondSend.signal()
        try await eventually(timeout: 5, description: "flag cleared once the drain confirmed") {
            !documentManager.hasUnsyncedLocalChanges(documentId)
        }
        try await client.documents.evict(documentId: documentId)

        await client.destroy()
    }

    /// Behavior 10. Retained updates are not left stranded: once a reconnect
    /// resync completes, the retained batch is flushed and the flag clears — the
    /// #1979 behavior still holds now that failed sends stay queued.
    func testRetainedUpdateIsFlushedAfterAReconnectResync() async throws {
        let client = makeZeroDebounceClient()
        let documentManager = client.documentManager
        let documentId = "unsynced-resync-retry-doc"

        struct SendFailure: Error {}
        let online = ThreadSafeBox(false)
        let sends = ThreadSafeBox<[String]>([])
        documentManager.sendWebSocketMessage = { message in
            guard online.value else { throw SendFailure() }
            sends.mutate { $0.append(outboundUpdateBase64(from: message) ?? "") }
        }
        let flushFinished = DispatchSemaphore(value: 0)
        client.onOutboundFlushedForTest = { _ in flushFinished.signal() }

        // Offline edit: the send fails, the update stays queued, flag stays set.
        await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [1, 2, 3])
        XCTAssertEqual(flushFinished.wait(timeout: .now() + 5), .success,
                       "the flush never finished after the failed send")
        XCTAssertEqual(client.pendingOutboundUpdateCountForTest(documentId), 1,
                       "the failed send must leave its update queued")
        XCTAssertTrue(documentManager.hasUnsyncedLocalChanges(documentId))

        // Reconnect: the resync completes and must carry the retained batch out.
        online.mutate { $0 = true }
        documentManager.handleSyncComplete(documentId: documentId)
        client.reconcileUnsyncedAfterSync(documentId: documentId)

        try await eventually(timeout: 5, description: "retained batch flushed after resync") {
            client.pendingOutboundUpdateCountForTest(documentId) == 0
                && !documentManager.hasUnsyncedLocalChanges(documentId)
        }
        XCTAssertEqual(sends.value, [Data([1, 2, 3]).base64EncodedString()],
                       "the retained update must be re-sent when the socket comes back")

        await client.destroy()
    }

    /// The same resync retry, but arriving while a flush already owns the
    /// document and is parked in the send that is about to fail (PR #2396
    /// review). The spawned flush can't claim ownership, so the owner is the only
    /// thing left that can carry the batch — and its failed-send path releases
    /// ownership. If the request were dropped there, the end state would be a
    /// non-empty queue with no owner, no debounce timer, and a healthy socket:
    /// the update would sit unsent until the next local edit, with the document
    /// stuck unsynced and `evict` refusing it.
    func testResyncRetryDuringAFailingSend_stillDrainsTheBatch() async throws {
        let client = makeZeroDebounceClient()
        let documentManager = client.documentManager
        let documentId = "unsynced-resync-during-failing-send-doc"

        struct SendFailure: Error {}
        let sends = ThreadSafeBox<[String]>([])
        let sendReached = DispatchSemaphore(value: 0)
        let releaseSend = DispatchSemaphore(value: 0)
        let firstSend = OneShotGate()
        documentManager.sendWebSocketMessage = { message in
            if firstSend.claim() {
                // The socket died while this send was in flight: park here until
                // the test has fired the resync retry, then fail.
                sendReached.signal()
                XCTAssertEqual(releaseSend.wait(timeout: .now() + 10), .success,
                               "the test never released the send")
                throw SendFailure()
            }
            sends.mutate { $0.append(outboundUpdateBase64(from: message) ?? "") }
        }

        await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [1, 2, 3])
        XCTAssertEqual(sendReached.wait(timeout: .now() + 5), .success,
                       "the flush never reached its send")

        // Reconnect resync completes while the owner is still inside the send.
        documentManager.handleSyncComplete(documentId: documentId)
        client.reconcileUnsyncedAfterSync(documentId: documentId)
        // Give the flush it spawned time to find the document owned and record
        // its request — that is the interleaving under test.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(client.isOutboundFlushInProgressForTest(documentId),
                      "the parked flush must still own the document when the retry arrives")

        releaseSend.signal()

        // No further local edit: the retained batch must drain on the strength of
        // the resync request alone.
        try await eventually(timeout: 5, description: "retained batch drained after the failed send") {
            client.pendingOutboundUpdateCountForTest(documentId) == 0
                && !documentManager.hasUnsyncedLocalChanges(documentId)
        }
        XCTAssertEqual(sends.value, [Data([1, 2, 3]).base64EncodedString()],
                       "the retained update must reach the socket exactly once after the retry")
        XCTAssertFalse(client.isOutboundFlushInProgressForTest(documentId),
                       "flush ownership must be released once the batch drains")

        await client.destroy()
    }

    /// Edge case: `closeDocument` while a send is in flight. The owner must
    /// tolerate its queue disappearing mid-drain — no crash — and must leave no
    /// ownership entry behind, since a leaked one would silently disable every
    /// future flush for that document.
    func testCloseDocumentDuringAnInFlightSend_leavesNoWedgedOwnership() async throws {
        let client = makeZeroDebounceClient()
        let documentManager = client.documentManager
        let documentId = "unsynced-close-during-send-doc"

        let sendReached = DispatchSemaphore(value: 0)
        let releaseSend = DispatchSemaphore(value: 0)
        let firstSend = OneShotGate()
        let sendCount = ThreadSafeBox(0)
        documentManager.sendWebSocketMessage = { _ in
            sendCount.mutate { $0 += 1 }
            if firstSend.claim() {
                sendReached.signal()
                XCTAssertEqual(releaseSend.wait(timeout: .now() + 10), .success,
                               "the test never released the send")
            }
        }

        await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [1, 2, 3])
        XCTAssertEqual(sendReached.wait(timeout: .now() + 5), .success,
                       "the flush never reached its send")

        await client.closeDocument(documentId)
        releaseSend.signal()

        try await eventually(timeout: 5, description: "flush ownership released after close") {
            !client.isOutboundFlushInProgressForTest(documentId)
        }
        XCTAssertEqual(client.pendingOutboundUpdateCountForTest(documentId), 0,
                       "closeDocument drops the queue")

        // A later edit must still flush — a leaked ownership entry would make
        // this send never happen.
        await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [7, 8, 9])
        try await eventually(timeout: 5, description: "a later edit still flushes") {
            sendCount.value == 2
        }

        await client.destroy()
    }

    /// A flush that arrives while another owns the drain returns immediately, so
    /// the owner is the only thing that can carry the edit that triggered it.
    /// An edit queued mid-drain must therefore still reach the socket, and the
    /// flag must still settle clear — a dropped handoff would leave the update
    /// queued with no flush pending.
    func testEditQueuedMidDrain_isCarriedByTheOwningFlush() async throws {
        let client = makeZeroDebounceClient()
        let documentManager = client.documentManager
        let documentId = "unsynced-mid-drain-handoff-doc"

        let sends = ThreadSafeBox<[String]>([])
        let firstSend = OneShotGate()
        documentManager.sendWebSocketMessage = { message in
            sends.mutate { $0.append(outboundUpdateBase64(from: message) ?? "") }
            guard firstSend.claim() else { return }
            // Queue a second edit from inside the first send: its own flush runs
            // while this one owns the drain and returns without draining.
            DispatchQueue.global().async {
                client.queueOutboundUpdate(documentId: documentId, update: [4, 5, 6])
            }
            // `sendWebSocketMessage` is an async closure, so hold the send in
            // flight by suspending rather than blocking the calling thread.
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [1, 2, 3])

        try await eventually(timeout: 5, description: "both updates drained") {
            client.pendingOutboundUpdateCountForTest(documentId) == 0
                && !documentManager.hasUnsyncedLocalChanges(documentId)
        }
        XCTAssertEqual(
            sends.value,
            [Data([1, 2, 3]).base64EncodedString(), Data([4, 5, 6]).base64EncodedString()],
            "an edit queued while a flush owned the drain must still be transmitted, exactly once"
        )

        await client.destroy()
    }

    /// Edge case: ownership is per-document. A held send on one document must
    /// not stall another document's flush.
    func testFlushOwnershipIsPerDocument() async throws {
        let client = makeZeroDebounceClient()
        let documentManager = client.documentManager
        let heldDocumentId = "unsynced-per-doc-held"
        let otherDocumentId = "unsynced-per-doc-other"

        let heldSendReached = DispatchSemaphore(value: 0)
        let releaseHeldSend = DispatchSemaphore(value: 0)
        documentManager.sendWebSocketMessage = { message in
            guard let json = try? JSONSerialization.jsonObject(
                with: Data(message.utf8)) as? [String: Any],
                json["documentId"] as? String == heldDocumentId else { return }
            heldSendReached.signal()
            XCTAssertEqual(releaseHeldSend.wait(timeout: .now() + 10), .success,
                           "the test never released the held send")
        }

        await queueOutboundUpdateOffPool(client: client, documentId: heldDocumentId, update: [1, 2, 3])
        XCTAssertEqual(heldSendReached.wait(timeout: .now() + 5), .success,
                       "the held document's flush never reached its send")

        await queueOutboundUpdateOffPool(client: client, documentId: otherDocumentId, update: [4, 5, 6])
        try await eventually(timeout: 5, description: "the other document drained independently") {
            !documentManager.hasUnsyncedLocalChanges(otherDocumentId)
        }

        releaseHeldSend.signal()
        try await eventually(timeout: 5, description: "the held document drained once released") {
            !documentManager.hasUnsyncedLocalChanges(heldDocumentId)
        }

        await client.destroy()
    }

    /// Close/reopen edge case (Codex review on PR #2396). `closeDocument` drops
    /// the flush-ownership entry while the owner may still be awaiting its send.
    /// If the document is then edited again, a new flush legitimately takes
    /// ownership — and the old flush must not come back and drain that new
    /// owner's queue. Ownership is a token for exactly this reason: the stale
    /// flush sees its token revoked and exits without sending, removing a head,
    /// or releasing the new owner's ownership.
    ///
    /// Pre-fix, the stale flush resumed, peeked the reopened document's queue,
    /// and re-sent the new owner's in-flight update — two owners for one
    /// document, and a duplicate outbound frame.
    func testStaleFlushAfterCloseAndReopen_doesNotDrainTheNewOwnersQueue() async throws {
        let client = makeZeroDebounceClient()
        let documentManager = client.documentManager
        let documentId = "unsynced-close-reopen-stale-flush-doc"

        let sends = ThreadSafeBox<[String]>([])
        let firstSendReached = DispatchSemaphore(value: 0)
        let releaseFirstSend = DispatchSemaphore(value: 0)
        let secondSendReached = DispatchSemaphore(value: 0)
        let releaseSecondSend = DispatchSemaphore(value: 0)
        let sendCount = ThreadSafeBox(0)

        documentManager.sendWebSocketMessage = { message in
            sends.mutate { $0.append(outboundUpdateBase64(from: message) ?? "") }
            var index = 0
            sendCount.mutate {
                $0 += 1
                index = $0
            }
            if index == 1 {
                firstSendReached.signal()
                XCTAssertEqual(releaseFirstSend.wait(timeout: .now() + 10), .success,
                               "the test never released the first send")
            } else if index == 2 {
                secondSendReached.signal()
                XCTAssertEqual(releaseSecondSend.wait(timeout: .now() + 10), .success,
                               "the test never released the second send")
            }
        }

        // The original owner is parked inside its send.
        await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [1, 2, 3])
        XCTAssertEqual(firstSendReached.wait(timeout: .now() + 5), .success,
                       "the first flush never reached its send")

        // Close revokes its ownership; the reopened document's edit takes a new
        // one and parks inside its own send.
        await client.closeDocument(documentId)
        await queueOutboundUpdateOffPool(client: client, documentId: documentId, update: [7, 8, 9])
        XCTAssertEqual(secondSendReached.wait(timeout: .now() + 5), .success,
                       "the reopened document's flush never reached its send")
        XCTAssertTrue(client.isOutboundFlushInProgressForTest(documentId),
                      "the new flush must own the reopened document's drain")

        // Release the stale flush. It must exit without touching the new
        // owner's queue: no third send, and the new owner keeps its ownership.
        releaseFirstSend.signal()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(sendCount.value, 2,
                       "a stale flush re-sent the new owner's update — two owners for one "
                           + "document (#2105 close/reopen window)")
        XCTAssertTrue(client.isOutboundFlushInProgressForTest(documentId),
                      "the stale flush released the new owner's flush ownership")
        XCTAssertEqual(client.pendingOutboundUpdateCountForTest(documentId), 1,
                       "the stale flush consumed the new owner's queued update")

        // The real owner still finishes normally.
        releaseSecondSend.signal()
        try await eventually(timeout: 5, description: "the new owner drained and cleared the flag") {
            client.pendingOutboundUpdateCountForTest(documentId) == 0
                && !documentManager.hasUnsyncedLocalChanges(documentId)
                && !client.isOutboundFlushInProgressForTest(documentId)
        }
        XCTAssertEqual(
            sends.value,
            [Data([1, 2, 3]).base64EncodedString(), Data([7, 8, 9]).base64EncodedString()],
            "each update must reach the socket exactly once across a close/reopen"
        )

        await client.destroy()
    }
}

/// The `update` payload of an intercepted outbound WebSocket frame, so a test
/// can assert exactly which updates reached the socket and in what order.
private func outboundUpdateBase64(from message: String) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any] else {
        return nil
    }
    return json["update"] as? String
}

/// One-shot claim, so only the first caller of a repeatedly-invoked closure
/// takes the "hold here" branch.
private final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
