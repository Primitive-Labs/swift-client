import XCTest
@testable import JsBaoClient

/// #2980, end to end against the live server: a document shared with a user
/// the server has no `name` for.
///
/// The permissions controller serializes `name: user.name` and JSON drops the
/// undefined key, so a listing that includes an OTP-provisioned user really
/// does arrive with the key missing from that entry. While
/// `DocumentPermissionEntry.name` was a non-optional `String` the array decode
/// threw `keyNotFound("name")` and `getPermissions` failed for the whole
/// document — callers wrapping it in `try?` saw an empty list.
///
/// The decode itself is pinned server-free in
/// `DocumentPermissionsNameOptionalHermeticTests`; this test is what proves the
/// premise that suite's fixture asserts — that the server omits the key — and
/// mirrors the JS pin in
/// `tests/client/js-bao-client-document-permissions-nameless-user.test.ts`.
final class DocumentPermissionsNamelessUserTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var ownerClient: JsBaoClient!
    var documentId: String!
    var namedUserId: String!
    /// The name add-by-email wrote for the named user: the email's local part.
    var namedUserName: String!
    var namelessUserId: String!
    var namelessEmail: String!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-perms-nameless")

        // The `+primitivetest` bypass is per-app: OTP on, base address listed.
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let baseEmail = "perms-nameless-\(suffix)@test.local"
        try await ctx.updateAppSettings(
            appId: testApp.appId,
            settings: ["otpEnabled": true, "testAccountBaseEmails": [baseEmail]]
        )

        // A user with a name: add-by-email writes the local part as one.
        namedUserName = "perms-named-\(suffix)"
        let namedUser = try await ctx.createTestUser(
            appId: testApp.appId,
            role: "member",
            email: "\(namedUserName!)@test.local"
        )
        namedUserId = namedUser.userId

        // A user with no name: the email-code path provisions without one.
        namelessEmail = "perms-nameless-\(suffix)+primitivetest-share@test.local"
        namelessUserId = try await ctx.signInWithTestOtp(
            appId: testApp.appId,
            email: namelessEmail
        )

        documentId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "Swift doc shared with a name-less user"
        )
        for userId in [namedUserId!, namelessUserId!] {
            try await ctx.grantPermission(
                appId: testApp.appId,
                documentId: documentId,
                userId: userId,
                permission: "read-write",
                jwt: testApp.ownerJWT
            )
        }

        // `getPermissions` is a plain HTTP call — no connect needed.
        ownerClient = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
    }

    override func tearDown() async throws {
        await ownerClient?.destroy()
        await ctx?.cleanup()
    }

    func testListingCarriesEveryPermitteeAndTheirName() async throws {
        let entries = try await ownerClient.documents.getPermissions(documentId: documentId)

        let named = try XCTUnwrap(
            entries.first { $0.userId == namedUserId },
            "the named user must be in the listing"
        )
        let nameless = try XCTUnwrap(
            entries.first { $0.userId == namelessUserId },
            "the name-less user must be in the listing — before #2980 the "
            + "missing `name` key failed the whole array decode"
        )

        XCTAssertEqual(named.name, namedUserName)
        XCTAssertEqual(named.permission, .readWrite)
        XCTAssertNil(nameless.name, "the server sends no name for this user")
        XCTAssertEqual(nameless.email, namelessEmail)
        XCTAssertEqual(nameless.permission, .readWrite)
    }
}
