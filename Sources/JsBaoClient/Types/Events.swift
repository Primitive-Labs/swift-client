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

    /// Generic "auth" event. **Swift-only and never emitted** — js-bao has
    /// no `"auth"` event, and nothing in this client emits it. It was dead
    /// surface. Subscribe to the specific typed auth events that JS actually
    /// emits instead: `.authSuccess` (`auth-success`), `.authFailed`
    /// (`auth-failed`), `.authState` (`auth:state`), `.authLogout`
    /// (`auth:logout`), `.authLogoutComplete` (`auth:logout:complete`).
    /// Scheduled for removal once the deprecation window closes (#1120).
    @available(*, deprecated, message: "Swift-only and never emitted; JS has no `auth` event. Subscribe to a specific event instead: .authSuccess / .authFailed / .authState / .authLogout / .authLogoutComplete (#1120).")
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
    /// **Swift-only and never emitted** — js-bao does not emit a distinct
    /// "queued" upload event. A blob that is enqueued surfaces through the
    /// regular `.blobsUploadProgress` (`blobs:upload-progress`) event with
    /// `status == "queued"`, exactly as on JS. Migrate any
    /// `.blobsUploadQueued` subscriber to `.blobsUploadProgress` and branch
    /// on `event.status`. Scheduled for removal once the deprecation window
    /// closes (#1120).
    @available(*, deprecated, message: "Swift-only and never emitted; JS has no queued event. Subscribe to .blobsUploadProgress and check `event.status == \"queued\"` (#1120).")
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

    // ── Swift-only (deprecated, #1120) ────────────────────────────
    /// Fires after a remote Yjs update lands in a local doc. **Swift-
    /// only**: js-bao uses the string `"remoteUpdate"` as a `Y.Doc`
    /// origin tag (passed to `Y.Doc.transact(fn, "remoteUpdate")`),
    /// not as an emitted event. Cross-language code that subscribes
    /// to `"remoteUpdate"` on the JS side will never fire.
    ///
    /// **Deprecated (#1120).** This is a Swift-only client event with no JS
    /// counterpart, so it's being retired for cross-platform parity. It is
    /// still emitted today (deprecation window) so existing subscribers keep
    /// working, but new code should migrate:
    ///   - **For a non-deprecated client event**: subscribe to
    ///     `.documentSyncStateChanged` and react when `state == "synced"` —
    ///     it now fires on every remote-update landing (see
    ///     `DocumentSyncStateChangedEvent`). This is the supported in-client
    ///     replacement.
    ///   - **For true JS parity**: observe the `Y.Doc` directly (the JS
    ///     pattern), e.g. a YSwift map/array/text observer, so your code
    ///     reacts to the actual CRDT change rather than a client-emitted
    ///     ping.
    ///
    /// Scheduled for removal once the deprecation window closes. It is
    /// load-bearing for downstream reload-on-remote-write loaders, so it will
    /// not be hard-removed until consumers have migrated.
    @available(*, deprecated, message: "Swift-only; JS has no `remoteUpdate` event (it's a Y.Doc origin tag there). Still emitted during the deprecation window. Migrate to .documentSyncStateChanged (state == \"synced\") for an in-client event, or observe the Y.Doc directly for JS parity (#1120).")
    case remoteUpdate

    // ── JS events not previously surfaced on Swift ────────────────
    // Added in the parity pass so cross-platform code can subscribe
    // by name without a quiet no-op. Each emission site is in the
    // file that owns the underlying signal; see corresponding payload
    // structs below for the data shape.
    case authLogout = "auth:logout"
    /// Fires when logout teardown finishes. Mirrors JS `auth:logout:complete`
    /// (`src/client/JsBaoClient.ts` `logout()`): JS emits `auth:logout`
    /// immediately on entry, then `auth:logout:complete` after the
    /// best-effort server logout, networking shutdown, and auth-state
    /// teardown have all run. Payload is `{}` on JS;
    /// `AuthLogoutCompleteEvent` is the (empty) Swift analog.
    case authLogoutComplete = "auth:logout:complete"
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

