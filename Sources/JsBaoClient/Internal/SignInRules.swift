import Foundation

// MARK: - SignInRules
//
// The two sign-in rules the client owns: where an emailed sign-in link lands,
// and which callback URLs `handleSignInCallback` accepts. The Swift twin of
// the JS client's `src/client/internal/signInRules.ts`, rule for rule, except
// that Swift accepts `links.appBaseURL`'s origin and the scheme a non-http(s)
// `oauthRedirectUri` registers, where JS accepts the page's origin and
// `oauthRedirectUri`'s. Pure, so each rule is tested with no client.

enum SignInRules {
    /// The path an emailed link lands on when the client derives its target.
    static let defaultCallbackPath = "/oauth/callback"

    /// A callback URL the grammar accepted, with the credential it carries.
    struct ParsedSignInCallback: Equatable {
        enum Credential: Equatable {
            case magicToken(String)
            /// `state` is the raw value, handed to the exchange unchanged.
            case oauth(code: String, state: String)
        }

        let credential: Credential
        /// The raw `state`, when the URL carries one.
        let state: String?
        /// `state` decoded from base64 JSON.
        let stateBag: [String: JSONValue]?
        /// `"login-add-passkey"` when the URL carries that purpose.
        let purpose: String?
    }

    /// The link-target rule, first match wins: (1) `.uri` with a non-empty
    /// string, or `.codeOnly` for none; (2) `oauthRedirectUri`; (3)
    /// `appBaseURL`'s http(s) origin + `/oauth/callback`; (4) `nil`, a
    /// code-only email.
    static func emailSignInLinkTarget(
        _ target: EmailSignInTarget,
        oauthRedirectUri: String?,
        appBaseURL: URL?
    ) -> String? {
        switch target {
        case .codeOnly: return nil
        case .uri(let uri) where !uri.isEmpty: return uri
        case .uri, .automatic: break
        }
        if let option = oauthRedirectUri, !option.isEmpty { return option }
        if let base = appBaseURL, let origin = httpOrigin(of: base) {
            return origin + defaultCallbackPath
        }
        return nil
    }

