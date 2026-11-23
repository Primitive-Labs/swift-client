import XCTest
@testable import JsBaoClient

/// The two sign-in rules the client owns: where an emailed link lands
/// (`emailSignInLinkTarget`) and which callback URLs `handleSignInCallback`
/// accepts. They mirror the JS client's `signInRules.ts` rule for rule, with
/// Swift's accepted origins: `links.appBaseURL`'s and the scheme
/// `oauthRedirectUri` registers.
///
/// Pure functions only: no client, no session, no request.
final class SignInRulesHermeticTests: XCTestCase {

    private let base = URL(string: "https://app.example")!

    private func target(
        _ target: EmailSignInTarget,
        oauthRedirectUri: String? = nil,
        appBaseURL: URL? = nil
    ) -> String? {
        SignInRules.emailSignInLinkTarget(
            target,
            oauthRedirectUri: oauthRedirectUri,
            appBaseURL: appBaseURL
        )
    }

    private func parse(
        _ url: String,
        appBaseURL: URL? = URL(string: "https://app.example"),
        oauthRedirectUri: String? = nil
    ) throws -> SignInRules.ParsedSignInCallback {
        try SignInRules.parseSignInCallbackURL(
            URL(string: url)!,
            appBaseURL: appBaseURL,
            oauthRedirectUri: oauthRedirectUri
        )
    }

