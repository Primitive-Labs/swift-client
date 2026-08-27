import Foundation
import XCTest
@testable import JsBaoClient

/// #2721 — the blob `…Async` twins #2172 added are covered only by the
/// *structural* checks in `ActorizedBlobManagerTests`
/// (`testTheSynchronousBlobMutatorsAreRemovedAndOnlyTheTwinsRemain`,
/// `testTheGuidedStubsStillPointAtTheirReplacements`): each asserts that a
/// `func …Async(` exists beside its `unavailable, renamed:` stub, which is a
/// claim about the *shape* of the surface and says nothing about what the twin
/// does. A twin that drops its `documentId:` scope — turning a per-document
/// `pauseAllUploadsAsync(documentId:)` into an app-wide pause — keeps that
/// shape and changes no test outcome.
///
/// So each of the twelve twins is exercised here against a **real**
/// `BlobManager` with a stub transport, over a queue seeded with one upload
/// under `doc-a` and one under `doc-b`. Two documents is what makes the scope
/// observable: a twin that loses or mixes up a `documentId:` touches the other
/// document's upload, which the assertions see. The `pause…` / `resume…` twins
/// additionally assert the returned `Bool`, so discarding it fails too.
///
/// This is cover added *beside* the structural tests, not a replacement — they
/// pin that the twins exist and the stubs still point at them; these pin where
/// the arguments go.
///
/// Server-free (`*HermeticTests`): the manager talks to a stub transport, and
/// the one `JsBaoClient` case points at a closed local port.
final class BlobAsyncTwinForwardingHermeticTests: XCTestCase {

