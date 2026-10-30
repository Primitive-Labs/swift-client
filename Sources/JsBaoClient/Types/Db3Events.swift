import Foundation

// MARK: - A db3's state on this device

/// Where a db3 is on this client: `idle` (no subscription, or never loaded),
/// `opening` (asking the room), `loading` (a first load, or a full reload of
/// its rows), `catchingUp` (changes since the last sync arriving), `live`
/// (subscribed and up to date), `reconnecting` (subscribed while the socket is
/// down), `gone` (the room refused this user access). The raw values are the
/// JS client's `Db3Phase`.
public enum Db3Phase: String, Sendable, Equatable {
    case idle
    case opening
    case loading
    case catchingUp = "catching-up"
    case live
    case reconnecting
    case gone
}

/// How far a `loading` or `catchingUp` phase is, when the room said how much is coming.
public struct Db3Progress: Sendable, Equatable {
    /// What `done` and `total` count.
    public enum Unit: String, Sendable, Equatable {
        /// Chunks of a load.
        case chunks
        /// Entries of a catch-up.
        case entries
    }

    public let done: Int
    public let total: Int
    public let unit: Unit

    public init(done: Int, total: Int, unit: Unit) {
        self.done = done
        self.total = total
        self.unit = unit
    }
}

/// The last permission a client learned for a db3, in the JS client's names;
/// `refused` once the room refused this user access.
public enum Db3Permission: String, Sendable, Equatable {
    case reader
    case readWrite = "read-write"
    case owner
    case admin
    case refused
}

/// Why a db3's last open attempt failed, or why it is `gone`.
public struct Db3StateError: Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// A db3's state on this device, as `client.db3.state(_:)`, a subscription's
/// `state` and `Db3StateEvent` answer it.
///
/// ```swift
/// let state = try await client.db3.state(db3Id)
/// if !state.resident { try await client.db3.subscribe(db3Id).available() }
/// ```
public struct Db3State: Sendable, Equatable {
    /// The db3.
    public let id: String
    /// Whether this device holds a readable copy: a load or catch-up completed
    /// here (an empty db3 that synced included), or it was created here and
    /// has not synced yet. A resident db3 answers queries and takes writes
    /// while unsubscribed.
    public let resident: Bool
    /// Whether this client holds at least one subscription to it.
    public let subscribed: Bool
    /// Where its load is.
    public let phase: Db3Phase
    /// How far a `loading` or `catchingUp` phase is, when the room said how much is coming.
    public let progress: Db3Progress?
    /// The room's log number this copy has caught up to (0 before any sync).
    public let cursor: Int
    /// How many records the local copy holds.
    public let rows: Int
    /// When a load or catch-up last completed on this device, or `nil` when none has.
    public let lastSyncAt: Date?
    /// Writes made on this device the room has not judged yet.
    public let pendingWrites: Int
    /// The last permission this client learned for the db3; `refused` once the room refused access.
    public let permission: Db3Permission?
    /// Why the last open attempt failed, why the db3 is `gone`, or why the
    /// server refused a create made on this device (`Db3CreateFailedEvent`).
    public let error: Db3StateError?
    /// Whether it was created on this device and the server does not have it
    /// yet: a `client.db3.create` of your own synced db3, until its commit
    /// lands (and while the server refuses it, `error` naming why).
    public let pendingCreate: Bool

    public init(
        id: String, resident: Bool, subscribed: Bool, phase: Db3Phase, progress: Db3Progress?, cursor: Int, rows: Int,
        lastSyncAt: Date?, pendingWrites: Int, permission: Db3Permission?, error: Db3StateError?, pendingCreate: Bool = false
    ) {
        self.id = id
        self.resident = resident
        self.subscribed = subscribed
        self.phase = phase
        self.progress = progress
        self.cursor = cursor
        self.rows = rows
        self.lastSyncAt = lastSyncAt
        self.pendingWrites = pendingWrites
        self.permission = permission
        self.error = error
        self.pendingCreate = pendingCreate
    }
}

