import Foundation

// MARK: - LinkTarget

/// A typed routing target parsed from an incoming Primitive link
/// (universal link, custom-scheme URL, or pasted share link). Issue #931.
///
/// `LinksAPI` is transport-only: it identifies *what* a link points at;
/// the app decides how to navigate there.
///
/// The grammar is derived from the link shapes the platform and its
/// reference apps actually produce — it is intentionally not invented:
///
/// - `{base}/document/{documentId}` — document share link
///   (sample-app `ShareDialog.tsx:130-132`, route `App.tsx:250`).
/// - `{app.baseUrl}/invite/accept?inviteToken={token}` — invitation
///   accept URL (server `src/app-api/helpers/invitation-helpers.ts:28-37`,
///   default `app-invite` email template). Per the server docs this is a
///   convention, not an enforced route — apps own their accept-page
///   routing — so the parser keys on the `inviteToken` query parameter
///   wherever it appears.
/// - `{redirectUri}?magic_token={token}[&purpose=…]` — magic-link
///   sign-in URL (server `src/app-api/controllers/magic-link-controller.ts:507-515`).
///   Apps that use a universal link as their magic-link `redirectUri`
///   receive these through the same OS entry points.
public enum LinkTarget: Sendable, Equatable {
    /// A document share link carrying a concrete document id
    /// (26-char ULID, the server's id format —
    /// `src/app-api/services/document-service.ts:59`).
    ///
    /// A `/document/{segment}` link whose trailing segment is not a ULID
    /// parses as `.unknown`: alias-based share links were built on
    /// app-scoped aliases, which were removed in #1168. A user-scoped
    /// alias is keyed to its owner, and a share URL carries no owner user
    /// id, so a recipient would resolve the key against their *own*
    /// aliases — the wrong document, or none.
    case document(id: String)
    /// An invitation accept link. Feed the token to
    /// `client.invitations.accept(inviteToken:)`.
    case invitation(token: String)
    /// A magic-link sign-in URL. Feed the token to the magic-link
    /// verify flow. `purpose` is present for non-standard flows
    /// (e.g. `login-add-passkey`).
    case magicLink(token: String, purpose: String?)
    /// The URL did not match any known Primitive link shape. Apps
    /// should fall through to their own routing.
    case unknown(URL)
}

// MARK: - LinksAPI

/// Deep-link / universal-link routing for the Swift client (#931).
///
/// ```swift
/// client.links.appBaseURL = URL(string: "https://notes.example.com")
///
/// // Incoming link → typed target
/// let target = try await client.links.resolve(url: incomingURL)
/// switch target {
/// case .document(let id): openEditor(id)
/// case .invitation(let token): try await client.invitations.accept(inviteToken: token)
/// case .magicLink(let token, _): try await verifyMagicLink(token)
/// case .unknown: fallBackToOwnRouting()
/// }
///
/// // Outgoing share link
/// let url = client.links.shareURL(forDocument: doc.id)
/// ```
///
/// Universal links additionally require the app to declare the
/// `applinks:{your-app-domain}` Associated Domains entitlement and the
/// domain to serve an `apple-app-site-association` file — that is app
/// configuration, intentionally out of scope for this client library.
///
/// > Important: This assumes the tenant **controls its own web domain** and
/// > can serve that AASA at the domain root. If a tenant runs on
/// > Primitive-managed hosting (no domain of their own), who serves the
/// > `applinks` AASA is unresolved — the platform domain can't vouch for an
/// > arbitrary tenant's bundle id from a shared root. This is the same
/// > domain-ownership problem tracked for passkey `webcredentials` in
/// > Primitive-Labs/js-bao-wss#1130; universal links need the same answer.
public final class LinksAPI: @unchecked Sendable {
    private let lock = NSLock()
    private var _appBaseURL: URL?

    /// The app's public web base URL — the same value as the server-side
    /// `app.baseUrl` setting (e.g. `https://notes.example.com`, no
    /// trailing slash needed). Required by the `shareURL(...)` /
    /// `inviteAcceptURL(...)` builders; parsing does not need it.
    ///
    /// This is an explicit knob because the client's `apiUrl` points at
    /// the Primitive worker, not at the app's own web domain, and the
    /// server's `GET /settings` endpoint (which exposes `baseUrl`) is
    /// admin-only.
    public var appBaseURL: URL? {
        get { lock.lock(); defer { lock.unlock() }; return _appBaseURL }
        set { lock.lock(); defer { lock.unlock() }; _appBaseURL = newValue }
    }

