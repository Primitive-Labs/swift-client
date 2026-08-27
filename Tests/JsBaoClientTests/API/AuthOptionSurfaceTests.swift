import XCTest
@testable import JsBaoClient

/// Auth option-surface parity (#1147, follow-up to #964): a Swift caller must
/// be able to express the same auth options a JS caller can —
/// `startOAuthFlow({ waitlist, inviteToken })`, `magicLinkVerify({ inviteToken })`,
/// and `logout({ revokeOffline, wipeLocal, clearOfflineIdentity, waitForDisconnect })`.
///
/// (`otpVerify`'s `inviteToken` was already covered by #1077/#1110 in
/// `AuthOtpInviteTokenTests`; not re-tested here.)
///
/// None of these hit the network: the OAuth tests assert the base64 state-bag
/// shape the JS client builds; the magic-link tests stub
/// `AuthController.makeRequest` and assert the exact POST body; the logout
/// tests assert the option bag is forwarded to the controller.
final class AuthOptionSurfaceTests: XCTestCase {

    // MARK: - OAuth state bag: waitlist + inviteToken (#466)

    private func decodeState(_ state: String) throws -> [String: Any] {
        let data = try XCTUnwrap(Data(base64Encoded: state))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testEncodeOAuthStateThreadsInviteToken() throws {
        let state = try AuthController.encodeOAuthState(
            redirectUri: "com.example:/oauth2redirect/google",
            inviteToken: "invite-tok-1",
            nonce: "n"
        )
        let json = try decodeState(state)
        XCTAssertEqual(json["inviteToken"] as? String, "invite-tok-1")
    }

    func testEncodeOAuthStateTrimsInviteToken() throws {
        let state = try AuthController.encodeOAuthState(
            redirectUri: "com.example:/cb",
            inviteToken: "  invite-tok-2 \n",
            nonce: "n"
        )
        let json = try decodeState(state)
        XCTAssertEqual(json["inviteToken"] as? String, "invite-tok-2")
    }

    func testEncodeOAuthStateOmitsInviteTokenWhenBlank() throws {
        let state = try AuthController.encodeOAuthState(
            redirectUri: "com.example:/cb",
            inviteToken: "   ",
            nonce: "n"
        )
        let json = try decodeState(state)
        XCTAssertFalse(json.keys.contains("inviteToken"))
    }

    func testEncodeOAuthStateThreadsWaitlist() throws {
        let state = try AuthController.encodeOAuthState(
            redirectUri: "com.example:/cb",
            waitlist: OAuthWaitlist(source: "campaign", note: "from ios"),
            nonce: "n"
        )
        let json = try decodeState(state)
        let waitlist = try XCTUnwrap(json["waitlist"] as? [String: Any])
        XCTAssertEqual(waitlist["source"] as? String, "campaign")
        XCTAssertEqual(waitlist["note"] as? String, "from ios")
    }

    func testEncodeOAuthStateTrimsAndClampsWaitlistFields() throws {
        // JS trims both fields and clamps each to 255 chars.
        let longNote = String(repeating: "x", count: 300)
        let state = try AuthController.encodeOAuthState(
            redirectUri: "com.example:/cb",
            waitlist: OAuthWaitlist(source: "  src  ", note: longNote),
            nonce: "n"
        )
        let json = try decodeState(state)
        let waitlist = try XCTUnwrap(json["waitlist"] as? [String: Any])
        XCTAssertEqual(waitlist["source"] as? String, "src")
        XCTAssertEqual((waitlist["note"] as? String)?.count, 255)
    }

    func testEncodeOAuthStateOmitsWaitlistWhenAllFieldsBlank() throws {
        // JS only attaches `waitlist` when at least one field survives trimming.
        let state = try AuthController.encodeOAuthState(
            redirectUri: "com.example:/cb",
            waitlist: OAuthWaitlist(source: "   ", note: nil),
            nonce: "n"
        )
        let json = try decodeState(state)
        XCTAssertFalse(json.keys.contains("waitlist"))
    }

    func testEncodeOAuthStateOmitsBothWhenAbsent() throws {
        // Back-compat: a state with neither option matches the original shape.
        let state = try AuthController.encodeOAuthState(
            redirectUri: "com.example:/cb",
            nonce: "n"
        )
        let json = try decodeState(state)
        XCTAssertFalse(json.keys.contains("waitlist"))
        XCTAssertFalse(json.keys.contains("inviteToken"))
        XCTAssertEqual(json["redirectUri"] as? String, "com.example:/cb")
        XCTAssertEqual(json["nonce"] as? String, "n")
    }

    // MARK: - magicLinkVerify inviteToken (#466)

    /// Canned magic-link-verify response. It carries a real (decodable) JWT
    /// because a 2xx verify without a `token` is a broken server contract the
    /// controller rejects (#1991 Phase B3). These tests only assert the
    /// outbound request body, so the token just has to be applicable.
    private static let magicLinkResponse = #"""
    {"token": "\#(makeTestJwt(userId: "u1"))", "user": {"userId": "u1", "email": "ml@example.com"}, "isNewUser": false}
    """#

    private func makeRecorder() -> RecordingTransport {
        RecordingTransport(json: Self.magicLinkResponse)
    }

    private func makeClient(_ recorder: RecordingTransport) -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://localhost:8787",
            wsUrl: "ws://localhost:8787",
            appId: "test-app",
            offline: true
        ))
        client.authController.replaceTransportForTesting(recorder)
        return client
    }

    /// JS parity: the top-level `magicLinkVerify(token, { inviteToken })`
    /// forwards `inviteToken` to the auth controller. The Swift wrapper
    /// previously dropped it.
    func test_topLevel_magicLinkVerify_forwardsInviteToken() async throws {
        let r = makeRecorder()
        let client = makeClient(r)
        defer { Task { await client.destroy() } }

        _ = try await client.magicLinkVerify(token: "ml-token", inviteToken: "invite-tok-ml")

        // Select the verify call by path rather than taking the last one: a
        // token-less client now issues a startup POST /auth/refresh (#2656),
        // which can land after this call.
        let call = r.lastCall(to: "/auth/magic-link/verify")
        XCTAssertEqual(call?.method, .post)
        let body = call?.jsonBody
        XCTAssertEqual(body?["token"]?.stringValue, "ml-token")
        XCTAssertEqual(body?["inviteToken"]?.stringValue, "invite-tok-ml")
    }

    /// Source compatibility: the one-arg call still works and sends no
    /// inviteToken (same body shape JS sends: just the token).
    func test_topLevel_magicLinkVerify_omitsInviteToken_whenNotPassed() async throws {
        let r = makeRecorder()
        let client = makeClient(r)
        defer { Task { await client.destroy() } }

        _ = try await client.magicLinkVerify(token: "ml-token")

        let body = r.lastCall(to: "/auth/magic-link/verify")?.jsonBody
        XCTAssertNotNil(body)
        XCTAssertNil(body?["inviteToken"])
        XCTAssertEqual(body?["token"]?.stringValue, "ml-token")
    }

    func test_topLevel_magicLinkVerify_trimsAndOmitsBlankInviteToken() async throws {
        let r = makeRecorder()
        let client = makeClient(r)
        defer { Task { await client.destroy() } }

        _ = try await client.magicLinkVerify(token: "ml-token", inviteToken: "   ")

        let body = r.lastCall(to: "/auth/magic-link/verify")?.jsonBody
        XCTAssertNil(body?["inviteToken"])
    }

    // MARK: - LogoutOptions surface

    /// The top-level `logout(options:)` overload accepts the full JS option
    /// bag. We can't observe the controller's private effects here, but the
    /// call must compile and run cleanly with every field set — proving the
    /// surface exists and forwards. (The controller-level honoring of each
    /// field is covered by the auth-controller logout tests.)
    func test_topLevel_logout_acceptsFullOptionBag() async throws {
        let r = makeRecorder()
        let client = makeClient(r)
        defer { Task { await client.destroy() } }

        try await client.logout(options: LogoutOptions(
            revokeOffline: true,
            wipeLocal: true,
            clearOfflineIdentity: false,
            waitForDisconnect: true
        ))

        XCTAssertFalse(client.isAuthenticated())
    }

    /// Source compatibility: the original `logout(wipeLocal:)` overload still
    /// works and is equivalent to `logout(options: .init(wipeLocal:))`.
    func test_topLevel_logout_wipeLocalOverload_stillWorks() async throws {
        let r = makeRecorder()
        let client = makeClient(r)
        defer { Task { await client.destroy() } }

        try await client.logout(wipeLocal: true)
        XCTAssertFalse(client.isAuthenticated())
    }

    /// Regression: `client.auth.logout(options:)` must route through the
    /// top-level client cleanup path, not directly to `AuthController`, so
    /// `wipeLocal` clears cached document data.
    ///
    /// JS parity (#2874): the logout itself closes every open document —
    /// `authController.logout` awaits the client's cleanup hook before it
    /// signals completion — and the `wipeLocal` purge runs after that sweep.
    /// So a still-open local-only document is closed by the logout, its
    /// persisted data and metadata row go with the wipe, and `hasLocalCopy`
    /// is `false` the moment the call returns. No explicit close is needed,
    /// and none is available: leaving the previous user's documents open is
    /// what let the next user read their rows.
    ///
    /// This reverses the #2836-era expectation that the document is held
    /// across the wipe. The #2691 marker rule (a local-only marker survives a
    /// store purge while its document is still held) is unchanged for the
    /// non-logout eviction path, `evictAllLocal(force:)`.
    func test_auth_logout_options_wipeLocal_clearsLocalDocuments() async throws {
        let r = makeRecorder()
        let client = makeClient(r)
        defer { Task { await client.destroy() } }

        let (docId, _) = try await client.createDocumentForTest(
            options: CreateDocumentOptions(localOnly: true)
        )
        XCTAssertTrue(client.hasLocalCopy(docId))

        try await client.auth.logout(options: LogoutOptions(wipeLocal: true))

        XCTAssertFalse(client.isAuthenticated())
        XCTAssertNil(client.getDoc(docId), "the logout must close the document")
        XCTAssertFalse(client.hasLocalCopy(docId), "closed and wiped: nothing local is left")
    }

    func test_logoutOptions_defaults_matchJS() {
        // JS defaults: clearOfflineIdentity true, the rest false.
        let opts = LogoutOptions()
        XCTAssertFalse(opts.revokeOffline)
        XCTAssertFalse(opts.wipeLocal)
        XCTAssertTrue(opts.clearOfflineIdentity)
        XCTAssertFalse(opts.waitForDisconnect)
    }
}
