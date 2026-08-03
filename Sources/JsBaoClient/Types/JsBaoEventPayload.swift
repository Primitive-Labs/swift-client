import Foundation

// MARK: - The payload/event association

/// A payload type that is delivered under exactly one client event key.
///
/// The conformance is what makes the event surface compiler-checked. Because
/// each payload names its own key, both ends of a subscription are derived from
/// one fact:
///
/// ```swift
/// for await status in client.stream(for: StatusChangedEvent.self) {
///     print(status.status)
/// }
/// ```
///
/// There is no separate event argument to get wrong, so a payload can no longer
/// be observed under a key it is never delivered on — the mistake that made a
/// mis-annotated `events.on` handler silently never fire.
///
/// Every event the client emits has exactly one conforming payload type. The two
/// deprecated cases that are never emitted — `JsBaoEvent.auth` and
/// `JsBaoEvent.blobsUploadQueued` — deliberately have none, so there is nothing
/// to subscribe to.
public protocol JsBaoEventPayload: Sendable {
    /// The event key this payload is always delivered under.
    static var eventKey: JsBaoEvent { get }

    /// Whether the client retains this event's most recent value, so a consumer
    /// that subscribes late can ask for it with
    /// `stream(for:replayingLatest: true)`.
    ///
    /// `true` for the client-global state-like events whose payload describes a
    /// condition that is still true after the event fired — connection status,
    /// network mode, auth state. A SwiftUI `.task` starts after the view
    /// appears, so without replay a status stream commonly misses the connection
    /// event that already happened.
    ///
    /// Retention is one slot per event key, so an event scoped to a document (or
    /// any other subject) must not opt in: the replay would deliver whichever
    /// subject changed last rather than the one the consumer cares about. That
    /// is why `DocumentSyncStateChangedEvent`, state-like as it is, returns
    /// `false`.
    ///
    /// `false` (the default) for one-shot events like `documentLoaded` or
    /// `blobsUploadFailed`, where a stale value would be misleading rather than
    /// helpful. Asking to replay one of those is not an error; there is simply
    /// nothing retained to deliver.
    static var isReplayable: Bool { get }
}

public extension JsBaoEventPayload {
    /// Most events describe something that happened rather than a condition that
    /// persists, so replay is off unless the payload opts in.
    static var isReplayable: Bool { false }
}

/// Adapt an untyped `(JsBaoEvent, Any)` emit closure onto the typed one.
///
/// The one place the deprecated untyped emit closures are bridged. The key
/// always comes from the payload's own type, so an adapted closure cannot pair
/// a payload with a key nothing delivers it under.
func adaptUntypedEmit(
    _ emit: @escaping @Sendable (JsBaoEvent, Any) -> Void
) -> @Sendable (any JsBaoEventPayload) -> Void {
    { payload in emit(Swift.type(of: payload).eventKey, payload) }
}

// MARK: - Legacy dictionary bridge

/// Internal bridge for the payload types that replaced a `[String: Any]` emit.
///
/// Nine events used to be emitted as bare dictionaries. Converting them to typed
/// payloads would silently stop an existing
/// `events.on(.offlineAuthEnabled) { (d: [String: Any]) in … }` handler from
/// firing, which is exactly the class of failure the typed surface exists to
/// remove. So for the whole deprecation window the callback shim converts back:
/// `on` falls back to this representation when the handler's annotation is not
/// the typed struct, and `onAny` delivers it verbatim.
///
/// The dictionary must reproduce the pre-conversion payload key-for-key,
/// including omitting optional keys that were absent, and preserving the
/// original Swift value types (an `Int` stays an `Int`, not a `Double`).
protocol LegacyEventDictionary {
    var legacyDictionary: [String: Any] { get }
}

// MARK: - New payload types (ported from the JS `JsBaoEvents` map)

