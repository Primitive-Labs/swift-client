import XCTest
@testable import JsBaoClient

/// Pure parser / builder tests for `client.links` (#931).
///
/// Every shape asserted here is cataloged from the platform's real link
/// producers:
/// - document share link `{base}/document/{id}` —
///   sample-app `ShareDialog.tsx:130-132`
/// - invite accept `{app.baseUrl}/invite/accept?inviteToken={token}` —
///   server `src/app-api/helpers/invitation-helpers.ts:28-37`
/// - magic link `{redirectUri}?magic_token={token}[&purpose=…]` —
///   server `src/app-api/controllers/magic-link-controller.ts:507-515`
final class LinksAPITests: XCTestCase {

    /// Records the request the API would have sent and plays back a
    /// canned response (same pattern as `ApiParityTests.CallRecorder`).
    final class CallRecorder: @unchecked Sendable {
        var method: String?
        var path: String?
        var body: Any?
        var response: Any = [String: Any]()
        var error: Error?
        func make(_ method: String, _ path: String, _ data: Any?) async throws -> Any {
            self.method = method
            self.path = path
            self.body = data
            if let error { throw error }
            return response
        }
    }

    private func makeLinks(
        recorder: CallRecorder = CallRecorder(),
        base: String? = "https://notes.example.com"
    ) -> LinksAPI {
        LinksAPI(
            aliases: DocumentAliasesAPI(makeRequest: recorder.make),
            appBaseURL: base.flatMap { URL(string: $0) }
        )
    }

    private let ulid = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

    // MARK: - Document share links

    func test_parse_documentShareLink_ulid() {
        let links = makeLinks()
        let url = URL(string: "https://notes.example.com/document/\(ulid)")!
        XCTAssertEqual(links.parse(url: url), .document(id: ulid))
    }

    func test_parse_documentShareLink_customScheme() {
        let links = makeLinks()
        // Custom-scheme URLs put the first segment in the host position.
        let hostForm = URL(string: "myapp://document/\(ulid)")!
        XCTAssertEqual(links.parse(url: hostForm), .document(id: ulid))
        // Triple-slash form keeps everything in the path.
        let pathForm = URL(string: "myapp:///document/\(ulid)")!
        XCTAssertEqual(links.parse(url: pathForm), .document(id: ulid))
    }

    func test_parse_documentShareLink_nonUlid_isAlias() {
        let links = makeLinks()
        let url = URL(string: "https://notes.example.com/document/spring-planning")!
        XCTAssertEqual(
            links.parse(url: url),
            .documentAlias(AliasRef(scope: .app, aliasKey: "spring-planning"))
        )
    }

    func test_parse_documentShareLink_percentEncodedAlias() {
        let links = makeLinks()
        let url = URL(string: "https://notes.example.com/document/spring%20planning")!
        XCTAssertEqual(
            links.parse(url: url),
            .documentAlias(AliasRef(scope: .app, aliasKey: "spring planning"))
        )
    }

    func test_parse_documentPathWithPrefix() {
        // Apps may mount the share route under a path prefix; the parser
        // keys on the trailing `document/{segment}` pair. (Same host as the
        // configured app base — the origin guard requires that.)
        let links = makeLinks()
        let url = URL(string: "https://notes.example.com/web/document/\(ulid)")!
        XCTAssertEqual(links.parse(url: url), .document(id: ulid))
    }

    // MARK: - Invitation accept links

    func test_parse_inviteAcceptLink_serverConvention() {
        // Exact `buildAcceptUrl` shape (invitation-helpers.ts:28-37).
        let links = makeLinks()
        let token = "h7K_9qZx-base64url-token"
        let url = URL(
            string: "https://notes.example.com/invite/accept?inviteToken=\(token)"
        )!
        XCTAssertEqual(links.parse(url: url), .invitation(token: token))
    }

    func test_parse_inviteToken_onCustomAcceptPage() {
        // Apps own their accept routing — the token param is the contract.
        // The accept page still has to live on the app's own (trusted) host.
        let links = makeLinks()
        let url = URL(string: "https://notes.example.com/welcome?inviteToken=tok123&utm=email")!
        XCTAssertEqual(links.parse(url: url), .invitation(token: "tok123"))
    }

