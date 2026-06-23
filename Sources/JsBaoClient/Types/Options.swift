import Foundation

// MARK: - Client Options

public struct JsBaoClientOptions: Sendable {
    public let apiUrl: String
    public let wsUrl: String
    public let appId: String
    /// Initial token. Immutable after construction so the value-type
    /// `JsBaoClientOptions` is safely `Sendable`. To change tokens at runtime,
    /// use the auth controller (e.g., `client.auth.updateToken(...)`).
    public let token: String?
    public let offline: Bool
    public let maxReconnectDelay: TimeInterval
    public let globalAdminAppId: String
    public let wsHeaders: [String: String]
    public let blobUploadConcurrency: Int
    public let logLevel: LogLevel
    public let storageConfig: StorageConfig
    public let auth: AuthConfig
    public let sync: SyncConfig
    public let commitRetryBackoff: CommitRetryBackoff
    public let autoNetwork: Bool
    public let connectivityProbeTimeoutMs: Int
    /// Per-feature gating for the analytics auto-events the client emits
    /// without explicit app calls (#963). Mirrors js-bao's
    /// `analyticsAutoEvents` option.
    public let analyticsAutoEvents: AnalyticsAutoEventsConfig

    public init(
        apiUrl: String,
        wsUrl: String,
        appId: String,
        token: String? = nil,
        offline: Bool = true,
        maxReconnectDelay: TimeInterval = 30,
        globalAdminAppId: String = "global-admin-app",
        wsHeaders: [String: String] = [:],
        blobUploadConcurrency: Int = 2,
        logLevel: LogLevel = .warn,
        storageConfig: StorageConfig = .sqlite(),
        auth: AuthConfig = AuthConfig(),
        sync: SyncConfig = SyncConfig(),
        commitRetryBackoff: CommitRetryBackoff = CommitRetryBackoff(),
        autoNetwork: Bool = true,
        connectivityProbeTimeoutMs: Int = 2000,
        analyticsAutoEvents: AnalyticsAutoEventsConfig = AnalyticsAutoEventsConfig()
    ) {
        self.apiUrl = apiUrl
        self.wsUrl = wsUrl
        self.appId = appId
        self.token = token
        self.offline = offline
        self.maxReconnectDelay = maxReconnectDelay
        self.globalAdminAppId = globalAdminAppId
        self.wsHeaders = wsHeaders
        self.blobUploadConcurrency = blobUploadConcurrency
        self.logLevel = logLevel
        self.storageConfig = storageConfig
        self.auth = auth
        self.sync = sync
        self.commitRetryBackoff = commitRetryBackoff
        self.autoNetwork = autoNetwork
        self.connectivityProbeTimeoutMs = connectivityProbeTimeoutMs
        self.analyticsAutoEvents = analyticsAutoEvents
    }
}

// MARK: - Analytics Auto-Events Config (#963)

