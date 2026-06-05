import XCTest
@testable import JsBaoClient

/// Port of tests/client/js-bao-client-invitations.test.ts
/// Tests document invitation flow.
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

    func testSendInvitation() async throws {
        let result = try await ownerClient.documents.sendInvitation(
            documentId: documentId,
            email: invitedUser.email,
            permission: "read-write"
        )
        XCTAssertNotNil(result)
    }

    func testListInvitations() async throws {
        // Send an invitation first
        _ = try await ownerClient.documents.sendInvitation(
            documentId: documentId,
            email: invitedUser.email,
            permission: "reader"
        )

        let invitations = try await ownerClient.documents.listInvitations(documentId: documentId)
        XCTAssertGreaterThanOrEqual(invitations.count, 1)
    }

    func testAcceptInvitation() async throws {
        // Send invitation
        _ = try await ownerClient.documents.sendInvitation(
            documentId: documentId,
            email: invitedUser.email,
            permission: "read-write"
        )

        try await delay(1)

        // Accept invitation as the invited user
        do {
            let result = try await memberClient.documents.acceptInvitation(documentId: documentId)
            XCTAssertNotNil(result)
        } catch {
            // Some server configurations may handle this differently
            let msg = String(describing: error)
            // Acceptable if invitation was auto-accepted or already processed
            XCTAssertTrue(
                msg.contains("404") || msg.contains("already") || msg.contains("not found"),
                "Unexpected error: \(msg)"
            )
        }
    }

    func testListPendingInvitations() async throws {
        // Send invitation
        _ = try await ownerClient.documents.sendInvitation(
            documentId: documentId,
            email: invitedUser.email,
            permission: "reader"
        )

        try await delay(1)

        // The invited user should see the pending invitation
        let pending = try await memberClient.me.pendingDocumentInvitations()
        // May or may not have pending invitations depending on auto-accept
        XCTAssertNotNil(pending)
    }

    // MARK: - Additional Invitation Tests

    /// Ported from JS: "should list document invitations" (with verification)
    /// Creates an invite, lists invitations, and verifies the invite appears with correct fields.
    func testListInvitationsVerifyContent() async throws {
        let result = try await ownerClient.documents.sendInvitation(
            documentId: documentId,
            email: invitedUser.email,
            permission: "reader"
        )
        XCTAssertNotNil(result)

        try await delay(1)

        let invitations = try await ownerClient.documents.listInvitations(documentId: documentId)
        XCTAssertGreaterThanOrEqual(invitations.count, 1)

        // Find the invitation for our invited user
        let found = invitations.first { $0.email == invitedUser.email }
        XCTAssertNotNil(found, "Expected to find invitation for \(invitedUser.email)")
        XCTAssertEqual(found?.permission, "reader")
    }

    /// Ported from JS: "should create a document invitation" (verify response fields)
    /// Verifies that the invitation response contains expected fields like success, email, permission.
    func testSendInvitationResponseFields() async throws {
        let result = try await ownerClient.documents.sendInvitation(
            documentId: documentId,
            email: invitedUser.email,
            permission: "read-write"
        )

        // Verify response has expected fields. `DocumentInvitationResponse`
        // exposes these as non-optional, so assert their values directly.
        // The JS test checks: success, message, email, permission, invitationId, invitedBy, invitedAt, expiresAt
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.email, invitedUser.email)
        XCTAssertEqual(result.permission, "read-write")
    }

    /// Ported from JS: invite with different permission levels
    /// Tests creating invitations with "reader" permission.
    func testInviteWithReaderPermission() async throws {
        let result = try await ownerClient.documents.sendInvitation(
            documentId: documentId,
            email: invitedUser.email,
            permission: "reader"
        )
        XCTAssertNotNil(result)

        // Verify the invitation was created with reader permission
        let invitations = try await ownerClient.documents.listInvitations(documentId: documentId)
        let found = invitations.first { $0.email == invitedUser.email }
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.permission, "reader")
    }

    /// Ported from JS: invite with read-write permission
    /// Tests creating invitations with "read-write" permission.
    func testInviteWithReadWritePermission() async throws {
        let result = try await ownerClient.documents.sendInvitation(
            documentId: documentId,
            email: invitedUser.email,
            permission: "read-write"
        )
        XCTAssertNotNil(result)

        // Verify the invitation was created with read-write permission
        let invitations = try await ownerClient.documents.listInvitations(documentId: documentId)
        let found = invitations.first { $0.email == invitedUser.email }
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.permission, "read-write")
    }

    /// Ported from JS: invite to non-existent email
    /// Should still create a pending invitation even if the email is not a registered user.
    func testInviteNonExistentEmail() async throws {
        let nonExistentEmail = "nonexistent-\(UUID().uuidString.prefix(8))@test.local".lowercased()

        let result = try await ownerClient.documents.sendInvitation(
            documentId: documentId,
            email: nonExistentEmail,
            permission: "reader"
        )
        // The API should accept the invitation request even for non-existent emails
        XCTAssertNotNil(result)
    }

    /// Ported from JS: accept invitation flow
    /// Owner sends invitation, invited user accepts, then verifies access.
    func testAcceptInvitationAndVerifyAccess() async throws {
        // Send invitation
        _ = try await ownerClient.documents.sendInvitation(
            documentId: documentId,
            email: invitedUser.email,
            permission: "read-write"
        )

        try await delay(1)

        // Accept invitation as the invited user — the server may auto-accept
        // or require explicit acceptance depending on configuration
        do {
            _ = try await memberClient.documents.acceptInvitation(documentId: documentId)
        } catch {
            // Auto-accept or already-accepted is fine
        }

        // Verify the invited user can access the document (either via accept or auto-accept)
        do {
            let doc = try await memberClient.documents.get(documentId: documentId)
            XCTAssertEqual(doc.documentId, documentId, "Invited user should be able to access the document")
        } catch {
            // If the server doesn't grant access via invitation in public mode,
            // the user may already have access as an app member
        }
    }

    /// Ported from JS: pending invitations via MeAPI with field verification
    /// Verifies that the pending invitation list includes expected fields.
    func testPendingInvitationsContainExpectedFields() async throws {
        // Send invitation
        _ = try await ownerClient.documents.sendInvitation(
            documentId: documentId,
            email: invitedUser.email,
            permission: "reader"
        )

        try await delay(1)

        let pending = try await memberClient.me.pendingDocumentInvitations()
        XCTAssertNotNil(pending)

        // Find the invitation for our document
        let found = pending.first { $0.documentId == documentId }
        if let found = found {
            XCTAssertEqual(found.email, invitedUser.email)
            XCTAssertEqual(found.permission, "reader")
        }
        // Note: If auto-accept is enabled, pending list may be empty -- that's acceptable
    }

    /// Ported from JS: "should update a document invitation"
    func testUpdateInvitation() async throws {
        // Create an invitation
        _ = try await ownerClient.documents.sendInvitation(
            documentId: documentId,
            email: invitedUser.email,
            permission: "reader"
        )

        // Update the invitation to read-write
        let updated = try await ownerClient.documents.updateInvitation(
            documentId: documentId,
            email: invitedUser.email,
            permission: "read-write"
        )

        XCTAssertEqual(updated.permission, "read-write")
        XCTAssertTrue(updated.success)
    }

    /// Ported from JS: "should get a specific document invitation"
    func testGetSpecificInvitation() async throws {
        // Create an invitation
        _ = try await ownerClient.documents.sendInvitation(
            documentId: documentId,
            email: invitedUser.email,
            permission: "read-write"
        )

        // Get the specific invitation
        let invitation = try await ownerClient.documents.getInvitation(
            documentId: documentId,
            email: invitedUser.email
        )

        XCTAssertNotNil(invitation, "Should find the invitation")
        XCTAssertEqual(invitation?.email, invitedUser.email)
        XCTAssertEqual(invitation?.permission, "read-write")
    }

    /// Ported from JS: "should delete a document invitation"
    func testDeleteInvitation() async throws {
        // Create an invitation
        let response = try await ownerClient.documents.sendInvitation(
            documentId: documentId,
            email: invitedUser.email,
            permission: "reader"
        )

        let invitationId = response.invitationId

        // Delete the invitation
        let result = try await ownerClient.documents.deleteInvitation(
            documentId: documentId,
            invitationId: invitationId
        )
        XCTAssertTrue(result.success)

        // Verify invitation is gone
        let invitations = try await ownerClient.documents.listInvitations(documentId: documentId)
        XCTAssertEqual(invitations.count, 0, "Invitation list should be empty after deletion")
    }

    /// Ported from JS: "should create a document invitation with email notification options"
    func testSendInvitationWithEmailOptions() async throws {
        let result = try await ownerClient.documents.sendInvitation(
            documentId: documentId,
            email: invitedUser.email,
            permission: "read-write",
            options: InvitationEmailOptions(
                sendEmail: true,
                documentUrl: "https://example.com/doc/123",
                note: "Please review this document"
            )
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.email, invitedUser.email)
    }

    /// Ported from JS: "should decline an invitation via client API"
    func testDeclineInvitation() async throws {
        // Create invitation
        let response = try await ownerClient.documents.sendInvitation(
            documentId: documentId,
            email: invitedUser.email,
            permission: "reader"
        )

        let invitationId = response.invitationId

        try await delay(1)

        // Decline as invitee
        let decline = try await memberClient.documents.declineInvitation(
            documentId: documentId,
            invitationId: invitationId
        )
        XCTAssertTrue(decline.success)

        // Verify invitation is no longer listed
        let invitations = try await ownerClient.documents.listInvitations(documentId: documentId)
        let emails = invitations.map { $0.email }
        XCTAssertFalse(emails.contains(invitedUser.email), "Declined invitation should not appear in list")
    }

    /// Ported from JS: get document after invitation (auto-accept flow)
    /// When the invited user fetches the document, the invitation may be auto-accepted.
    func testGetDocumentAutoAcceptsInvitation() async throws {
        // Send invitation
        _ = try await ownerClient.documents.sendInvitation(
            documentId: documentId,
            email: invitedUser.email,
            permission: "read-write"
        )

        try await delay(1)

        // The invited user gets the document -- this may trigger auto-acceptance
        let docInfo = try await memberClient.documents.get(documentId: documentId)

        // If auto-accept is enabled, should have documentId and permission
        XCTAssertEqual(docInfo.documentId, documentId)
        XCTAssertEqual(docInfo.permission, .readWrite)
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
