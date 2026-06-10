import XCTest
@testable import JsBaoClient

/// Regression guard: a `.network` open of a freshly-created document must
/// complete the WS sync handshake instead of stalling on the timeout.
///
/// `openDocument(.network)` parks in a `withCheckedContinuation` until the
/// server emits a `syncComplete` message, falling back to the
/// `availabilityWaitMs` (default 30_000ms) timeout if it never arrives. A
/// freshly-created doc tripped two #852 gaps: (1) its sync protocol was never
/// built (the open fast-paths past `_openDocumentImpl`; see
/// `createLocalDocument`), so `buildSyncStep1Message` returned nil and
/// `syncStep1` was never sent; and (2) even once it can send, a just-created
/// doc is `pendingCreate` — not on the server yet — so the first `syncStep1`
/// gets no answer. The wait now re-sends `syncStep1` on a 350ms tick (js-bao
/// `waitForAvailability` parity) until the background commit lands. Before, a
/// `.network` open ate the full 30s.
///
/// A consuming app (StoryLens) had ~31s added to every scan because its
/// story-doc open used `.network` on the just-created doc. This pins the
/// expectation so the handshake can't silently regress back to a timeout.
final class OpenFreshDocTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-open-fresh-doc")
    }

    override func tearDown() async throws {
        if let ctx: TestContext = ctx { await ctx.cleanup() }
    }

    /// A `.network` open of a freshly-created doc must complete the WS sync
    /// handshake — not hit the 30s `availabilityWaitMs` timeout.
    ///
    /// Regression for the two-part #852 local-first-create gap: the sync
    /// protocol is now built in `createLocalDocument` (so `syncStep1` can be
    /// sent), and the `.network` wait re-sends `syncStep1` on a 350ms tick
    /// until the `pendingCreate` doc's background commit lands and the server
    /// answers — bringing a fresh-doc `.network` open from ~30s to ~1s.
    func testOpenFreshDoc_networkHandshakeCompletes_notTimeout() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }
        try await client.connect()
        try await waitForConnection(client: client)

        // Fresh doc — local-first create; commits to the server in the
        // background, so the doc is still `pendingCreate` when we open it below.
        let (documentId, _) = try await client.createDocument(
            options: CreateDocumentOptions(title: "fresh-open")
        )
        XCTAssertFalse(documentId.isEmpty)

        let start = DispatchTime.now().uptimeNanoseconds
        _ = try await client.openDocument(documentId, options: OpenDocumentOptions(
            waitForLoad: .network,
            enableNetworkSync: true
        ))
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        // Functional guard: a `.network` open resolves on `syncComplete`, so the
        // doc must actually be synced on return — not merely that the call came
        // back quickly. This catches a regression that returns fast *without*
        // completing the handshake (e.g. the timeout path firing, which leaves
        // the doc unsynced), independent of the timing bound below.
        XCTAssertTrue(
            client.documents.isSynced(documentId: documentId),
            "a .network open returned but the doc is not synced — the WS handshake "
            + "(syncStep1 → syncStep2 → syncComplete) didn't complete."
        )

        // Timing guard: the bug parked on the full 30s `availabilityWaitMs`
        // timeout. A healthy handshake is ~1s; 10s leaves generous margin for a
        // loaded CI runner while still cleanly catching the 30s stall.
        XCTAssertLessThan(
            elapsedMs, 10_000,
            "a .network open of a freshly-created doc took \(Int(elapsedMs))ms — it hit "
            + "the 30s availabilityWaitMs timeout instead of completing the handshake."
        )
    }
}