// MARK: - The db3:* events

/// Payload for `.db3State`: a db3's new state. Emitted only when it changed.
public struct Db3StateEvent: Sendable, Equatable {
    public let state: Db3State

    public init(state: Db3State) {
        self.state = state
    }
}

/// Payload for `.db3Ready`: a subscription reached `live`. Once per subscribe, not per reconnect.
public struct Db3ReadyEvent: Sendable, Equatable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

/// One changed record of a `Db3RowsEvent`, with its row (`nil` once the record is gone).
public struct Db3RowChange: Sendable, Equatable {
    public let model: String
    public let id: String
    public let row: [String: JSONValue]?

    public init(model: String, id: String, row: [String: JSONValue]?) {
        self.model = model
        self.id = id
        self.row = row
    }
}

/// Payload for `.db3Rows`: records of a db3 changed in the local copy.
public struct Db3RowsEvent: Sendable, Equatable {
    /// Who changed them: `local` for this device's own optimistic write,
    /// applied before the room has seen it; `sibling` for another client on
    /// the same store (never on Apple platforms, where one process holds a
    /// store); `remote` for the room changing the local copy — a change
    /// relayed from elsewhere, but also the room correcting or reverting
    /// this client's own write (a server-stamped field, or a refusal that
    /// rolls the write back).
    public enum Origin: String, Sendable, Equatable, CaseIterable {
        case local
        case remote
        case sibling
    }

    public let id: String
    /// The changed records and their rows.
    public let changes: [Db3RowChange]
    public let origin: Origin
    /// For a change in bulk (a load), the models whose records changed;
    /// `changes` then lists only some of them.
    public let models: [String]?

    public init(id: String, changes: [Db3RowChange], origin: Origin, models: [String]?) {
        self.id = id
        self.changes = changes
        self.origin = origin
        self.models = models
    }
}

/// Payload for `.db3WriteRefused`: writes to a db3 were handed back. The same
/// fields as the `DocumentWriteRefusedEvent` emitted with it.
public struct Db3WriteRefusedEvent: Sendable {
    public let documentId: String
    public let model: String
    public let recordId: String
    /// Why, typed: `.writeAccessDenied`, `.documentStorePurged`, `.documentConstraintViolated`, ….
    public let error: JsBaoError
    /// Every handed-back write with its values, in the order they were made.
    public let writes: [RecordLogRefusedWrite]?
    /// The record already holding the key, for a constraint refusal.
    public let conflictingRecord: RecordLogRecordKey?
    /// For `DB3_CONDITION_NOT_MET`, the record whose guard failed and the
    /// room's row of it; for `DB3_RECORD_NOT_FOUND`, the record an increment
    /// named (`row == nil`).
    public let current: RecordLogCurrentRecord?

    /// The db3 form of a `DocumentWriteRefusedEvent`.
    /// - Parameter event: The refusal as `document:write-refused` carries it.
    public init(_ event: DocumentWriteRefusedEvent) {
        documentId = event.documentId
        model = event.model
        recordId = event.recordId
        error = event.error
        writes = event.writes
        conflictingRecord = event.conflictingRecord
        current = event.current
    }
}

/// Payload for `.db3Evicted`: a db3's records left this device.
public struct Db3EvictedEvent: Sendable, Equatable {
    /// `explicit` for `client.db3.evict` (or another door's eviction),
    /// `retention` for the retention policy's sweep.
    public enum Reason: String, Sendable, Equatable, CaseIterable {
        case explicit
        case retention
    }

    public let id: String
    public let reason: Reason

    public init(id: String, reason: Reason) {
        self.id = id
        self.reason = reason
    }
}