    /// `scheme://host[:port]` of an http(s) URL, the WHATWG origin: scheme and
    /// host lowercased, a default port dropped. `nil` for any other URL.
    static func httpOrigin(of url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              isHttpScheme(scheme),
              let host = components.percentEncodedHost?.lowercased(),
              !host.isEmpty
        else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        if let port = components.port, port != defaultPort {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    /// The URL's path in percent-encoded form, the twin of JS `pathname`, so
    /// `/oauth%2Fcallback` stays distinct from `/oauth/callback`. A custom
    /// scheme's "host" is its first segment, as `LinksAPI` reads it:
    /// `myapp://oauth/callback` and `myapp:///oauth/callback` both read
    /// `/oauth/callback`. An empty path reads `/`.
    static func callbackPath(of url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = components?.percentEncodedPath ?? ""
        if !isHttpScheme(components?.scheme?.lowercased() ?? ""),
           let host = components?.percentEncodedHost, !host.isEmpty {
            path = "/" + host + path
        }
        return path.isEmpty ? "/" : path
    }

    /// The callback grammar. A URL is accepted only when every rule holds; the
    /// first that fails names the refusal, and no message carries a
    /// credential value.
    ///
    /// 1. A URL is given (the parameter type).
    /// 2. Its scheme is http(s), or the scheme of a non-http(s)
    ///    `oauthRedirectUri`.
    /// 3. An http(s) URL's origin is `appBaseURL`'s.
    /// 4. Its path is the callback path: `oauthRedirectUri`'s when it has the
    ///    URL's kind (http(s) or scheme), else `/oauth/callback`.
    /// 5. `magic_token`, `code` and `state` each appear at most once, never
    ///    empty.
    /// 6. Not both `magic_token` and `code`.
    /// 7. `code` comes with `state`.
    /// 8. It carries a credential: `magic_token`, or `code` with `state`.
    /// 9. A `state` decodes as base64 JSON to an object.
    static func parseSignInCallbackURL(
        _ url: URL,
        appBaseURL: URL?,
        oauthRedirectUri: String?
    ) throws -> ParsedSignInCallback {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased()
        else { throw refusal("not a URL with a scheme") }

        let option = oauthRedirectUri.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let optionScheme = option?.scheme?.lowercased()
        let expectedPath: String
        if isHttpScheme(scheme) {
            let origin = httpOrigin(of: url)
            guard let origin, origin == appBaseURL.flatMap(httpOrigin(of:)) else {
                throw refusal("origin \(origin ?? "(none)") is not links.appBaseURL's origin")
            }
            if let option, let optionScheme, isHttpScheme(optionScheme) {
                expectedPath = callbackPath(of: option)
            } else {
                expectedPath = defaultCallbackPath
            }
        } else {
            guard let option, let optionScheme, !isHttpScheme(optionScheme), optionScheme == scheme else {
                throw refusal("scheme \(scheme) is neither http(s) nor oauthRedirectUri's")
            }
            expectedPath = callbackPath(of: option)
        }
        let path = callbackPath(of: url)
        guard path == expectedPath else {
            throw refusal("path \(path) is not the callback path \(expectedPath)")
        }

        // A name with no `=` (`?code`) reads as empty, as in JS.
        let items = components.queryItems ?? []
        for name in ["magic_token", "code", "state"] {
            let values = items.filter { $0.name == name }
            if values.count > 1 { throw refusal("\(name) appears more than once") }
            if let only = values.first, (only.value ?? "").isEmpty {
                throw refusal("\(name) is empty")
            }
        }
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        let magicToken = value("magic_token")
        let code = value("code")
        let state = value("state")

        if magicToken != nil && code != nil { throw refusal("carries both magic_token and code") }
        if code != nil && state == nil { throw refusal("code without state") }

        let credential: ParsedSignInCallback.Credential
        if let magicToken {
            credential = .magicToken(magicToken)
        } else if let code, let state {
            credential = .oauth(code: code, state: state)
        } else {
            throw refusal("no credential (magic_token, or code with state)")
        }

        var stateBag: [String: JSONValue]?
        if let state {
            guard let decoded = decodeStateBag(state) else {
                throw refusal("state is not a base64 JSON object")
            }
            stateBag = decoded
        }
        let purpose = value("purpose") == "login-add-passkey" ? "login-add-passkey" : nil
        return ParsedSignInCallback(
            credential: credential,
            state: state,
            stateBag: stateBag,
            purpose: purpose
        )
    }

    /// `state` decoded leniently: a `+` that arrived as a space, base64url
    /// characters and missing padding are accepted. `nil` unless the JSON is
    /// an object. The base64 grammar is JS `atob`'s, so excess padding is
    /// refused as it is there; the JSON is read as UTF-8 (a Swift-produced
    /// bag), else as the Latin-1 byte string JS `btoa` encodes.
    static func decodeStateBag(_ raw: String) -> [String: JSONValue]? {
        var base64 = Array(raw.unicodeScalars).map { scalar -> Unicode.Scalar in
            switch scalar {
            case " ", "-": return "+"
            case "_": return "/"
            default: return scalar
            }
        }
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = atobBytes(base64) else { return nil }
        let value = (try? JSONCoding.decodeData(JSONValue.self, from: data))
            ?? String(data: data, encoding: .isoLatin1).flatMap {
                try? JSONCoding.decodeData(JSONValue.self, from: Data($0.utf8))
            }
        return value?.objectValue
    }

    /// WHATWG forgiving-base64 decode, the grammar of JS `atob`: ASCII
    /// whitespace is dropped, then at most two trailing `=` when the length
    /// is a multiple of four; any other `=` or non-alphabet character, or a
    /// length of 1 mod 4, refuses. Leftover bits are discarded.
    private static func atobBytes(_ input: [Unicode.Scalar]) -> Data? {
        var scalars = input.filter { !["\t", "\n", "\u{0C}", "\r", " "].contains($0) }
        if scalars.count % 4 == 0 {
            for _ in 0..<2 where scalars.last == "=" { scalars.removeLast() }
        }
        if scalars.count % 4 == 1 { return nil }
        var bytes = Data()
        var buffer: UInt32 = 0
        var bits = 0
        for scalar in scalars {
            let sextet: UInt32
            switch scalar.value {
            case 0x41...0x5A: sextet = scalar.value - 0x41
            case 0x61...0x7A: sextet = scalar.value - 0x61 + 26
            case 0x30...0x39: sextet = scalar.value - 0x30 + 52
            case 0x2B: sextet = 62
            case 0x2F: sextet = 63
            default: return nil
            }
            buffer = (buffer << 6) | sextet
            bits += 6
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return bytes
    }

    /// The invite to accept with a magic link: the parameter, else the state
    /// bag's `inviteToken` string.
    static func resolveInviteToken(parameter: String?, bag: [String: JSONValue]?) -> String? {
        parameter ?? bag?["inviteToken"]?.stringValue
    }

    /// The result of a verified magic link.
    static func callbackResult(
        from verified: MagicLinkVerifyResult,
        parsed: ParsedSignInCallback
    ) -> SignInCallbackResult {
        SignInCallbackResult(
            method: .magicLink,
            userId: verified.user.userId,
            user: verified.user,
            isNewUser: verified.isNewUser,
            promptAddPasskey: verified.promptAddPasskey,
            purpose: parsed.purpose,
            continueUrl: parsed.stateBag?["continueUrl"]?.stringValue,
            state: parsed.stateBag
        )
    }

    /// The result of an OAuth exchange that signed `oauthUserId` in.
    static func callbackResult(
        oauthUserId: String,
        parsed: ParsedSignInCallback
    ) -> SignInCallbackResult {
        SignInCallbackResult(
            method: .oauth,
            userId: oauthUserId,
            purpose: parsed.purpose,
            continueUrl: parsed.stateBag?["continueUrl"]?.stringValue,
            state: parsed.stateBag
        )
    }

    /// The user an OAuth exchange signed in. A token that names no user is an
    /// impossible state, refused with the same coded error as every other
    /// callback failure.
    static func requireSignedInUserId(_ userId: String?) throws -> String {
        guard let userId, !userId.isEmpty else {
            throw AuthError(
                code: .invalidToken,
                message: "OAuth callback signed in with a token that names no user"
            )
        }
        return userId
    }

    static func refusal(_ reason: String) -> AuthError {
        AuthError(code: .invalidToken, message: "Sign-in callback refused: \(reason)")
    }

    private static func isHttpScheme(_ scheme: String) -> Bool {
        scheme == "http" || scheme == "https"
    }
}
