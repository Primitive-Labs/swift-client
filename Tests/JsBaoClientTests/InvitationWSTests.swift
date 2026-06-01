import XCTest
@testable import JsBaoClient

/// Port of tests/client/js-bao-client-invitation-ws.test.ts
/// Tests invitation WebSocket events.
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

    func testReceiveInvitationEvent() async throws {
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

        // Listen for invitation events on the invitee client. NSLock is
        // overkill but it's the simplest way to share a mutable flag
        // between the event-emitter callback (called off the main
        // thread) and the assertion below.
        let lock = NSLock()
        var invitationReceived = false
        let sub = inviteeClient.events.onAny(.invitation) { _ in
            lock.lock()
            invitationReceived = true
            lock.unlock()
        }

        // Send invitation
        _ = try await ownerClient.documents.sendInvitation(
            documentId: docId,
            email: user2.email,
            permission: "read-write"
        )

        // Wait for WS event
        try await delay(3)
        sub.cancel()

        lock.lock()
        let received = invitationReceived
        lock.unlock()

        // Previous version of this test cancelled the subscription and
        // returned without asserting. That made it a no-op smoke test
        // ("didn't crash"). The actual server contract guarantees an
        // invitation WS event lands on the invitee within a few
        // seconds, so we assert it.
        XCTAssertTrue(
            received,
            "Expected an invitation WS event on the invitee client " +
            "within 3 seconds of `documents.sendInvitation`. If this " +
            "starts failing, check whether the server-side notifier " +
            "is still wired to forward invitation events to the " +
            "invitee's session — same place WorkflowStatusEvent is " +
            "delivered."
        )
    }
}
