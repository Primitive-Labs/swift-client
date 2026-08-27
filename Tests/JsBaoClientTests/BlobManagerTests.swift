import XCTest
@testable import JsBaoClient

/// Unit tests for `BlobManager`'s thread safety after the
/// `NSLock.lock()/unlock()` → scoped `withLock` conversion (issue #1910,
/// Phase 2). These are server-free: the HTTP transport (a `RecordingTransport`) is
/// stubbed, so the tests exercise only the two lock-guarded structures —
/// the upload queue (`uploadQueue` + `activeUploads`) and the memory cache
/// (`memoryBlobs`) — under concurrent access, asserting no lost/duplicated
/// state and no deadlock.
final class BlobManagerTests: XCTestCase {

    /// Local error for the stubbed transport's failure path.
    private struct StubTransportError: Error {}

    /// The manager's transport arrives at construction (#2172) — it is an
    /// actor, so there is no post-construction setter to assign it with.
    private func makeManager(transport: (any Transport)? = nil) -> BlobManager {
        BlobManager(
            logger: Logger(level: .error, scope: "test"),
            uploadConcurrency: 4,
            transport: transport
        )
    }

    /// Concurrent `uploadFromSource` calls whose immediate upload always fails
    /// each enqueue exactly one retry task. The invariant is queue conservation:
    /// every failed upload is tracked once — none lost or duplicated — even
    /// while the queue processor mutates `uploadQueue`/`activeUploads` on its
    /// own Task under the same lock.
    func testConcurrentQueuedUploadsConserveQueue() async throws {
        // Transport always fails → uploadImmediate throws → task is queued.
        let manager = makeManager(
            transport: RecordingTransport(responder: { _ in throw StubTransportError() }))

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
        let observed1 = await manager.listUploads().count
        XCTAssertEqual(observed1, count, "every queued upload must survive concurrent enqueue + processing — no lost or duplicated task")
    }

    /// Race the queue-management ops (`pauseAll`/`resumeAll`/`pauseUpload`/
    /// `resumeUpload`/`listUploads`/`setUploadConcurrency`) from many tasks at
    /// once over a pre-seeded queue. The invariant is liveness plus
    /// conservation — none of these ops removes a task, so the queue size is
    /// unchanged. Wrapped in the shared deadlock watchdog so a regression fails
    /// the test rather than hanging.
    ///
    /// They are `async` since the actor conversion (#2172), so the driver is a
    /// task group rather than `DispatchQueue.concurrentPerform`; the failure it
    /// guards changed shape from "a lock-ordering deadlock" to "an isolated
    /// call that never returns", and the watchdog catches both the same way.
    func testConcurrentPauseResumeListIsDeadlockFree() async throws {
        let manager = makeManager(
            transport: RecordingTransport(responder: { _ in throw StubTransportError() }))

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
        blobIds = await manager.listUploads().map { $0.blobId }
        XCTAssertEqual(blobIds.count, seeded, "seeding must queue one task per failed upload")

        let ids = blobIds
        // 15s rather than the watchdog's 3s default: 400 actor hops are
        // milliseconds of work, but this suite also runs under TSan, where
        // instrumentation slows every hop by an order of magnitude. The
        // timeout only has to be far below "hangs the suite".
        await assertCompletesAsync(within: 15, "concurrent BlobManager queue-management") {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<400 {
                    group.addTask {
                        switch i % 6 {
                        case 0: await manager.pauseAll(documentId: "doc")
                        case 1: await manager.resumeAll(documentId: "doc")
                        case 2: _ = await manager.listUploads()
                        case 3: _ = await manager.pauseUpload(ids[i % ids.count])
                        case 4: _ = await manager.resumeUpload(ids[i % ids.count])
                        default: await manager.setUploadConcurrency((i % 4) + 1)
                        }
                    }
                }
                await group.waitForAll()
            }

            // None of the exercised ops removes a task, so the queue is
            // conserved. Read it from *inside* the watchdog: on a genuine
            // regression the actor is still occupied when the timeout fires,
            // and an unguarded read out here would hang the suite the watchdog
            // exists to keep alive.
            let observed = await manager.listUploads().count
            XCTAssertEqual(observed, seeded, "pause/resume/list must never drop a queued task")
        }
    }

    /// Concurrent successful uploads each write the memory cache once. The
    /// invariant is cache conservation: every uploaded blob is retrievable
    /// from the local cache afterwards with its exact bytes (a cache hit, no
    /// network), proving no write was lost under concurrent `memoryBlobs`
    /// mutation.
    func testConcurrentUploadsPopulateCacheWithoutLoss() async throws {
        // Transport always succeeds (2xx) → uploadImmediate returns, task is
        // never queued, and the pre-upload cache write survives.
        let manager = makeManager(transport: RecordingTransport(status: 200))

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
        let observed3 = await manager.listUploads().isEmpty
        XCTAssertTrue(observed3, "successful uploads are never queued")

        // Each blob must round-trip from the cache with its exact bytes. `read`
        // defaults to the inline disposition — the same key `uploadFromSource`
        // wrote — so this is a pure cache hit (no transport call).
        for (blobId, data) in results {
            let cached = try await manager.read(documentId: "doc", blobId: blobId)
            XCTAssertEqual(cached, data, "cached bytes for \(blobId) must match the uploaded payload")
        }
    }
}
