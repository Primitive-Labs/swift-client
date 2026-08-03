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
