import Foundation

// MARK: - Connection Status

public enum ConnectionStatus: String, Sendable {
    case connecting
    case connected
    case disconnected
}

// MARK: - Network Mode

public enum NetworkMode: String, Sendable, Codable {
    case auto
    case online
    case offline
}

// MARK: - Document Permission

public enum DocumentPermission: String, Sendable, Codable {
    case owner
    case readWrite = "read-write"
    case reader
    case admin
}

// MARK: - Wait For Load Mode

public enum WaitForLoadMode: String, Sendable {
    case local
    case network
    case localIfAvailableElseNetwork
}

// MARK: - Start Network Mode

public enum StartNetworkMode: String, Sendable {
    case immediate
    case afterLocalPersistence = "afterIndexedDb"
    case manual
}

// MARK: - Event Types

public enum JsBaoEvent: String, Sendable {
    case status
    case networkMode
    case auth
    case authSuccess = "auth-success"
    case authFailed = "auth-failed"
    case authState = "auth:state"
    case offlineAuthEnabled = "offlineAuth:enabled"
    case offlineAuthUnlocked = "offlineAuth:unlocked"
    case offlineAuthFailed = "offlineAuth:failed"
    case offlineAuthRenewed = "offlineAuth:renewed"
    case offlineAuthRevoked = "offlineAuth:revoked"
    case documentLoaded
    case documentClosed
    case sync
    case awareness
    case blobsUploadProgress = "blobs:upload-progress"
    case blobsUploadCompleted = "blobs:upload-completed"
    case blobsUploadFailed = "blobs:upload-failed"
    case blobsUploadQueued = "blobs:upload-queued"
    case blobsUploadPaused = "blobs:upload-paused"
    case blobsUploadResumed = "blobs:upload-resumed"
    case blobsQueueDrained = "blobs:queue-drained"
    case permission
    case meUpdated
    case invitation
    case workflowStatus
    case documentMetadataChanged
    case pendingCreateFailed
    case authRefreshDeferred = "auth-refresh-deferred"

    // ── Swift-only ────────────────────────────────────────────────
    /// Fires after a remote Yjs update lands in a local doc. **Swift-
    /// only**: js-bao uses the string `"remoteUpdate"` as a `Y.Doc`
    /// origin tag (passed to `Y.Doc.transact(fn, "remoteUpdate")`),
    /// not as an emitted event. Cross-language code that subscribes
    /// to `"remoteUpdate"` on the JS side will never fire — use the
    /// origin tag pattern there instead.
    case remoteUpdate

    // ── JS events not previously surfaced on Swift ────────────────
    // Added in the parity pass so cross-platform code can subscribe
    // by name without a quiet no-op. Each emission site is in the
    // file that owns the underlying signal; see corresponding payload
    // structs below for the data shape.
    case authLogout = "auth:logout"
    case authOnlineRequired = "auth:onlineAuthRequired"
    case connectionClose = "connection-close"
    case connectionError = "connection-error"
    case documentOpened
    case documentCreateCommitFailed
    case error
    case meUpdateFailed
    case offlineAuthExpiringSoon = "offlineAuth:expiringSoon"
    case pendingCreateCommitted
    case schemaDiscovered = "schema-discovered"
    case syncPerf
    case workflowStarted
    case documentSyncStateChanged

    /// Derived from a `docMetadata` frame with `action: "deleted"`.
    /// Covers both "the doc was hard-deleted server-side" and "your
    /// access to the doc was revoked" — the server collapses both to
    /// the same wire shape, so subscribers can't distinguish from the
    /// payload alone. Detail views that have the doc open should
    /// dismiss themselves on this event regardless of cause.
    case documentDeleted

    // ── Cache lifecycle (parity with JS KvCache) ──────────────────
    /// Fires after a successful network refresh of a cached entry.
    /// Mirrors JS `KvCache`'s `cacheUpdated` (`src/client/kv-cache.ts`),
    /// emitted from the network path in `KvCache.fetchCached`. Payload:
    /// `CacheUpdatedEvent` (`key` / `updatedAt` / `source` / `value`).
    case cacheUpdated
    /// Fires when a network refresh of a cached entry throws. Mirrors
    /// JS `KvCache`'s `cacheUpdateFailed` (`src/client/kv-cache.ts`).
    /// Payload: `CacheUpdateFailedEvent` (`key` / `error`).
    case cacheUpdateFailed
}

// MARK: - Event Payloads

public struct StatusChangedEvent: Sendable {
    public let status: ConnectionStatus
}

public struct NetworkModeEvent: Sendable {
    public let mode: NetworkMode
    public let isOnline: Bool
    public let reason: String?
}

