import XCTest
@testable import JsBaoClient

/// A whole-scope `syncMetadata` against the dev server (#4830): it lists the
/// member's owned and shared documents, and a later sync evicts the owned
/// document deleted and the shared one revoked in between, keeping the rest.
/// The hermetic twin, `SyncMetadataWholeScopeHermeticTests`, pins the walk's
/// edge cases.
final class SyncMetadataWholeScopeLiveTests: XCTestCase {
    private var ctx: TestContext!
    private var client: JsBaoClient?

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx?.cleanup()
    }

    func testAWholeScopeSyncListsOwnedAndSharedAndEvictsWhatTheServerNoLongerReturns() async throws {
        let app = try await ctx.createTestApp(name: "swift-sync-whole-scope-4830")
        let member = try await ctx.createTestUser(appId: app.appId)
        let owned = try await ctx.createDocument(appId: app.appId, jwt: member.jwt, title: "Owned, kept")
        let deleted = try await ctx.createDocument(appId: app.appId, jwt: member.jwt, title: "Owned, deleted")
        let shared = try await ctx.createDocument(appId: app.appId, jwt: app.ownerJWT, title: "Shared, kept")
        let revoked = try await ctx.createDocument(appId: app.appId, jwt: app.ownerJWT, title: "Shared, revoked")
        for id in [shared, revoked] {
            try await ctx.grantPermission(
                appId: app.appId, documentId: id, userId: member.userId, permission: "read-write", jwt: app.ownerJWT
            )
        }

        let c = createTestClient(appId: app.appId, token: member.jwt)
        client = c
        _ = await c.waitForStorageReady()

        try await eventually(timeout: 15, interval: 0.5, description: "all four documents listed") {
            try await c.syncMetadata()
            return [owned, deleted, shared, revoked].allSatisfy { c.documentManager.getLocalMetadata($0) != nil }
        }
        XCTAssertEqual(c.documentManager.getLocalMetadata(shared)?.permission, "read-write")

        _ = try await ctx.appRequest(
            method: "DELETE", appId: app.appId, path: "/documents/\(deleted)", body: nil, jwt: member.jwt
        )
        _ = try await ctx.appRequest(
            method: "DELETE", appId: app.appId, path: "/documents/\(revoked)/permissions/\(member.userId)",
            body: nil, jwt: app.ownerJWT
        )

        try await eventually(timeout: 15, interval: 0.5, description: "the deleted and revoked documents evicted") {
            try await c.syncMetadata()
            return c.documentManager.getLocalMetadata(deleted) == nil
                && c.documentManager.getLocalMetadata(revoked) == nil
        }
        XCTAssertNotNil(c.documentManager.getLocalMetadata(owned))
        XCTAssertNotNil(c.documentManager.getLocalMetadata(shared))
    }
}
