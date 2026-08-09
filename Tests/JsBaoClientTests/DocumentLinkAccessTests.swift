import XCTest
@testable import JsBaoClient

/// Swift-client parity for document link access ("anyone with the link"),
/// issue #1604 — the port of #1564 (set/clear + `linkAccess`/`accessSource` on
/// document-info) plus the dedicated read path from #1623
/// (`GET /documents/:id/link-access` → `documents.getLinkAccess`).
///
/// Live tests against the dev server, matching the JS coverage in
/// `tests/client/js-bao-client-link-access.test.ts`.
final class DocumentLinkAccessTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-linkaccess")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    // MARK: - Set / clear round-trip

    /// Behaviors 1 + 3: `setLinkAccess` turns link access on and reports the
    /// new level; `clearLinkAccess` turns it off and reports `nil`.
    func testSetAndClearLinkAccessRoundTrip() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let docId = try await ctx.createDocument(
            appId: testApp.appId, jwt: testApp.ownerJWT, title: "Link Access Round Trip"
        )

        let set = try await client.documents.setLinkAccess(documentId: docId, level: .reader)
        XCTAssertEqual(set.documentId, docId)
        XCTAssertEqual(set.linkAccess, .reader)
        // The server stamps who/when on a set — parity with js-bao's
        // LinkAccessResult, whose `linkAccessUpdatedBy`/`At` are populated here.
        XCTAssertEqual(set.linkAccessUpdatedBy, testApp.ownerUserId)
        XCTAssertNotNil(set.linkAccessUpdatedAt)

        let cleared = try await client.documents.clearLinkAccess(documentId: docId)
        XCTAssertEqual(cleared.documentId, docId)
        XCTAssertNil(cleared.linkAccess, "clearLinkAccess reports link access off")
    }

    /// Behavior 2: both levels round-trip, including the hyphenated
    /// `read-write` wire value (`DocumentLinkAccessLevel.readWrite`).
    func testSetLinkAccessReadWriteLevel() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let docId = try await ctx.createDocument(
            appId: testApp.appId, jwt: testApp.ownerJWT, title: "Link Access RW"
        )

        let set = try await client.documents.setLinkAccess(documentId: docId, level: .readWrite)
        XCTAssertEqual(set.linkAccess, .readWrite, "read-write decodes to .readWrite")

        // Re-setting to a different level overwrites rather than erroring.
        let downgraded = try await client.documents.setLinkAccess(documentId: docId, level: .reader)
        XCTAssertEqual(downgraded.linkAccess, .reader)
    }

    // MARK: - document-info decode (linkAccess + accessSource)

    /// Behavior 4: the single-document GET surfaces `linkAccess`, and the
    /// owner's `accessSource` is `.owner`.
    func testDocumentInfoSurfacesLinkAccessAndOwnerAccessSource() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let docId = try await ctx.createDocument(
            appId: testApp.appId, jwt: testApp.ownerJWT, title: "Link Access Info"
        )

        // Link access off: the field is absent on the wire → nil.
        let before = try await client.documents.get(documentId: docId)
        XCTAssertNil(before.linkAccess, "linkAccess is nil while link access is off")
        XCTAssertEqual(before.accessSource, .owner, "the document's creator reads as .owner")

        _ = try await client.documents.setLinkAccess(documentId: docId, level: .readWrite)

        let after = try await client.documents.get(documentId: docId)
        XCTAssertEqual(after.linkAccess, .readWrite, "linkAccess is visible on document-info")
        XCTAssertEqual(after.accessSource, .owner, "the owner's access still comes from ownership")
    }

    /// Behavior 5: a member with no explicit grant resolves through the link
    /// floor — `accessSource == .link` — and loses access once it is cleared.
    /// This is the whole point of the feature, and the field that tells an app
    /// the document won't appear in `me/shared-documents`.
    func testLinkViewerSeesAccessSourceLinkAndLosesAccessOnClear() async throws {
        let ownerClient = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await ownerClient.destroy() } }

        let docId = try await ctx.createDocument(
            appId: testApp.appId, jwt: testApp.ownerJWT, title: "Link Viewer"
        )
        let member = try await ctx.createTestUser(appId: testApp.appId, role: "member")
        let memberClient = createTestClient(appId: testApp.appId, token: member.jwt)
        defer { Task { await memberClient.destroy() } }

        // No grant, link access off → no access.
        await XCTAssertThrowsErrorAsync(
            try await memberClient.documents.get(documentId: docId),
            "a member with no grant cannot read the document before link access is on"
        )

        _ = try await ownerClient.documents.setLinkAccess(documentId: docId, level: .reader)

        let viewed = try await memberClient.documents.get(documentId: docId)
        XCTAssertEqual(viewed.documentId, docId)
        XCTAssertEqual(viewed.accessSource, .link, "access came from the link floor, not a grant")
        XCTAssertEqual(viewed.linkAccess, .reader)
        XCTAssertEqual(viewed.permission, .reader, "the link floor sets the effective permission")

        try await ownerClient.documents.clearLinkAccess(documentId: docId)

        await XCTAssertThrowsErrorAsync(
            try await memberClient.documents.get(documentId: docId),
            "clearing link access revokes the link-only viewer"
        )
    }

    // MARK: - getLinkAccess (dedicated read path, #1623)

    /// Behavior 6: `getLinkAccess` reports the current state for a caller who
    /// can read the document, and reflects the last set/clear write.
    func testGetLinkAccessReflectsCurrentState() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let docId = try await ctx.createDocument(
            appId: testApp.appId, jwt: testApp.ownerJWT, title: "Get Link Access"
        )
        try await skipUnlessLinkAccessGetIsDeployed(client: client, documentId: docId)

        // Off → 200 with linkAccess nil (not a 404).
        let off = try await client.documents.getLinkAccess(documentId: docId)
        XCTAssertEqual(off.documentId, docId)
        XCTAssertNil(off.linkAccess, "reports link access off rather than erroring")

        _ = try await client.documents.setLinkAccess(documentId: docId, level: .reader)
        let on = try await client.documents.getLinkAccess(documentId: docId)
        XCTAssertEqual(on.linkAccess, .reader)
        XCTAssertEqual(on.linkAccessUpdatedBy, testApp.ownerUserId)
        XCTAssertNotNil(on.linkAccessUpdatedAt)

        try await client.documents.clearLinkAccess(documentId: docId)
        let cleared = try await client.documents.getLinkAccess(documentId: docId)
        XCTAssertNil(cleared.linkAccess)
    }

    /// Behavior 7: the reason the dedicated endpoint exists (#1623) — an app
    /// owner who can MANAGE a member's private document but holds no content
    /// grant can read its link state via `getLinkAccess`, while the
    /// content-gated `get` refuses them.
    func testAppOwnerWithoutContentGrantCanGetLinkAccess() async throws {
        let member = try await ctx.createTestUser(appId: testApp.appId, role: "member")
        // The document is created BY the member, so the app owner has no
        // content grant on it — only app-level management authority.
        let docId = try await ctx.createDocument(
            appId: testApp.appId, jwt: member.jwt, title: "Member Private Doc"
        )

        let ownerClient = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await ownerClient.destroy() } }
        try await skipUnlessLinkAccessGetIsDeployed(client: ownerClient, documentId: docId)

        // The content-gated document GET refuses the app owner...
        await XCTAssertThrowsErrorAsync(
            try await ownerClient.documents.get(documentId: docId),
            "the document GET requires content access, which the app owner lacks"
        )

        // ...but the dedicated link-access read admits them.
        let state = try await ownerClient.documents.getLinkAccess(documentId: docId)
        XCTAssertEqual(state.documentId, docId)
        XCTAssertNil(state.linkAccess, "link access is off, and that is readable")

        // And it tracks a write the app owner is already authorized to make.
        _ = try await ownerClient.documents.setLinkAccess(documentId: docId, level: .reader)
        let afterSet = try await ownerClient.documents.getLinkAccess(documentId: docId)
        XCTAssertEqual(afterSet.linkAccess, .reader)
    }

    // MARK: - Authorization and guards

    /// Behavior 8: a plain member with no grant may not change link access.
    func testMemberWithoutGrantCannotSetLinkAccess() async throws {
        let docId = try await ctx.createDocument(
            appId: testApp.appId, jwt: testApp.ownerJWT, title: "Link Access Authz"
        )
        let member = try await ctx.createTestUser(appId: testApp.appId, role: "member")
        let memberClient = createTestClient(appId: testApp.appId, token: member.jwt)
        defer { Task { await memberClient.destroy() } }

        await XCTAssertThrowsErrorAsync(
            try await memberClient.documents.setLinkAccess(documentId: docId, level: .reader),
            "only document owners, app owners, or editors can change link access"
        )
    }

    /// Behavior 9: root documents cannot be link-shared. The guard is
    /// client-side on set/clear, mirroring js-bao — it throws
    /// `invalidArgument` without a round trip. The root document id comes from
    /// the JWT (`isRootDocument` is a local read), so this needs no root row on
    /// the server.
    func testRootDocumentCannotBeLinkShared() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let rootDocId = try XCTUnwrap(client.rootDocId, "test JWT should carry a rootDocId")
        XCTAssertTrue(client.isRootDocument(rootDocId))

        do {
            _ = try await client.documents.setLinkAccess(documentId: rootDocId, level: .reader)
            XCTFail("setLinkAccess on the root document should throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertEqual(error.message, "Root documents cannot be shared")
        }

        do {
            _ = try await client.documents.clearLinkAccess(documentId: rootDocId)
            XCTFail("clearLinkAccess on the root document should throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertEqual(error.message, "Root documents cannot be shared")
        }
    }

    // MARK: - Helpers

    /// `GET /documents/:id/link-access` ships in #1623 (PR #1679), which had
    /// not merged when this port was written — the sponsor authorized building
    /// against its approved spec. Until it lands, a server without the route
    /// answers 404 for a document that demonstrably exists, so skip rather
    /// than fail.
    ///
    /// The skip is deliberately keyed to the *route-miss* 404 only, because 404
    /// is also a legitimate response of this endpoint once it exists (#1679's
    /// `openapi.json` declares `404: Document not found`). The two are
    /// distinguishable on the wire — every app-api error body is
    /// `corsErrorResponse`-shaped `{ error, status, timestamp }` (`src/utils.ts:385`):
    ///
    /// - route not registered → `error: "API endpoint not found"`
    ///   (`src/app-api.ts:7168`, the `documents/*` dispatch fallback)
    /// - route registered, document missing → `error: "Document not found"`
    ///   (`src/app-api/helpers/document-helpers.ts:157`)
    ///
    /// Callers pass a document they just created, so a "Document not found" 404
    /// is a real regression — it must reach the test and go red, not skip.
    ///
    /// TODO(#1623): delete this probe once PR #1679 is on main. After that any
    /// 404 here means the endpoint is broken rather than absent, and the
    /// remaining route-miss skip below would hide a deregistered route.
    private func skipUnlessLinkAccessGetIsDeployed(
        client: JsBaoClient,
        documentId: String
    ) async throws {
        do {
            _ = try await client.documents.getLinkAccess(documentId: documentId)
        } catch let error as HttpError where error.status == 404
            && (error.serverMessage ?? error.body ?? "").contains("API endpoint not found") {
            throw XCTSkip(
                "GET /documents/:id/link-access is not deployed on this server — "
                + "it ships with #1623 (PR #1679). Skipping the getLinkAccess coverage."
            )
        } catch {
            // Any other error (e.g. a 403, or a "Document not found" 404) means
            // the route exists; the test itself asserts the real behavior.
        }
    }
}