/// Per-feature gating for the auto-events the client emits without explicit
/// app calls. Mirrors js-bao's `AnalyticsAutoEventsOptions` /
/// `AnalyticsAutoEventsInternalConfig` (`src/client/JsBaoClient.ts`) flag for
/// flag, including the same defaults (every event on; the `minIntervalMs`
/// rate-limit windows match the JS `DEFAULT_*` constants).
///
/// Parity note: several flags exist for option-surface parity but never emit,
/// because the corresponding JS emitters are currently no-ops (`boot`,
/// `firstDocOpen`, `firstDocEdit`, `offlineRecovery` were removed in JS as
/// low-value / pre-auth; `serviceWorker` is browser-only). They are kept here
/// so app config written against the JS option shape compiles unchanged, and
/// so the Swift client can light them up the moment JS does.
public struct AnalyticsAutoEventsConfig: Sendable {
    /// `user_active_daily` on the first successful auth of each calendar day.
    public var dailyAuth: Bool
    /// `user_returned` when the app returns to the foreground after at least
    /// `minResumeMs` of inactivity.
    public var returnActive: Bool
    /// Minimum gap (ms) between consecutive `returnActive` events.
    /// JS default: 5 minutes.
    public var minResumeMs: Int
    /// No-op in both JS and Swift today (fires before auth → no user). Kept
    /// for option-surface parity.
    public var boot: Bool
    /// No-op in both JS and Swift today (removed as low-value). Kept for
    /// option-surface parity.
    public var firstDocOpen: Bool
    /// No-op in both JS and Swift today (removed as low-value). Kept for
    /// option-surface parity.
    public var firstDocEdit: Bool
    /// `offlineRecovery`: no-op in both JS and Swift today (removed as a rare,
    /// non-actionable edge case). Kept for option-surface parity.
    public var offlineRecoveryEnabled: Bool
    public var offlineRecoveryMinIntervalMs: Int
    /// `sync_error` (feature `sync`) when a sync/commit fails. Rate-limited to
    /// one event per `syncErrorsMinIntervalMs`. JS default: 30s.
    public var syncErrorsEnabled: Bool
    public var syncErrorsMinIntervalMs: Int
    /// Blob upload lifecycle events (feature `blobs`): start / success /
    /// failure, each one-shot per upload.
    public var blobUploadsStart: Bool
    public var blobUploadsSuccess: Bool
    public var blobUploadsFailure: Bool
    /// `serviceWorker`: browser-only; no Swift equivalent (N/A). Kept for
    /// option-surface parity.
    public var serviceWorkerControl: Bool
    public var serviceWorkerTokenUpdate: Bool
    /// `session_end` (feature `_session`) on background / terminate / destroy.
    /// Already wired via the session-lifecycle observers.
    public var sessionEnd: Bool

    public init(
        dailyAuth: Bool = true,
        returnActive: Bool = true,
        minResumeMs: Int = 5 * 60 * 1000,
        boot: Bool = true,
        firstDocOpen: Bool = true,
        firstDocEdit: Bool = true,
        offlineRecoveryEnabled: Bool = true,
        offlineRecoveryMinIntervalMs: Int = 60 * 1000,
        syncErrorsEnabled: Bool = true,
        syncErrorsMinIntervalMs: Int = 30 * 1000,
        blobUploadsStart: Bool = true,
        blobUploadsSuccess: Bool = true,
        blobUploadsFailure: Bool = true,
        serviceWorkerControl: Bool = true,
        serviceWorkerTokenUpdate: Bool = true,
        sessionEnd: Bool = true
    ) {
        self.dailyAuth = dailyAuth
        self.returnActive = returnActive
        self.minResumeMs = minResumeMs
        self.boot = boot
        self.firstDocOpen = firstDocOpen
        self.firstDocEdit = firstDocEdit
        self.offlineRecoveryEnabled = offlineRecoveryEnabled
        self.offlineRecoveryMinIntervalMs = offlineRecoveryMinIntervalMs
        self.syncErrorsEnabled = syncErrorsEnabled
        self.syncErrorsMinIntervalMs = syncErrorsMinIntervalMs
        self.blobUploadsStart = blobUploadsStart
        self.blobUploadsSuccess = blobUploadsSuccess
        self.blobUploadsFailure = blobUploadsFailure
        self.serviceWorkerControl = serviceWorkerControl
        self.serviceWorkerTokenUpdate = serviceWorkerTokenUpdate
        self.sessionEnd = sessionEnd
    }
}

// MARK: - Auth Config

public struct AuthConfig: Sendable {
    public let persistJwtInStorage: Bool
    public let storageKeyPrefix: String?
    public let refreshProxy: RefreshProxyConfig?

    public init(
        persistJwtInStorage: Bool = false,
        storageKeyPrefix: String? = nil,
        refreshProxy: RefreshProxyConfig? = nil
    ) {
        self.persistJwtInStorage = persistJwtInStorage
        self.storageKeyPrefix = storageKeyPrefix
        self.refreshProxy = refreshProxy
    }
}

public struct RefreshProxyConfig: Sendable {
    public let baseUrl: String
    public let cookieMaxAgeSeconds: Int?
    public let enabled: Bool

