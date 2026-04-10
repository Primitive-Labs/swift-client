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
        connectivityProbeTimeoutMs: Int = 2000
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
        baseMs: Int = 2000,
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

    public init(
        waitForLoad: WaitForLoadMode = .localIfAvailableElseNetwork,
        enableNetworkSync: Bool = true,
        retainLocal: Bool = true
    ) {
        self.waitForLoad = waitForLoad
        self.enableNetworkSync = enableNetworkSync
        self.retainLocal = retainLocal
    }
}

public struct CreateDocumentOptions: Sendable {
    public var title: String?
    public var tags: [String]?
    public var localOnly: Bool

    public init(title: String? = nil, tags: [String]? = nil, localOnly: Bool = false) {
        self.title = title
        self.tags = tags
        self.localOnly = localOnly
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

    public init(
        filename: String? = nil,
        contentType: String? = nil,
        sha256Base64: String? = nil,
        disposition: BlobDisposition? = nil
    ) {
        self.filename = filename
        self.contentType = contentType
        self.sha256Base64 = sha256Base64
        self.disposition = disposition
    }
}

// MARK: - Document Info

public struct DocumentInfo: Codable, Sendable {
    public let documentId: String
    public var title: String?
    public var createdBy: String?
    public var createdAt: String?
    public var modifiedAt: String?
    public var permission: String?
    public var tags: [String]?
    public var tenantScopedDO: Bool?
}

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

public struct StartWorkflowOptions: @unchecked Sendable {
    public var runKey: String?
    public var contextDocId: String?
    public var meta: [String: Any]?

    public init(runKey: String? = nil, contextDocId: String? = nil, meta: [String: Any]? = nil) {
        self.runKey = runKey
        self.contextDocId = contextDocId
        self.meta = meta
    }
}

public struct ListWorkflowRunsOptions: Sendable {
    public var workflowKey: String?
    public var status: String?
    public var limit: Int?
    public var cursor: String?

    public init(workflowKey: String? = nil, status: String? = nil, limit: Int? = nil, cursor: String? = nil) {
        self.workflowKey = workflowKey
        self.status = status
        self.limit = limit
        self.cursor = cursor
    }
}

// MARK: - Offline Access Options

public struct EnableOfflineAccessOptions: Sendable {
    public var ttlDays: Int
    public var requireBiometric: Bool

    public init(ttlDays: Int = 14, requireBiometric: Bool = true) {
        self.ttlDays = ttlDays
        self.requireBiometric = requireBiometric
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
