import XCTest
@testable import JsBaoClient

/// Port of tests/client/js-bao-client-invitations.test.ts
/// Tests document sharing and the deferred-grant invitation flow.
///
/// Issue #619 replaced the per-document invitation verbs
/// (`sendInvitation` / `listInvitations` / `getInvitation` /
/// `updateInvitation` / `deleteInvitation` / `declineInvitation` /
/// `acceptInvitation`) with the unified share flow, and #2367 removed them
/// from the Swift client. The replacements these tests use:
///
/// - share by email → `documents.updatePermissions(documentId:params: .email(...))`
///   (idempotent, so it also covers what `updateInvitation` did);
/// - an email that already maps to an app user → a live permission row,
///   visible in `documents.getPermissions(documentId:)`;
/// - an email with no user yet → a deferred grant, visible in
///   `documents.listPendingInvitations(documentId:)`;
/// - cancel a share → `documents.removePermission(documentId:, .email(...))`;
/// - accept → nothing to call: email-matched shares resolve on their own, and
///   `documents.validateAccess(documentId:)` is the access check the removed
///   `acceptInvitation` sent under the hood.
///
/// Deferred grants to an address with no account are admin-gated
/// (`MEMBER_INVITATIONS_DISABLED` fires for a plain "member" caller), so every
/// test that drives one uses the app owner's client and an owner-created
/// document.
final class InvitationTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var ownerClient: JsBaoClient!
    var memberClient: JsBaoClient!
    var invitedUser: TestUser!
    var documentId: String!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-invitations")

        // Create a member user who owns a document
        let memberUser = try await ctx.createTestUser(appId: testApp.appId, role: "member", email: "member-inv@test.local")

        // Create an invited user
        invitedUser = try await ctx.createTestUser(appId: testApp.appId, role: "member", email: "invited-inv@test.local")

        // Create a test document
        documentId = try await ctx.createDocument(appId: testApp.appId, jwt: memberUser.jwt, title: "Invitation Test Doc")

        // Initialize owner client
        ownerClient = createTestClient(appId: testApp.appId, token: memberUser.jwt)

        // Initialize invited user client
        memberClient = createTestClient(appId: testApp.appId, token: invitedUser.jwt)

        // Connect both
        try await ownerClient.connect()
        try await memberClient.connect()
        try await waitForConnection(client: ownerClient)
        try await waitForConnection(client: memberClient)
    }

    override func tearDown() async throws {
        await ownerClient?.destroy()
        await memberClient?.destroy()
        await ctx.cleanup()
    }

    // MARK: - Helpers

    /// An address no app user owns, so a share to it lands as a deferred grant.
    private func unregisteredEmail(_ label: String) -> String {
        "\(label)-\(UUID().uuidString.prefix(8))@test.local".lowercased()
    }

    /// The permission entry the given email holds on a document, or `nil`.
    private func permissionEntry(
        client: JsBaoClient,
        documentId: String,
        email: String
    ) async throws -> DocumentPermissionEntry? {
        let entries = try await client.documents.getPermissions(documentId: documentId)
        return entries.first { $0.email == email }
    }

    // MARK: - Sharing with an existing app user

    /// Ported from JS: "should create a document invitation".
    func testShareByEmail() async throws {
        let result = try await ownerClient.documents.updatePermissions(
            documentId: documentId,
            params: .email(invitedUser.email, permission: "read-write")
        )
        XCTAssertTrue(result.success)
    }

    /// Ported from JS: "should list document invitations". An email that
    /// already maps to an app user gets a live permission row rather than a
    /// pending invitation, so the grant is read back from `getPermissions`.
    func testShareByEmailAppearsInPermissions() async throws {
        _ = try await ownerClient.documents.updatePermissions(
            documentId: documentId,
            params: .email(invitedUser.email, permission: "reader")
        )

        let entry = try await permissionEntry(
            client: ownerClient,
            documentId: documentId,
            email: invitedUser.email
        )
        XCTAssertNotNil(entry, "Expected a permission entry for \(invitedUser.email)")
        XCTAssertEqual(entry?.permission, .reader)
    }

    /// Ported from JS: accept flow. There is no per-document accept verb any
    /// more — an email-matched share resolves on its own — so this asserts the
    /// access check the removed `acceptInvitation` sent
    /// (`POST /documents/:id/validate-access`).
    func testValidateAccessAfterShare() async throws {
        _ = try await ownerClient.documents.updatePermissions(
            documentId: documentId,
            params: .email(invitedUser.email, permission: "read-write")
        )

        try await delay(1)

        let result = try await memberClient.documents.validateAccess(documentId: documentId)
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.hasAccess, "The shared-with user should have access")
    }

    /// Ported from JS: "should update a document invitation".
    /// `updatePermissions` is idempotent, so re-calling it with a higher
    /// permission upgrades the existing grant.
    func testReSharingUpgradesThePermission() async throws {
        _ = try await ownerClient.documents.updatePermissions(
            documentId: documentId,
            params: .email(invitedUser.email, permission: "reader")
        )

        let updated = try await ownerClient.documents.updatePermissions(
            documentId: documentId,
            params: .email(invitedUser.email, permission: "read-write")
        )
        XCTAssertTrue(updated.success)

        let entry = try await permissionEntry(
            client: ownerClient,
            documentId: documentId,
            email: invitedUser.email
        )
        XCTAssertEqual(entry?.permission, .readWrite)
    }

    /// Ported from JS: invite with "reader" permission.
    func testShareWithReaderPermission() async throws {
        let result = try await ownerClient.documents.updatePermissions(
            documentId: documentId,
            params: .email(invitedUser.email, permission: "reader")
        )
        XCTAssertTrue(result.success)

        let entry = try await permissionEntry(
            client: ownerClient,
            documentId: documentId,
            email: invitedUser.email
        )
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.permission, .reader)
    }

    /// Ported from JS: invite with "read-write" permission.
    func testShareWithReadWritePermission() async throws {
        let result = try await ownerClient.documents.updatePermissions(
            documentId: documentId,
            params: .email(invitedUser.email, permission: "read-write")
        )
        XCTAssertTrue(result.success)

        let entry = try await permissionEntry(
            client: ownerClient,
            documentId: documentId,
            email: invitedUser.email
        )
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.permission, .readWrite)
    }

    /// Ported from JS: "should delete a document invitation". The replacement
    /// for `deleteInvitation` is `removePermission(documentId:, .email(...))`,
    /// which drops both the live row and any deferred rows for the address.
    func testRemovePermissionByEmailDropsTheGrant() async throws {
        _ = try await ownerClient.documents.updatePermissions(
            documentId: documentId,
            params: .email(invitedUser.email, permission: "reader")
        )
        let before = try await permissionEntry(
            client: ownerClient,
            documentId: documentId,
            email: invitedUser.email
        )
        XCTAssertNotNil(before, "The share should exist before it is removed")

        try await ownerClient.documents.removePermission(
            documentId: documentId,
            .email(invitedUser.email)
        )

        let after = try await permissionEntry(
            client: ownerClient,
            documentId: documentId,
            email: invitedUser.email
        )
        XCTAssertNil(after, "The permission should be gone after removePermission")
    }

    /// Ported from JS: "should create a document invitation with email
    /// notification options". The three options moved onto
    /// `UpdatePermissionsData` (`sendEmail` / `documentUrl` / `note`).
    /// `sendEmail: true` requires the app to have a `baseUrl`, so the test
    /// configures one first.
    func testShareByEmailWithEmailNotificationOptions() async throws {
        try await ctx.updateAppSettings(
            appId: testApp.appId,
            updates: ["baseUrl": "https://example.com"],
            jwt: testApp.ownerJWT
        )

        let result = try await ownerClient.documents.updatePermissions(
            documentId: documentId,
            params: .email(
                invitedUser.email,
                permission: "read-write",
                sendEmail: true,
                documentUrl: "https://example.com/doc/123",
                note: "Please review this document"
            )
        )
        XCTAssertTrue(result.success)

        let entry = try await permissionEntry(
            client: ownerClient,
            documentId: documentId,
            email: invitedUser.email
        )
        XCTAssertEqual(entry?.permission, .readWrite)
    }

    /// Ported from JS: get document after invitation (auto-accept flow).
    /// A share to an existing app user resolves without any accept call, so
    /// the recipient can read the document straight away.
    func testGetDocumentAfterShare() async throws {
        _ = try await ownerClient.documents.updatePermissions(
            documentId: documentId,
            params: .email(invitedUser.email, permission: "read-write")
        )

        try await delay(1)

        let docInfo = try await memberClient.documents.get(documentId: documentId)
        XCTAssertEqual(docInfo.documentId, documentId)
        XCTAssertEqual(docInfo.permission, .readWrite)
    }

    // MARK: - MeAPI pending invitations

    /// Ported from JS: pending invitations via MeAPI. `me/document-invitations`
    /// reads the legacy `DocumentInvitation` rows, and the share flow no longer
    /// writes any: an email that resolves to an app user gets a live permission
    /// row instead. So the grant lands and the recipient's pending list stays
    /// empty for this document.
    func testShareToExistingUserLeavesNoPendingInvitation() async throws {
        _ = try await ownerClient.documents.updatePermissions(
            documentId: documentId,
            params: .email(invitedUser.email, permission: "reader")
        )

        try await delay(1)

        let entry = try await permissionEntry(
            client: ownerClient,
            documentId: documentId,
            email: invitedUser.email
        )
        XCTAssertEqual(entry?.permission, .reader, "The share should be a live permission")

        let pending = try await memberClient.me.pendingDocumentInvitations()
        XCTAssertFalse(
            pending.contains { $0.documentId == documentId },
            "A share to an existing app user must not create a pending invitation"
        )
    }

    // MARK: - Sharing with an address that has no account yet

    /// Ported from JS: "should list document invitations" (with verification).
    /// Shares to an unregistered address, lists the document's pending
    /// invitations, and verifies the entry's email and permission.
    func testListPendingInvitationsVerifyContent() async throws {
        let appOwner = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await appOwner.destroy() } }
        let ownerDocId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "Pending invitation content"
        )
        let email = unregisteredEmail("list-content")

        let result = try await appOwner.documents.updatePermissions(
            documentId: ownerDocId,
            params: .email(email, permission: "reader")
        )
        XCTAssertTrue(result.success)

        try await delay(1)

        let pending = try await appOwner.documents.listPendingInvitations(documentId: ownerDocId)
        let found = pending.first { $0.email == email }
        XCTAssertNotNil(found, "Expected to find a pending invitation for \(email)")
        XCTAssertEqual(found?.permission, "reader")
    }

    /// Ported from JS: "should create a document invitation" (verify response
    /// fields). A deferred grant is the case that carries the invitation
    /// detail back on the response — the JS test checked email, permission and
    /// invitationId, which live on `PermissionUpdateResult.results`.
    func testDeferredShareResponseFields() async throws {
        let appOwner = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await appOwner.destroy() } }
        let ownerDocId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "Deferred share response"
        )
        let email = unregisteredEmail("response-fields")

        let result = try await appOwner.documents.updatePermissions(
            documentId: ownerDocId,
            params: .email(email, permission: "read-write")
        )

        XCTAssertTrue(result.success)
        XCTAssertFalse(result.message.isEmpty)

        let grants = try XCTUnwrap(result.results, "A deferred share should report its grants")
        var deferredGrant: DeferredPermissionGrant?
        for grant in grants {
            if case let .deferred(value) = grant, value.email == email {
                deferredGrant = value
            }
        }
        let deferred = try XCTUnwrap(deferredGrant, "Expected a deferred grant for \(email)")
        XCTAssertEqual(deferred.permission, "read-write")
        XCTAssertEqual(deferred.status, "pending_signup")
        XCTAssertFalse(deferred.invitationId.isEmpty)
    }

    /// Ported from JS: invite to a non-existent email. The share is accepted
    /// and becomes a pending invitation that resolves when the address signs up.
    func testShareWithUnregisteredEmailCreatesPendingInvitation() async throws {
        let appOwner = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await appOwner.destroy() } }
        let ownerDocId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "Unregistered email share"
        )
        let email = unregisteredEmail("nonexistent")

        let result = try await appOwner.documents.updatePermissions(
            documentId: ownerDocId,
            params: .email(email, permission: "reader")
        )
        XCTAssertTrue(result.success)

        let pending = try await appOwner.documents.listPendingInvitations(documentId: ownerDocId)
        XCTAssertTrue(
            pending.contains { $0.email == email },
            "An unregistered address should appear in the pending list"
        )
    }

    /// Ported from JS: "should get a specific document invitation". The
    /// replacement for `getInvitation(documentId:email:)` is
    /// `listPendingInvitations(documentId:)` filtered by email.
    func testGetSpecificPendingInvitation() async throws {
        let appOwner = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await appOwner.destroy() } }
        let ownerDocId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "Specific pending invitation"
        )
        let email = unregisteredEmail("specific")

        _ = try await appOwner.documents.updatePermissions(
            documentId: ownerDocId,
            params: .email(email, permission: "read-write")
        )

        let pending = try await appOwner.documents.listPendingInvitations(documentId: ownerDocId)
        let invitation = pending.first { $0.email == email }

        XCTAssertNotNil(invitation, "Should find the pending invitation")
        XCTAssertEqual(invitation?.email, email)
        XCTAssertEqual(invitation?.permission, "read-write")
    }

    /// Ported from JS: pending invitations with field verification. Every
    /// field the entry declares should be populated, not just email and
    /// permission.
    func testPendingInvitationEntryCarriesExpectedFields() async throws {
        let appOwner = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await appOwner.destroy() } }
        let ownerDocId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "Pending invitation fields"
        )
        let email = unregisteredEmail("fields")

        _ = try await appOwner.documents.updatePermissions(
            documentId: ownerDocId,
            params: .email(email, permission: "reader")
        )

        let pending = try await appOwner.documents.listPendingInvitations(documentId: ownerDocId)
        let entry = try XCTUnwrap(
            pending.first { $0.email == email },
            "Expected a pending invitation for \(email)"
        )
        XCTAssertEqual(entry.permission, "reader")
        XCTAssertFalse(entry.invitationId.isEmpty)
        XCTAssertFalse(entry.createdAt.isEmpty)
        XCTAssertFalse(entry.expiresAt.isEmpty)
        XCTAssertEqual(entry.grantedBy, testApp.ownerUserId)
    }

    // MARK: - Migration path (issue #619/#628): pending-invitations + email-removal

    /// Inviting a not-yet-existing email via `updatePermissions` should
    /// create a `DeferredDocumentPermission` that `listPendingInvitations`
    /// surfaces. Uses the app-owner JWT because deferred grants to
    /// brand-new emails are admin-gated (MEMBER_INVITATIONS_DISABLED
    /// fires for plain "member" users).
    func testListPendingInvitationsForDeferredEmail() async throws {
        let appOwner = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await appOwner.destroy() } }
        let ownerDocId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "Migration: pending invitations"
        )

        let pendingEmail = "pending-\(UUID().uuidString.prefix(8))@test.local".lowercased()
        _ = try await appOwner.documents.updatePermissions(
            documentId: ownerDocId,
            params: .email(pendingEmail, permission: "read-write")
        )

        let pending = try await appOwner.documents.listPendingInvitations(
            documentId: ownerDocId
        )
        XCTAssertTrue(
            pending.contains { $0.email == pendingEmail },
            "Pending invitation for \(pendingEmail) should surface"
        )
    }

    /// `removePermission(documentId:, email:)` cancels the deferred
    /// grant so the email no longer appears in `listPendingInvitations`.
    func testRemovePermissionByEmailDropsDeferredGrant() async throws {
        let appOwner = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await appOwner.destroy() } }
        let ownerDocId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "Migration: cancel by email"
        )

        let pendingEmail = "to-cancel-\(UUID().uuidString.prefix(8))@test.local".lowercased()
        _ = try await appOwner.documents.updatePermissions(
            documentId: ownerDocId,
            params: .email(pendingEmail, permission: "read-write")
        )
        let before = try await appOwner.documents.listPendingInvitations(
            documentId: ownerDocId
        )
        XCTAssertTrue(before.contains { $0.email == pendingEmail })

        _ = try await appOwner.documents.removePermission(
            documentId: ownerDocId,
            .email(pendingEmail)
        )

        let after = try await appOwner.documents.listPendingInvitations(
            documentId: ownerDocId
        )
        XCTAssertFalse(
            after.contains { $0.email == pendingEmail },
            "Cancelled email should be gone from pending list"
        )
    }
}
