import Foundation

/// The app id and URLs to construct a client with, as
/// `JsBaoClient.resolveBackend(options:timeout:)` answers them, and where they
/// came from.
public struct ResolvedBackend: Sendable, Equatable {
    /// Where an answer came from.
    public enum Source: String, Sendable, Equatable {
        /// Decided from a policy read made in this call.
        case fresh
        /// Decided from the policy an earlier call stored.
        case stored
        /// Neither was used: the build's own values.
        case build
    }

    /// The app id to construct the client with.
    public let appId: String
    /// The API URL to construct the client with.
    public let apiUrl: String
    /// The socket URL to construct the client with.
    public let wsUrl: String
    /// True when the app id and URLs come from a backend override.
    public let overridden: Bool
    /// Where the answer came from.
    public let source: Source

    /// `options` with `appId`, `apiUrl` and `wsUrl` replaced by this answer's.
    ///
    /// Every other value is kept, except that an overridden answer drops
    /// `token`: the given token belongs to the home app, and sessions do not
    /// follow an override. An explicit SQLite file (`.sqlite(directory:)`)
    /// holds one session whatever the app id, so an overridden answer gets a
    /// file of its own beside it, `<database file>.<encoded app id>.sqlite`, and the
    /// home app's stored session stays out of the target client (the default
    /// `.sqlite()` is one file per app id, except that an app id other than a
    /// plain name, or the home app's in other letter case, gets a file beside
    /// the home app's). A session the target app's
    /// store already holds is restored as usual; otherwise give the client one
    /// by signing in, or with a token for the target app once its stored
    /// session has been restored:
    ///
    /// ```swift
    /// let client = JsBaoClient(options: backend.applied(to: options))
    /// if backend.overridden, let token = targetToken {
    ///     await client.waitForStorageReady()
    ///     client.updateToken(token)
    /// }
    /// ```
    /// - Stability: beta
    public func applied(to options: JsBaoClientOptions) -> JsBaoClientOptions {
        JsBaoClientOptions(
            apiUrl: apiUrl,
            wsUrl: wsUrl,
            appId: appId,
            token: overridden ? nil : options.token,
            offline: options.offline,
            maxReconnectDelay: options.maxReconnectDelay,
            globalAdminAppId: options.globalAdminAppId,
            wsHeaders: options.wsHeaders,
            blobUploadConcurrency: options.blobUploadConcurrency,
            logLevel: options.logLevel,
            storageConfig: overridden ? Self.targetStorage(options.storageConfig, appId: appId, home: options.appId) : options.storageConfig,
            auth: options.auth,
            sync: options.sync,
            commitRetryBackoff: options.commitRetryBackoff,
            autoNetwork: options.autoNetwork,
            analyticsAutoEvents: options.analyticsAutoEvents,
            deviceIndexes: options.deviceIndexes,
            appVersion: options.appVersion,
            platform: options.platform
        )
    }

    /// The target's own file beside an explicit SQLite file, or beside the
    /// home app's default file when the target's default path could name the
    /// home app's (`./home`, `HOME`); other storage as given. Upper-case
    /// letters are encoded too, so two app ids that differ only in letter case
    /// never share a file on a case-insensitive volume.
    private static func targetStorage(_ storage: StorageConfig, appId: String, home: String) -> StorageConfig {
        let lower = "abcdefghijklmnopqrstuvwxyz0123456789-_"
        let safe = appId.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: lower)) ?? appId
        let plain = appId.unicodeScalars.allSatisfy { CharacterSet(charactersIn: lower + "ABCDEFGHIJKLMNOPQRSTUVWXYZ").contains($0) }
        switch storage {
        case .sqlite(let path?): return .sqlite(directory: "\(path).\(safe).sqlite")
        case .sqlite(nil) where !plain || appId.compare(home, options: .caseInsensitive) == .orderedSame:
            return .sqlite(directory: "\(SQLiteStorageProvider.defaultDatabasePath(appId: home)).\(safe).sqlite")
        default: return storage
        }
    }
}

extension JsBaoClient {
    /// Resolve the app id and URLs to construct the client with, from the
    /// home app's backend overrides (`[[clients.<platform>.backendOverrides]]`
    /// in `app.toml`). Call it before constructing the client; a constructed
    /// client never changes its backend, so a changed override takes effect on
    /// the next launch.
    ///
    /// ```swift
    /// let backend = await JsBaoClient.resolveBackend(options: options)
    /// let client = JsBaoClient(options: backend.applied(to: options))
    /// ```
    ///
    /// `options` are the build's own, the ones the app would construct its
    /// client with. Copies at an override's `from` version or above get its
    /// `appId`, and its `apiUrl` when it names one (the socket URL is derived
    /// from it). Without a version, a legal platform, or an override that
    /// applies, the answer is the build's own values. Only the home app's
    /// policy decides; the request carries no session token.
    ///
    /// The first run waits for one policy read, up to `timeout` seconds (10
    /// when the value is not positive), and answers the build's values when it
    /// fails. Later runs answer from the stored policy at once and refresh it
    /// in the background, except that a copy with an override waits for a
    /// fresh read; if that fails, it answers the stored override only when
    /// this copy was already sent to that override's app id and API URL. The
    /// stored policy lives in `<database file>.backend-resolver.json` beside
    /// the client's SQLite file, and nowhere with `.memory` storage.
    ///
    /// Never throws. Logs one line, at every `logLevel` but `.none`, saying
    /// what it chose: `[resolveBackend] home=… version=… platform=… appId=…
    /// apiUrl=… overridden=… source=…`.
    /// - Stability: beta
    public static func resolveBackend(options: JsBaoClientOptions, timeout: TimeInterval = 10) async -> ResolvedBackend {
        await BackendResolver.resolve(options: options, timeout: timeout)
    }
}