    private var _trustedLinkHosts: [String] = []

    /// Extra `http(s)` hosts to accept as Primitive links, in addition to
    /// `appBaseURL`'s host — e.g. a magic-link `redirectUri` served on a
    /// different domain than the app's web base. `appBaseURL`'s host is
    /// always trusted; custom-scheme links are registered to this app, so
    /// the OS already scopes them and they bypass this list.
    ///
    /// This is the allowlist behind `parse(...)`'s origin guard: a web link
    /// from a host that is neither `appBaseURL`'s nor in this list is
    /// returned as `.unknown` rather than a real invitation/magic-link/
    /// document target. When neither `appBaseURL` nor this list is set,
    /// web links are not trusted; configure one before routing universal
    /// links or pasted `http(s)` URLs.
    public var trustedLinkHosts: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _trustedLinkHosts }
        set { lock.lock(); defer { lock.unlock() }; _trustedLinkHosts = newValue }
    }

    /// Server-side document id format: 26-char Crockford-base32 ULID
    /// (`src/app-api/services/document-service.ts:59`).
    private static let ulidRegex = try! NSRegularExpression(
        pattern: "^[0-9A-HJKMNP-TV-Z]{26}$"
    )

    public init(appBaseURL: URL? = nil) {
        self._appBaseURL = appBaseURL
    }

    // MARK: - Parsing (pure)

    /// Parse a URL into a `LinkTarget` without any network access.
    ///
    /// Both `https://` universal links and custom-scheme links
    /// (`myapp://document/abc` or `myapp:///document/abc`) are
    /// understood; for custom schemes the URL "host" is treated as the
    /// first path segment.
    public func parse(url: URL) -> LinkTarget {
        // Origin guard: only treat a web link's query/path as a trusted
        // Primitive link when it comes from a host we recognize. Without
        // this, `https://evil.example/?inviteToken=…` would parse as a real
        // invitation and could drive a confused-deputy `invitations.accept`.
        // Custom-scheme links are registered to this app, so the OS already
        // scopes their delivery — they bypass the guard. (Universal links
        // are additionally OS origin-checked against the app's Associated
        // Domains, but pasted/handed-off web URLs are not, which is why we
        // check here too.)
        guard isTrustedLinkOrigin(url) else { return .unknown(url) }

        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []

        // 1. Invitation accept link. Convention:
        //    `{app.baseUrl}/invite/accept?inviteToken={token}`
        //    (invitation-helpers.ts:28-37). Apps own their accept-page
        //    routing, so key on the query parameter, not the path.
        if let token = firstValue(of: "inviteToken", in: queryItems) {
            return .invitation(token: token)
        }

        // 2. Magic-link sign-in. `buildMagicLink` appends `magic_token`
        //    (+ optional `purpose`) to the app-chosen redirectUri
        //    (magic-link-controller.ts:507-515).
        if let token = firstValue(of: "magic_token", in: queryItems) {
            return .magicLink(
                token: token,
                purpose: firstValue(of: "purpose", in: queryItems)
            )
        }

        // 3. Document share link: `{base}/document/{id}`
        //    (sample-app ShareDialog.tsx:130-132). Only a concrete ULID is a
        //    document target: alias share links were an app-scope feature
        //    removed in #1168, and a user-scoped alias key without its owner's
        //    user id cannot be resolved cross-user (see `LinkTarget.document`).
        let components = pathSegments(of: url)
        if components.count >= 2,
           components[components.count - 2] == "document" {
            let segment = components[components.count - 1]
            if !segment.isEmpty, Self.isUlid(segment) {
                return .document(id: segment)
            }
        }

        return .unknown(url)
    }

    // MARK: - Resolution

    /// Resolve an incoming URL to a routing target. Since alias share
    /// links were removed (#1168) every target parses purely — this is
    /// now equivalent to `parse(url:)`. The `async throws` signature is
    /// kept so existing `try await` call sites stay source-compatible.
    public func resolve(url: URL) async throws -> LinkTarget {
        return parse(url: url)
    }

    #if canImport(ObjectiveC)
    /// Convenience for the `NSUserActivity` hand-off path
    /// (`onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` /
    /// `application(_:continue:restorationHandler:)`). Extracts the
    /// activity's `webpageURL` and resolves it. Throws
    /// `JsBaoError(.invalidArgument)` when the activity carries no URL.
    public func resolve(userActivity: NSUserActivity) async throws -> LinkTarget {
        guard let url = userActivity.webpageURL else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "userActivity has no webpageURL to resolve"
            )
        }
        return try await resolve(url: url)
    }
    #endif

    // MARK: - Builders

    /// Build a document share URL: `{appBaseURL}/document/{documentId}`,
    /// matching the share link the reference web app copies to the
    /// clipboard (sample-app `ShareDialog.tsx:130-132`).
    ///
    /// The former `alias:` variant was removed with app-scoped aliases
    /// (#1168): a user-scoped alias key is meaningless to a recipient,
    /// so an alias-based link cannot work as a share URL.
    ///
    /// Returns `nil` until `appBaseURL` is configured.
    public func shareURL(forDocument documentId: String) -> URL? {
        guard let base = appBaseURL, !documentId.isEmpty else { return nil }
        let encoded = encodePathSegment(documentId)
        return URL(string: "\(normalizedBase(base))/document/\(encoded)")
    }

    /// Build an invitation accept URL:
    /// `{appBaseURL}/invite/accept?inviteToken={token}`, byte-for-byte
    /// the server's `buildAcceptUrl` convention
    /// (`src/app-api/helpers/invitation-helpers.ts:28-37`) used by the
    /// default `app-invite` email template.
    ///
    /// Returns `nil` until `appBaseURL` is configured.
    public func inviteAcceptURL(inviteToken: String) -> URL? {
        guard let base = appBaseURL, !inviteToken.isEmpty else { return nil }
        var components = URLComponents(
            string: "\(normalizedBase(base))/invite/accept"
        )
        components?.queryItems = [
            URLQueryItem(name: "inviteToken", value: inviteToken)
        ]
        return components?.url
    }

    // MARK: - Helpers

    /// Whether `parse(...)` should trust `url`'s origin enough to interpret
    /// it as a Primitive link. Custom (non-web) schemes are OS-scoped to
    /// this app and always trusted. Web links are trusted only when their
    /// host matches `appBaseURL` or one of `trustedLinkHosts`; when neither
    /// is configured, web links are rejected instead of treating arbitrary
    /// hosts as trusted.
    private func isTrustedLinkOrigin(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        if scheme != "http" && scheme != "https" { return true }

        let baseHost = appBaseURL?.host?.lowercased()
        let extraHosts = trustedLinkHosts
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
        if baseHost == nil && extraHosts.isEmpty { return false }

        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        var trusted = Set(extraHosts)
        if let baseHost { trusted.insert(baseHost) }
        return trusted.contains(host)
    }

    private func firstValue(
        of name: String,
        in items: [URLQueryItem]
    ) -> String? {
        guard let value = items.first(where: { $0.name == name })?.value,
              !value.isEmpty else { return nil }
        return value
    }

    /// Path segments of the URL with the leading "/" entry removed.
    /// For custom (non-web) schemes the host is treated as the first
    /// path segment, so `myapp://document/abc` and
    /// `myapp:///document/abc` parse identically.
    private func pathSegments(of url: URL) -> [String] {
        var segments = url.pathComponents.filter { $0 != "/" }
        let scheme = url.scheme?.lowercased()
        let isWebScheme = scheme == "http" || scheme == "https"
        if !isWebScheme, let host = url.host, !host.isEmpty {
            segments.insert(host, at: 0)
        }
        return segments.map { $0.removingPercentEncoding ?? $0 }
    }

    private func normalizedBase(_ base: URL) -> String {
        var str = base.absoluteString
        while str.hasSuffix("/") { str.removeLast() }
        return str
    }

    private func encodePathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func isUlid(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return ulidRegex.firstMatch(in: value, range: range) != nil
    }
}
