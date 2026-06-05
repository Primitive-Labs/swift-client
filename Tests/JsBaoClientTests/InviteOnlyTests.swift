import XCTest
@testable import JsBaoClient

/// Port of tests/client/js-bao-client-invite-only-flow.test.ts
/// Tests behavior with invite-only apps.
final class InviteOnlyTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-invite-only")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    func testInviteOnlyAppUserCanConnect() async throws {
        // The test app was created in public mode -- the owner should be able to connect
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        XCTAssertTrue(client.isConnected)
    }

    func testInviteOnlyAppCanCreateDocument() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        // The invite-only app owner CAN create a document. We use the
        // local-first `createDocument`, which returns a freshly-minted
        // documentId synchronously and throws on failure — a non-empty id is
        // the success signal. We deliberately avoid `documents.list()`
        // visibility, which is racy for a just-created local-first doc.
        let (documentId, doc) = try await client.createDocument(
            options: CreateDocumentOptions(title: "Invite-Only Doc")
        )
        XCTAssertFalse(
            documentId.isEmpty,
            "Invite-only app owner should be able to create a document"
        )
        XCTAssertNotNil(doc)
    }

    func testInviteOnlyMemberCanOpenSharedDocument() async throws {
        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Shared Doc")
        let member = try await ctx.createTestUser(appId: testApp.appId, role: "member")
        try await ctx.grantPermission(
            appId: testApp.appId,
            documentId: docId,
            userId: member.userId,
            permission: "read-write",
            jwt: testApp.ownerJWT
        )

        let memberClient = createTestClient(appId: testApp.appId, token: member.jwt)
        defer { Task { await memberClient.destroy() } }

        try await memberClient.connect()
        try await waitForConnection(client: memberClient)

        let ydoc = try await memberClient.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: memberClient, documentId: docId)

        XCTAssertNotNil(ydoc)
        XCTAssertTrue(memberClient.isSynced(docId))
    }
}
