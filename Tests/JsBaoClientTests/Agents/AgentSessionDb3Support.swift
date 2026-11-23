import Foundation
import XCTest
@testable import JsBaoClient

/// A session's db3 on a device, for the hermetic view suites (#4884, DSO-4884-003).
///
/// Nothing of the platform is faked. A real `RecordLogDocumentBinding` on a
/// temporary SQLite store holds the db3's rows, and the room's writes reach
/// it the way the client's session applies them: a page applied to the store,
/// then announced to the binding's listeners. A real `Db3Lifecycle` hands out
/// the subscriptions, over deps answering what the client would for that
/// binding: format 3, the binding's marks and stored state, the socket up,
/// the store purged and unbound on an eviction. The room's answers reach the
/// lifecycle as the client's `RecordLogSession` reports them: an open that
/// goes live, and a refusal that marks the store refused and then fails the
/// open with `ACCESS_DENIED` (or `DB3_SYNC_OFF`, or `DB3_CLIENT_OUTDATED`).
///
/// `door` is what a view's host reaches the db3 through: `subscribe`,
/// `records` and `evict`, as the client wires them.
final class SessionDb3: @unchecked Sendable {
    let id: String
    let directory: String
    private let provider: SQLiteStorageProvider
    private let lock = NSLock()
    private var bound: RecordLogDocumentBinding?
    private(set) var lifecycle: Db3Lifecycle!

    // Guarded by `lock`.
    private var socket = true
    private var goesLive = true
    private var format: Int
    private var readyTimeout: TimeInterval = Db3Lifecycle.defaultReadyTimeout
    private var evictionsHeld = false
    private var opened: [String] = []
    private var evictions = 0
    private var heldReads: DispatchSemaphore?
    private var readsHeld = 0

    private init(id: String, directory: String, provider: SQLiteStorageProvider, format: Int) {
        self.id = id
        self.directory = directory
        self.provider = provider
        self.format = format
    }

    /// A session's db3 with an empty, caught-up local copy (`resident`), as a
    /// first load leaves it. `resident: false` binds a store nothing has
    /// loaded; `bound: false` binds none, the documents API answering
    /// `format` for the id.
    static func make(
        id: String = "s1", resident: Bool = true, format: Int = RecordLogTransport.documentFormat, bound: Bool = true
    ) async throws -> SessionDb3 {
        let directory = NSTemporaryDirectory() + "agent-session-db3-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let db3 = SessionDb3(id: id, directory: directory, provider: provider, format: format)
        if bound {
            try db3.bind()
            if resident { try db3.binding().markCaughtUpAtCreate() }
        }
        db3.lifecycle = Db3Lifecycle(deps: db3.deps())
        return db3
    }

    func cleanup() {
        lock.withLock { bound }?.close()
        try? FileManager.default.removeItem(atPath: directory)
    }

    // MARK: - What the host reaches it through

    var door: AgentSessionDb3Door {
        AgentSessionDb3Door(
            subscribe: { [self] id in
                try lifecycle.subscribe(id, options: Db3SubscribeOptions(readyTimeout: lock.withLock { readyTimeout }))
            },
            records: { [self] id in
                DocumentRecords(documentId: id) { [self] in
                    let (gate, binding) = lock.withLock { () -> (DispatchSemaphore?, RecordLogDocumentBinding?) in
                        if heldReads != nil { readsHeld += 1 }
                        return (heldReads, bound)
                    }
                    gate?.wait()
                    gate?.signal()
                    guard let binding, !binding.isClosed else { throw JsBaoClient.documentNotOpenForRecords(id) }
                    return binding
                }
            },
            evict: { [self] id in
                lock.withLock { evictions += 1 }
                while lock.withLock({ evictionsHeld }) { try await Task.sleep(nanoseconds: 10_000_000) }
                try await lifecycle.evict(id, options: Db3EvictOptions(force: true))
            }
        )
    }