    public init(baseUrl: String, cookieMaxAgeSeconds: Int? = nil, enabled: Bool = true) {
        self.baseUrl = baseUrl
        self.cookieMaxAgeSeconds = cookieMaxAgeSeconds
        self.enabled = enabled
    }
}

// MARK: - Sync Config

public struct SyncConfig: Sendable {
    public var outboundDebounceMs: Int
    public var handshakeTimeoutMs: Int

    public init(outboundDebounceMs: Int = 50, handshakeTimeoutMs: Int = 10000) {
        self.outboundDebounceMs = outboundDebounceMs
        self.handshakeTimeoutMs = handshakeTimeoutMs
    }
}

// MARK: - Commit Retry Backoff

public struct CommitRetryBackoff: Sendable {
    public var baseMs: Int
    public var factor: Double
    public var maxMs: Int
    public var jitter: Bool
    public var maxAttempts: Int

    public init(
        baseMs: Int = 1000,
        factor: Double = 2.0,
        maxMs: Int = 60000,
        jitter: Bool = true,
        maxAttempts: Int = 10
    ) {
        self.baseMs = baseMs
        self.factor = factor
        self.maxMs = maxMs
        self.jitter = jitter
        self.maxAttempts = maxAttempts
    }
}

// MARK: - Storage Config

public enum StorageConfig: Sendable {
    case sqlite(directory: String? = nil)
    case memory
}

// MARK: - Document Options

public struct OpenDocumentOptions: Sendable {
    public var waitForLoad: WaitForLoadMode
    public var enableNetworkSync: Bool
    public var retainLocal: Bool
    /// Maximum time in milliseconds to wait for the document to become
    /// available from the network before resolving with whatever local
    /// (possibly empty) state exists. Mirrors JS
    /// `open`/`openDocument`'s `availabilityWaitMs` (default 30000).
    /// Clamped to `>= 0`.
    public var availabilityWaitMs: Int
    /// When `true`, open the document locally without starting server
    /// sync — sync begins only on an explicit `startNetworkSync(documentId:)`
    /// call. Mirrors JS `open`/`openDocument`'s `deferNetworkSync`.
    public var deferNetworkSync: Bool
    /// When `true`, syncStep1 messages for this document carry
    /// `requestPerf: true`, asking the server for a `syncPerf` telemetry
    /// frame after each sync round-trip (delivered via the `.syncPerf`
    /// event). Mirrors JS `openDocument`'s `requestSyncPerf` option (#996).
    public var requestSyncPerf: Bool

    public init(
        waitForLoad: WaitForLoadMode = .localIfAvailableElseNetwork,
        enableNetworkSync: Bool = true,
        retainLocal: Bool = true,
        availabilityWaitMs: Int = 30_000,
        deferNetworkSync: Bool = false,
        requestSyncPerf: Bool = false
    ) {
        self.waitForLoad = waitForLoad
        self.enableNetworkSync = enableNetworkSync
        self.retainLocal = retainLocal
        self.availabilityWaitMs = max(0, availabilityWaitMs)
        self.deferNetworkSync = deferNetworkSync
        self.requestSyncPerf = requestSyncPerf
    }
}

public struct CreateDocumentOptions: Encodable, Sendable {
    public var title: String?
    public var tags: [String]?
    public var localOnly: Bool
    /// Opaque metadata blob to attach at creation (≤ 4 KB). The platform
    /// round-trips it verbatim — it does not introspect the value.
    public var metadata: JSONValue?

    public init(
        title: String? = nil,
        tags: [String]? = nil,
        localOnly: Bool = false,
        metadata: JSONValue? = nil
    ) {
        self.title = title
        self.tags = tags
        self.localOnly = localOnly
        self.metadata = metadata
    }
}

public struct CloseDocumentOptions: Sendable {
    public var evictLocal: Bool

    public init(evictLocal: Bool = false) {
        self.evictLocal = evictLocal
    }
}

public struct EvictDocumentOptions: Sendable {
    public var force: Bool

    public init(force: Bool = false) {
        self.force = force
    }
}

// MARK: - Blob Options

public enum BlobDisposition: String, Sendable, Codable {
    case attachment
    case inline
}

