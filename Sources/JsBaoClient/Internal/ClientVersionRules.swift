import Foundation

/// The version and platform a client reports. Either may be missing: a client
/// whose bundle has no `CFBundleShortVersionString` and that was given no
/// `appVersion` option has no version.
struct ClientIdentity: Sendable, Equatable {
    let version: String?
    let platform: String?
}

/// What `ClientVersionRules.resolveClientIdentity` decided: the identity to
/// report, or the sentence that stops construction (`refusal`).
struct ClientIdentityResolution: Sendable, Equatable {
    let identity: ClientIdentity
    let refusal: String?
}

/// The app's whole version policy, every platform, as
/// `GET settings/client-versions` serves it. Stored as is, one row per app.
struct ClientVersionPolicyRecord: Codable, Sendable, Equatable {
    let clients: [String: ClientPlatformVersions]

    /// Read a response body. A body that is not a JSON object is not a policy
    /// (`nil`); an object with no usable `clients` map is an empty policy, as
    /// the JS client reads it. Each entry is read key by key: a key of the
    /// wrong type is unset, and an entry that is not an object, or that holds
    /// none of the five keys (only `backendOverrides`, say), is dropped.
    static func decode(from data: Data) -> ClientVersionPolicyRecord? {
        guard let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue else {
            return nil
        }
        var clients: [String: ClientPlatformVersions] = [:]
        for (platform, value) in object["clients"]?.objectValue ?? [:] {
            guard let entry = value.objectValue else { continue }
            clients[platform] = ClientPlatformVersions(
                latest: entry["latest"]?.stringValue,
                minRecommended: entry["minRecommended"]?.stringValue,
                minRequired: entry["minRequired"]?.stringValue,
                updateUrl: entry["updateUrl"]?.stringValue,
                enforce: entry["enforce"]?.boolValue
            )
        }
        return ClientVersionPolicyRecord(clients: clients).droppingEmptyEntries()
    }

    /// The policy without the entries that set none of the five keys, which
    /// read as no table for their platform.
    func droppingEmptyEntries() -> ClientVersionPolicyRecord {
        ClientVersionPolicyRecord(clients: clients.filter { $0.value != ClientPlatformVersions() })
    }
}

/// The rules of the client version policy, the same as the server's
/// (`src/config-surface/client-versions.ts`): a version is one to three
/// dot-separated parts of one to six ASCII digits, compared numerically with
/// missing parts zero; a platform name matches `[a-z][a-z0-9-]{0,31}`.
enum ClientVersionRules {

    /// The platform a client reports when the app passes none.
    static var osPlatform: String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(watchOS)
        return "watchos"
        #elseif os(visionOS)
        return "visionos"
        #else
        return "linux"
        #endif
    }

    /// The parts of a legal version, padded to three, or `nil`. Only ASCII
    /// digits count: `Character.isNumber` would admit other scripts' digits,
    /// which the server refuses.
    static func parseClientVersion(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard (1...6).contains(part.utf8.count),
                  part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        return numbers
    }

    /// `-1`, `0` or `1` as `a` is below, equal to or above `b`; `nil` when
    /// either is not a legal version.
    static func compareClientVersions(_ a: String, _ b: String) -> Int? {
        guard let left = parseClientVersion(a), let right = parseClientVersion(b) else { return nil }
        for (l, r) in zip(left, right) where l != r {
            return l < r ? -1 : 1
        }
        return 0
    }

    static func isLegalPlatformName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...32).contains(bytes.count), (97...122).contains(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    /// The version and platform a client reports, or why construction stops.
    ///
    /// `bundleVersion` is the raw `CFBundleShortVersionString` value, read only
    /// when no `appVersion` option is given: `nil` (no key) means no version,
    /// and any other value that is not a legal version string — an empty one
    /// included — is refused.
    static func resolveClientIdentity(
        optionVersion: String?,
        optionPlatform: String?,
        bundleVersion: @autoclosure () -> Any?,
        osPlatform: String
    ) -> ClientIdentityResolution {
        let platform = optionPlatform ?? osPlatform
        let version: String?
        var refusal: String?
        if let optionVersion {
            version = optionVersion
            if parseClientVersion(optionVersion) == nil {
                refusal = "JsBaoClient: the appVersion option \"\(optionVersion)\" is not a legal version. "
                    + versionRule + " Fix: pass a legal version as appVersion:, or leave it out to use the bundle's."
            }
        } else if let raw = bundleVersion() {
            let text = raw as? String
            version = text
            if text.flatMap(parseClientVersion) == nil {
                refusal = "JsBaoClient: the bundle's CFBundleShortVersionString \"\(text ?? "\(raw)")\" is not a legal version. "
                    + versionRule + " Fix: set MARKETING_VERSION to a legal version, or pass appVersion: in JsBaoClientOptions."
            }
        } else {
            version = nil
        }
        if refusal == nil, !isLegalPlatformName(platform) {
            refusal = "JsBaoClient: the platform option \"\(platform)\" is not a legal platform name. "
                + "A platform name is a lowercase letter followed by up to 31 lowercase letters, digits or hyphens, such as ios or macos. "
                + "Fix: pass a legal name as platform:, or leave it out to use the OS default (\(osPlatform))."
        }
        return ClientIdentityResolution(
            identity: ClientIdentity(version: version, platform: platform),
            refusal: refusal
        )
    }

    private static let versionRule =
        "A version is one to three dot-separated numbers of one to six digits, such as 1.4 or 2.0.1."

    /// The status one policy gives a client: `updateRequired` below
    /// `minRequired`, else `updateRecommended` below `minRecommended`, else
    /// `updateAvailable` below `latest`, else `current`; `unknown` with no
    /// version, no platform, no policy or no table for the platform. A policy
    /// value that does not parse is read as unset.
    static func clientVersionStatus(
        version: String?,
        platform: String?,
        policy: ClientVersionPolicyRecord?
    ) -> AppVersionStatus {
        guard let version, let platform, let entry = policy?.clients[platform] else { return .unknown }
        func below(_ bound: String?) -> Bool {
            guard let bound else { return false }
            return compareClientVersions(version, bound) == -1
        }
        if below(entry.minRequired) { return .updateRequired }
        if below(entry.minRecommended) { return .updateRecommended }
        if below(entry.latest) { return .updateAvailable }
        return .current
    }

    /// The server's refusal of an outdated client over HTTP: a 426 whose body
    /// code is `CLIENT_UPDATE_REQUIRED`. A 426 with another code (one relayed
    /// from a function, say) is not one.
    static func isUpdateRequiredRefusal(status: Int, body: Data?) -> Bool {
        guard status == 426, let body else { return false }
        return HttpError.parseBody(String(data: body, encoding: .utf8)).code == updateRequiredCode
    }

    static let updateRequiredCode = "CLIENT_UPDATE_REQUIRED"
}