/// Payload for `.db3Gone`: the room will not sync the db3 with this client.
/// `.permission` (`DB3_ACCESS_REFUSED`): it refused this user access (a
/// revoked grant). `.syncOff` (`DB3_SYNC_OFF`): the db3's sync was turned
/// off; new writes are refused until it is on again, and a subscribe then
/// opens it as before. `.clientOutdated` (`DB3_CLIENT_OUTDATED`): it needs a
/// newer client; update the client to sync the db3. `.deleted`
/// (`DB3_DELETED`): the db3 was deleted; evict it to remove the copy. Either
/// way its rows stay readable on the device, and writes made before are kept
/// until the room judges them.
///
/// ```swift
/// let watching = sub.observe { event in
///     if case .gone(let gone) = event, gone.reason == .syncOff { print("\(gone.id) is server-only now") }
/// }
/// ```
public struct Db3GoneEvent: Sendable, Equatable {
    /// Why the db3 is gone.
    public enum Reason: String, Sendable, Equatable {
        case permission
        case clientOutdated = "client-outdated"
        case syncOff = "sync-off"
        case deleted
    }

    public let id: String
    public let reason: Reason
    /// `DB3_ACCESS_REFUSED` for `.permission`, `DB3_SYNC_OFF` for `.syncOff`,
    /// `DB3_CLIENT_OUTDATED` for `.clientOutdated`, `DB3_DELETED` for `.deleted`.
    public let code: String

    public init(id: String) {
        self.init(id: id, reason: .permission)
    }

    public init(id: String, reason: Reason) {
        self.id = id
        self.reason = reason
        switch reason {
        case .permission: self.code = JsBaoErrorCode.db3AccessRefused.rawValue
        case .clientOutdated: self.code = JsBaoErrorCode.db3ClientOutdated.rawValue
        case .syncOff: self.code = JsBaoErrorCode.db3SyncOff.rawValue
        case .deleted: self.code = JsBaoErrorCode.db3Deleted.rawValue
        }
    }
}

/// Payload for `.db3Error`: an open attempt of a db3 failed (not for being
/// offline or refused). The client retries.
public struct Db3ErrorEvent: Sendable, Equatable {
    public let id: String
    public let code: String
    public let message: String

    public init(id: String, code: String, message: String) {
        self.id = id
        self.code = code
        self.message = message
    }
}

/// Payload for `.db3Created`: the server has the db3 `client.db3.create` (or
/// the alias call) created. A create of your own synced db3 fires it when its
/// commit lands.
public struct Db3CreatedEvent: Sendable, Equatable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

/// Payload for `.db3CreateFailed`: the server refused a `client.db3.create`
/// (or the alias call). For a create of your own synced db3, `id` names it:
/// `create` had already returned, and the db3's rows stay readable, with
/// `state.pendingCreate` true, until `commitOfflineCreate(documentId:)`
/// succeeds or a forced evict removes them. A create the server mints the id
/// of (sync off, or naming a custodian) created nothing, and its call threw.
public struct Db3CreateFailedEvent: Sendable, Equatable {
    /// The refusal's code, as the thrown error carries it.
    public let code: String
    public let message: String
    /// The title asked for.
    public let title: String?
    /// The type asked for, or `nil`.
    public let type: String?
    /// The id this client minted for the db3; `nil` when the server mints it.
    public let id: String?

    public init(code: String, message: String, title: String?, type: String?, id: String? = nil) {
        self.code = code
        self.message = message
        self.title = title
        self.type = type
        self.id = id
    }
}

extension Db3StateEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .db3State }
}

extension Db3CreatedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .db3Created }
}

extension Db3CreateFailedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .db3CreateFailed }
}

extension Db3ReadyEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .db3Ready }
}

extension Db3RowsEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .db3Rows }
}

extension Db3WriteRefusedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .db3WriteRefused }
}

extension Db3EvictedEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .db3Evicted }
}

extension Db3GoneEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .db3Gone }
}

extension Db3ErrorEvent: JsBaoEventPayload {
    public static var eventKey: JsBaoEvent { .db3Error }
}