    // MARK: - Origin guard (#1132 review follow-up)

    func test_parse_foreignHost_isUnknown() {
        // A web link from a host that is neither appBaseURL nor a trusted
        // host must NOT be parsed as a real Primitive link — otherwise a
        // pasted/handed-off `https://evil.example/?inviteToken=…` would drive
        // a confused-deputy `invitations.accept`.
        let links = makeLinks() // base = notes.example.com
        for raw in [
            "https://evil.example/welcome?inviteToken=tok123",
            "https://evil.example/auth?magic_token=abc123",
            "https://evil.example/document/\(ulid)",
        ] {
            let url = URL(string: raw)!
            XCTAssertEqual(links.parse(url: url), .unknown(url), raw)
        }
    }

    func test_parse_trustedLinkHosts_allowsAdditionalHost() {
        // A magic-link redirectUri served on a different domain than the web
        // base is honored once added to trustedLinkHosts.
        let links = makeLinks()
        links.trustedLinkHosts = ["auth.example.com"]
        let url = URL(string: "https://auth.example.com/callback?magic_token=abc123")!
        XCTAssertEqual(links.parse(url: url), .magicLink(token: "abc123", purpose: nil))
    }

    func test_parse_customScheme_bypassesOriginGuard() {
        // Custom schemes are registered to this app, so the OS scopes their
        // delivery — they are trusted regardless of the "host" segment.
        let links = makeLinks()
        let url = URL(string: "myapp://anything/welcome?inviteToken=tok123")!
        XCTAssertEqual(links.parse(url: url), .invitation(token: "tok123"))
    }

    func test_parse_withoutConfiguredHost_rejectsWebLinks() {
        // With no appBaseURL and no trustedLinkHosts, a pasted web URL has
        // no app-owned origin to validate against.
        let links = makeLinks(base: nil)
        let url = URL(string: "https://anywhere.example/welcome?inviteToken=tok123")!
        XCTAssertEqual(links.parse(url: url), .unknown(url))
    }

    func test_parse_inviteAcceptPath_withoutToken_isUnknown() {
        let links = makeLinks()
        let url = URL(string: "https://notes.example.com/invite/accept")!
        XCTAssertEqual(links.parse(url: url), .unknown(url))
    }

    // MARK: - Magic links

    func test_parse_magicLink() {
        let links = makeLinks()
        let url = URL(string: "https://notes.example.com/auth?magic_token=abc123")!
        XCTAssertEqual(links.parse(url: url), .magicLink(token: "abc123", purpose: nil))
    }

    func test_parse_magicLink_withPurpose() {
        // `buildMagicLink` adds `purpose` for non-standard flows
        // (magic-link-controller.ts:510-513).
        let links = makeLinks()
        let url = URL(
            string: "https://notes.example.com/auth?magic_token=abc123&purpose=login-add-passkey"
        )!
        XCTAssertEqual(
            links.parse(url: url),
            .magicLink(token: "abc123", purpose: "login-add-passkey")
        )
    }

    // MARK: - Unknown

    func test_parse_unknownLink() {
        let links = makeLinks()
        for raw in [
            "https://notes.example.com/",
            "https://notes.example.com/settings",
            "https://notes.example.com/document/",
            "myapp://settings/profile",
        ] {
            let url = URL(string: raw)!
            XCTAssertEqual(links.parse(url: url), .unknown(url), raw)
        }
    }

    // MARK: - Builders + round trips

    func test_shareURL_roundTrip_documentId() {
        let links = makeLinks()
        let url = links.shareURL(forDocument: ulid)
        XCTAssertEqual(
            url?.absoluteString,
            "https://notes.example.com/document/\(ulid)"
        )
        XCTAssertEqual(links.parse(url: url!), .document(id: ulid))
    }