/// Payload for `.meUpdated`. Fires when the signed-in user's own record
/// changes. Mirrors the JS client's `MeUpdatedEvent` field for field
/// (`{ value, updatedAt?, source? }`).
///
/// The me record carries app-defined custom fields, so there is no fixed
/// schema — `value` is a `JSONValue`, the same "shape is yours to define"
/// typing the JS client expresses as `unknown`. Read fields with `JSONValue`'s
/// accessors: `event.value["name"]?.stringValue`.
public struct MeUpdatedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .meUpdated }

    /// The updated me record itself — the `value` field of the server frame,
    /// not the frame.
    public let value: JSONValue

    /// Where the new value came from. `"server"` for a server push, matching
    /// the JS client's `source`.
    public let source: String?

    /// When the record was updated, when the frame carries it.
    public let updatedAt: String?

    /// The whole server frame, retained only so the deprecated callback shim
    /// can hand back byte-for-byte what it delivered before this event became
    /// a typed struct.
    private let frame: JSONValue

    public init(value: JSONValue, source: String? = nil, updatedAt: String? = nil) {
        self.value = value
        self.source = source
        self.updatedAt = updatedAt
        var frame: [String: JSONValue] = [
            "type": .string(Self.eventKey.rawValue),
            "value": value,
        ]
        if let source { frame["source"] = .string(source) }
        if let updatedAt { frame["updatedAt"] = .string(updatedAt) }
        self.frame = .object(frame)
    }

    /// Build from the raw `meUpdated` WebSocket frame.
    ///
    /// The pre-conversion emit handed subscribers this whole frame, so it is
    /// kept verbatim for `legacyDictionary` while the typed fields are read out
    /// of it. `source` is `"server"` for the same reason the JS client sets it
    /// there: this initializer is only reached from a server push.
    init(serverFrame: JSONValue) {
        self.frame = serverFrame
        self.value = serverFrame["value"] ?? .null
        self.source = serverFrame["source"]?.stringValue ?? "server"
        self.updatedAt = serverFrame["updatedAt"]?.stringValue
    }
}

extension MeUpdatedEvent: LegacyEventDictionary {
    /// The raw server frame this event used to be emitted as — `{"type":
    /// "meUpdated", "value": …}`, not the me record. Rendered through
    /// `JSONCoding`, so JSON numbers arrive as `NSNumber` and still bridge to
    /// `Int` or `Double` at the call site.
    var legacyDictionary: [String: Any] {
        (try? JSONCoding.jsonObject(from: frame)) as? [String: Any] ?? [:]
    }
}

/// Payload for `.pendingCreateFailed`. Fires when a document created offline
/// could not be committed to the server. Mirrors the JS client's
/// `PendingCreateFailedEvent`.
public struct PendingCreateFailedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .pendingCreateFailed }

    public let documentId: String
    /// Description of the failure.
    public let error: String

    public init(documentId: String, error: String) {
        self.documentId = documentId
        self.error = error
    }
}

extension PendingCreateFailedEvent: LegacyEventDictionary {
    var legacyDictionary: [String: Any] {
        ["documentId": documentId, "error": error]
    }
}

/// Payload for `.authRefreshDeferred`. Fires when a token refresh could not be
/// attempted and has been rescheduled (or abandoned because the client went
/// offline).
public struct AuthRefreshDeferredEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .authRefreshDeferred }

    /// Why the refresh was deferred, e.g. `"offline"` or `"backoff"`.
    public let status: String
    /// The operation that asked for the refresh, when known.
    public let cause: String?
    /// Milliseconds until the next scheduled attempt. `nil` when no further
    /// attempt is promised (for example after going offline).
    public let nextAttemptMs: Int?
    /// The underlying error, when the deferral came from a failed attempt.
    public let error: String?

    public init(
        status: String,
        cause: String? = nil,
        nextAttemptMs: Int? = nil,
        error: String? = nil
    ) {
        self.status = status
        self.cause = cause
        self.nextAttemptMs = nextAttemptMs
        self.error = error
    }
}

extension AuthRefreshDeferredEvent: LegacyEventDictionary {
    /// Optional keys are omitted rather than set to `NSNull`, matching the
    /// pre-conversion emit — callers distinguish "no next attempt promised"
    /// by the key's absence.
    var legacyDictionary: [String: Any] {
        var details: [String: Any] = ["status": status]
        if let cause { details["cause"] = cause }
        if let nextAttemptMs { details["nextAttemptMs"] = nextAttemptMs }
        if let error { details["error"] = error }
        return details
    }
}

/// Payload for `.offlineAuthEnabled`. Fires when an offline-auth grant is
/// stored, so the app can sign in without the network. Mirrors the JS client's
/// `OfflineAuthEnabledEvent`.
public struct OfflineAuthEnabledEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .offlineAuthEnabled }

    /// How the grant is protected, e.g. `"signed"` or `"biometric"`.
    public let method: String

    public init(method: String) {
        self.method = method
    }
}

extension OfflineAuthEnabledEvent: LegacyEventDictionary {
    var legacyDictionary: [String: Any] { ["method": method] }
}

/// Payload for `.offlineAuthUnlocked`. Fires when a stored offline-auth grant
/// was unlocked and the user is signed in without the network. Mirrors the JS
/// client's `OfflineAuthUnlockedEvent`.
public struct OfflineAuthUnlockedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .offlineAuthUnlocked }

    public let userId: String

    public init(userId: String) {
        self.userId = userId
    }
}

extension OfflineAuthUnlockedEvent: LegacyEventDictionary {
    var legacyDictionary: [String: Any] { ["userId": userId] }
}