public struct AuthSuccessEvent: Sendable {
    public let token: String
    public let previousToken: String?
    public let cause: String?
}

public struct AuthFailedEvent: Sendable {
    public let message: String?
    public let reason: String?
}

public struct AuthStateEvent: Sendable {
    public let authenticated: Bool
    public let mode: NetworkMode
    public let userId: String?
}

public struct DocumentLoadedEvent: Sendable {
    public let documentId: String
    /// Where the doc was loaded from. Matches js-bao's value vocabulary:
    /// - `"local"`   — offline-store hydration (SQLite on Apple,
    ///                  IndexedDB on the browser, in-memory in tests)
    /// - `"server"` — fresh sync from the WebSocket
    /// - `"indexeddb"` — browser-only, never emitted on Swift
    public let source: String
    public let hadData: Bool
    public let bytes: Int?
    public let elapsedMs: Double
}

public struct DocumentClosedEvent: Sendable {
    public let documentId: String
}

public struct SyncEvent: Sendable {
    public let documentId: String
    public let synced: Bool
}

public struct AwarenessEvent: Sendable {
    public let documentId: String
    public let states: [[String: Any]]

    // Sendable conformance note: states contains Any but is only used on main actor
    nonisolated public init(documentId: String, states: [[String: Any]]) {
        self.documentId = documentId
        self.states = states
    }
}

public struct RemoteUpdateEvent: Sendable {
    public let documentId: String
}

public struct PermissionEvent: Sendable {
    public let documentId: String
    public let permission: DocumentPermission
}

/// Typed payload for `.documentMetadataChanged`. Mirrors the JS
/// client's `documentMetadataChanged` event and the server-side
/// `docMetadata` frame. `metadata` is nil when `action == "deleted"`
/// (the server clears the metadata as part of the delete/revoke).
public struct DocumentMetadataChangedEvent: @unchecked Sendable {
    public let documentId: String
    /// `"created" | "updated" | "deleted" | "evicted"`. See the JS
    /// client's `documentMetadataChanged` docs for the full vocabulary.
    public let action: String
    public let metadata: [String: Any]?
    public let changedFields: [String]?
    /// Where the change originated. Matches js-bao's
    /// `documentMetadataChanged.source` vocabulary field-for-field:
    /// - `"local"`  — write originated on this device
    /// - `"server"` — the server pushed it over the WebSocket
    ///
    /// JS additionally emits `"idb"` for IndexedDB-replayed changes; that
    /// has no Swift/SQLite analog and is intentionally dropped (the Swift
    /// offline store doesn't re-emit metadata changes on hydration).
    public let source: String

    public init(
        documentId: String,
        action: String,
        metadata: [String: Any]? = nil,
        changedFields: [String]? = nil,
        source: String
    ) {
        self.documentId = documentId
        self.action = action
        self.metadata = metadata
        self.changedFields = changedFields
        self.source = source
    }
}

/// Derived event fired when the server signals that a doc is no
/// longer visible to the user (server-side delete OR access
/// revocation — see `JsBaoEvent.documentDeleted` docstring). Detail
/// views should subscribe to this and dismiss themselves.
public struct DocumentDeletedEvent: Sendable {
    public let documentId: String
    /// Best-effort source classification:
    ///  - `"server-push"` — the server sent a `docMetadata` deletion frame
    ///  - `"local-delete"` — `documents.delete(...)` was called locally
    public let source: String
}

/// Payload for `blobs:upload-progress`. Mirrors the JS client's
/// `BlobUploadProgressEvent` (`src/client/JsBaoClient.ts`) field-for-field:
/// it carries the full upload-queue record, not a byte-transfer delta. The
/// Swift `BlobManager` emits this from its queue, so every field is sourced
/// from the tracked `UploadTask`.
public struct BlobUploadProgressEvent: Sendable {
    public let documentId: String
    public let blobId: String
    public let queueId: String
    public let filename: String
    public let contentType: String
    public let numBytes: Int
    /// `"queued" | "uploading" | "pending" | "paused"`.
    public let status: String
    public let attempts: Int
    /// Epoch seconds of the next scheduled attempt (JS uses ms; Swift's
    /// `UploadTask.nextAttemptAt` is a `TimeInterval`/epoch-seconds).
    public let nextAttemptAt: TimeInterval
    public let retainLocal: Bool?
    public let lastError: String?
    /// Epoch seconds of the last update to the queue record.
    public let updatedAt: TimeInterval

