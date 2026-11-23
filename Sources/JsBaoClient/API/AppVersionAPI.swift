import Foundation

// MARK: - Types

/// Where this copy of the app stands against the app's version policy for its
/// platform.
///
/// - `updateRequired`: below the platform's `minRequired`, or the server
///   refused this client as outdated.
/// - `updateRecommended`: below `minRecommended`.
/// - `updateAvailable`: below `latest`.
/// - `current`: at or above every version the policy names.
/// - `unknown`: the client has no version or no platform, no policy has been
///   fetched yet, or the policy has no table for this platform.
public enum AppVersionStatus: String, Sendable, Codable, Equatable, CaseIterable {
    case current
    case updateAvailable
    case updateRecommended
    case updateRequired
    case unknown
}

/// One platform's entry in the app's version policy, the `[clients.<platform>]`
/// table of `app.toml`. Every key is optional. A version value the client
/// cannot read is treated as unset.
public struct ClientPlatformVersions: Codable, Sendable, Equatable {
    /// The newest version of the app on this platform.
    public let latest: String?
    /// Versions below this one are told an update is recommended.
    public let minRecommended: String?
    /// Versions below this one are told an update is required.
    public let minRequired: String?
    /// Where the app sends the user to update (an App Store link, say).
    public let updateUrl: String?
    /// Whether the server refuses versions below `minRequired`.
    public let enforce: Bool?

    /// Build an entry; every key defaults to unset.
    public init(
        latest: String? = nil,
        minRecommended: String? = nil,
        minRequired: String? = nil,
        updateUrl: String? = nil,
        enforce: Bool? = nil
    ) {
        self.latest = latest
        self.minRecommended = minRecommended
        self.minRequired = minRequired
        self.updateUrl = updateUrl
        self.enforce = enforce
    }
}

// MARK: - AppVersionAPI

/// This copy of the app's version, its platform, and where it stands against
/// the app's version policy (`[clients.<platform>]` in `app.toml`).
///
/// The version comes from the bundle's `CFBundleShortVersionString` and the
/// platform from the OS, unless `JsBaoClientOptions.appVersion` or `.platform`
/// replaces them. Nothing is fetched until the first `getStatus()`,
/// `getPolicy()`, `refresh()` or `onStatusChange(_:)`. From then on the status
/// follows a policy change on its own: the client refetches shortly after
/// each socket reconnect (a random wait of up to 30 seconds, so clients that
/// reconnect together do not all fetch at once), on each return to the
/// foreground and hourly, and keeps the last policy for offline use and the
/// next launch.
///
/// ```swift
/// let subscription = client.appVersion.onStatusChange { status in
///     if status == .updateRequired { showUpdateGate() }
/// }
/// ```
///
/// When the server refuses this build as outdated, the status becomes
/// `updateRequired` at once and the client stops reconnecting on its own until
/// a later fetch says otherwise. A status computed from the policy alone never
/// closes or holds the connection.
public final class AppVersionAPI: Sendable {
    private let controller: AppVersionController

    init(controller: AppVersionController) {
        self.controller = controller
    }

    /// The version this client reports, or `nil` when the bundle has none and
    /// no `appVersion` option was given.
    public var version: String? { controller.identity.version }

    /// The platform this client reports: the `platform` option, or `ios` or
    /// `macos` from the OS.
    public var platform: String? { controller.identity.platform }

    /// The status. The first call fetches the policy, or reports at once from
    /// the policy kept from an earlier launch while the fetch runs. Never
    /// throws: with no policy and no network it returns `.unknown`.
    /// - Stability: beta
    public func getStatus() async -> AppVersionStatus {
        await controller.currentStatus()
    }

    /// This client's platform entry in the policy (with its `updateUrl`), or
    /// `nil` when there is none.
    /// - Stability: beta
    public func getPolicy() async -> ClientPlatformVersions? {
        await controller.currentPolicy()
    }

    /// Fetch the policy now and return the status. A failed fetch returns the
    /// status unchanged.
    /// - Stability: beta
    public func refresh() async -> AppVersionStatus {
        await controller.refresh()
    }

    /// Call `handler` with the status each time what the client reports
    /// changes: the status, this platform's policy entry (a raised `latest`
    /// that keeps `updateAvailable`, say), or a server refusal. Read
    /// `getPolicy()` for the entry. Keep the returned subscription; cancel it
    /// to stop.
    /// - Stability: beta
    public func onStatusChange(_ handler: @escaping @Sendable (AppVersionStatus) -> Void) -> EventSubscription {
        controller.onStatusChange(handler)
    }
}
