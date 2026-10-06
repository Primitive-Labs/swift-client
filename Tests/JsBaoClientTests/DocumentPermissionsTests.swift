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
            perm.userId == user2.userId
        }
        XCTAssertTrue(hasUser2, "User2 should appear in permission list after grant")

        // Revoke permission
        let _ = try await client.documents.removePermission(documentId: docId, .userId(user2.userId))

        // Verify permission was revoked
        let postRevokePermissions = try await client.documents.getPermissions(documentId: docId)
        let stillHasUser2 = postRevokePermissions.contains { perm in
            perm.userId == user2.userId
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

        // Transfer ownership (returns Void on success; throws on failure)
        try await client.documents.transferOwnership(
            documentId: docId,
            newOwnerId: user2.userId
        )

        // Verify new owner by checking permissions
        let permissions = try await client.documents.getPermissions(documentId: docId)
        let newOwner = permissions.first { perm in
            perm.userId == user2.userId && perm.permission == .owner
        }
        XCTAssertNotNil(newOwner, "User2 should be the new owner")
    }

    // MARK: - Validate Access (#2358)

    /// The owner of a document must get `hasAccess: true` with `owner`.
    /// Exercises the live `POST /documents/:documentId/validate-access`
    /// route — the only access-validation route the server registers.
    func testValidateAccessAsOwner() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let docId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "Validate Access Owner"
        )

        let result = try await client.documents.validateAccess(documentId: docId)
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.hasAccess, "Owner must have access to their own document")
        XCTAssertEqual(result.permission, .owner)
    }

    /// A member with an explicit grant sees that grant's level; a member
    /// with no grant sees `hasAccess: false` rather than an error.
    func testValidateAccessForGrantedAndUngrantedMember() async throws {
        let ownerClient = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await ownerClient.destroy() } }

        let docId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "Validate Access Member"
        )
        let user2 = try await ctx.createTestUser(appId: testApp.appId, role: "member")
        let user2Client = createTestClient(appId: testApp.appId, token: user2.jwt)
        defer { Task { await user2Client.destroy() } }

        // No grant yet — the call must succeed and report no access.
        let before = try await user2Client.documents.validateAccess(documentId: docId)
        XCTAssertTrue(before.success)
        XCTAssertFalse(before.hasAccess, "Member without a grant must not have access")

        try await ctx.grantPermission(
            appId: testApp.appId,
            documentId: docId,
            userId: user2.userId,
            permission: "read-write",
            jwt: testApp.ownerJWT
        )

        let after = try await user2Client.documents.validateAccess(documentId: docId)
        XCTAssertTrue(after.success)
        XCTAssertTrue(after.hasAccess, "Member with a grant must have access")
        XCTAssertEqual(after.permission, .readWrite)
    }

    /// The owner asks about somebody else (#3658): the answer is the
    /// SUBJECT's, and it carries where the level came from and the subject's
    /// role in the app.
    func testValidateAccessForANamedSubject() async throws {
        let ownerClient = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await ownerClient.destroy() } }

        let docId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "Validate Access Subject"
        )
        let subject = try await ctx.createTestUser(appId: testApp.appId, role: "member")
        try await ctx.grantPermission(
            appId: testApp.appId,
            documentId: docId,
            userId: subject.userId,
            permission: "reader",
            jwt: testApp.ownerJWT
        )

        let answer = try await ownerClient.documents.validateAccess(
            documentId: docId,
            userId: subject.userId
        )
        XCTAssertTrue(answer.hasAccess)
        XCTAssertEqual(answer.permission, .reader)
        XCTAssertEqual(answer.accessSource, "grant")
        XCTAssertEqual(answer.appRole, "member")

        // The caller form is unchanged: the owner's own access to the
        // document, with no role reported.
        let own = try await ownerClient.documents.validateAccess(documentId: docId)
        XCTAssertEqual(own.permission, .owner)
        XCTAssertNil(own.appRole)
    }

    // MARK: - A pending create's commit (#4159)

    /// The create's id, out of the `{ metadata }` result. `documents.create`
    /// does not open the document.
    private func createUnopened(_ client: JsBaoClient, title: String) async throws -> String {
        let created = try await client.documents.create(options: CreateDocumentOptions(title: title))
        return try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
    }

    func testCreateAloneEmitsPendingCreateCommittedOverHttp() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        var docId = ""
        let events = try await collectEvents(
            from: client.eventEmitter,
            event: PendingCreateCommittedEvent.self
        ) {
            docId = try await createUnopened(client, title: "Commit event")
            try await eventually(timeout: 15, description: "the HTTP commit") {
                !client.isPendingCreate(docId)
            }
            // Room for a second, duplicate emission to show up.
            try await delay(0.5)
        }

        XCTAssertFalse(client.isPendingCreate(docId))
        XCTAssertEqual(events.map(\.documentId).filter { $0 == docId }.count, 1)
    }

    func testValidateAccessWaitsForAPendingCreateToCommit() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let docId = try await createUnopened(client, title: "Asked at once")
        XCTAssertTrue(client.isPendingCreate(docId))

        let answer = try await client.documents.validateAccess(documentId: docId)
        XCTAssertTrue(answer.hasAccess)
        XCTAssertEqual(answer.permission, .owner)
        XCTAssertFalse(client.isPendingCreate(docId))
    }

    func testValidateAccessForANamedUserWaitsTheSameWay() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let docId = try await createUnopened(client, title: "Named at once")
        XCTAssertTrue(client.isPendingCreate(docId))

        let answer = try await client.documents.validateAccess(
            documentId: docId,
            userId: testApp.ownerUserId
        )
        XCTAssertTrue(answer.hasAccess)
        XCTAssertEqual(answer.permission, .owner)
    }

    func testValidateAccessOnAPendingCreateOfflineThrowsPendingCreate() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }
        await client.goOffline()

        let docId = try await createUnopened(client, title: "Asked offline")
        XCTAssertTrue(client.isPendingCreate(docId))

        let started = Date()
        do {
            _ = try await client.documents.validateAccess(documentId: docId)
            XCTFail("expected PENDING_CREATE")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .pendingCreate)
            XCTAssertEqual(error.details?["documentId"], .string(docId))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }
}
