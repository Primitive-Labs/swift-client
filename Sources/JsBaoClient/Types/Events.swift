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

public struct WorkflowStatusEvent: Sendable {
    public let documentId: String
    public let workflowRunId: String
    public let status: String
}

// MARK: - Auth State

public struct AuthState: Sendable {
    public let authenticated: Bool
    public let mode: NetworkMode
    public let userId: String?
}