public struct BlobUploadSourceOptions: Sendable {
    public var filename: String?
    public var contentType: String?
    public var sha256Base64: String?
    public var disposition: BlobDisposition?
    /// Whether to keep the uploaded bytes in the local cache after a successful
    /// upload. Mirrors JS `BlobUploadSourceOptions.retainLocal` (defaults to
    /// `true` when unset, matching the JS queue record default).
    public var retainLocal: Bool?

    public init(
        filename: String? = nil,
        contentType: String? = nil,
        sha256Base64: String? = nil,
        disposition: BlobDisposition? = nil,
        retainLocal: Bool? = nil
    ) {
        self.filename = filename
        self.contentType = contentType
        self.sha256Base64 = sha256Base64
        self.disposition = disposition
        self.retainLocal = retainLocal
    }
}

// MARK: - Document Info
//
// `DocumentInfo` and the other typed document request/response models live
// in `DocumentTypes.swift`, where they mirror the JS client's published
// interfaces field-for-field (issue #954).

// MARK: - Pagination

public struct PaginationOptions: Sendable {
    public var limit: Int?
    public var cursor: String?

    public init(limit: Int? = nil, cursor: String? = nil) {
        self.limit = limit
        self.cursor = cursor
    }
}

public struct PaginatedResult<T: Sendable>: Sendable {
    public let items: [T]
    public let cursor: String?

    public init(items: [T], cursor: String? = nil) {
        self.items = items
        self.cursor = cursor
    }
}

// MARK: - Network Status

public struct NetworkStatus: Sendable {
    public let mode: NetworkMode
    public let isOnline: Bool
    public let lastOnlineAt: Date?
    public let reason: String?
}

// MARK: - Workflow Options

/// Options for `client.setNetworkMode(_:options:)`. Matches the JS
/// client's options bag passed as the second argument.
public struct SetNetworkModeOptions: Sendable {
    /// Reason string surfaced on the emitted `networkMode` event so
    /// subscribers can distinguish user-initiated from
    /// system-initiated transitions.
    public var reason: String?
    public init(reason: String? = nil) {
        self.reason = reason
    }
}

/// Retention budget for the local document store. Mirrors js-bao's
/// `setRetentionPolicy(opts)` shape field-for-field.
public struct RetentionPolicy: Sendable {
    public enum DefaultMode: String, Sendable {
        case persist
        case session
    }
    /// Default persistence mode for newly-opened docs. Stored for
    /// shape parity with js-bao; not yet consumed by enforcement
    /// (matches JS — same field is set but unused in enforcement).
    public var `default`: DefaultMode
    /// Evict docs whose `lastOpenedAt` age exceeds this (ms).
    public var ttlMs: Int?
    /// Cap on local-doc count; oldest-first eviction when exceeded.
    public var maxDocs: Int?
    /// Cap on total `localBytes`; oldest-first eviction when exceeded.
    public var maxBytes: Int?
    /// Stored for parity with js-bao; not yet consumed.
    public var preserveOnSignOut: Bool?

    public init(
        default: DefaultMode = .persist,
        ttlMs: Int? = nil,
        maxDocs: Int? = nil,
        maxBytes: Int? = nil,
        preserveOnSignOut: Bool? = nil
    ) {
        self.default = `default`
        self.ttlMs = ttlMs
        self.maxDocs = maxDocs
        self.maxBytes = maxBytes
        self.preserveOnSignOut = preserveOnSignOut
    }
}

/// Options for `client.syncMetadata(options:)`. Matches the JS
/// client's options bag.
public struct SyncMetadataOptions: Sendable {
    /// Restrict the sync to a single document. `nil` syncs all open
    /// docs (default).
    public var documentId: String?
    /// `"ids"` (default) syncs only the doc ID list; `"full"` syncs
    /// every doc's full metadata blob. js-bao name parity.
    public var payloadType: String?
    /// When true, the sync runs without blocking the caller.
    public var background: Bool?
    public init(
        documentId: String? = nil,
        payloadType: String? = nil,
        background: Bool? = nil
    ) {
        self.documentId = documentId
        self.payloadType = payloadType
        self.background = background
    }
}