/// Payload for `.offlineAuthFailed`. Fires when an offline-auth unlock could
/// not complete. Mirrors the JS client's `OfflineAuthFailedEvent`.
public struct OfflineAuthFailedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .offlineAuthFailed }

    /// Why the unlock failed, e.g. `"expired"` or `"biometric_cancelled"`.
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

extension OfflineAuthFailedEvent: LegacyEventDictionary {
    var legacyDictionary: [String: Any] { ["reason": reason] }
}

/// Payload for `.offlineAuthRenewed`. Fires when a stored offline-auth grant's
/// lifetime was extended. Carries no fields, matching the JS client's
/// `OfflineAuthRenewedEvent`.
public struct OfflineAuthRenewedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .offlineAuthRenewed }

    public init() {}
}

extension OfflineAuthRenewedEvent: LegacyEventDictionary {
    var legacyDictionary: [String: Any] { [:] }
}

/// Payload for `.offlineAuthRevoked`. Fires when a stored offline-auth grant
/// was removed.
public struct OfflineAuthRevokedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .offlineAuthRevoked }

    /// Whether the revoke also wiped the device's local data.
    public let wipeLocal: Bool

    public init(wipeLocal: Bool) {
        self.wipeLocal = wipeLocal
    }
}

extension OfflineAuthRevokedEvent: LegacyEventDictionary {
    var legacyDictionary: [String: Any] { ["wipeLocal": wipeLocal] }
}

/// Payload for `.blobsQueueDrained`. Fires when the blob upload queue has no
/// remaining work. Carries no fields.
///
/// Field-level divergence from JS (#2241): the JS client's payload carries a
/// `timestamp` (epoch milliseconds) that the Swift emit sites do not produce.
/// The Swift struct stays field-free until the Swift queue has a timestamp to
/// report.
public struct BlobsQueueDrainedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .blobsQueueDrained }

    public init() {}
}

extension BlobsQueueDrainedEvent: LegacyEventDictionary {
    var legacyDictionary: [String: Any] { [:] }
}

// MARK: - Conformances for the existing payload types

extension StatusChangedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .status }
    public static var isReplayable: Bool { true }
}

extension NetworkModeEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .networkMode }
    public static var isReplayable: Bool { true }
}

extension AuthSuccessEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .authSuccess }
}

extension AuthFailedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .authFailed }
}

extension AuthStateEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .authState }
    public static var isReplayable: Bool { true }
}

extension AuthLogoutEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .authLogout }
}

extension AuthLogoutCompleteEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .authLogoutComplete }
}

extension AuthOnlineRequiredEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .authOnlineRequired }
}

extension OfflineAuthExpiringSoonEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .offlineAuthExpiringSoon }
}

extension DocumentLoadedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .documentLoaded }
}

extension DocumentClosedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .documentClosed }
}

extension DocumentOpenedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .documentOpened }
}

extension DocumentCreateCommitFailedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .documentCreateCommitFailed }
}

extension PendingCreateCommittedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .pendingCreateCommitted }
}

extension DocumentMetadataChangedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .documentMetadataChanged }
}

extension DocumentSyncStateChangedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .documentSyncStateChanged }
    // Deliberately not replayable, unlike the other state-like events. Retention
    // is one slot per event key, and this is the only state-like payload scoped
    // to a *document*, so a replay would hand back whichever document changed
    // last — frequently not the one the consumer cares about. Read the current
    // value for a specific document with `client.isSynced(documentId)` instead,
    // and use the stream for subsequent changes.
}

extension SyncEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .sync }
}

extension SyncPerfEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .syncPerf }
}

extension AwarenessEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .awareness }
}

extension PermissionEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .permission }
}

extension SchemaDiscoveredEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .schemaDiscovered }
}

extension RemoteUpdateEvent: JsBaoEventPayload {
    /// Resolved from `JsBaoClient.remoteUpdateRawKey` rather than naming the
    /// deprecated `.remoteUpdate` case, the same escape hatch
    /// `JsBaoClient.emitRemoteUpdate` uses so the client's own code does not
    /// trip the case's deprecation during its window (#1120).
    ///
    /// The lookup always succeeds: the raw key is the case's own `rawValue`,
    /// which `DeprecationWindowInternalUseTests` guards against drift, and
    /// `JsBaoEventPayloadTests` asserts this key resolves to `"remoteUpdate"`.
    /// The fallback only keeps this a total function, and points at the
    /// documented migration target for `.remoteUpdate`.
    public static var eventKey: JsBaoEvent {
        JsBaoEvent(rawValue: JsBaoClient.remoteUpdateRawKey) ?? .documentSyncStateChanged
    }
}