    public init(
        documentId: String,
        blobId: String,
        queueId: String,
        filename: String,
        contentType: String,
        numBytes: Int,
        status: String,
        attempts: Int,
        nextAttemptAt: TimeInterval,
        retainLocal: Bool? = nil,
        lastError: String? = nil,
        updatedAt: TimeInterval
    ) {
        self.documentId = documentId
        self.blobId = blobId
        self.queueId = queueId
        self.filename = filename
        self.contentType = contentType
        self.numBytes = numBytes
        self.status = status
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.retainLocal = retainLocal
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}

/// Payload for `blobs:upload-completed`. Mirrors the JS client's
/// `BlobUploadCompletedEvent` field-for-field.
public struct BlobUploadCompletedEvent: Sendable {
    public let documentId: String
    public let blobId: String
    public let queueId: String
    public let filename: String
    public let contentType: String
    public let numBytes: Int
    public let attempts: Int
    public let retainLocal: Bool?
    public let updatedAt: TimeInterval

    public init(
        documentId: String,
        blobId: String,
        queueId: String,
        filename: String,
        contentType: String,
        numBytes: Int,
        attempts: Int,
        retainLocal: Bool? = nil,
        updatedAt: TimeInterval
    ) {
        self.documentId = documentId
        self.blobId = blobId
        self.queueId = queueId
        self.filename = filename
        self.contentType = contentType
        self.numBytes = numBytes
        self.attempts = attempts
        self.retainLocal = retainLocal
        self.updatedAt = updatedAt
    }
}

/// Payload for `blobs:upload-failed`. Mirrors the JS client's
/// `BlobUploadFailedEvent` field-for-field. `lastError` is optional to
/// match JS (`lastError?: string`).
public struct BlobUploadFailedEvent: Sendable {
    public let documentId: String
    public let blobId: String
    public let queueId: String
    public let filename: String
    public let contentType: String
    public let numBytes: Int
    public let attempts: Int
    public let retainLocal: Bool?
    public let lastError: String?
    public let willRetry: Bool
    public let nextAttemptAt: TimeInterval
    public let updatedAt: TimeInterval

    public init(
        documentId: String,
        blobId: String,
        queueId: String,
        filename: String,
        contentType: String,
        numBytes: Int,
        attempts: Int,
        retainLocal: Bool? = nil,
        lastError: String? = nil,
        willRetry: Bool,
        nextAttemptAt: TimeInterval,
        updatedAt: TimeInterval
    ) {
        self.documentId = documentId
        self.blobId = blobId
        self.queueId = queueId
        self.filename = filename
        self.contentType = contentType
        self.numBytes = numBytes
        self.attempts = attempts
        self.retainLocal = retainLocal
        self.lastError = lastError
        self.willRetry = willRetry
        self.nextAttemptAt = nextAttemptAt
        self.updatedAt = updatedAt
    }
}

/// Server-pushed workflow status event. Mirrors the JS client's
/// `WorkflowStatusEvent` payload field-for-field — matches the
/// `WorkflowStatusPayload` the server emits in
/// `src/app-api/services/websocket-notifier.ts`.
///
/// The server only fires this for terminal statuses (`completed`, `failed`,
/// `terminated`). When `needsApply == true` and the workflow has a handler
/// registered via `client.workflows.define(...)`, the client triggers the
/// claim → apply → confirm flow automatically.
public struct WorkflowStatusEvent: @unchecked Sendable {
    public let workflowKey: String
    public let workflowId: String
    public let runKey: String
    public let runId: String
    public let status: String   // "completed" | "failed" | "terminated"
    public let output: Any?
    public let error: String?
    public let contextDocId: String?
    public let needsApply: Bool
    public let meta: [String: Any]?
    public let startedByUserId: String?

    public init(
        workflowKey: String,
        workflowId: String,
        runKey: String,
        runId: String,
        status: String,
        output: Any? = nil,
        error: String? = nil,
        contextDocId: String? = nil,
        needsApply: Bool = false,
        meta: [String: Any]? = nil,
        startedByUserId: String? = nil
    ) {
        self.workflowKey = workflowKey
        self.workflowId = workflowId
        self.runKey = runKey
        self.runId = runId
        self.status = status
        self.output = output
        self.error = error
        self.contextDocId = contextDocId
        self.needsApply = needsApply
        self.meta = meta
        self.startedByUserId = startedByUserId
    }
}

/// Context delivered to the user's `onApply` handler registered via
/// `client.workflows.define(...)`. Mirrors the JS client's apply context.
public struct WorkflowApplyContext: @unchecked Sendable {
    public let workflowKey: String
    public let runKey: String
    public let runId: String
    public let contextDocId: String?
    public let output: Any?
    public let startedByUserId: String?
    public let meta: [String: Any]?

