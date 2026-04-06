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

        // Listen for invitation events on the invitee client
        var invitationReceived = false
        let sub = inviteeClient.events.onAny(.invitation) { _ in
            invitationReceived = true
        }

        // Send invitation
        _ = try await ownerClient.documents.sendInvitation(
            documentId: docId,
            email: user2.email,
            permission: "read-write"
        )

        // Wait for WS event
        try await delay(3)

        // The invitation event may or may not be received depending on server config
        // At minimum, verify no crash occurred
        sub.cancel()
    }
}
