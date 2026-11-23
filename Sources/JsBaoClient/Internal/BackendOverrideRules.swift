import Foundation

/// The build's own app id and URLs, and the version and platform it reports.
struct BackendBuild: Sendable, Equatable {
    let appId: String
    let apiUrl: String
    let wsUrl: String
    let version: String
    let platform: String
}

/// The app id and URLs a copy constructs its client with.
struct BackendChoice: Sendable, Equatable {
    let appId: String
    let apiUrl: String
    let wsUrl: String
    /// True when the values come from an override.
    let overridden: Bool
}

/// One usable override. `apiUrl` and `wsUrl` are what it answers, or `nil`
/// when it names no `apiUrl`.
struct BackendOverride: Sendable, Equatable {
    let from: String
    let appId: String
    let apiUrl: String?
    let wsUrl: String?
}

/// The rules for a platform's `backendOverrides`, the same as the server's
/// (`[[clients.<platform>.backendOverrides]]` in `app.toml`) and the JS
/// resolver's.
enum BackendOverrideRules {
    static let maxOverrides = 16
    static let maxAppIdLength = 128
    static let maxApiUrlLength = 2048

    /// The override `clients` (a policy's platform map, as served) gives a
    /// copy: of the platform's first 16 usable overrides, skipping the later of
    /// two whose `from` compare equal, the one with the highest `from` at or
    /// below the version. `skipped` hears each skipped entry's 1-based position
    /// and why.
    static func selectOverride(
        clients: JSONValue?,
        build: BackendBuild,
        skipped: ((Int, String) -> Void)? = nil
    ) -> BackendOverride? {
        guard let list = clients?.objectValue?[build.platform]?.objectValue?["backendOverrides"]?.arrayValue else {
            return nil
        }
        var kept: [BackendOverride] = []
        for (index, item) in list.enumerated() {
            guard index < maxOverrides else {
                skipped?(index + 1, "only the first \(maxOverrides) overrides are read")
                continue
            }
            switch usable(item, ownAppId: build.appId) {
            case .failure(let reason):
                skipped?(index + 1, reason.text)
            case .success(let override):
                if kept.contains(where: { ClientVersionRules.compareClientVersions($0.from, override.from) == 0 }) {
                    skipped?(index + 1, "its from equals an earlier override's")
                } else {
                    kept.append(override)
                }
            }
        }
        var best: BackendOverride?
        for candidate in kept where ClientVersionRules.compareClientVersions(candidate.from, build.version) != 1 {
            if let current = best, ClientVersionRules.compareClientVersions(candidate.from, current.from) != 1 { continue }
            best = candidate
        }
        return best
    }

    /// The app id and URLs an override answers, from the build's own values.
    static func backendFor(_ override: BackendOverride?, build: BackendBuild) -> BackendChoice {
        guard let override else {
            return BackendChoice(appId: build.appId, apiUrl: build.apiUrl, wsUrl: build.wsUrl, overridden: false)
        }
        guard let apiUrl = override.apiUrl, let wsUrl = override.wsUrl else {
            return BackendChoice(appId: override.appId, apiUrl: build.apiUrl, wsUrl: build.wsUrl, overridden: true)
        }
        return BackendChoice(appId: override.appId, apiUrl: apiUrl, wsUrl: wsUrl, overridden: true)
    }

    /// The backend `clients` gives this copy: its override's, else the build's own.
    static func chooseBackend(clients: JSONValue?, build: BackendBuild) -> BackendChoice {
        backendFor(selectOverride(clients: clients, build: build), build: build)
    }

    /// An API URL with its trailing slashes removed.
    static func normalizeApiUrl(_ apiUrl: String) -> String {
        var scalars = Substring(apiUrl).unicodeScalars
        while scalars.last == "/" { scalars.removeLast() }
        return String(scalars)
    }

    struct Skip: Error {
        let text: String
    }

    static func usable(_ item: JSONValue, ownAppId: String) -> Result<BackendOverride, Skip> {
        guard let table = item.objectValue else { return .failure(Skip(text: "it is not a table")) }
        guard let from = table["from"]?.stringValue, ClientVersionRules.parseClientVersion(from) != nil else {
            return .failure(Skip(text: "its from is not a legal version"))
        }
        guard let appId = table["appId"]?.stringValue, !appId.isEmpty, appId.utf16.count <= maxAppIdLength else {
            return .failure(Skip(text: "its appId is not a non-empty string of at most \(maxAppIdLength) characters"))
        }
        guard appId != ownAppId else { return .failure(Skip(text: "its appId is the build's own")) }
        guard let raw = table["apiUrl"] else { return .success(BackendOverride(from: from, appId: appId, apiUrl: nil, wsUrl: nil)) }
        guard let text = raw.stringValue else { return .failure(Skip(text: "its apiUrl is not a string")) }
        return readApiUrl(text).map { BackendOverride(from: from, appId: appId, apiUrl: $0.apiUrl, wsUrl: $0.wsUrl) }
    }

    /// The API URL and socket URL a usable override `apiUrl` answers, or why
    /// it is skipped.
    ///
    /// Push accepts an `apiUrl` only in canonical form with plain characters,
    /// so the server is the only URL parser and this reads such a URL with
    /// Foundation. It must hold at most 2048 UTF-16 units, no `?` or `#`, and
    /// only the plain characters; Foundation must read a host without user
    /// info, with no upper-case letter or `%`; and it must use `https`, or
    /// `http` on `localhost`, `127.0.0.1` or `[::1]`. The API URL is the string
    /// without trailing slashes; the socket URL is the same string with `wss`
    /// for `https` (or `ws` for `http`).
    static func readApiUrl(_ value: String) -> Result<(apiUrl: String, wsUrl: String), Skip> {
        guard value.utf16.count <= maxApiUrlLength, value.unicodeScalars.allSatisfy(isPlainScalar) else {
            return .failure(Skip(text: "its apiUrl is too long or holds a character push does not accept"))
        }
        let scheme = value.hasPrefix("https://") ? "https" : value.hasPrefix("http://") ? "http" : nil
        guard let scheme, let parts = URLComponents(string: value), parts.scheme == scheme,
              parts.user == nil, parts.password == nil,
              let host = parts.encodedHost, !host.isEmpty,
              !host.unicodeScalars.contains(where: { $0 == "%" || ("A"..."Z").contains($0) }) else {
            return .failure(Skip(text: "its apiUrl is not a URL push accepts"))
        }
        guard scheme == "https" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else {
            return .failure(Skip(text: "its apiUrl uses http off localhost, 127.0.0.1 and [::1]"))
        }
        let apiUrl = normalizeApiUrl(value)
        return .success((apiUrl, (scheme == "https" ? "wss" : "ws") + apiUrl.dropFirst(scheme.count)))
    }

    /// An ASCII letter or digit, or one of `-._~!$&'()*+,;=:@/%[]`.
    private static func isPlainScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9": return true
        default: return "-._~!$&'()*+,;=:@/%[]".unicodeScalars.contains(scalar)
        }
    }
}