public struct StartWorkflowOptions: @unchecked Sendable {
    /// The workflow key identifying which workflow to start. Carried here so
    /// the single-object `start(_:)` overload mirrors js-bao's
    /// `start({ workflowKey, input, ... })`. Defaults to `""` for the
    /// positional `start(workflowKey:input:options:)` form, which sources
    /// the key from its own parameter and ignores this field.
    public var workflowKey: String
    /// Input data passed to the workflow (the server's opaque `rootInput`).
    /// Used by the single-object `start(_:)` overload; ignored by the
    /// positional form, which takes its own `input` parameter.
    public var input: [String: Any]
    public var runKey: String?
    public var contextDocId: String?
    public var meta: [String: Any]?
    /// When true, re-runs a workflow even if a prior run with the same
    /// `runKey` exists. Matches js-bao's `StartWorkflowOptions.forceRerun`.
    public var forceRerun: Bool?

    public init(
        workflowKey: String = "",
        input: [String: Any] = [:],
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        forceRerun: Bool? = nil
    ) {
        self.workflowKey = workflowKey
        self.input = input
        self.runKey = runKey
        self.contextDocId = contextDocId
        self.meta = meta
        self.forceRerun = forceRerun
    }
}

/// Options for terminating a workflow run. Mirrors js-bao's
/// `TerminateWorkflowOptions` so the single-object `terminate(_:)` call
/// lines up field-for-field. `contextDocId` rides here rather than as a
/// positional parameter.
public struct TerminateWorkflowOptions: Sendable {
    /// The workflow key identifying which workflow this run belongs to.
    public var workflowKey: String
    /// The run key identifying this workflow run.
    public var runKey: String
    /// Document ID the workflow is scoped to. Uses the user's root document
    /// when not provided.
    public var contextDocId: String?

    public init(
        workflowKey: String,
        runKey: String,
        contextDocId: String? = nil
    ) {
        self.workflowKey = workflowKey
        self.runKey = runKey
        self.contextDocId = contextDocId
    }
}

public struct ListWorkflowRunsOptions: Sendable {
    public var workflowKey: String?
    public var status: String?
    public var limit: Int?
    public var cursor: String?
    /// Walk-direction for cursor pagination. `true` = forward (default),
    /// `false` = backward. Matches js-bao's `forward` flag on the same
    /// options object.
    public var forward: Bool?
    /// Restrict to runs scoped to a particular document (multi-doc
    /// workflows fan out per `contextDocId`). Matches js-bao's
    /// `ListWorkflowRunsOptions.contextDocId`.
    public var contextDocId: String?

    public init(
        workflowKey: String? = nil,
        status: String? = nil,
        limit: Int? = nil,
        cursor: String? = nil,
        forward: Bool? = nil,
        contextDocId: String? = nil
    ) {
        self.workflowKey = workflowKey
        self.status = status
        self.limit = limit
        self.cursor = cursor
        self.forward = forward
        self.contextDocId = contextDocId
    }
}

// MARK: - Offline Access Options

/// Retention policy for a stored offline grant. Mirrors the JS
/// `EnableOfflineAccessOptions.retention` bag (`{ preserveOnSignOut? }`).
public struct OfflineRetentionOptions: Sendable {
    /// When `true`, the stored grant survives a sign-out so the user can
    /// unlock offline without re-authenticating online first.
    public var preserveOnSignOut: Bool?

    public init(preserveOnSignOut: Bool? = nil) {
        self.preserveOnSignOut = preserveOnSignOut
    }
}