    /// Clients built by a case here, torn down before the next one starts —
    /// `destroy()` awaits several cleanups of its own, so a fire-and-forget
    /// teardown would let storage and connection work outlive the test.
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
    }

    // MARK: - Fixtures

    private struct StubTransportError: Error {}

    /// Fails every attempt, which is what puts an upload on the queue: the
    /// immediate transfer throws, the task is queued for retry, and the twins
    /// have something to list, pause and resume.
    private struct StubTransport: Transport {
        func execute(
            method: HTTPMethod,
            path: String,
            body: Data?,
            options: RequestOptions?
        ) async throws -> TransportResponse {
            throw StubTransportError()
        }
    }

    /// A manager with two queued uploads under two different documents, and the
    /// surfaces the twins live on: the app-wide `DocumentsAPI` and a
    /// `DocumentBlobContext` scoped to `doc-a`.
    private struct Fixture {
        let manager: BlobManager
        let documents: DocumentsAPI
        /// `documents.blobs(documentId: "doc-a")` — the per-document surface.
        let contextA: DocumentBlobContext
        let blobA: String
        let blobB: String
    }

    private static let documentA = "doc-a"
    private static let documentB = "doc-b"

    private func makeFixture() async throws -> Fixture {
        let transport = StubTransport()
        // A 100s backoff parks each queued task well past the end of the test,
        // so the retry rotation cannot pause, resume or drain anything behind
        // the assertions' back.
        let manager = BlobManager(
            logger: Logger(level: .error, scope: "test"),
            backoffBaseMs: 100_000,
            backoffMaxMs: 100_000,
            transport: transport
        )
        for documentId in [Self.documentA, Self.documentB] {
            _ = try? await manager.uploadFromSource(
                documentId: documentId, source: Data("payload-\(documentId)".utf8))
        }
        // Settle before sampling: a freshly queued task is due immediately, so
        // the manager arms a zero-delay timer and runs one retry before parking
        // 100s out. Reading the queue mid-rotation would race that.
        try await waitForAParkedQueueTimer(manager)

        let queued = await manager.listUploads()
        XCTAssertEqual(queued.count, 2, "the fixture must seed one queued upload per document")
        let blobA = try XCTUnwrap(queued.first { $0.documentId == Self.documentA }?.blobId)
        let blobB = try XCTUnwrap(queued.first { $0.documentId == Self.documentB }?.blobId)

        let documents = DocumentsAPI(transport: transport, blobManager: manager)
        return Fixture(
            manager: manager,
            documents: documents,
            contextA: documents.blobs(documentId: Self.documentA),
            blobA: blobA,
            blobB: blobB
        )
    }

    // MARK: - DocumentsAPI — the app-wide twins

    /// `uploadsAsync(documentId:)` must forward the scope to
    /// `listUploads(documentId:)`. A twin that drops it answers a per-document
    /// question with the whole queue.
    func testDocumentsUploadsAsyncForwardsTheDocumentScope() async throws {
        let fixture = try await makeFixture()

        let scoped = await fixture.documents.uploadsAsync(documentId: Self.documentA)
        XCTAssertEqual(scoped.map(\.blobId), [fixture.blobA],
                       "uploadsAsync(documentId:) must list only that document's uploads")

        // The default (`nil`) is the app-wide form, so it must *not* be scoped
        // to anything — a twin that hardcodes a document fails here.
        let appWide = await fixture.documents.uploadsAsync()
        XCTAssertEqual(Set(appWide.map(\.blobId)), [fixture.blobA, fixture.blobB],
                       "uploadsAsync() must list every document's uploads")
    }

    /// `setUploadConcurrencyAsync(_:)` must forward its argument. Two different
    /// values, so a twin that passes a constant fails one of them.
    func testDocumentsSetUploadConcurrencyAsyncForwardsTheValue() async throws {
        let fixture = try await makeFixture()

        await fixture.documents.setUploadConcurrencyAsync(5)
        var applied = await fixture.manager.getUploadConcurrency()
        XCTAssertEqual(applied, 5, "setUploadConcurrencyAsync must forward its argument")

        await fixture.documents.setUploadConcurrencyAsync(7)
        applied = await fixture.manager.getUploadConcurrency()
        XCTAssertEqual(applied, 7, "setUploadConcurrencyAsync must forward the new argument too")
    }

    /// `pauseAllUploadsAsync(documentId:)` scoped to one document must leave the
    /// other document's upload running — the exact mutation the filing repros.
    func testDocumentsPauseAllUploadsAsyncForwardsTheDocumentScope() async throws {
        let fixture = try await makeFixture()

        await fixture.documents.pauseAllUploadsAsync(documentId: Self.documentA)
        var pausedA = await isPaused(fixture, fixture.blobA)
        var pausedB = await isPaused(fixture, fixture.blobB)
        XCTAssertTrue(pausedA, "the scoped document's upload must be paused")
        XCTAssertFalse(pausedB, "another document's upload must not be paused by a scoped call")

        // And the app-wide default really is app-wide.
        await fixture.documents.pauseAllUploadsAsync()
        pausedA = await isPaused(fixture, fixture.blobA)
        pausedB = await isPaused(fixture, fixture.blobB)
        XCTAssertTrue(pausedA && pausedB, "pauseAllUploadsAsync() must pause every document")
    }

    /// The mirror: a scoped resume must not lift another document's pause.
    func testDocumentsResumeAllUploadsAsyncForwardsTheDocumentScope() async throws {
        let fixture = try await makeFixture()
        await fixture.manager.pauseAll()

        await fixture.documents.resumeAllUploadsAsync(documentId: Self.documentA)
        var pausedA = await isPaused(fixture, fixture.blobA)
        var pausedB = await isPaused(fixture, fixture.blobB)
        XCTAssertFalse(pausedA, "the scoped document's upload must be resumed")
        XCTAssertTrue(pausedB, "another document's upload must stay paused")

        await fixture.documents.resumeAllUploadsAsync()
        pausedA = await isPaused(fixture, fixture.blobA)
        pausedB = await isPaused(fixture, fixture.blobB)
        XCTAssertFalse(pausedA || pausedB, "resumeAllUploadsAsync() must resume every document")
    }

    /// `pauseUploadAsync(blobId:documentId:)` forwards **two** arguments, so the
    /// mismatched pair (`doc-a`'s scope, `doc-b`'s blob) is the case that pins
    /// both: it must refuse, and it must say so by returning `false`.
    func testDocumentsPauseUploadAsyncForwardsBothArgumentsAndItsResult() async throws {
        let fixture = try await makeFixture()

        let mismatched = await fixture.documents.pauseUploadAsync(
            blobId: fixture.blobB, documentId: Self.documentA)
        XCTAssertFalse(mismatched, "a blob outside the scoped document must not be pausable")
        var pausedB = await isPaused(fixture, fixture.blobB)
        XCTAssertFalse(pausedB, "the refused call must not have paused anything")

        let matched = await fixture.documents.pauseUploadAsync(
            blobId: fixture.blobB, documentId: Self.documentB)
        XCTAssertTrue(matched, "a matching blob and scope must pause, and report that it did")
        pausedB = await isPaused(fixture, fixture.blobB)
        let pausedA = await isPaused(fixture, fixture.blobA)
        XCTAssertTrue(pausedB, "the named blob must be the one paused")
        XCTAssertFalse(pausedA, "no other document's upload may be touched")
    }

    /// The mirror, over an already-paused queue.
    func testDocumentsResumeUploadAsyncForwardsBothArgumentsAndItsResult() async throws {
        let fixture = try await makeFixture()
        await fixture.manager.pauseAll()

        let mismatched = await fixture.documents.resumeUploadAsync(
            blobId: fixture.blobB, documentId: Self.documentA)
        XCTAssertFalse(mismatched, "a blob outside the scoped document must not be resumable")
        var pausedB = await isPaused(fixture, fixture.blobB)
        XCTAssertTrue(pausedB, "the refused call must not have resumed anything")

        let matched = await fixture.documents.resumeUploadAsync(
            blobId: fixture.blobB, documentId: Self.documentB)
        XCTAssertTrue(matched, "a matching blob and scope must resume, and report that it did")
        pausedB = await isPaused(fixture, fixture.blobB)
        let pausedA = await isPaused(fixture, fixture.blobA)
        XCTAssertFalse(pausedB, "the named blob must be the one resumed")
        XCTAssertTrue(pausedA, "no other document's upload may be touched")
    }

    // MARK: - DocumentBlobContext — the per-document twins

    /// The context's twins take no `documentId`: they must supply their own.
    /// A twin that forwards `nil` instead answers for the whole app.
    func testContextUploadsAsyncForwardsTheContextsDocumentId() async throws {
        let fixture = try await makeFixture()

        let uploads = await fixture.contextA.uploadsAsync()
        XCTAssertEqual(uploads.map(\.blobId), [fixture.blobA],
                       "the context must list only its own document's uploads")
    }

    func testContextPauseAllAsyncForwardsTheContextsDocumentId() async throws {
        let fixture = try await makeFixture()

        await fixture.contextA.pauseAllAsync()
        let pausedA = await isPaused(fixture, fixture.blobA)
        let pausedB = await isPaused(fixture, fixture.blobB)
        XCTAssertTrue(pausedA, "the context's own upload must be paused")
        XCTAssertFalse(pausedB, "another document's upload must not be paused")
    }

    func testContextResumeAllAsyncForwardsTheContextsDocumentId() async throws {
        let fixture = try await makeFixture()
        await fixture.manager.pauseAll()

        await fixture.contextA.resumeAllAsync()
        let pausedA = await isPaused(fixture, fixture.blobA)
        let pausedB = await isPaused(fixture, fixture.blobB)
        XCTAssertFalse(pausedA, "the context's own upload must be resumed")
        XCTAssertTrue(pausedB, "another document's upload must stay paused")
    }

    func testContextPauseUploadAsyncForwardsTheContextsDocumentIdAndItsResult() async throws {
        let fixture = try await makeFixture()

        let foreign = await fixture.contextA.pauseUploadAsync(blobId: fixture.blobB)
        XCTAssertFalse(foreign, "the context must refuse a blob belonging to another document")
        let pausedB = await isPaused(fixture, fixture.blobB)
        XCTAssertFalse(pausedB, "the refused call must not have paused anything")

        let own = await fixture.contextA.pauseUploadAsync(blobId: fixture.blobA)
        XCTAssertTrue(own, "the context must pause its own blob, and report that it did")
        let pausedA = await isPaused(fixture, fixture.blobA)
        XCTAssertTrue(pausedA)
    }

    func testContextResumeUploadAsyncForwardsTheContextsDocumentIdAndItsResult() async throws {
        let fixture = try await makeFixture()
        await fixture.manager.pauseAll()

        let foreign = await fixture.contextA.resumeUploadAsync(blobId: fixture.blobB)
        XCTAssertFalse(foreign, "the context must refuse a blob belonging to another document")
        let pausedB = await isPaused(fixture, fixture.blobB)
        XCTAssertTrue(pausedB, "the refused call must not have resumed anything")

        let own = await fixture.contextA.resumeUploadAsync(blobId: fixture.blobA)
        XCTAssertTrue(own, "the context must resume its own blob, and report that it did")
        let pausedA = await isPaused(fixture, fixture.blobA)
        XCTAssertFalse(pausedA)
    }

    // MARK: - JsBaoClient — the app-wide concurrency twin

    /// The twelfth twin. Read back through `blobUploadConcurrency`, the async
    /// property that answers from the manager, so the assertion covers the
    /// whole round trip rather than a field the client kept to itself. Two
    /// values again, so a constant cannot pass.
    func testClientSetBlobUploadConcurrencyAsyncForwardsTheValue() async throws {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "blob-twin-forwarding-app",
            token: "test-token",
            offline: false,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
        clients.append(client)

        await client.setBlobUploadConcurrencyAsync(5)
        var applied = await client.blobUploadConcurrency
        XCTAssertEqual(applied, 5, "setBlobUploadConcurrencyAsync must forward its argument")

        await client.setBlobUploadConcurrencyAsync(7)
        applied = await client.blobUploadConcurrency
        XCTAssertEqual(applied, 7, "setBlobUploadConcurrencyAsync must forward the new argument too")
    }

    // MARK: - Helpers

    /// Whether the manager considers this upload paused. Read straight off the
    /// manager rather than through a twin, so a broken twin cannot also supply
    /// the evidence that it worked. `listUploads` reports `"uploading"` or
    /// `"pending"` for a running task depending on where the rotation is, so
    /// only the paused state is asserted on.
    private func isPaused(_ fixture: Fixture, _ blobId: String) async -> Bool {
        let uploads = await fixture.manager.listUploads()
        return uploads.first { $0.blobId == blobId }?.status == "paused"
    }

    /// Wait until the manager has parked a queue timer and stopped starting new
    /// ones — the same quiescence `ActorizedBlobManagerTests` and
    /// `BlobBackoffTests` wait for, for the same reason: a queue read taken
    /// mid-retry measures the manager's rotation rather than the test's setup.
    private func waitForAParkedQueueTimer(
        _ manager: BlobManager,
        timeoutMs: Int = 3000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        var last = await manager.queueTimerStartCount
        var stableSamples = 0
        var waited = 0
        while waited < timeoutMs {
            try await Task.sleep(nanoseconds: 25 * 1_000_000)
            waited += 25
            let current = await manager.queueTimerStartCount
            let pending = await manager.hasPendingQueueTimer
            if current == last, pending {
                stableSamples += 1
                if stableSamples >= 3 { return }
            } else {
                stableSamples = 0
                last = current
            }
        }
        XCTFail("the queue never parked a timer within \(timeoutMs)ms", file: file, line: line)
    }
}