/// Payload for `.awareness`. Mirrors the JS client's `AwarenessEvent`
/// (`src/client/JsBaoClient.ts`) field-for-field: a **delta** of client
/// IDs whose presence state changed — `added` (new clients), `updated`
/// (existing clients with new state), `removed` (clients whose state was
/// cleared). To read the actual states, call
/// `client.getAwarenessStates(documentId:)` with the delivered IDs —
/// same pattern as JS.
///
/// (#996: this replaced the previous Swift-only full-snapshot `states`
/// payload, which JS never delivered.)
public struct AwarenessEvent: Sendable {
    public let documentId: String
    public let added: [String]
    public let updated: [String]
    public let removed: [String]

    public init(documentId: String, added: [String], updated: [String], removed: [String]) {
        self.documentId = documentId
        self.added = added
        self.updated = updated
        self.removed = removed
    }
}

/// Payload for the deprecated `.remoteUpdate` event (#1120). See
/// `JsBaoEvent.remoteUpdate` for the migration path
/// (`.documentSyncStateChanged` with `state == "synced"`, or a direct
/// `Y.Doc` observer). Not annotated `@available(deprecated)` itself so the
/// internal emit site and the still-supported subscribers don't trip a
/// warning during the deprecation window.
public struct RemoteUpdateEvent: Sendable {
    public let documentId: String
}

/// Payload for `.permission`. JS delivers `permission` as a plain string
/// (`"owner" | "read-write" | "reader" | "admin"`); Swift keeps a typed
/// enum whose `rawValue`s are exactly those wire strings (#996 decision:
/// typed accessor with matching observable value). Read
/// `event.permission.rawValue` for the JS-identical string — also exposed
/// directly as `permissionRaw`.
public struct PermissionEvent: Sendable {
    public let documentId: String
    public let permission: DocumentPermission

    /// The JS wire string for `permission` (e.g. `"read-write"`).
    public var permissionRaw: String { permission.rawValue }
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
    /// Where the change originated. Always present (#996). Matches js-bao's
    /// `documentMetadataChanged.source` vocabulary field-for-field:
    /// - `"local"`  — write originated on this device
    /// - `"server"` — the server pushed it over the WebSocket
    /// - `"idb"`    — replayed from local persistence. JS uses this value
    ///   for IndexedDB-originated changes; Swift maps its SQLite
    ///   offline-store hydration to the **same wire value** so
    ///   cross-platform subscribers see one vocabulary. (Neither client
    ///   currently emits a hydration-sourced change — the value is
    ///   declared in both type surfaces and reserved for that path.)
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

/// Payload for `blobs:upload-paused`. Mirrors the JS client's
/// `emitUploadPaused` payload (`src/client/internal/blobManager.ts`)
/// field-for-field: the full queue record at pause time.
public struct BlobUploadPausedEvent: Sendable {
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

/// Payload for `blobs:upload-resumed`. Mirrors the JS client's
/// `emitUploadResumed` payload field-for-field (same record shape as
/// `BlobUploadPausedEvent`).
public struct BlobUploadResumedEvent: Sendable {
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

/// Real-time notification that a document invitation has changed state.
///
/// Payload for `.invitation` (`client.events.on(.invitation) { (e: InvitationEvent) in … }`).
/// Mirrors the JS client's `InvitationEvent` (`src/client/JsBaoClient.ts`)
/// field-for-field, including optionality.
///
/// **Important:** events are targeted — most actions are delivered to only
/// one side of the invitation (inviter _or_ invitee, not both). Consumers
/// should `switch` on `action` and handle every value, with a `default`
/// branch for forward-compatibility (new action values may be added without
/// a breaking change). See {@link InvitationEvent.action} on the JS side for
/// the full targeting matrix:
///
/// - `"created"`   — invitee only. A new invitation was sent to them.
/// - `"updated"`   — invitee only. An existing pending invitation changed.
/// - `"cancelled"` — invitee only. The inviter/admin cancelled it.
/// - `"declined"`  — both invitee and inviter. The invitee declined.
/// - `"accepted"`  — inviter only. The invitee accepted; `acceptedBy`
///                   carries the accepting user's `userId`.
public struct InvitationEvent: Sendable, Equatable {
    /// Nested document summary carried on the event. Mirrors the JS
    /// `InvitationEvent.document` object field-for-field; every field is
    /// optional, matching JS.
    public struct Document: Sendable, Equatable {
        public let documentId: String?
        public let title: String?
        public let tags: [String]?
        public let createdAt: String?
        public let lastModified: String?
        public let createdBy: String?