    public init(
        workflowKey: String,
        runKey: String,
        runId: String,
        contextDocId: String? = nil,
        output: Any? = nil,
        startedByUserId: String? = nil,
        meta: [String: Any]? = nil
    ) {
        self.workflowKey = workflowKey
        self.runKey = runKey
        self.runId = runId
        self.contextDocId = contextDocId
        self.output = output
        self.startedByUserId = startedByUserId
        self.meta = meta
    }
}

/// Closure type for the user's apply handler registered via
/// `client.workflows.define(workflowKey, onApply: ...)`. The closure runs
/// after the client successfully claims the apply lease and fetches the
/// workflow output. Throw to cause the claim to be released so another
/// client (or a retry) can pick it up.
public typealias WorkflowApplyHandler = @Sendable (WorkflowApplyContext) async throws -> Void

// MARK: - Newly-added event payloads (parity gap 5)
// Each struct mirrors the JS counterpart's payload field-for-field.
// Where the JS payload is `{}`, the struct is empty.

public struct AuthLogoutEvent: Sendable {
    public let reason: String?
    public init(reason: String? = nil) { self.reason = reason }
}

public struct AuthOnlineRequiredEvent: Sendable {
    public let reason: String?
    public init(reason: String? = nil) { self.reason = reason }
}

public struct ConnectionCloseEvent: Sendable {
    public let code: Int?
    public let reason: String?
    public init(code: Int? = nil, reason: String? = nil) {
        self.code = code
        self.reason = reason
    }
}

public struct ConnectionErrorEvent: Sendable {
    public let message: String?
    public init(message: String? = nil) { self.message = message }
}

public struct DocumentOpenedEvent: Sendable {
    public let documentId: String
    public init(documentId: String) { self.documentId = documentId }
}

public struct DocumentCreateCommitFailedEvent: Sendable {
    public let documentId: String
    public let reason: String?
    public init(documentId: String, reason: String? = nil) {
        self.documentId = documentId
        self.reason = reason
    }
}

/// Generic error bus. Subscribed by app-level error reporters that
/// want a single hose to listen on; specific errors still emit their
/// own typed events.
public struct GenericErrorEvent: Sendable {
    public let scope: String?
    public let message: String
    public init(scope: String? = nil, message: String) {
        self.scope = scope
        self.message = message
    }
}

public struct MeUpdateFailedEvent: Sendable {
    public let reason: String?
    public init(reason: String? = nil) { self.reason = reason }
}

public struct OfflineAuthExpiringSoonEvent: Sendable {
    public let expiresAtMs: Double?
    public let remainingMs: Double?
    public init(expiresAtMs: Double? = nil, remainingMs: Double? = nil) {
        self.expiresAtMs = expiresAtMs
        self.remainingMs = remainingMs
    }
}

public struct PendingCreateCommittedEvent: Sendable {
    public let documentId: String
    public init(documentId: String) { self.documentId = documentId }
}

public struct SchemaDiscoveredEvent: Sendable {
    public let documentId: String
    public let modelNames: [String]
    public init(documentId: String, modelNames: [String]) {
        self.documentId = documentId
        self.modelNames = modelNames
    }
}

/// Payload for `.syncPerf`. Mirrors the JS client's `syncPerf` event
/// (`src/client/JsBaoClient.ts`): `{ documentId, timings, clientTimings? }`.
///
/// In JS, `timings` is the server-provided per-phase timing map carried on
/// the `syncPerf` WS frame, and `clientTimings` is derived from
/// `docManager.getSyncTimings(documentId)` (e.g. `clientTotalMs`). The Swift
/// client does **not** yet handle a `syncPerf` WS frame and does not
/// instrument per-phase sync timings (no `getSyncTimings` analog), so these
/// maps are present for cross-platform decode parity but are populated only
/// if/when a Swift emit site is wired. `phase`/`elapsedMs` are a Swift-only
/// convenience pair retained for existing callers.
public struct SyncPerfEvent: @unchecked Sendable {
    public let documentId: String
    /// Server-provided per-phase timing map (mirrors JS `timings`). Empty
    /// when no server frame supplied it.
    public let timings: [String: Any]
    /// Client-side derived timings (mirrors JS `clientTimings?`). `nil` when
    /// the Swift client hasn't computed any (the common case today, since
    /// Swift lacks the `getSyncTimings` instrumentation).
    public let clientTimings: [String: Any]?
    /// Swift-only: a coarse single-phase label. Not present in JS.
    public let phase: String
    /// Swift-only: elapsed ms for `phase`. Not present in JS.
    public let elapsedMs: Double

