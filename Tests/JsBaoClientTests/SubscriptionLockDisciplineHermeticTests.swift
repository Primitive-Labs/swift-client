import XCTest
@testable import JsBaoClient
import YSwift

/// A `YSubscription` is never cancelled while `DocumentManager.lock` is held
/// (issue #3200, phase 2 — the F3 finding and its close-path sibling).
///
/// `YSubscription.cancel` (and its `deinit`) takes the owning document's FFI
/// lock, while the update callback takes `DocumentManager.lock` *under* that
/// FFI lock. Cancelling under the manager lock therefore inverts the two: a
/// thread editing the document at that moment deadlocks the process. The entry
/// is swapped or removed under the lock; the cancel happens after it is
/// released — at registration, in `closeDocument`, and in `removeOpenDoc`.
///
/// Two things make these tests usable as evidence rather than as a hang:
///
/// 1. **The interleaving is driven, not hoped for.** The update callback yrs
///    runs *inside* the document's FFI lock parks there for a fixed window
///    (`CallbackWedge`), and the test only cancels once it is in. Against the
///    inversion the deadlock is then certain rather than probabilistic; with
///    the cancel outside the lock the operation simply waits out the window.
/// 2. **A regression fails this test instead of wedging the suite.** Every
///    cancelling operation runs under a deadline, and once one is missed the
///    test touches nothing that would block on either lock again: the wedged
///    writer is never joined, and the manager and the document are handed to
///    `Quarantine` so their deinit never runs. Before that, this file's own
///    regression took `swift test --filter HermeticTests` past its timeout
///    with no failure reported — which reads as a pass, not a red.
final class SubscriptionLockDisciplineHermeticTests: XCTestCase {

    // MARK: - Fixtures

    /// A one-shot, waitable flag.
    private final class Signal: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var fired = false

        func signal() {
            let first: Bool = lock.withLock {
                guard !fired else { return false }
                fired = true
                return true
            }
            if first { semaphore.signal() }
        }

        @discardableResult
        func wait(_ timeout: TimeInterval) -> Bool {
            semaphore.wait(timeout: .now() + timeout) == .success
        }

