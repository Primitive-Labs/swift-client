import XCTest
@testable import JsBaoClient

/// Unit tests for `BlobManager`'s thread safety after the
/// `NSLock.lock()/unlock()` → scoped `withLock` conversion (issue #1910,
/// Phase 2). These are server-free: the HTTP transport (`makeRawRequest`) is
/// stubbed, so the tests exercise only the two lock-guarded structures —
/// the upload queue (`uploadQueue` + `activeUploads`) and the memory cache
/// (`memoryBlobs`) — under concurrent access, asserting no lost/duplicated
/// state and no deadlock.
final class BlobManagerTests: XCTestCase {

    /// Local error for the stubbed transport's failure path.
    private struct StubTransportError: Error {}

    private func makeManager() -> BlobManager {
        BlobManager(logger: Logger(level: .error, scope: "test"), uploadConcurrency: 4)
    }

    /// Concurrent `uploadFromSource` calls whose immediate upload always fails
    /// each enqueue exactly one retry task. The invariant is queue conservation:
    /// every failed upload is tracked once — none lost or duplicated — even
    /// while the queue processor mutates `uploadQueue`/`activeUploads` on its
    /// own Task under the same lock.
    func testConcurrentQueuedUploadsConserveQueue() async throws {
        let manager = makeManager()
        // Transport always fails → uploadImmediate throws → task is queued.
        manager.makeRawRequest = { _, _, _, _ in throw StubTransportError() }

        let count = 100
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    let data = "payload-\(i)".data(using: .utf8)!
                    // Each call rethrows the transport error after queueing;
                    // swallow it — the queueing side effect is what we assert.
                    _ = try? await manager.uploadFromSource(documentId: "doc", source: data)
                }
            }
            await group.waitForAll()
        }

        // Every failed upload must be queued exactly once. A failing transport
        // never removes a task, so the count is deterministic.
        XCTAssertEqual(manager.listUploads().count, count, "every queued upload must survive concurrent enqueue + processing — no lost or duplicated task")
    }

    /// Race the synchronous queue-management ops (`pauseAll`/`resumeAll`/
    /// `pauseUpload`/`resumeUpload`/`listUploads`/`setUploadConcurrency`) from
    /// many threads at once over a pre-seeded queue. The invariant is liveness
    /// (no lock-ordering deadlock) plus conservation — none of these ops
    /// removes a task, so the queue size is unchanged. Wrapped in the shared
    /// deadlock watchdog so a regression fails the test rather than hanging.
    func testConcurrentPauseResumeListIsDeadlockFree() async throws {
        let manager = makeManager()
        manager.makeRawRequest = { _, _, _, _ in throw StubTransportError() }

        // Seed the queue deterministically: each failing upload leaves one task.
        let seeded = 50
        var blobIds: [String] = []
        for i in 0..<seeded {
            let data = "seed-\(i)".data(using: .utf8)!
            do {
                _ = try await manager.uploadFromSource(documentId: "doc", source: data)
            } catch {
                // Recover the queued blobId from the snapshot after the throw.
            }
        }
        blobIds = manager.listUploads().map { $0.blobId }
        XCTAssertEqual(blobIds.count, seeded, "seeding must queue one task per failed upload")

        assertCompletes(within: 5, "concurrent BlobManager queue-management") {
            DispatchQueue.concurrentPerform(iterations: 400) { i in
                switch i % 6 {
                case 0: manager.pauseAll(documentId: "doc")
                case 1: manager.resumeAll(documentId: "doc")
                case 2: _ = manager.listUploads()
                case 3: _ = manager.pauseUpload(blobIds[i % blobIds.count])
                case 4: _ = manager.resumeUpload(blobIds[i % blobIds.count])
                default: manager.setUploadConcurrency((i % 4) + 1)
                }
            }
        }

        // None of the exercised ops removes a task, so the queue is conserved.
        XCTAssertEqual(manager.listUploads().count, seeded, "pause/resume/list must never drop a queued task")
    }

    /// Concurrent successful uploads each write the memory cache once. The
    /// invariant is cache conservation: every uploaded blob is retrievable
    /// from the local cache afterwards with its exact bytes (a cache hit, no
    /// network), proving no write was lost under concurrent `memoryBlobs`
    /// mutation.
    func testConcurrentUploadsPopulateCacheWithoutLoss() async throws {
        let manager = makeManager()
        // Transport always succeeds (2xx) → uploadImmediate returns, task is
        // never queued, and the pre-upload cache write survives.
        manager.makeRawRequest = { _, _, _, _ in (Data(), 200) }

        let count = 100
        var results: [(blobId: String, data: Data)] = []
        try await withThrowingTaskGroup(of: (String, Data).self) { group in
            for i in 0..<count {
                group.addTask {
                    let data = "cache-payload-\(i)".data(using: .utf8)!
                    let result = try await manager.uploadFromSource(documentId: "doc", source: data)
                    return (result.blobId, data)
                }
            }
            for try await pair in group {
                results.append(pair)
            }
        }

        XCTAssertEqual(results.count, count, "every concurrent upload must succeed")
        XCTAssertTrue(manager.listUploads().isEmpty, "successful uploads are never queued")

        // Each blob must round-trip from the cache with its exact bytes. `read`
        // defaults to the inline disposition — the same key `uploadFromSource`
        // wrote — so this is a pure cache hit (no transport call).
        for (blobId, data) in results {
            let cached = try await manager.read(documentId: "doc", blobId: blobId)
            XCTAssertEqual(cached, data, "cached bytes for \(blobId) must match the uploaded payload")
        }
    }
}