        public init(
            documentId: String? = nil,
            title: String? = nil,
            tags: [String]? = nil,
            createdAt: String? = nil,
            lastModified: String? = nil,
            createdBy: String? = nil
        ) {
            self.documentId = documentId
            self.title = title
            self.tags = tags
            self.createdAt = createdAt
            self.lastModified = lastModified
            self.createdBy = createdBy
        }
    }

    /// The lifecycle transition that just occurred. JS types this as a
    /// closed union (`"created" | "updated" | "cancelled" | "declined" |
    /// "accepted"`) but documents that new values may appear; Swift keeps
    /// it as the raw `String` so an unknown server value is delivered
    /// rather than dropped. Compare against the literals above.
    public let action: String
    public let invitationId: String
    public let documentId: String
    public let permission: String
    public let title: String?
    public let invitedBy: String?
    public let invitedAt: String?
    public let expiresAt: String?
    /// UserId of the invitee who accepted. Populated only when
    /// `action == "accepted"` (matches JS).
    public let acceptedBy: String?
    public let document: Document?

    public init(
        action: String,
        invitationId: String,
        documentId: String,
        permission: String,
        title: String? = nil,
        invitedBy: String? = nil,
        invitedAt: String? = nil,
        expiresAt: String? = nil,
        acceptedBy: String? = nil,
        document: Document? = nil
    ) {
        self.action = action
        self.invitationId = invitationId
        self.documentId = documentId
        self.permission = permission
        self.title = title
        self.invitedBy = invitedBy
        self.invitedAt = invitedAt
        self.expiresAt = expiresAt
        self.acceptedBy = acceptedBy
        self.document = document
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

/// Payload for `.authLogoutComplete`. JS emits `{}`; the struct is empty
/// to match (mirrors the `AuthLogoutEvent` / JS `auth:logout` pairing).
public struct AuthLogoutCompleteEvent: Sendable {
    public init() {}
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
/// `timings` is the server-provided per-phase timing map carried on the
/// `syncPerf` WS frame (`totalMs`, `reconstructMs`, `docHashMs`, … — see
/// `src/yjs-room-v2.ts`). The server only sends the frame when the client
/// set `requestPerf: true` on its `syncStep1` — request it via
/// `OpenDocumentOptions(requestSyncPerf: true)`, same as JS
/// `openDocument(..., { requestSyncPerf: true })`.
///
/// `clientTimings` is the client-side derived map (JS `clientTimings?`,
/// e.g. `clientTotalMs`/`clientRoundTripMs`). The Swift client does not
/// yet instrument per-phase sync timings (no `getSyncTimings` analog), so
/// it is `nil` today; the field exists for cross-platform payload parity.
///
/// (#996: the previous Swift-only `phase`/`elapsedMs` pair was removed —
/// JS never carried those fields.)
public struct SyncPerfEvent: @unchecked Sendable {
    public let documentId: String
    /// Server-provided per-phase timing map (mirrors JS `timings`).
    public let timings: [String: Any]
    /// Client-side derived timings (mirrors JS `clientTimings?`). `nil`
    /// until Swift grows sync-timing instrumentation.
    public let clientTimings: [String: Any]?

    public init(
        documentId: String,
        timings: [String: Any] = [:],
        clientTimings: [String: Any]? = nil
    ) {
        self.documentId = documentId
        self.timings = timings
        self.clientTimings = clientTimings
    }
}

/// Fired when a workflow run is started. Mirrors the JS client's
/// `WorkflowStartedEvent` (`src/client/JsBaoClient.ts`) field-for-field.
///
/// Emitted exclusively from the server-pushed `workflowStarted` WS frame
/// (the JS source of truth); every field is populated from the frame.
/// The local `workflows.start(...)` HTTP path does NOT emit — it did
/// pre-#1112, which double-emitted every start observed over WS.
/// All fields beyond `workflowKey`/`runId` are optional so decoding /
/// construction stays lenient when the frame omits them.
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

/// Payload for `.documentSyncStateChanged`. `state` is one of
/// `"syncing" | "synced" | "stale" | "error"`.
///
/// This is the supported in-client replacement for the deprecated
/// `.remoteUpdate` event (#1120): a `"synced"` change is emitted each time a
/// remote Yjs update lands for an open document, so reload-on-remote-write
/// loaders can subscribe here instead of `.remoteUpdate`.
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