    /// Opens the lifecycle asked for (a subscribe's first open), in order.
    var opens: [String] { lock.withLock { opened } }

    /// Evictions the door was asked for.
    var evictionCount: Int { lock.withLock { evictions } }

    /// The db3's state, as `client.db3.state` answers it.
    func state() async throws -> Db3State { try await lifecycle.state(id) }

    /// The phase the lifecycle last applied (and told its subscriptions).
    var appliedPhase: Db3Phase { lifecycle.current(id).phase }

    /// Whether an open goes live at once, as a session whose handshake the room answered.
    func setGoesLive(_ live: Bool) { lock.withLock { goesLive = live } }

    /// How long a subscription's `ready()` waits without progress.
    func setReadyTimeout(_ seconds: TimeInterval) { lock.withLock { readyTimeout = seconds } }

    /// Hold every eviction asked for from now until `releaseEvictions()`.
    func holdEvictions() { lock.withLock { evictionsHeld = true } }

    func releaseEvictions() { lock.withLock { evictionsHeld = false } }

    /// The client ends every subscription (a sign-out): each pending `ready()` throws `DB3_DISPOSED`.
    func endSubscriptions() async { await lifecycle.releaseAll(unbind: false) }

    // MARK: - The room

    /// Rows the room wrote, applied to the local copy as a page and announced
    /// as the session announces it.
    func write(_ rows: [(model: String, row: [String: JSONValue])]) throws {
        let binding = try binding()
        let reply = try binding.store.applyCatchUpPage(writer: binding.writer, rows: rows.map { entry in
            RecordLogCatchUpRow(model: entry.model, id: entry.row["id"]?.stringValue ?? "", row: entry.row)
        })
        binding.notify(reply.changed.map { RecordLogRecordKey(model: $0.model, id: $0.id) })
        lifecycle.pendingChanged(id)
    }

    func write(_ model: String, _ row: [String: JSONValue]) throws {
        try write([(model, row)])
    }

    /// The local copy's rows of `model`, as stored.
    func rows(_ model: String) throws -> [[String: JSONValue]] {
        try binding().store.queryView(model, [:], options: QueryOptions(limit: 10_000)).data
    }

    /// The room refused this client the db3 (its release frame, `ACCESS_DENIED`
    /// on `record.open`): the store is marked refused and the open reported
    /// failed, as `RecordLogSession.accessRefused` does.
    func refuse() throws {
        try binding().setState(permission: .some(RecordLogPermission.refused))
        lifecycle.syncFailed(id, "ACCESS_DENIED")
    }

    /// The room refused the db3 because its sync is off (`DB3_SYNC_OFF`).
    func turnSyncOff() throws {
        lifecycle.syncOffHeard(id)
        try binding().setState(permission: .some(RecordLogPermission.refused))
        lifecycle.syncFailed(id, JsBaoErrorCode.db3SyncOff.rawValue)
    }

    /// The room needs a newer client for the db3 (`DB3_CLIENT_OUTDATED`).
    func outdate() {
        lifecycle.syncFailed(id, JsBaoErrorCode.db3ClientOutdated.rawValue)
    }

    /// The session's status as the client's session reports it.
    func report(_ phase: RecordLogSessionPhase) {
        lifecycle.statusChanged(id, RecordLogSessionStatus(phase: phase))
    }

    /// The socket closed or opened.
    func setSocket(_ up: Bool) {
        lock.withLock { socket = up }
        lifecycle.connectionChanged()
    }

    // MARK: - Holding reads

    /// Hold every records read made from now until `releaseReads()`.
    func holdReads() {
        lock.withLock {
            heldReads = DispatchSemaphore(value: 0)
            readsHeld = 0
        }
    }

    /// How many reads have been held since `holdReads()`.
    var heldReadCount: Int { lock.withLock { readsHeld } }