extension ConnectionCloseEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .connectionClose }
}

extension ConnectionErrorEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .connectionError }
}

extension GenericErrorEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .error }
}

extension MeUpdateFailedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .meUpdateFailed }
}

extension InvitationEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .invitation }
}

extension NotificationEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .notification }
}

extension WorkflowStatusEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .workflowStatus }
}

extension WorkflowStartedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .workflowStarted }
}

extension BlobUploadProgressEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .blobsUploadProgress }
}

extension BlobUploadCompletedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .blobsUploadCompleted }
}

extension BlobUploadFailedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .blobsUploadFailed }
}

extension BlobUploadPausedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .blobsUploadPaused }
}

extension BlobUploadResumedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .blobsUploadResumed }
}

extension CacheUpdatedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .cacheUpdated }
}

extension CacheUpdateFailedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .cacheUpdateFailed }
}

// MARK: - The conformance table

/// Every `JsBaoEventPayload` conformance in the client.
///
/// Swift cannot enumerate a protocol's conformances at runtime, so the set is
/// listed once here and the drift guards read it: `JsBaoEventPayloadTests`
/// asserts it covers every `JsBaoEvent` case except the two deprecated,
/// never-emitted ones, that no two payloads claim the same key, and that it
/// stays aligned with the JS client's `JsBaoEvents` map. Adding an event
/// without adding its payload here fails those tests.
let allJsBaoEventPayloadTypes: [any JsBaoEventPayload.Type] = [
    StatusChangedEvent.self,
    NetworkModeEvent.self,
    AuthSuccessEvent.self,
    AuthFailedEvent.self,
    AuthStateEvent.self,
    AuthLogoutEvent.self,
    AuthLogoutCompleteEvent.self,
    AuthOnlineRequiredEvent.self,
    AuthRefreshDeferredEvent.self,
    OfflineAuthEnabledEvent.self,
    OfflineAuthUnlockedEvent.self,
    OfflineAuthFailedEvent.self,
    OfflineAuthRenewedEvent.self,
    OfflineAuthRevokedEvent.self,
    OfflineAuthExpiringSoonEvent.self,
    DocumentLoadedEvent.self,
    DocumentClosedEvent.self,
    DocumentOpenedEvent.self,
    DocumentCreateCommitFailedEvent.self,
    PendingCreateCommittedEvent.self,
    PendingCreateFailedEvent.self,
    DocumentMetadataChangedEvent.self,
    DocumentSyncStateChangedEvent.self,
    SyncEvent.self,
    SyncPerfEvent.self,
    AwarenessEvent.self,
    PermissionEvent.self,
    SchemaDiscoveredEvent.self,
    RemoteUpdateEvent.self,
    ConnectionCloseEvent.self,
    ConnectionErrorEvent.self,
    GenericErrorEvent.self,
    MeUpdatedEvent.self,
    MeUpdateFailedEvent.self,
    InvitationEvent.self,
    NotificationEvent.self,
    WorkflowStatusEvent.self,
    WorkflowStartedEvent.self,
    BlobUploadProgressEvent.self,
    BlobUploadCompletedEvent.self,
    BlobUploadFailedEvent.self,
    BlobUploadPausedEvent.self,
    BlobUploadResumedEvent.self,
    BlobsQueueDrainedEvent.self,
    CacheUpdatedEvent.self,
    CacheUpdateFailedEvent.self,
]

/// The event keys that have no payload type, and why.
///
/// Both are deprecated Swift-only cases that nothing emits (#1120), so there is
/// nothing for a payload to carry and no stream to open. Listed by raw value so
/// naming them here does not trip their own deprecation.
let unpayloadedJsBaoEventKeys: Set<String> = [
    "auth",
    "blobs:upload-queued",
]

/// Event keys the Swift client declares that the JS client's `JsBaoEvents` map
/// does not.
///
/// Each entry is a deliberate divergence, not an oversight — the JS-parity
/// drift guard in `JsBaoEventPayloadTests` fails on any Swift key that is
/// neither in the JS map nor listed here, so a new Swift-only event forces a
/// decision. Listed by raw value.
let swiftOnlyJsBaoEventKeys: Set<String> = [
    // Swift-only and deprecated, never emitted (#1120). (`auth` is not listed:
    // the JS map does carry an `auth` key as a legacy catch-all, it is just
    // never emitted on either side.)
    "blobs:upload-queued",
    // Swift-only and deprecated, still emitted during its window (#1120).
    "remoteUpdate",
    // `KvCache` lifecycle. Both clients emit these (JS from `kv-cache.ts`),
    // but the JS map covers only the client's own events, not the cache's.
    "cacheUpdated",
    "cacheUpdateFailed",
]