    func test_shareURL_roundTrip_alias() {
        let links = makeLinks()
        let url = links.shareURL(forDocument: ulid, alias: "spring-planning")
        XCTAssertEqual(
            url?.absoluteString,
            "https://notes.example.com/document/spring-planning"
        )
        XCTAssertEqual(
            links.parse(url: url!),
            .documentAlias(AliasRef(scope: .app, aliasKey: "spring-planning"))
        )
    }

    func test_shareURL_aliasEncodesSinglePathSegment() {
        let links = makeLinks()
        let url = links.shareURL(forDocument: ulid, alias: "folder/spring planning?#1")
        XCTAssertEqual(
            url?.absoluteString,
            "https://notes.example.com/document/folder%2Fspring%20planning%3F%231"
        )
        XCTAssertEqual(
            links.parse(url: url!),
            .documentAlias(AliasRef(scope: .app, aliasKey: "folder/spring planning?#1"))
        )
    }

    func test_shareURL_trailingSlashBase() {
        // Server normalizes app.baseUrl by stripping trailing slashes
        // (settings-controller.ts:348-353); the builder tolerates them too.
        let links = makeLinks(base: "https://notes.example.com/")
        XCTAssertEqual(
            links.shareURL(forDocument: ulid)?.absoluteString,
            "https://notes.example.com/document/\(ulid)"
        )
    }

    func test_inviteAcceptURL_roundTrip() {
        let links = makeLinks()
        let token = "h7K_9qZx-base64url-token"
        let url = links.inviteAcceptURL(inviteToken: token)
        XCTAssertEqual(
            url?.absoluteString,
            "https://notes.example.com/invite/accept?inviteToken=\(token)"
        )
        XCTAssertEqual(links.parse(url: url!), .invitation(token: token))
    }

    func test_builders_returnNil_withoutBaseURL() {
        let links = makeLinks(base: nil)
        XCTAssertNil(links.shareURL(forDocument: ulid))
        XCTAssertNil(links.inviteAcceptURL(inviteToken: "tok"))
    }

    // MARK: - resolve(url:) plumbing

    func test_resolve_aliasLink_callsAliasEndpoint() async throws {
        let recorder = CallRecorder()
        recorder.response = [
            "aliasKey": "spring-planning",
            "scope": "app",
            "documentId": ulid,
        ]
        let links = makeLinks(recorder: recorder)
        let url = URL(string: "https://notes.example.com/document/spring-planning")!
        let target = try await links.resolve(url: url)
        XCTAssertEqual(target, .document(id: ulid))
        XCTAssertEqual(recorder.method, "GET")
        XCTAssertEqual(recorder.path, "/document-aliases/app/spring-planning")
    }

    func test_resolve_documentLink_isPure() async throws {
        let recorder = CallRecorder()
        let links = makeLinks(recorder: recorder)
        let url = URL(string: "https://notes.example.com/document/\(ulid)")!
        let target = try await links.resolve(url: url)
        XCTAssertEqual(target, .document(id: ulid))
        XCTAssertNil(recorder.method, "no request expected for a concrete-id link")
    }

    func test_resolve_unknownAlias_throwsAliasNotFound() async {
        let recorder = CallRecorder()
        recorder.error = JsBaoError(code: .notFound, message: "HTTP 404")
        let links = makeLinks(recorder: recorder)
        let url = URL(string: "https://notes.example.com/document/no-such-alias")!
        do {
            _ = try await links.resolve(url: url)
            XCTFail("expected aliasNotFound")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .aliasNotFound)
        } catch {
            XCTFail("expected JsBaoError, got \(error)")
        }
    }

    #if canImport(ObjectiveC)
    func test_resolve_userActivity() async throws {
        let links = makeLinks()
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = URL(string: "https://notes.example.com/document/\(ulid)")
        let target = try await links.resolve(userActivity: activity)
        XCTAssertEqual(target, .document(id: ulid))
    }

    func test_resolve_userActivity_withoutURL_throws() async {
        let links = makeLinks()
        let activity = NSUserActivity(activityType: "com.example.custom")
        do {
            _ = try await links.resolve(userActivity: activity)
            XCTFail("expected invalidArgument")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
        } catch {
            XCTFail("expected JsBaoError, got \(error)")
        }
    }
    #endif
}