    func releaseReads() {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            defer { heldReads = nil }
            return heldReads
        }
        gate?.signal()
    }

    // MARK: - The client's answers

    private func binding() throws -> RecordLogDocumentBinding {
        guard let binding = lock.withLock({ bound }), !binding.isClosed else {
            throw JsBaoClient.documentNotOpenForRecords(id)
        }
        return binding
    }

    private func bind() throws {
        let binding = try RecordLogDocumentBinding(host: provider, documentId: id, clientId: "client-1", logger: Logger(level: .none))
        lock.withLock { bound = binding }
    }

    private func marks() -> Db3SyncMarks? {
        guard let binding = lock.withLock({ bound }), !binding.isClosed else { return nil }
        let marks = (try? binding.refreshMarks()) ?? binding.marks
        return Db3SyncMarks(
            cursor: marks.cursor, permission: marks.permission, lastCatchUpAt: marks.lastCatchUpAt,
            replacing: marks.replacing, staged: marks.staged
        )
    }

    private func storedState() throws -> RecordLogStoredState? {
        if let binding = lock.withLock({ bound }), !binding.isClosed { return try binding.store.storedState() }
        guard try RecordLogStore.hasTables(host: provider) else { return nil }
        let state = try RecordLogStore(host: provider, documentId: id, clientId: "client-1").storedState()
        let empty = state.cursor == 0 && state.rows == 0 && state.writers.isEmpty && state.lastCatchUpAt == nil && !state.replacing
        return empty ? nil : state
    }

    private func deps() -> Db3LifecycleDeps {
        Db3LifecycleDeps(
            socketUp: { [self] in lock.withLock { socket } },
            resolveFormat: { [self] _ in lock.withLock { format } },
            open: { [self] id in
                let live = lock.withLock { () -> Bool in
                    opened.append(id)
                    return goesLive
                }
                if live {
                    Task { [self] in lifecycle.statusChanged(id, RecordLogSessionStatus(phase: .live)) }
                }
            },
            close: { [self] id in lifecycle.statusChanged(id, RecordLogSessionStatus(phase: .idle)) },
            bind: { [self] _ in try bind() },
            unbind: { [self] _ in
                let binding = lock.withLock { () -> RecordLogDocumentBinding? in
                    defer { bound = nil }
                    return bound
                }
                binding?.close()
            },
            knownPermission: { _ in .reader },
            isBound: { [self] _ in lock.withLock { bound.map { !$0.isClosed } ?? false } },
            syncMarks: { [self] _ in marks() },
            storedState: { [self] _ in try storedState() },
            storedIds: { [self] in try storedState() == nil ? [] : [id] },
            purge: { [self] id, force in
                let reply = try? RecordLogStore(host: provider, documentId: id, clientId: "client-1").purge(force: force)
                return Db3PurgeOutcome(purged: reply?.purged ?? false)
            }
        )
    }
}

