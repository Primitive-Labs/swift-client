import XCTest
@testable import JsBaoClient

/// Port of tests/client/js-bao-client-invitation-ws.test.ts
/// Tests the WebSocket event a share delivers to the recipient.
final class InvitationWSTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-invitation-ws")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    /// Sharing a document with an existing app user must reach that user over
    /// their WebSocket within a few seconds.
    ///
    /// This used to assert the typed `InvitationEvent` raised by
    /// `documents.sendInvitation`. That verb is gone (#619 / #2367), and the
    /// `invitation` / `created` frame it produced came from the legacy
    /// per-document invitation route, so nothing the client can call raises one
    /// any more: an email that resolves to an app user now gets a live
    /// permission row, and the server announces it with a
    /// `documentMetadataChanged` frame carrying the granted permission. That
    /// frame is what this test now waits for — same contract (the recipient is
    /// told, over the socket, which document and which permission), same
    /// three-second budget.
    func testShareDeliversDocumentMetadataEventToRecipient() async throws {
        // Create two users
        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member", email: "invitee-ws@test.local")

        let ownerClient = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        let inviteeClient = createTestClient(appId: testApp.appId, token: user2.jwt)
        defer {
            Task {
                await ownerClient.destroy()
                await inviteeClient.destroy()
            }
        }

        try await ownerClient.connect()
        try await inviteeClient.connect()
        try await waitForConnection(client: ownerClient)
        try await waitForConnection(client: inviteeClient)

        // Create a document
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Invitation WS Doc")

        // Listen for the share event on the invitee client. NSLock is
        // overkill but it's the simplest way to share a mutable flag
        // between the event-emitter callback (called off the main
        // thread) and the assertion below. Only frames for this document
        // count — the client also emits local metadata changes.
        let lock = NSLock()
        var shareReceived = false
        var receivedEvent: DocumentMetadataChangedEvent?
        let sub = inviteeClient.eventEmitter.subscribe(DocumentMetadataChangedEvent.self) { e in
            guard e.documentId == docId, e.source == "server" else { return }
            lock.lock()
            shareReceived = true
            receivedEvent = e
            lock.unlock()
        }

        // Share the document with the invitee
        _ = try await ownerClient.documents.updatePermissions(
            documentId: docId,
            params: .email(user2.email, permission: "read-write")
        )

        // Wait for WS event
        try await delay(3)
        sub.cancel()

        let (received, event) = lock.withLock { (shareReceived, receivedEvent) }

        // An earlier version of this test cancelled the subscription and
        // returned without asserting. That made it a no-op smoke test
        // ("didn't crash"). The server contract guarantees the share lands
        // on the recipient within a few seconds, so we assert it.
        XCTAssertTrue(
            received,
            "Expected a document metadata WS event on the invitee client " +
            "within 3 seconds of the share. If this starts failing, check " +
            "whether the server-side notifier is still wired to forward " +
            "permission grants to the recipient's session — same place " +
            "WorkflowStatusEvent is delivered."
        )

        // The event must be delivered as a typed payload with the document
        // and permission populated, not a raw dictionary.
        let payload = try XCTUnwrap(event, "Expected the typed DocumentMetadataChangedEvent payload")
        XCTAssertEqual(payload.action, "created")
        XCTAssertEqual(payload.documentId, docId)
        XCTAssertEqual(payload.metadata?["permission"], .string("read-write"))
    }
}