        var isSignalled: Bool { lock.withLock { fired } }
    }

    /// Objects a wedged test must never release. On a regression one thread is
    /// parked inside the document's FFI lock and another owns
    /// `DocumentManager.lock` for good, so deallocating either object would
    /// block *teardown* — turning a failed test into a hung suite.
    private final class Quarantine: @unchecked Sendable {
        static let shared = Quarantine()
        private let lock = NSLock()
        private var held: [AnyObject] = []
        func keep(_ objects: AnyObject...) {
            lock.withLock { held.append(contentsOf: objects) }
        }
    }

    /// Parks the first update callback inside the document's FFI lock for a
    /// fixed window — the window a cancel has to be caught in — and counts
    /// every update after that.
    private final class CallbackWedge: @unchecked Sendable {
        let entered = Signal()
        private let hold: TimeInterval
        private let lock = NSLock()
        private var parked = false
        private var seen: [String] = []

        init(hold: TimeInterval) { self.hold = hold }

        func handle(_ documentId: String) {
            let shouldPark: Bool = lock.withLock {
                seen.append(documentId)
                guard !parked else { return false }
                parked = true
                return true
            }
            guard shouldPark else { return }
            entered.signal()
            Thread.sleep(forTimeInterval: hold)
        }

        func count(_ documentId: String) -> Int {
            lock.withLock { seen.filter { $0 == documentId }.count }
        }
    }

    /// Writes to a retained `YDocument` off the test thread, so the write can
    /// still be inside the FFI lock while the test cancels a subscription.
    private final class BackgroundWriter: @unchecked Sendable {
        private let doc: YDocument
        private let queue = DispatchQueue(label: "subscription-lock-writer")
        private let idle = Signal()

        init(_ doc: YDocument) { self.doc = doc }

        func write(_ key: String) {
            queue.async { [self] in
                let map: YMap<String> = doc.getOrCreateMap(named: "wedge")
                doc.transactSync { txn in map.updateValue(key, forKey: key, transaction: txn) }
                idle.signal()
            }
        }

        /// Bounded on purpose: against the inversion this thread never leaves
        /// the FFI lock, and joining it would hang the suite.
        @discardableResult
        func waitForIdle(_ timeout: TimeInterval) -> Bool { idle.wait(timeout) }
    }

    private func makeManager(_ appId: String) -> DocumentManager {
        let manager = DocumentManager(logger: Logger(level: .none, scope: "test"))
        manager.appId = appId
        manager.userId = "lock-discipline-user"
        return manager
    }

    private let localOpen = OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)

    /// How long the parked update callback holds the document's FFI lock. Long
    /// enough that the cancelling operation is certain to run inside it; short
    /// enough that a healthy cancel just waits it out.
    private let wedgeHold: TimeInterval = 3.0

    /// Runs `work` with a hard deadline, and reports whether it finished. A
    /// lock inversion shows up as `false` — never as a blocked test thread.
    private func completes(
        within seconds: TimeInterval,
        _ work: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let done = Signal()
        Task.detached {
            await work()
            done.signal()
        }
        let deadline = Date().addingTimeInterval(seconds)
        while !done.isSignalled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return done.isSignalled
    }

    // MARK: - Behavior 14: re-registering an observer while the old document is edited

    func testReopeningAnIdWhoseSubscriptionSurvivedEvictAllDoesNotDeadlock() async throws {
        let manager = makeManager("lock-discipline-reopen")
        let documentId = "reopen-wedge-doc"
        let wedge = CallbackWedge(hold: wedgeHold)
        manager.onLocalUpdate = { docId, _ in wedge.handle(docId) }

        let first = try await manager.openDocument(documentId: documentId, options: localOpen)

        // `evictAllLocalData` deliberately keeps `updateSubscriptions`, so the
        // reopen below has a prior entry to displace — the case where a
        // cancel-under-lock meets a live FFI transaction.
        await manager.evictAllLocalData()

        let writer = BackgroundWriter(first)
        writer.write("wedged")
        XCTAssertTrue(
            wedge.entered.wait(10),
            "precondition: an update callback is parked inside the old document's FFI lock"
        )

        let openOptions = localOpen
        let completed = await completes(within: 20) {
            _ = try? await manager.openDocument(documentId: documentId, options: openOptions)
        }
        guard completed else {
            Quarantine.shared.keep(manager, first, writer)
            return XCTFail(
                "the reopen deadlocked: the displaced subscription was cancelled while DocumentManager.lock was held"
            )
        }
        writer.waitForIdle(10)

        let reopened = try XCTUnwrap(
            manager.getDocument(documentId),
            "the reopen must have completed rather than deadlocked"
        )
        XCTAssertFalse(reopened === first, "the reopen builds a fresh YDocument")

        // Only the new observer forwards: the displaced subscription was
        // cancelled (after the lock was released), so the retained old document
        // no longer reaches the funnel.
        let before = wedge.count(documentId)
        let oldMap: YMap<String> = first.getOrCreateMap(named: "wedge")
        first.transactSync { txn in
            oldMap.updateValue("after the reopen", forKey: "old", transaction: txn)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            wedge.count(documentId), before,
            "the displaced subscription must be cancelled — a retained old document must not double-forward"
        )

        let newMap: YMap<String> = reopened.getOrCreateMap(named: "wedge")
        reopened.transactSync { txn in
            newMap.updateValue("through the new observer", forKey: "new", transaction: txn)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            wedge.count(documentId), before + 1,
            "the reopened document forwards through its own observer, exactly once"
        )

        await manager.closeDocument(documentId: documentId)
    }

    // MARK: - Behavior 15: closing (and cleaning up) while the document is edited

    func testClosingADocumentWhileItsUpdateCallbackIsRunningDoesNotDeadlock() async throws {
        let manager = makeManager("lock-discipline-close")
        let documentId = "close-wedge-doc"
        let wedge = CallbackWedge(hold: wedgeHold)
        manager.onLocalUpdate = { docId, _ in wedge.handle(docId) }

        let doc = try await manager.openDocument(documentId: documentId, options: localOpen)
        let writer = BackgroundWriter(doc)
        writer.write("wedged")
        XCTAssertTrue(
            wedge.entered.wait(10),
            "precondition: an update callback is parked inside the document's FFI lock"
        )

        // `evictLocal` is what makes this reach the cancel while the writer's
        // transaction is still live: an ordinary close flushes a persist first,
        // and that flush waits for the document's FFI lock — so by the time it
        // reaches the teardown the parked callback has long since left, and the
        // inversion is never exercised. The evicting close skips the flush and
        // goes straight to the critical section, which is where the cancel is.
        let completed = await completes(within: 20) {
            await manager.closeDocument(
                documentId: documentId,
                options: CloseDocumentOptions(evictLocal: true)
            )
        }
        guard completed else {
            Quarantine.shared.keep(manager, doc, writer)
            return XCTFail(
                "closeDocument deadlocked: it cancelled the subscription while holding DocumentManager.lock"
            )
        }
        writer.waitForIdle(10)

        XCTAssertFalse(
            manager.isOpen(documentId),
            "the close must have completed rather than deadlocked"
        )
    }

    func testRemovingAHalfOpenDocumentWhileItsUpdateCallbackIsRunningDoesNotDeadlock() async throws {
        let manager = makeManager("lock-discipline-remove")
        let documentId = "remove-wedge-doc"
        let wedge = CallbackWedge(hold: wedgeHold)
        manager.onLocalUpdate = { docId, _ in wedge.handle(docId) }

        let doc = try await manager.openDocument(documentId: documentId, options: localOpen)
        let writer = BackgroundWriter(doc)
        writer.write("wedged")
        XCTAssertTrue(
            wedge.entered.wait(10),
            "precondition: an update callback is parked inside the document's FFI lock"
        )

        let completed = await completes(within: 20) {
            manager.removeOpenDoc(documentId)
        }
        guard completed else {
            Quarantine.shared.keep(manager, doc, writer)
            return XCTFail(
                "removeOpenDoc deadlocked: the open-failure cleanup cancelled the subscription under DocumentManager.lock"
            )
        }
        writer.waitForIdle(10)

        XCTAssertFalse(
            manager.isOpen(documentId),
            "the open-failure cleanup must have completed rather than deadlocked"
        )
    }
}