    /// Asserts the URL is refused with the coded `AuthError`, that the message
    /// names `rule`, and that no credential value leaks into it.
    private func assertRefused(
        _ url: String,
        naming rule: String,
        appBaseURL: URL? = URL(string: "https://app.example"),
        oauthRedirectUri: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try parse(url, appBaseURL: appBaseURL, oauthRedirectUri: oauthRedirectUri)
            XCTFail("expected \(url) to be refused", file: file, line: line)
        } catch let error as AuthError {
            XCTAssertEqual(error.code, .invalidToken, file: file, line: line)
            XCTAssertTrue(
                error.message.hasPrefix("Sign-in callback refused:"),
                error.message, file: file, line: line
            )
            XCTAssertTrue(
                error.message.contains(rule),
                "\(error.message) should name \(rule)", file: file, line: line
            )
            for secret in ["SECRETTOKEN", "SECRETCODE", stateFor(["inviteToken": "SECRETINVITE"])] {
                XCTAssertFalse(error.message.contains(secret), file: file, line: line)
            }
        } catch {
            XCTFail("expected AuthError, got \(error)", file: file, line: line)
        }
    }

    private func stateFor(_ bag: [String: Any]) -> String {
        try! JSONSerialization.data(withJSONObject: bag, options: [.sortedKeys])
            .base64EncodedString()
    }

    private func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)!
    }

    // MARK: - The link-target rule

    func testAnExplicitTargetWinsOverEverythingConfigured() {
        XCTAssertEqual(
            target(.uri("https://x.test/cb"), oauthRedirectUri: "myapp://oauth/callback", appBaseURL: base),
            "https://x.test/cb"
        )
    }

    func testCodeOnlyAnswersNilWhateverIsConfigured() {
        XCTAssertNil(target(.codeOnly, oauthRedirectUri: "myapp://oauth/callback", appBaseURL: base))
        XCTAssertNil(target(.codeOnly))
    }

    func testAutomaticPrefersTheOptionThenTheBaseURLThenNothing() {
        XCTAssertEqual(
            target(.automatic, oauthRedirectUri: "myapp://oauth/callback", appBaseURL: base),
            "myapp://oauth/callback"
        )
        XCTAssertEqual(target(.automatic, appBaseURL: base), "https://app.example/oauth/callback")
        XCTAssertNil(target(.automatic))
    }

    func testEmptyStringsCountAsAbsent() {
        XCTAssertEqual(target(.uri(""), appBaseURL: base), "https://app.example/oauth/callback")
        XCTAssertEqual(target(.uri(""), oauthRedirectUri: "", appBaseURL: base), "https://app.example/oauth/callback")
        XCTAssertNil(target(.uri(""), oauthRedirectUri: ""))
    }

    func testTheDerivedTargetIsTheBaseURLsOriginAlone() {
        XCTAssertEqual(
            target(.automatic, appBaseURL: URL(string: "https://App.Example:8443/base/")!),
            "https://app.example:8443/oauth/callback"
        )
        XCTAssertEqual(
            target(.automatic, appBaseURL: URL(string: "https://a.example/app/")!),
            "https://a.example/oauth/callback"
        )
        XCTAssertEqual(
            target(.automatic, appBaseURL: URL(string: "http://localhost:5173")!),
            "http://localhost:5173/oauth/callback"
        )
    }

    func testANonHttpBaseURLContributesNothing() {
        XCTAssertNil(target(.automatic, appBaseURL: URL(string: "myapp://home")!))
        XCTAssertNil(target(.automatic, appBaseURL: URL(string: "file:///tmp/x")!))
    }

    // MARK: - Callback grammar: accepted URLs

    func testAMagicTokenOnTheBaseOriginIsAMagicLink() throws {
        let parsed = try parse("https://app.example/oauth/callback?magic_token=t")
        XCTAssertEqual(parsed.credential, .magicToken("t"))
        XCTAssertNil(parsed.state)
        XCTAssertNil(parsed.stateBag)
        XCTAssertNil(parsed.purpose)
    }

    func testACodeWithStateIsOAuthWithTheRawStateAndItsBag() throws {
        let state = stateFor(["nonce": "n", "continueUrl": "/next"])
        let parsed = try parse(
            "https://app.example/oauth/callback?code=c&state=\(percentEncoded(state))"
        )
        XCTAssertEqual(parsed.credential, .oauth(code: "c", state: state))
        XCTAssertEqual(parsed.state, state)
        XCTAssertEqual(parsed.stateBag?["continueUrl"], .string("/next"))
    }

    func testPurposeIsSurfacedAndOtherParametersAndTheFragmentIgnored() throws {
        let parsed = try parse(
            "https://app.example/oauth/callback?utm=x&magic_token=t&purpose=login-add-passkey#frag"
        )
        XCTAssertEqual(parsed.credential, .magicToken("t"))
        XCTAssertEqual(parsed.purpose, "login-add-passkey")

        let other = try parse("https://app.example/oauth/callback?magic_token=t&purpose=other")
        XCTAssertNil(other.purpose)
    }

    func testStateBesideAMagicTokenIsTheAppsBag() throws {
        let state = stateFor(["inviteToken": "inv", "continueUrl": "/x"])
        let parsed = try parse(
            "https://app.example/oauth/callback?magic_token=t&state=\(percentEncoded(state))"
        )
        XCTAssertEqual(parsed.credential, .magicToken("t"))
        XCTAssertEqual(parsed.stateBag?["inviteToken"], .string("inv"))
    }

    func testStateDecodesLeniently() throws {
        // `{"a":"??>"}` encodes with '+' and '/', and needs padding.
        let raw = Data(#"{"a":"??>","b":1}"#.utf8).base64EncodedString()
        XCTAssertTrue(raw.contains("+") || raw.contains("/"))
        let spaced = raw.replacingOccurrences(of: "+", with: " ")
        let url64 = raw.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        for variant in [raw, spaced, url64] {
            XCTAssertEqual(
                SignInRules.decodeStateBag(variant)?["a"], .string("??>"),
                "variant \(variant)"
            )
        }
        XCTAssertNil(SignInRules.decodeStateBag(Data("[1,2]".utf8).base64EncodedString()))
        XCTAssertNil(SignInRules.decodeStateBag(Data("\"s\"".utf8).base64EncodedString()))
        XCTAssertNil(SignInRules.decodeStateBag("not base64 json"))
    }

    func testStateAcceptsTheJSClientsByteStringEncoding() {
        // JS `btoa(JSON.stringify({continueUrl: "/café"}))`: 'é' is the
        // single byte 0xE9, not UTF-8. JS `atob` + `JSON.parse` reads it back.
        XCTAssertEqual(
            SignInRules.decodeStateBag("eyJjb250aW51ZVVybCI6Ii9jYWbpIn0=")?["continueUrl"],
            .string("/café")
        )
        // A Swift-produced (UTF-8) bag keeps its text.
        let utf8 = Data(#"{"continueUrl":"/café"}"#.utf8).base64EncodedString()
        XCTAssertEqual(SignInRules.decodeStateBag(utf8)?["continueUrl"], .string("/café"))
    }

    func testStateFollowsAtobsBase64Grammar() {
        // Accepted by JS `atob` after the normalization: no padding, one
        // padding character, whitespace, non-zero trailing bits.
        for accepted in ["e30=", "e30", "e30\t", "e31"] {
            XCTAssertEqual(SignInRules.decodeStateBag(accepted), [:], "accepted \(accepted.debugDescription)")
        }
        // Refused by JS `atob`: excess or misplaced padding.
        for refused in ["e30==", "e30===", "e3=0", "e30=\n", "=e30"] {
            XCTAssertNil(SignInRules.decodeStateBag(refused), "refused \(refused.debugDescription)")
        }
    }

    // MARK: - Callback grammar: origin and scheme

    func testAnHttpURLIsAcceptedOnlyOnTheBaseURLsOrigin() throws {
        XCTAssertNoThrow(try parse("https://APP.example:443/oauth/callback?magic_token=t"))
        assertRefused("https://other.example/oauth/callback?magic_token=SECRETTOKEN", naming: "origin")
        assertRefused("http://app.example/oauth/callback?magic_token=SECRETTOKEN", naming: "origin")
        assertRefused("https://app.example:8443/oauth/callback?magic_token=SECRETTOKEN", naming: "origin")
        assertRefused(
            "http://localhost:5173/oauth/callback?magic_token=SECRETTOKEN",
            naming: "origin",
            appBaseURL: URL(string: "http://localhost:5174")
        )
        XCTAssertNoThrow(try parse(
            "http://localhost:5173/oauth/callback?magic_token=t",
            appBaseURL: URL(string: "http://localhost:5173/app/")
        ))
    }

    func testAnHttpOptionOnAnotherOriginAddsNoOriginButSetsThePath() throws {
        let option = "https://other.example/cb"
        assertRefused(
            "https://other.example/cb?magic_token=SECRETTOKEN",
            naming: "origin",
            oauthRedirectUri: option
        )
        XCTAssertNoThrow(try parse("https://app.example/cb?magic_token=t", oauthRedirectUri: option))
        assertRefused(
            "https://app.example/oauth/callback?magic_token=SECRETTOKEN",
            naming: "path",
            oauthRedirectUri: option
        )
    }

    func testAnOptionsQueryStringContributesOnlyItsPath() throws {
        XCTAssertNoThrow(try parse(
            "https://app.example/cb?magic_token=t",
            oauthRedirectUri: "https://app.example/cb?x=1"
        ))
        XCTAssertNoThrow(try parse(
            "myapp://oauth/callback?magic_token=t",
            oauthRedirectUri: "myapp://oauth/callback?x=1"
        ))
    }

    func testWithNoBaseURLEveryHttpURLIsRefused() {
        assertRefused(
            "https://app.example/oauth/callback?magic_token=SECRETTOKEN",
            naming: "origin",
            appBaseURL: nil
        )
        assertRefused(
            "https://app.example/cb?magic_token=SECRETTOKEN",
            naming: "origin",
            appBaseURL: nil,
            oauthRedirectUri: "https://app.example/cb"
        )
    }

    func testTheSchemeOptionRegistersItsScheme() throws {
        let option = "myapp://oauth/callback"
        for url in [
            "myapp://oauth/callback?magic_token=t",
            "myapp:///oauth/callback?magic_token=t",
            "MyApp://oauth/callback?magic_token=t",
        ] {
            XCTAssertEqual(
                try parse(url, appBaseURL: nil, oauthRedirectUri: option).credential,
                .magicToken("t"),
                url
            )
        }
        XCTAssertNoThrow(try parse(
            "myapp:///oauth/callback?magic_token=t",
            appBaseURL: nil,
            oauthRedirectUri: "myapp:///oauth/callback"
        ))
        // An https callback still needs the base URL's origin, and its path
        // falls back to /oauth/callback when the option is a scheme URL.
        XCTAssertNoThrow(try parse("https://app.example/oauth/callback?magic_token=t", oauthRedirectUri: option))
        assertRefused(
            "https://other.example/oauth/callback?magic_token=SECRETTOKEN",
            naming: "origin",
            oauthRedirectUri: option
        )
        assertRefused(
            "myapp://oauth/other?magic_token=SECRETTOKEN",
            naming: "path",
            oauthRedirectUri: option
        )
    }

    func testASchemeURLIsRefusedUnlessTheOptionNamesThatScheme() {
        assertRefused("myapp://oauth/callback?magic_token=SECRETTOKEN", naming: "scheme")
        assertRefused(
            "otherapp://oauth/callback?magic_token=SECRETTOKEN",
            naming: "scheme",
            oauthRedirectUri: "myapp://oauth/callback"
        )
        assertRefused(
            "ftp://app.example/oauth/callback?magic_token=SECRETTOKEN",
            naming: "scheme"
        )
    }

    // MARK: - Callback grammar: path

    func testThePathMatchesExactlyInPercentEncodedForm() {
        assertRefused("https://app.example/oauth%2Fcallback?magic_token=SECRETTOKEN", naming: "path")
        assertRefused("https://app.example/oauth/callback/?magic_token=SECRETTOKEN", naming: "path")
        assertRefused("https://app.example/Oauth/callback?magic_token=SECRETTOKEN", naming: "path")
        assertRefused("https://app.example/other?magic_token=SECRETTOKEN", naming: "path")
        assertRefused("https://app.example?magic_token=SECRETTOKEN", naming: "path /")
    }

    func testCallbackPathReadsASchemeURLsHostAsTheFirstSegment() {
        XCTAssertEqual(SignInRules.callbackPath(of: URL(string: "myapp://oauth/callback")!), "/oauth/callback")
        XCTAssertEqual(SignInRules.callbackPath(of: URL(string: "myapp:///oauth/callback")!), "/oauth/callback")
        XCTAssertEqual(SignInRules.callbackPath(of: URL(string: "myapp://oauth/a%2Fb")!), "/oauth/a%2Fb")
        XCTAssertEqual(SignInRules.callbackPath(of: URL(string: "https://a.example")!), "/")
        XCTAssertEqual(SignInRules.callbackPath(of: URL(string: "https://a.example/oauth%2Fcallback")!), "/oauth%2Fcallback")
    }

    func testHttpOriginKeepsAnExplicitPortAndLowercasesTheHost() {
        XCTAssertEqual(SignInRules.httpOrigin(of: URL(string: "http://LocalHost:5173/x")!), "http://localhost:5173")
        XCTAssertEqual(SignInRules.httpOrigin(of: URL(string: "https://a.example:443/")!), "https://a.example")
        XCTAssertEqual(SignInRules.httpOrigin(of: URL(string: "http://a.example:80")!), "http://a.example")
        XCTAssertNil(SignInRules.httpOrigin(of: URL(string: "myapp://oauth/callback")!))
    }

    // MARK: - Callback grammar: credentials

    func testDuplicatedCredentialsOrStateAreRefused() {
        let state = percentEncoded(stateFor(["nonce": "n"]))
        assertRefused(
            "https://app.example/oauth/callback?magic_token=SECRETTOKEN&magic_token=SECRETTOKEN",
            naming: "magic_token appears more than once"
        )
        assertRefused(
            "https://app.example/oauth/callback?code=SECRETCODE&code=SECRETCODE&state=\(state)",
            naming: "code appears more than once"
        )
        assertRefused(
            "https://app.example/oauth/callback?code=SECRETCODE&state=\(state)&state=\(state)",
            naming: "state appears more than once"
        )
    }

    func testEmptyCredentialsAreRefused() {
        assertRefused("https://app.example/oauth/callback?code=", naming: "code is empty")
        assertRefused("https://app.example/oauth/callback?code", naming: "code is empty")
        assertRefused("https://app.example/oauth/callback?magic_token=", naming: "magic_token is empty")
        assertRefused(
            "https://app.example/oauth/callback?magic_token=SECRETTOKEN&state=",
            naming: "state is empty"
        )
    }

    func testIncompleteOrMixedCredentialsAreRefused() {
        let state = percentEncoded(stateFor(["nonce": "n"]))
        assertRefused(
            "https://app.example/oauth/callback?magic_token=SECRETTOKEN&code=SECRETCODE&state=\(state)",
            naming: "both magic_token and code"
        )
        assertRefused("https://app.example/oauth/callback?code=SECRETCODE", naming: "code without state")
        assertRefused("https://app.example/oauth/callback?state=\(state)", naming: "no credential")
        assertRefused("https://app.example/oauth/callback", naming: "no credential")
    }

    func testAStateThatIsNotABase64JSONObjectIsRefused() {
        let array = percentEncoded(Data("[1]".utf8).base64EncodedString())
        assertRefused(
            "https://app.example/oauth/callback?code=SECRETCODE&state=\(array)",
            naming: "state is not a base64 JSON object"
        )
        assertRefused(
            "https://app.example/oauth/callback?code=SECRETCODE&state=SECRETCODE",
            naming: "state is not a base64 JSON object"
        )
        assertRefused(
            "https://app.example/oauth/callback?magic_token=SECRETTOKEN&state=e30%3D%3D",
            naming: "state is not a base64 JSON object"
        )
    }

    // MARK: - Mappings

    private func verified(isNewUser: Bool?, prompt: Bool?) throws -> MagicLinkVerifyResult {
        let json = #"{"user":{"userId":"u1","email":"a@b.test","name":"A"},"isNewUser":\#(isNewUser.map(String.init) ?? "null"),"promptAddPasskey":\#(prompt.map(String.init) ?? "null")}"#
        return try JSONDecoder().decode(MagicLinkVerifyResult.self, from: Data(json.utf8))
    }

    func testAVerifiedMagicLinkMapsToTheResult() throws {
        let state = stateFor(["continueUrl": "/next", "inviteToken": "inv"])
        let parsed = try parse(
            "https://app.example/oauth/callback?magic_token=t&purpose=login-add-passkey&state=\(percentEncoded(state))"
        )
        let result = SignInRules.callbackResult(
            from: try verified(isNewUser: true, prompt: false),
            parsed: parsed
        )
        XCTAssertEqual(result.method, .magicLink)
        XCTAssertEqual(result.method.rawValue, "magic-link")
        XCTAssertEqual(result.userId, "u1")
        XCTAssertEqual(result.user?.email, "a@b.test")
        XCTAssertEqual(result.isNewUser, true)
        XCTAssertEqual(result.promptAddPasskey, false)
        XCTAssertEqual(result.purpose, "login-add-passkey")
        XCTAssertEqual(result.continueUrl, "/next")
        XCTAssertEqual(result.state?["inviteToken"], .string("inv"))
    }

    func testAnOAuthUserMapsToTheResultWithNoMagicLinkFields() throws {
        let state = stateFor(["nonce": "n", "continueUrl": 7])
        let parsed = try parse(
            "https://app.example/oauth/callback?code=c&state=\(percentEncoded(state))"
        )
        let result = SignInRules.callbackResult(oauthUserId: "u2", parsed: parsed)
        XCTAssertEqual(result.method, .oauth)
        XCTAssertEqual(result.userId, "u2")
        XCTAssertNil(result.user)
        XCTAssertNil(result.isNewUser)
        XCTAssertNil(result.promptAddPasskey)
        XCTAssertNil(result.continueUrl, "a non-string continueUrl is ignored")
        XCTAssertEqual(result.state?["nonce"], .string("n"))
    }

    func testTheInviteTokenIsTheParameterElseTheBagsString() {
        let bag: [String: JSONValue] = ["inviteToken": .string("from-bag")]
        XCTAssertEqual(SignInRules.resolveInviteToken(parameter: "param", bag: bag), "param")
        XCTAssertEqual(SignInRules.resolveInviteToken(parameter: nil, bag: bag), "from-bag")
        XCTAssertNil(SignInRules.resolveInviteToken(parameter: nil, bag: ["inviteToken": .number(1)]))
        XCTAssertNil(SignInRules.resolveInviteToken(parameter: nil, bag: nil))
    }

    func testASignedInUserIdIsRequired() throws {
        XCTAssertEqual(try SignInRules.requireSignedInUserId("u1"), "u1")
        for missing in [nil, ""] as [String?] {
            XCTAssertThrowsError(try SignInRules.requireSignedInUserId(missing)) { error in
                XCTAssertEqual((error as? AuthError)?.code, .invalidToken)
            }
        }
    }
}
