import XCTest
@testable import JsBaoClient
import YSwift

/// Server-free unit tests for `DocumentManager.openDocument(...)` single-flight
/// coalescing, added with the `NSLock.lock()/unlock()` → scoped `withLock`
/// conversion (issue #1910, Phase 6 / `DocumentManager`).
///
/// `openDocument` coalesces concurrent opens for the same `documentId` through
/// the `pendingOpens` table so every caller receives the SAME `YDocument`
/// instance (`===`). The `withLock` conversion moved the check-open /
/// check-in-flight / claim-the-slot decision into a single atomic `withLock`
/// returning an `OpenOutcome` enum, with the trailing `await task.value`
/// running OUTSIDE the lock. This is the exact hazard the source comment warns
/// about: without that atomicity two callers could both miss `pendingOpens`
/// and each construct a duplicate `YDocument`, the second insert clobbering the
/// first and orphaning the loser's observer wiring.
///
/// The server-dependent `DocumentManagerRaceTests` asserts the same invariant
/// through the full `JsBaoClient` + live WS stack; this suite proves the
/// coalescing directly against a `DocumentManager` with no network, so it runs
/// in the isolated Swift-only environment. `openDocument` reaches the full
/// open lifecycle (sync protocol, observer registration) without a server when
/// `enableNetworkSync: false` — the network sync lives one layer up in
/// `JsBaoClient`, not in `DocumentManager.openDocument`.
final class DocumentManagerCoalescingTests: XCTestCase {

    /// Resume the awaiting continuation exactly once (timeout vs. body race).
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Bool, Never>?
        init(_ c: CheckedContinuation<Bool, Never>) { cont = c }
        func resume(_ value: Bool) {
            let taken: CheckedContinuation<Bool, Never>? = lock.withLock {
                let c = cont; cont = nil; return c
            }
            taken?.resume(returning: value)
        }
    }

    /// Fails (rather than hanging the suite) if `body` does not finish within
    /// `timeout`. A caller stranded by a broken coalescing split would never
    /// return, hanging `withTaskGroup` forever; the timeout resumes and the
    /// stuck task is leaked — acceptable, it only happens on a genuine
    /// regression (mirrors `OnlineHandoffCoalescingTests.assertAsyncCompletes`).
    private func assertAsyncCompletes(
        within timeout: TimeInterval = 8,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: @escaping @Sendable () async -> Void
    ) async {
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = ResumeOnce(continuation)
            let timer = DispatchWorkItem { gate.resume(false) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            Task {
                await body()
                timer.cancel()
                gate.resume(true)
            }
        }
        if !finished {
            XCTFail("Timed out after \(timeout)s waiting for: \(description)", file: file, line: line)
        }
    }

    private func makeManager() -> DocumentManager {
        let mgr = DocumentManager(logger: Logger(level: .none, scope: "coalesce-test"))
        mgr.appId = "test-app"
        mgr.userId = "test-user"
        return mgr
    }

    private func localOptions() -> OpenDocumentOptions {
        OpenDocumentOptions(
            waitForLoad: .localIfAvailableElseNetwork,
            enableNetworkSync: false
        )
    }

    /// N concurrent `openDocument(id)` calls for the same, not-yet-open id must
    /// all resolve to the SAME `YDocument` instance. A broken coalescer would
    /// let two callers each construct their own doc, so at least one returned
    /// instance would differ from the canonical one. Wrapped in the async
    /// watchdog so a stranded coalesced caller fails rather than hangs.
    func testConcurrentOpenDocumentCoalescesToSingleInstance() async throws {
        let mgr = makeManager()
        let docId = "coalesce-\(UUID().uuidString.prefix(8))"
        let n = 50

        var instances: [YDocument] = []
        await assertAsyncCompletes(within: 8, "50 concurrent openDocument callers all resolve") {
            let collected: [YDocument] = await withThrowingTaskGroup(of: YDocument.self) { group in
                for _ in 0..<n {
                    group.addTask {
                        try await mgr.openDocument(documentId: docId, options: self.localOptions())
                    }
                }
                var docs: [YDocument] = []
                // `try?` inside the collector: a genuine open failure surfaces
                // below as a short `instances` count, not a swallowed hang.
                while let next = try? await group.next() {
                    docs.append(next)
                }
                return docs
            }
            instances = collected
        }

        XCTAssertEqual(
            instances.count, n,
            "every concurrent openDocument caller should resolve to a YDocument"
        )
        let canonical = instances[0]
        for (i, doc) in instances.enumerated() {
            XCTAssertTrue(
                doc === canonical,
                "openDocument caller #\(i) returned a different YDocument than #0 — " +
                "concurrent opens for the same id must coalesce to a single instance."
            )
        }

        // Exactly one canonical doc is registered; the coalescing slot is
        // cleaned up after the in-flight open completes.
        XCTAssertEqual(mgr.listOpenDocuments(), [docId])
        await mgr.destroy()
    }

    /// Back-to-back opens on the same id return the same instance: the second
    /// call hits the fast path (`openDocs[id]` already populated) rather than
    /// constructing a fresh doc. Deterministic even without true parallelism —
    /// catches the "second insert clobbered the first" tail of the race.
    func testSequentialOpenDocumentReturnsCachedInstance() async throws {
        let mgr = makeManager()
        let docId = "cached-\(UUID().uuidString.prefix(8))"

        let first = try await mgr.openDocument(documentId: docId, options: localOptions())
        let second = try await mgr.openDocument(documentId: docId, options: localOptions())

        XCTAssertTrue(
            first === second,
            "second openDocument(\(docId)) must return the cached YDocument instance"
        )
        await mgr.destroy()
    }
}
