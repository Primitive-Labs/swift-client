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
    /// `"local"` (write originated on this device), `"remote"` (server
    /// pushed it), or `nil` when the emitter doesn't know.
    public let source: String?

    public init(
        documentId: String,
        action: String,
        metadata: [String: Any]? = nil,
        changedFields: [String]? = nil,
        source: String? = nil
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

public struct BlobUploadProgressEvent: Sendable {
    public let documentId: String
    public let blobId: String
    public let bytesTransferred: Int
    public let totalBytes: Int
}

public struct BlobUploadCompletedEvent: Sendable {
    public let documentId: String
    public let blobId: String
    public let numBytes: Int
}

public struct BlobUploadFailedEvent: Sendable {
    public let documentId: String
    public let blobId: String
    public let error: String
    public let willRetry: Bool
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

public struct SyncPerfEvent: Sendable {
    public let documentId: String
    public let phase: String
    public let elapsedMs: Double
    public init(documentId: String, phase: String, elapsedMs: Double) {
        self.documentId = documentId
        self.phase = phase
        self.elapsedMs = elapsedMs
    }
}

public struct WorkflowStartedEvent: Sendable {
    public let workflowKey: String
    public let runId: String
    public init(workflowKey: String, runId: String) {
        self.workflowKey = workflowKey
        self.runId = runId
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