/// Options for `enableOfflineAccess` / `renewOfflineGrant`. Mirrors JS
/// `EnableOfflineAccessOptions`
/// (`{ preferBiometric, allowPinFallback, ttlDays, retention, pinProvider }`).
///
/// Grant-method selection matches the JS controller: the default grant is the
/// non-biometric `"signed"` method (biometric is strictly opt-in via
/// `preferBiometric`). `allowPinFallback` + `pinProvider` describe the PIN
/// path used to wrap/unwrap the grant key when biometric is unavailable.
public struct EnableOfflineAccessOptions: Sendable {
    /// Opt in to a biometric-protected (Face ID / Touch ID) grant. Defaults to
    /// `false` — matching JS, where the default grant is `"signed"`.
    public var preferBiometric: Bool
    /// Allow falling back to a PIN-derived key when biometric is unavailable.
    public var allowPinFallback: Bool
    /// Grant time-to-live in days (server-enforced). Defaults to 14.
    public var ttlDays: Int
    /// Retention policy for the stored grant (e.g. preserve on sign-out).
    public var retention: OfflineRetentionOptions?
    /// Async provider that supplies the user's PIN when the PIN path is used.
    /// Mirrors JS `pinProvider: () => Promise<string>`.
    public var pinProvider: (@Sendable () async -> String)?

    public init(
        preferBiometric: Bool = false,
        allowPinFallback: Bool = false,
        ttlDays: Int = 14,
        retention: OfflineRetentionOptions? = nil,
        pinProvider: (@Sendable () async -> String)? = nil
    ) {
        self.preferBiometric = preferBiometric
        self.allowPinFallback = allowPinFallback
        self.ttlDays = ttlDays
        self.retention = retention
        self.pinProvider = pinProvider
    }
}

// MARK: - OAuth code exchange

/// Parameters for the static `JsBaoClient.exchangeOAuthCode(_:)`. Mirrors the
/// single-object form of JS `exchangeOAuthCode({ apiUrl, appId, code, state,
/// refreshProxyBaseUrl?, refreshProxyCookieMaxAgeSeconds? })`. The two
/// `refreshProxy*` fields route the callback through a refresh proxy (which
/// sets the httpOnly refresh cookie) instead of calling the API directly.
public struct ExchangeOAuthCodeParams: Sendable {
    public var apiUrl: String
    public var appId: String
    public var code: String
    public var state: String
    /// Base URL of the refresh proxy; when set, the callback is exchanged
    /// through `"<base>/oauth/callback"` rather than the API directly.
    public var refreshProxyBaseUrl: String?
    /// Max-age (seconds) for the proxy's refresh cookie, forwarded via the
    /// `X-Refresh-Cookie-Max-Age` header when positive.
    public var refreshProxyCookieMaxAgeSeconds: Int?

    public init(
        apiUrl: String,
        appId: String,
        code: String,
        state: String,
        refreshProxyBaseUrl: String? = nil,
        refreshProxyCookieMaxAgeSeconds: Int? = nil
    ) {
        self.apiUrl = apiUrl
        self.appId = appId
        self.code = code
        self.state = state
        self.refreshProxyBaseUrl = refreshProxyBaseUrl
        self.refreshProxyCookieMaxAgeSeconds = refreshProxyCookieMaxAgeSeconds
    }
}

public struct RevokeOfflineGrantOptions: Sendable {
    public var wipeLocal: Bool

    public init(wipeLocal: Bool = false) {
        self.wipeLocal = wipeLocal
    }
}

public struct OfflineIdentity: Sendable {
    public let userId: String
    public let appId: String
    public let rootDocId: String?
    public let email: String?
    public let name: String?
    public let expiresAt: String?
    public let method: String
}

public struct OfflineGrantStatus: Sendable {
    public let available: Bool
    public let expiresAt: String?
    public let daysLeft: Int?
    public let method: String?
}

// MARK: - Cache Options

public struct FetchCachedOptions: Sendable {
    public var waitForLoad: WaitForLoadMode?
    public var refreshNetwork: Bool?
    public var refreshIfOlderThanMs: Int?
    public var serverTimeoutMs: Int?

    public init(
        waitForLoad: WaitForLoadMode? = nil,
        refreshNetwork: Bool? = nil,
        refreshIfOlderThanMs: Int? = nil,
        serverTimeoutMs: Int? = nil
    ) {
        self.waitForLoad = waitForLoad
        self.refreshNetwork = refreshNetwork
        self.refreshIfOlderThanMs = refreshIfOlderThanMs
        self.serverTimeoutMs = serverTimeoutMs
    }
}
