import XCTest
@testable import JsBaoClient
import YSwift

final class DocumentPermissionsTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-docperms")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    // MARK: - Grant and Revoke Permission

    func testGrantAndRevokePermission() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Permission Test")
        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")

        // Grant read-write permission via TestContext helper (uses admin API internally)
        try await ctx.grantPermission(
            appId: testApp.appId,
            documentId: docId,
            userId: user2.userId,
            permission: "read-write",
            jwt: testApp.ownerJWT
        )

        // Verify permission was granted by listing permissions
        let permissions = try await client.documents.getPermissions(documentId: docId)
        let hasUser2 = permissions.contains { perm in
            (perm["userId"] as? String) == user2.userId
        }
        XCTAssertTrue(hasUser2, "User2 should appear in permission list after grant")

        // Revoke permission
        let _ = try await client.documents.removePermission(documentId: docId, userId: user2.userId)

        // Verify permission was revoked
        let postRevokePermissions = try await client.documents.getPermissions(documentId: docId)
        let stillHasUser2 = postRevokePermissions.contains { perm in
            (perm["userId"] as? String) == user2.userId
        }
        XCTAssertFalse(stillHasUser2, "User2 should not appear in permission list after revoke")
    }

    // MARK: - Transfer Ownership

    func testTransferOwnership() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Transfer Test")
        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")

        // Grant some permission first so the user exists on the doc
        try await ctx.grantPermission(
            appId: testApp.appId,
            documentId: docId,
            userId: user2.userId,
            permission: "read-write",
            jwt: testApp.ownerJWT
        )

        // Transfer ownership
        let result = try await client.documents.transferOwnership(
            documentId: docId,
            newOwnerId: user2.userId
        )

        XCTAssertFalse(result.isEmpty, "Expected non-empty response from transfer")

        // Verify new owner by checking permissions
        let permissions = try await client.documents.getPermissions(documentId: docId)
        let newOwner = permissions.first { perm in
            (perm["userId"] as? String) == user2.userId
                && ((perm["permission"] as? String) == "owner" || (perm["role"] as? String) == "owner")
        }
        XCTAssertNotNil(newOwner, "User2 should be the new owner")
    }
}