/// The JSON `get` answers for a session, as the phase-2 server sends it.
func agentSessionInfoJSON(
    _ sessionId: String, role: String = "owner", ownerUserId: String = "u1", turnId: String? = nil,
    hasUnread: Bool = false, lastActivityAt: String? = nil, title: String? = nil
) -> String {
    let turn = turnId.map {
        #"{"turnId":"\#($0)","initiatorUserId":"u1","startedAt":null,"phase":"model","rounds":1,"leaseUntil":null,"answeredBy":null,"pause":null,"pending":null}"#
    } ?? "null"
    let activity = lastActivityAt.map { "\"\($0)\"" } ?? "null"
    let named = title.map { "\"\($0)\"" } ?? "null"
    return #"""
    {"sessionId":"\#(sessionId)","agentKey":"helper","ownerUserId":"\#(ownerUserId)",
     "createdAt":"2026-10-01T00:00:00.000Z","title":\#(named),"scope":null,"lastActivityAt":\#(activity),
     "hasUnread":\#(hasUnread),"lastReadAt":null,
     "members":{"viewers":[],"participants":["u2"]},"role":"\#(role)","status":"idle","turn":\#(turn)}
    """#
}

extension AgentSessionsAPI {
    /// `open` over `db3` instead of the client's own db3s: the host the client
    /// builds, its db3 door replaced.
    func open(
        sessionId: String, options: OpenAgentSessionOptions = OpenAgentSessionOptions(), db3: SessionDb3
    ) async throws -> AgentSessionView {
        let client = try XCTUnwrap(self.client, "a sessions API with a client")
        var host = AgentSessionViewHost(client: client, sessions: self)
        host.db3 = db3.door
        return try await open(host: host, sessionId: sessionId, options: options)
    }
}

/// The rows a hermetic view suite writes, as the session object writes them.
enum SessionRows {
    static let at = "2026-10-01T00:00:00.000Z"

    static func session(
        _ id: String = "s1", status: String = "idle", activeTurnId: String? = nil, title: String? = nil
    ) -> [String: JSONValue] {
        var row: [String: JSONValue] = ["id": .string(id), "agentKey": "helper", "status": .string(status), "createdAt": .string(at)]
        if let activeTurnId { row["activeTurnId"] = .string(activeTurnId) }
        if let title { row["title"] = .string(title) }
        return row
    }

    static func member(_ userId: String, role: String = "participant", addedAt: String = at) -> [String: JSONValue] {
        ["id": .string(userId), "role": .string(role), "addedAt": .string(addedAt)]
    }

    static func message(
        _ id: String, seq: Double, turnId: String? = nil, authorKind: String = "user", authorUserId: String? = "u1",
        clientMessageId: String? = nil, queueSeq: JSONValue? = nil
    ) -> [String: JSONValue] {
        var row: [String: JSONValue] = ["id": .string(id), "seq": .number(seq), "authorKind": .string(authorKind), "createdAt": .string(at)]
        if let turnId { row["turnId"] = .string(turnId) }
        if let authorUserId, authorKind != "agent" { row["authorUserId"] = .string(authorUserId) }
        if let clientMessageId { row["clientMessageId"] = .string(clientMessageId) }
        if let queueSeq { row["queueSeq"] = queueSeq }
        return row
    }

    static func text(_ id: String, messageId: String, seq: Double, text: String = "hello") -> [String: JSONValue] {
        ["id": .string(id), "messageId": .string(messageId), "seq": .number(seq), "kind": "text", "text": .string(text),
         "textState": "done", "createdAt": .string(at)]
    }

    static func call(
        _ id: String, messageId: String, seq: Double, turnId: String, toolName: String = "pick",
        state: String = "input-available", input: String = #"{"question":"How many?"}"#, callNumber: Double? = nil,
        approvalApproved: Bool? = nil, artifact: String? = nil, artifactBlobId: String? = nil, output: String? = nil
    ) -> [String: JSONValue] {
        var row: [String: JSONValue] = [
            "id": .string(id), "messageId": .string(messageId), "seq": .number(seq), "turnId": .string(turnId),
            "toolName": .string(toolName), "state": .string(state), "input": .string(input), "createdAt": .string(at),
        ]
        if let callNumber { row["callNumber"] = .number(callNumber) }
        if let approvalApproved { row["approvalApproved"] = .bool(approvalApproved) }
        if let artifact { row["artifact"] = .string(artifact) }
        if let artifactBlobId { row["artifactBlobId"] = .string(artifactBlobId) }
        if let output { row["output"] = .string(output) }
        return row
    }

    static func step(_ id: String, turnId: String, seq: Double, kind: String = "model_call") -> [String: JSONValue] {
        ["id": .string(id), "turnId": .string(turnId), "seq": .number(seq), "kind": .string(kind), "status": "completed",
         "startedAt": .string(at)]
    }

    static func turn(_ id: String, seq: Double, status: String = "running", initiatorUserId: String? = "u1") -> [String: JSONValue] {
        var row: [String: JSONValue] = ["id": .string(id), "seq": .number(seq), "status": .string(status)]
        if let initiatorUserId { row["initiatorUserId"] = .string(initiatorUserId) }
        return row
    }
}
