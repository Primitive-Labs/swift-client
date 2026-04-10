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
    case remoteUpdate
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
    public let source: String // "sqlite" or "server"
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

// MARK: - Auth State

public struct AuthState: Sendable {
    public let authenticated: Bool
    public let mode: NetworkMode
    public let userId: String?
}