    public init(
        documentId: String,
        timings: [String: Any] = [:],
        clientTimings: [String: Any]? = nil,
        phase: String,
        elapsedMs: Double
    ) {
        self.documentId = documentId
        self.timings = timings
        self.clientTimings = clientTimings
        self.phase = phase
        self.elapsedMs = elapsedMs
    }
}

/// Fired when a workflow run is started. Mirrors the JS client's
/// `WorkflowStartedEvent` (`src/client/JsBaoClient.ts`) field-for-field.
///
/// On the server-pushed path (a `workflowStarted` WS frame, the JS
/// source of truth) every field is populated from the frame. On the
/// local `workflows.start(...)` HTTP-response path, only the fields the
/// `StartWorkflowResult` envelope and the caller's options carry are
/// set — `meta`/`contextDocId` come from the start options when present.
/// All fields beyond `workflowKey`/`runId` are optional so decoding /
/// construction stays lenient when a source can't supply them.
public struct WorkflowStartedEvent: @unchecked Sendable {
    public let workflowKey: String
    public let runId: String
    public let workflowId: String?
    public let runKey: String?
    public let instanceId: String?
    public let contextDocId: String?
    public let meta: [String: Any]?

    public init(
        workflowKey: String,
        runId: String,
        workflowId: String? = nil,
        runKey: String? = nil,
        instanceId: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil
    ) {
        self.workflowKey = workflowKey
        self.runId = runId
        self.workflowId = workflowId
        self.runKey = runKey
        self.instanceId = instanceId
        self.contextDocId = contextDocId
        self.meta = meta
    }
}

public struct DocumentSyncStateChangedEvent: Sendable {
    public let documentId: String
    public let state: String // "syncing" | "synced" | "stale" | "error"
    public init(documentId: String, state: String) {
        self.documentId = documentId
        self.state = state
    }
}

// MARK: - Cache lifecycle payloads (parity with JS KvCache)

/// Payload for `.cacheUpdated`. Mirrors the JS `KvCache` `cacheUpdated`
/// payload field-for-field (`src/client/kv-cache.ts`): `{ key, updatedAt,
/// source, value }`. `source` is always `"server"` (the event only fires
/// after a successful network refresh). `value` is the decoded server
/// response, so it's untyped `Any` — `@unchecked Sendable` like the other
/// `Any`-carrying payloads in this file.
public struct CacheUpdatedEvent: @unchecked Sendable {
    public let key: String
    /// ISO-8601 timestamp of the refresh.
    public let updatedAt: String
    /// Always `"server"` — matches the JS emit site.
    public let source: String
    public let value: Any?

    public init(key: String, updatedAt: String, source: String = "server", value: Any?) {
        self.key = key
        self.updatedAt = updatedAt
        self.source = source
        self.value = value
    }
}

/// Payload for `.cacheUpdateFailed`. Mirrors the JS `KvCache`
/// `cacheUpdateFailed` payload (`src/client/kv-cache.ts`): `{ key, error }`.
public struct CacheUpdateFailedEvent: Sendable {
    public let key: String
    public let error: String

    public init(key: String, error: String) {
        self.key = key
        self.error = error
    }
}

// MARK: - Analytics context (P2)

/// Bundle returned by `client.getLlmAnalyticsContext()` /
/// `getGeminiAnalyticsContext()`. Lets feature code log structured
/// analytics events without holding a direct reference to the client.
/// Matches js-bao's shape — `logEvent(event)` plus an `isEnabled`
/// guard for callers that want to skip work when analytics is off.
public final class AnalyticsContext: @unchecked Sendable {
    private let logger: @Sendable ([String: Any]) -> Void
    private let enabledCheck: @Sendable (String?) -> Bool

    public init(
        logEvent: @escaping @Sendable ([String: Any]) -> Void,
        isEnabled: @escaping @Sendable (String?) -> Bool = { _ in true }
    ) {
        self.logger = logEvent
        self.enabledCheck = isEnabled
    }

    public func logEvent(_ event: [String: Any]) { logger(event) }

    /// Optional `phase` argument — `"start"`, `"success"`, `"failure"`,
    /// or `nil` for "any phase". Matches js-bao's signature so the call
    /// sites are identical across languages.
    public func isEnabled(_ phase: String? = nil) -> Bool {
        enabledCheck(phase)
    }
}

// MARK: - Auth State

public struct AuthState: Sendable {
    public let authenticated: Bool
    public let mode: NetworkMode
    public let userId: String?
}
