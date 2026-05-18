import XCTest
@testable import JsBaoClient
import YSwift

/// Regression tests for `DocumentManager.openDocument(...)` lifecycle races.
///
/// Originally surfaced by code review of PR #349: the `openDocument`
/// implementation held the lock for the idempotency check, **released
/// it**, then constructed `YDocument()` outside the lock and re-acquired
/// the lock to insert. Two concurrent calls for the same `documentId`
/// could each create their own `YDocument` and the second insert would
/// clobber the first — leaving one caller holding a `YDocument`
/// reference that no longer maps to anything inside `openDocs`, with
/// observers wired to a doc that's no longer canonical.
///
/// The fix coalesces concurrent opens for the same `documentId` so all
/// callers receive **the same** `YDocument` instance (`===`).
final class DocumentManagerRaceTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-doc-mgr-race")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    /// Spawns N concurrent `openDocument(id)` calls and asserts every
    /// returned `YDocument` is the same instance. Pre-fix, this is
    /// flaky-to-failing because the check-then-insert window allows
    /// duplicate construction. Post-fix, the coalescing pendingOpens
    /// table holds the single in-flight Task so all callers await it.
    func testOpenDocument_concurrentCallsForSameId_returnIdenticalInstance() async throws {
        let docId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "Open-Race-Test"
        )

        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }
        try await client.connect()
        try await waitForConnection(client: client)

        // 10 concurrent openDocument calls for the same docId. Use
        // `.network` so the open path goes through the full lifecycle
        // (sync protocol, persistence wiring, observer registration).
        let n = 10
        var instances: [YDocument] = []
        try await withThrowingTaskGroup(of: YDocument.self) { group in
            for _ in 0..<n {
                group.addTask {
                    try await client.openDocument(
                        docId,
                        options: OpenDocumentOptions(waitForLoad: .network)
                    )
                }
            }
            for try await doc in group {
                instances.append(doc)
            }
        }

        XCTAssertEqual(instances.count, n)

        // Every returned YDocument must be the same reference. A single
        // mismatch indicates the race re-occurred and a duplicate was
        // returned to one of the racing callers.
        let canonical = instances[0]
        for (i, doc) in instances.enumerated() {
            XCTAssertTrue(
                doc === canonical,
                "openDocument call #\(i) returned a different YDocument instance " +
                "than call #0 — concurrent opens for the same docId should be " +
                "coalesced to a single YDocument."
            )
        }
    }

    /// A weaker form of the same invariant that's deterministic even
    /// without true parallelism: back-to-back `openDocument` calls on
    /// the same docId must return the same instance once the first
    /// call returns. This catches the "second insert clobbered the
    /// first" tail of the race even on systems where the racing
    /// behavior of the first test is non-deterministic.
    func testOpenDocument_serialCallsForSameId_returnIdenticalInstance() async throws {
        let docId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "Open-Same-Test"
        )

        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }
        try await client.connect()
        try await waitForConnection(client: client)

        let first = try await client.openDocument(
            docId,
            options: OpenDocumentOptions(waitForLoad: .network)
        )
        // Second call should hit the in-memory cache — using `.local`
        // is fine because by this point the doc is already open.
        let second = try await client.openDocument(
            docId,
            options: OpenDocumentOptions(waitForLoad: .local)
        )

        XCTAssertTrue(
            first === second,
            "Second openDocument(docId:) call must return the cached YDocument"
        )
    }
}
