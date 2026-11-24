import Foundation

/// Where a change to a db3's view rows came from: this client's commit
/// (`local`), or what the room sent (`remote`).
enum RecordLogChangeOrigin: String, Sendable, Equatable {
    case local
    case remote
}

/// The permissions a store's `permission` mark holds besides the room's own
/// names: `read` (the room said this client may only read), `refused` (the
/// room refused the document for access; js-bao's `"refused"`).
enum RecordLogPermission {
    static let read = "read"
    static let refused = "refused"
}

/// One change to a db3's view rows, as a binding's change listeners hear it.
struct RecordLogChangeNotice: Sendable, Equatable {
    var origin: RecordLogChangeOrigin
    /// Every record whose view row changed.
    var records: [RecordLogRecordKey]
    /// Of `records`, those the command that changed them answered a row for
    /// (`row: nil` once the record shows none).
    var changes: [RecordLogRowChange] = []
    /// Models whose rows changed in bulk (a chunk): a listener re-reads them.
    var models: [String] = []
}

/// One open format-3 document: its store, this client's writer, the models
/// bound to it, and what the app is waiting on — the entries the
/// room has not acknowledged, the saves that wait for it, and the writes it
/// handed back. A port of the parts of js-bao's `facade.ts` and `binding.ts`
/// the Swift client needs.
///
/// **Locks.** Two, never nested the other way round:
///
/// - `operation` (recursive) serializes a save's view read, its uniqueness
///   check and its commit, and every command the session applies, so nothing
///   the room sends lands between a save's decision and its commit. It is held
///   across store calls, which hop onto the provider's queue.
/// - `state` guards the acknowledgement bookkeeping and the listener tables.
///   It is a leaf: held only around reads and writes of those fields, never
///   across a store call or a listener — because the group-commit listener
///   runs ON the provider's queue, and a thread holding `operation` may be
///   waiting for that queue.
///
/// `@unchecked Sendable`: every mutable property is read and written under
/// the `state` lock, and the store calls are serialized by the `operation`
/// lock and the provider's queue.
final class RecordLogDocumentBinding: @unchecked Sendable {

    let documentId: String
    let store: RecordLogStore
    private let logger: Logger?

    private let operation = NSRecursiveLock()
    private let state = NSLock()

    private var _writer: String
    private var _marks: RecordLogMarks
    private var schemas: [String: PrimitiveSchema] = [:]
    /// The vector fields whose stored value did not fit, warned about once.
    private var vectorMisfits: Set<String> = []
    /// This writer's entries the room has not acknowledged, with the records each touches.
    private var unacked: [Int: [RecordLogRecordKey]] = [:]
    /// This writer's entries handed back, by `seq`. A later save that takes
    /// the same number (a failed group's numbers are minted again) clears it.
    private var handedBack: [Int: JsBaoError] = [:]
    /// The save each of this writer's numbers belongs to now: a ticket per
    /// committed entry, so a handle keeps naming its own save after its number
    /// was minted again.
    private var ticketOfSeq: [Int: Int] = [:]
    private var lastTicket = 0
    /// The saves handed back, by ticket.
    private var refusedTickets: Set<Int> = []
    /// Bumped whenever a model is registered: the room's `record.declare` is
    /// stale until it hears this version.
    private var _declarationVersion = 0
    /// Saves waiting for the room's acknowledgement, by `seq`.
    private var ackWaiters: [Int: [CheckedContinuation<Void, Error>]] = [:]
    /// This writer's committed entries not yet settled.
    private var unsettled: Set<Int> = []
    /// The confirmed rows each recently settled entry left, by `seq`, the oldest first.
    private var settlements: [Int: RecordLogSettlement] = [:]
    private var settlementOrder: [Int] = []
    /// Writes waiting for their entry to settle, by `seq`.
    private var settleWaiters: [Int: [CheckedContinuation<RecordLogSettlement, Error>]] = [:]
    /// How many settled entries' rows are kept for a write that asks after its entry settled.
    private static let settlementsKept = 256
    /// Unique constraints the room keeps out of force: the local pre-check skips them.
    private var refusedConstraints: Set<String> = []
    private var closed = false
    private var modelListeners: [String: [UUID: @Sendable () -> Void]] = [:]
    private var commitListeners: [UUID: @Sendable ([RecordLogPendingEntry]) -> Void] = [:]
    private var changeListeners: [UUID: @Sendable (RecordLogChangeNotice) -> Void] = [:]
    private var pendingListeners: [UUID: @Sendable () -> Void] = [:]
    private var _createdLocally = true
    private var _attached = false
    private var errorListeners: [UUID: @Sendable (JsBaoError) -> Void] = [:]
    private var refusalReporter: (@Sendable (DocumentWriteRefusedEvent) -> Void)?
    /// Records this writer upserted under one id that the room applied to
    /// another (its alias), so a handle on the first id reads the second.
    private var aliases: [RecordLogRecordKey: String] = [:]

    // MARK: - Opening

    /// Open `documentId`'s store over `host`: create the tables, mint this
    /// client's writer (a ULID per document and client id), read the marks.
    init(
        host: any Format2SqlHost, documentId: String, clientId: String, logger: Logger? = nil, deviceIndexes: Db3DeviceIndexes = .all
    ) throws {
        self.documentId = documentId
        self.logger = logger
        let store = RecordLogStore(host: host, documentId: documentId, clientId: clientId, logger: logger, deviceIndexes: deviceIndexes)
        try store.initialize()
        let writer = try store.mintWriter()
        let marks = try store.marks()
        self.store = store
        self._writer = writer
        self._marks = marks
        for (seq, records) in marks.unacked { unacked[seq] = records }
        vectorJobs = RecordLogVectorJobs(store: store) { [weak self] notice in self?.vectorNoticed(notice) }
    }

    // MARK: - Vector indexes (#5230)

    /// The background work on the db3's device vector indexes: fills, and
    /// what their `ann` entries want, told to ``onVectorNotice(_:)``.
    private var vectorJobs: RecordLogVectorJobs!
    private var vectorListener: (@Sendable (RecordLogVectorJobs.Notice) -> Void)?

    /// Hear what the db3's vector indexes want and when their statuses change.
    func onVectorNotice(_ listener: @escaping @Sendable (RecordLogVectorJobs.Notice) -> Void) {
        state.withLock { vectorListener = listener }
    }

    private func vectorNoticed(_ notice: RecordLogVectorJobs.Notice) {
        let listener = state.withLock { closed ? nil : vectorListener }
        listener?(notice)
    }

    /// A store operation that may change the vector indexes' wants or start a fill ran.
    func vectorsChanged(_ change: RecordLogVectorJobs.Change) {
        guard !isClosed, let jobs = vectorJobs else { return }
        // Off the caller's stack: a change heard inside a store operation runs once it returns.
        Task.detached(priority: .utility) { jobs.after(change) }
    }

    /// This client's writer.
    var writer: String { state.withLock { _writer } }

    /// The marks as of the last command that read them.
    var marks: RecordLogMarks { state.withLock { _marks } }

    /// Whether the room said this client may only read.
    var isReadOnly: Bool { marks.permission == RecordLogPermission.read }

    /// Whether the room refused this document for access: its rows stay
    /// readable, and a write is refused `WRITE_ACCESS_DENIED`.
    var isAccessRefused: Bool { marks.permission == RecordLogPermission.refused }

    /// The db3 was created on this device and bound before its room's copy
    /// loaded (a pending create): it is readable at once. `true` for a binding
    /// no room serves (js-bao's `createdLocally` default); the client sets it
    /// at every bind.
    var createdLocally: Bool {
        get { state.withLock { _createdLocally } }
        set { state.withLock { _createdLocally = newValue } }
    }

    /// Whether the client's registered models read this binding: set once
    /// `connectToSharedModels` attached them (with no model registered too),
    /// cleared when they are disconnected. A binding published but not yet
    /// attached answers no model query, so the db3 is not resident.
    var attached: Bool {
        get { state.withLock { _attached } }
        set { state.withLock { _attached = newValue } }
    }

    /// Whether this document's store holds a readable copy (js-bao's
    /// `isRecordLogResident`): it lives only on this device, or it was
    /// created here, or a load completed and no unstaged replacement is in
    /// progress. Answered from the mirrored marks; they are read again only
    /// when they say no.
    var isResident: Bool {
        let createdLocally = self.createdLocally
        if RecordLogStore.isResident(marks, createdLocally: createdLocally) { return true }
        guard let fresh = try? refreshMarks() else { return false }
        return RecordLogStore.isResident(fresh, createdLocally: createdLocally)
    }

    // MARK: - Vector fields (#5225)

    /// Each vector field of `model` this device knows, with the encoding its
    /// numbers are written and read with: the one the db3's type declares,
    /// when the room sent it, else the registered model's own.
    func vectorEncodings(model: String) -> [String: VectorEncoding] {
        var out: [String: VectorEncoding] = [:]
        for (field, descriptor) in state.withLock({ schemas[model] })?.fields ?? [:] {
            if let encoding = descriptor.vectorEncoding { out[field] = encoding }
        }
        for (field, encoding) in declaredType?.vectors[model] ?? [:] { out[field] = encoding }
        return out
    }

    /// `row` with each of `encodings`' fields read as its numbers: the
    /// encoding's canonical base64 as an array of numbers, `null` as `null`,
    /// and anything else (a writer that disagreed with the schema) as it is
    /// stored, warned about once per model and field.
    func decodedVectors(_ row: RecordLogRow, model: String, encodings: [String: VectorEncoding]) -> RecordLogRow {
        // A field the db3's held revision clears leaves the row first (#6021).
        let row = hidingCleared(row, model: model)
        guard !encodings.isEmpty else { return row }
        var out = row
        for (field, encoding) in encodings {
            guard let value = row[field], value != .null else { continue }
            if case .string(let text) = value, let numbers = try? VectorCodec.decode(text, encoding: encoding) {
                out[field] = .array(numbers.map { .number(Double($0)) })
                continue
            }
            let first = state.withLock { vectorMisfits.insert("\(model)\u{0}\(field)").inserted }
            if first {
                logger?.warn(
                    "[record-log] \(model).\(field): a stored value does not fit the field's encoding (\(VectorCodec.describeField(encoding))); it reads as it is stored"
                )
            }
        }
        return out
    }

    // MARK: - Cleared fields (#6021)

    /// The db3's held cleared and tombstoned fields, per model the names; `nil`
    /// when the db3 is not typed or its held revision hides none. Read from the
    /// in-memory marks: no statement.
    var heldCleared: RecordLogClearedDeclarations? {
        let marks = self.marks
        guard marks.typed == .yes, let cleared = marks.cleared, !cleared.isEmpty else { return nil }
        return cleared
    }

    /// `row` of `model` without the fields the db3's held revision clears:
    /// the same row when it holds none of them.
    func hidingCleared(_ row: RecordLogRow, model: String) -> RecordLogRow {
        guard let names = heldCleared?[model], names.contains(where: { row[$0] != nil }) else { return row }
        var out = row
        for name in names { out.removeValue(forKey: name) }
        return out
    }

    /// `values`' vector numbers as the stored base64 of each field's encoding.
    /// A value that does not fit is refused `.db3VectorInvalid`, and numbers
    /// for a field this device does not know to be a vector
    /// `.documentEntryInvalid`, before anything commits, each reported once as
    /// a `DocumentWriteRefusedEvent`.
    func encodedVectors(
        _ values: [String: JSONValue], numbers: [String: [Float]], model: String, id: String, kind: RecordLogWriteKind
    ) throws -> [String: JSONValue] {
        guard !numbers.isEmpty else { return values }
        let encodings = vectorEncodings(model: model)
        var out = values
        for (field, vector) in numbers.sorted(by: { $0.key < $1.key }) {
            guard let encoding = encodings[field] else {
                throw refusedVector(
                    "Cannot save \(model) \(id): field `\(field)` holds numbers, and this device knows no vector field of that name: "
                        + "declare it type \"vector\" with dims and element, or write its stored base64",
                    code: .documentEntryInvalid, model: model, id: id, kind: kind
                )
            }
            do {
                out[field] = .string(try VectorCodec.encode(vector, encoding: encoding))
            } catch let cause as JsBaoError {
                throw refusedVector(
                    "\(model) id=\(id): field \"\(field)\" is declared \(VectorCodec.describeField(encoding)); \(cause.message)",
                    model: model, id: id, kind: kind
                )
            }
        }
        return out
    }

    private func refusedVector(
        _ message: String, code: JsBaoErrorCode = .db3VectorInvalid, model: String, id: String, kind: RecordLogWriteKind
    ) -> JsBaoError {
        let error = JsBaoError(code: code, message: message, details: ["documentId": .string(documentId), "scope": "local"])
        reportRefused(recordLogLocalRefusal(error, documentId: documentId, mutations: [RecordLogMutation(model: model, id: id, kind: kind)]))
        return error
    }

    /// Every registered model's schema, by name.
    var registeredSchemas: [PrimitiveSchema] {
        state.withLock { schemas.keys.sorted().compactMap { schemas[$0] } }
    }

    /// Moves whenever a model is registered on this document.
    var declarationVersion: Int { state.withLock { _declarationVersion } }

    // MARK: - Models

    /// Bind a model to this document. Its reads answer from the document's
    /// view; no index is built here (the store builds its indexes from the
    /// room's list, which a declaration reaches through the room). A db3 that
    /// lives only on this device takes the model's constraints and indexes
    /// now (``applyLocalDeclarations()``).
    func registerModel(_ schema: PrimitiveSchema) throws {
        let changed = state.withLock { () -> Bool in
            guard schemas[schema.name] != schema else { return false }
            _declarationVersion += 1
            schemas[schema.name] = schema
            return true
        }
        if changed && isLocalOnly { try applyLocalDeclarations() }
    }

    // MARK: - A db3 that lives only on this device (#5155)

    /// Whether the db3 lives only on this device: its store judges and
    /// confirms its own writes, and its session sends nothing.
    var isLocalOnly: Bool { marks.localOnly }

    /// Mark the db3 as living only on this device. The mark is the store's,
    /// so every later bind finds it; its constraints and indexes follow from
    /// its models at once. `type`, for a typed local-only db3 whose store
    /// holds no type yet (its create), is recorded with the mark in one
    /// transaction (#6025).
    func markLocalOnly(type: RecordLogLocalType? = nil) throws {
        let marks = self.marks
        // A store already marked, and typed (or holding an unreadable type), is written nothing more.
        if !marks.localOnly || (type != nil && marks.typed != .yes && !marks.localTypeUnreadable) {
            let marks = try withOperation { try store.markLocalOnly(type: type) }
            state.withLock { _marks = marks }
        }
        try applyLocalDeclarations()
    }

    // MARK: - A typed db3 that lives only on this device (#6025)

    private var _localBuild: RecordLogLocalType?
    private var _localStanding: Db3StateError?
    /// The type entry a typed local-only copy's marks were last checked
    /// against; `nil` until the first read checks it.
    private var _checkedTypeEntry: String??

    /// For a typed local-only copy (#6025), read its marks again when the
    /// type entry its store holds is no longer the one they were checked
    /// against: another client of the store installed declarations, so the
    /// cleared names, declarations and index list a read uses here are
    /// theirs from this read on. One read of the type entry per read
    /// operation; nothing for any other db3.
    func revalidateLocalType() {
        let marks = self.marks
        guard marks.localOnly, marks.typed == .yes || marks.localTypeUnreadable else { return }
        guard let entry = try? store.typeEntry() else { return }
        if state.withLock({ _checkedTypeEntry }) == .some(entry) { return }
        guard (try? refreshMarks()) != nil else { return }
        state.withLock { _checkedTypeEntry = .some(entry) }
    }

    /// This client's build's declarations of the copy's type, which its
    /// writes carry to the store: a build diverged from the installed ones
    /// has its writes refused. `nil` when the build carries none.
    var localBuild: RecordLogLocalType? {
        get { state.withLock { _localBuild } }
        set { state.withLock { _localBuild = newValue } }
    }

    /// How a typed local-only copy stands with this build when it cannot
    /// simply be written (`DB3_TYPE_REFUSED`), as the db3's state reports it;
    /// `nil` when its writes are judged as usual.
    var localTypeStanding: Db3StateError? { state.withLock { _localStanding } }

    /// The models a local-only db3's constraints and indexes are derived
    /// from: a typed one's installed declarations, else the registered models.
    var localSchemas: [PrimitiveSchema] {
        if let local = marks.localDeclarations { return recordLogLocalSchemas(local) }
        return registeredSchemas
    }

    /// Reconcile a typed local-only copy with this build's declarations
    /// for its type at bind (#6025): nothing for a copy that is not one, for
    /// the same hash, and for a build that carries none while the installed
    /// ones can be read. Otherwise the store installs a superset (or
    /// recovers unreadable declarations, the type named by `knownType` when
    /// the store lost it) after checking the records, in one transaction,
    /// and the standing says how the copy then stands with this build. One
    /// line is logged per install, refused install, diverged open and
    /// unreadable open.
    ///
    /// Gated on the marks this binding already holds (the bind read them):
    /// a copy that syncs, an untyped local-only one, and a typed one whose
    /// build carries the installed hash read and write nothing here. The
    /// store's install judges against what it holds in its own transaction.
    func reconcileLocalType(_ buildOf: (String) -> RecordLogLocalType?, knownType: String?) throws {
        let marks = self.marks
        guard marks.localOnly, marks.typed == .yes || marks.localTypeUnreadable else { return }
        let unreadable = marks.localTypeUnreadable
        let name = marks.db3Type?.name ?? knownType
        let build = name.flatMap(buildOf)
        localBuild = build
        if !unreadable && (build == nil || build?.hash == marks.db3Type?.hash) {
            state.withLock { _localStanding = nil }
            return
        }
        guard let build else {
            logger?.warn("[db3] \(documentId): local type \(name ?? "(unknown)"): declarations unreadable; writes are refused (DB3_TYPE_REFUSED)")
            state.withLock { _localStanding = RecordLogLocalTypeStanding.unreadable(documentId) }
            return
        }
        let answer = try withOperation { try store.installLocalType(build) }
        var standing: Db3StateError?
        switch answer {
        case .installed(let from):
            logger?.log("[db3] \(documentId): local type \(build.name) installed (\(from ?? "unreadable") → \(build.hash))")
            try refreshMarks()
            try applyLocalDeclarations()
        case .refused(let reasons, let unreadable):
            logger?.warn(
                "[db3] \(documentId): local type \(build.name) not installed (DB3_TYPE_REFUSED): "
                    + reasons.map { "\($0.path) \($0.reason)" }.joined(separator: "; ")
            )
            standing = RecordLogLocalTypeStanding.refused(documentId, type: build.name, reasons: reasons, unreadable: unreadable)
        case .diverged:
            logger?.warn(
                "[db3] \(documentId): local type \(build.name): this build's declarations diverged from the installed ones; "
                    + "its writes are refused (DB3_TYPE_REFUSED)"
            )
            standing = RecordLogLocalTypeStanding.diverged(documentId, type: build.name)
        case .same, .subset, .untyped:
            break
        }
        state.withLock { _localStanding = standing }
    }

    /// Make a local-only db3's constraints and view indexes what its models
    /// declare and what was registered on it here
    /// (``RecordLogLocalOnly/constraints(_:_:)``,
    /// ``RecordLogLocalOnly/indexList(_:_:)``): at every bind, when a model
    /// registers later, and after a registration or a drop. Nothing happens
    /// for a db3 that syncs.
    func applyLocalDeclarations() throws {
        guard isLocalOnly else { return }
        _ = try changeLocalIndexes { current in (current, nil) }
    }

    /// Change a local-only db3's registrations to what `plan` makes of the
    /// ones its store holds, with the constraints and view indexes that
    /// follow, in one store transaction: written only while the store still
    /// holds the registrations it was planned from and, for a unique key, no
    /// two records share it; planned again when another change came first.
    /// Answers the registrations written.
    ///
    /// - Throws: what `plan` throws, or `DB3_INDEX_NOT_UNIQUE` when records share the key.
    private func changeLocalIndexes(
        _ plan: ([RecordLogLocalIndex]) throws -> (registrations: [RecordLogLocalIndex], unique: (model: String, fields: [String])?)
    ) throws -> [RecordLogLocalIndex] {
        try withOperation {
            var current = try refreshMarks().localIndexes
            while true {
                let marks = self.marks
                let schemas = marks.localDeclarations.map(recordLogLocalSchemas) ?? registeredSchemas
                let (registrations, unique) = try plan(current)
                let change = try store.changeLocalIndexes(
                    from: current, to: registrations, constraints: RecordLogLocalOnly.constraints(schemas, registrations),
                    unique: unique.map { ($0.model, $0.fields, RecordLogLocalOnly.maxDuplicates) },
                    // A typed copy's change is written only under the declarations it was
                    // derived from: another client's install meanwhile plans it again (#6025).
                    typeHash: marks.typed == .yes ? .some(marks.db3Type?.hash) : nil,
                    // The list is cached in the change's own transaction, under its checks (#6025)…
                    indexes: RecordLogLocalOnly.entries(RecordLogLocalOnly.indexList(schemas, registrations))
                )
                switch change {
                case .changed(let marks):
                    state.withLock { _marks = marks }
                    // …and the indexes then follow the list the store holds, which a later change (another
                    // handle's, under newer declarations) may have replaced meanwhile: never this change's own.
                    try store.syncIndexes(nil)
                    vectorsChanged(.list)
                    return registrations
                case .duplicates(let duplicates, let marks):
                    state.withLock { _marks = marks }
                    throw RecordLogLocalOnly.notUnique(model: unique?.model ?? "", fields: unique?.fields ?? [], duplicates: duplicates)
                case .moved(let marks):
                    // Planned again from the store's registrations and declarations.
                    state.withLock { _marks = marks }
                    current = marks.localIndexes
                }
            }
        }
    }

    /// A local-only db3's index list, as the room lists its registry.
    var localIndexes: [Db3Index] {
        RecordLogLocalOnly.indexList(localSchemas, marks.localIndexes)
    }

    /// Register an index on a local-only db3 by the room's rules
    /// (``RecordLogLocalOnly/register(_:_:_:)``): kept in its store, and its
    /// constraints and view indexes made to match before this returns.
    /// Answers the index as the list now shows it.
    ///
    /// - Throws: the room's refusal, as a `JsBaoError` with its code.
    func registerLocalIndex(_ registration: Db3IndexRegistration) throws -> Db3Index {
        // Checked before anything reads the store: a malformed body is the room's `DB3_INDEX_INVALID`.
        let parsed = try RecordLogLocalOnly.parse(registration)
        var index: Db3Index?
        let written = try changeLocalIndexes { current in
            // No index of any kind over a field the installed declarations clear or
            // tombstone, as the room refuses it (#6025): judged on each plan, so
            // against what another client installed meanwhile.
            let hidden = Set(recordLogLocalHidden(self.marks.localDeclarations?[parsed.model]))
            if let over = parsed.fields.first(where: hidden.contains) {
                throw JsBaoError(
                    code: .db3IndexInvalid,
                    message: "\(parsed.model).\(over) is cleared by the db3's type: no write stores it and no read answers it, so it takes no index",
                    details: ["field": .string(over)]
                )
            }
            let planned = try RecordLogLocalOnly.register(localSchemas, current, registration)
            index = planned.index
            return (planned.registrations, parsed.unique ? (parsed.model, parsed.fields) : nil)
        }
        return RecordLogLocalOnly.indexList(localSchemas, written).first { $0.name == index?.name } ?? index!
    }

    /// Drop an index of a local-only db3 by the room's rules
    /// (``RecordLogLocalOnly/drop(_:_:name:)``); its constraints and view
    /// indexes follow before this returns.
    func dropLocalIndex(_ name: String) throws {
        _ = try changeLocalIndexes { current in (try RecordLogLocalOnly.drop(localSchemas, current, name: name), nil) }
    }

    /// This writer's entries not yet acknowledged, in order: none on a db3
    /// that lives only on this device once its save returned.
    var unacknowledgedSeqs: [Int] { state.withLock { unacked.keys.sorted() } }

    /// This writer's committed entries not yet settled, in order.
    var unsettledSeqs: [Int] { state.withLock { unsettled.sorted() } }

    /// Hear that `model`'s rows changed through the room. Returns a token for ``removeModelListener(_:_:)``.
    @discardableResult
    func onModelChanged(_ model: String, _ listener: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        state.withLock { modelListeners[model, default: [:]][token] = listener }
        return token
    }

    func removeModelListener(_ model: String, _ token: UUID) {
        state.withLock { _ = modelListeners[model]?.removeValue(forKey: token) }
    }

    /// Tell each changed model's listeners, once per model: the models of
    /// `records`, and `models` (those a chunk changed in bulk); and the change
    /// listeners, with `origin` and the rows `changes` answered, unless
    /// `origin` is `nil` (a commit, which told them already).
    func notify(
        _ records: [RecordLogRecordKey], models bulk: [String] = [], origin: RecordLogChangeOrigin? = .remote,
        changes: [RecordLogRowChange] = []
    ) {
        let models = Set(records.map(\.model)).union(bulk)
        // A row count is what a `train` want weighs (#5230).
        if !records.isEmpty || !bulk.isEmpty { vectorsChanged(.rows) }
        let listeners = state.withLock { models.flatMap { modelListeners[$0]?.values.map { $0 } ?? [] } }
        for listener in listeners { listener() }
        guard let origin, !records.isEmpty || !bulk.isEmpty else { return }
        noticeChange(RecordLogChangeNotice(origin: origin, records: records, changes: changes, models: bulk))
    }

    /// Tell the listeners of what a chunk of a load or a segment changed, once
    /// per model: reads go to the store, so a listener re-reads the rows.
    func notify(_ reply: RecordLogChunkReply) {
        notify(
            reply.changed.map { RecordLogRecordKey(model: $0.model, id: $0.id) }, models: reply.models,
            changes: reply.changed
        )
    }

    private func noticeChange(_ notice: RecordLogChangeNotice) {
        // A change carries no field the db3's held revision clears (#6021).
        var notice = notice
        if heldCleared != nil {
            notice.changes = notice.changes.map { change in
                var change = change
                change.row = change.row.map { hidingCleared($0, model: change.model) }
                return change
            }
        }
        if notice.origin == .local { vectorsChanged(.rows) }
        let listeners = state.withLock { Array(changeListeners.values) }
        for listener in listeners { listener(notice) }
    }

    /// Hear every change to the document's view rows, with where it came from.
    /// Returns a token for ``removeChangeListener(_:)``.
    @discardableResult
    func onChange(_ listener: @escaping @Sendable (RecordLogChangeNotice) -> Void) -> UUID {
        let token = UUID()
        state.withLock { changeListeners[token] = listener }
        return token
    }

    /// Hear every change to this writer's unjudged entries: an acknowledgement
    /// or a hand-back, whether or not a row changed; and every results frame
    /// that changed no row but may have moved the cursor or the head heard.
    @discardableResult
    func onPendingChanged(_ listener: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        state.withLock { pendingListeners[token] = listener }
        return token
    }

    /// A results frame changed no row but may have moved the cursor or the
    /// head heard: the pending listeners read the db3's state again.
    func noticeHeard() { noticePending() }

    private func noticePending() {
        let listeners = state.withLock { Array(pendingListeners.values) }
        for listener in listeners { listener() }
    }

    func removeChangeListener(_ token: UUID) {
        state.withLock { _ = changeListeners.removeValue(forKey: token) }
    }

    /// Hear this writer's entries once their group has committed: what the session sends.
    @discardableResult
    func onCommitted(_ listener: @escaping @Sendable ([RecordLogPendingEntry]) -> Void) -> UUID {
        let token = UUID()
        state.withLock { commitListeners[token] = listener }
        return token
    }

    func removeCommitListener(_ token: UUID) {
        state.withLock { _ = commitListeners.removeValue(forKey: token) }
    }

    /// Hear a failure the document cannot hand to a caller: a group of saves
    /// whose `COMMIT` failed after the saves returned.
    @discardableResult
    func onError(_ listener: @escaping @Sendable (JsBaoError) -> Void) -> UUID {
        let token = UUID()
        state.withLock { errorListeners[token] = listener }
        return token
    }

    /// Where refused writes are reported (the client's `DocumentWriteRefusedEvent`).
    func setRefusalReporter(_ reporter: (@Sendable (DocumentWriteRefusedEvent) -> Void)?) {
        state.withLock { refusalReporter = reporter }
    }

    /// Report a refusal to the app.
    func reportRefused(_ event: DocumentWriteRefusedEvent) {
        let reporter = state.withLock { refusalReporter }
        reporter?(event)
    }

    // MARK: - The operation

    /// Run `body` with this document's saves and session commands serialized.
    func withOperation<T>(_ body: () throws -> T) throws -> T {
        operation.lock()
        defer { operation.unlock() }
        return try body()
    }

    private func assertOpen() throws {
        if state.withLock({ closed }) { throw Self.closedError(documentId) }
    }

    static func closedError(_ documentId: String) -> JsBaoError {
        JsBaoError(
            code: .notFound,
            message: "Document `\(documentId)` is closed.",
            details: ["documentId": .string(documentId)]
        )
    }

    // MARK: - Saves

    /// Commit local writes as one save each, inside the connection's group of
    /// saves. The entries count as unacknowledged at once; the session hears
    /// them once their group commits, and the change listeners hear the view
    /// rows they changed as `local`. A save refused before it commits (the
    /// epoch budget, or the room's access refusal: `WRITE_ACCESS_DENIED`) is
    /// reported with its writes and thrown.
    ///
    /// On a db3 that lives only on this device the store judges the writes
    /// and confirms them in the commit: its group commits before this
    /// returns, and only then are the entries acknowledged and settled here
    /// (no sender is handed one); a refusal is reported and thrown as the
    /// room's would be, and a group whose `COMMIT` fails throws its
    /// `.unavailable` (`commit-failed`), its writes handed back.
    @discardableResult
    func commit(_ writes: [RecordLogWrite]) throws -> [RecordLogPendingEntry] {
        try assertOpen()
        if isAccessRefused {
            let error = JsBaoError(
                code: .writeAccessDenied,
                message: "Cannot save to document `\(documentId)`: the room refused this client access to it; "
                    + "the write was not applied.",
                details: ["documentId": .string(documentId)]
            )
            logger?.warn("[record-log] write-refused", documentId, "— WRITE_ACCESS_DENIED: access to the document was refused")
            let mutations = writes.flatMap(\.mutations)
            if !mutations.isEmpty {
                reportRefused(recordLogLocalRefusal(error, documentId: documentId, mutations: mutations))
            }
            throw error
        }
        if isReadOnly {
            // #5888 — the code the room's refusal of the same write carries.
            throw JsBaoError(
                code: .writeAccessDenied,
                message: "Cannot save to document `\(documentId)`: the room allows this client to read it only.",
                details: ["documentId": .string(documentId)]
            )
        }
        let writer = self.writer
        let documentId = self.documentId
        let delivery = Delivery()
        let reply: RecordLogCommitReply
        do {
            reply = try withOperation {
                try store.commitEntries(writer: writer, writes: writes, listener: { [weak self] error in
                    if let saved = delivery.outcome(error) { self?.groupCommitted(saved, writer: writer, error: error) }
                }, localBuild: localBuild)
            }
        } catch let error as JsBaoError
            where RecordLogHandBackCode.all.contains(error.code.rawValue) || error.code == .db3TypeRefused {
            if let first = writes.first?.mutations, !first.isEmpty {
                reportRefused(recordLogLocalRefusal(
                    error, documentId: documentId, mutations: writes.flatMap(\.mutations)
                ))
            }
            throw error
        }
        state.withLock {
            for entry in reply.entries {
                unacked[entry.seq] = entry.keys
                unsettled.insert(entry.seq)
                // The number may have been an earlier save's whose group failed
                // to commit: this save starts with none of that one's history.
                handedBack[entry.seq] = nil
                lastTicket += 1
                ticketOfSeq[entry.seq] = lastTicket
            }
            _marks.nextSeq = max(_marks.nextSeq, (reply.entries.map(\.seq).max() ?? 0) + 1)
            _marks.cursor = reply.cursor
        }
        if let (saved, error) = delivery.entries(reply) { groupCommitted(saved, writer: writer, error: error) }
        // Confirmed by the store itself: its group commits now, so the
        // confirmation it carries is released before this returns.
        if reply.acknowledged != nil {
            try? store.flush()
            if let failure = delivery.failure { throw failure }
        }
        if !reply.changed.isEmpty {
            noticeChange(RecordLogChangeNotice(
                origin: .local, records: reply.changed.map { RecordLogRecordKey(model: $0.model, id: $0.id) },
                changes: reply.changed
            ))
        }
        return reply.entries
    }

    /// The save this writer's number `seq` belongs to now, for a handle to
    /// keep: `nil` for a number no save of this binding committed.
    func ticket(of seq: Int) -> Int? {
        state.withLock { ticketOfSeq[seq] }
    }

    /// The highest number a save of this writer took, and the newest save's
    /// ticket, read together: every save numbered at or below `minted` holds
    /// a ticket at or below `ticket`. A number a failed group gave back and a
    /// later save took again carries a newer ticket than the save before it.
    func savesThrough() -> (minted: Int, ticket: Int) {
        state.withLock { (_marks.nextSeq - 1, lastTicket) }
    }

    /// The newest save's ticket.
    func lastSaveTicket() -> Int {
        state.withLock { lastTicket }
    }

    /// A save's entries and its group's outcome, which arrive in either order:
    /// a group commits on the provider's queue after the save returned, and a
    /// host that cannot defer commits it before. Whichever comes second delivers.
    ///
    /// `@unchecked Sendable`: both fields are read and written only under
    /// `lock`, a leaf lock held for the assignment alone.
    private final class Delivery: @unchecked Sendable {
        private let lock = NSLock()
        private var saved: RecordLogCommitReply?
        private var heard: (error: Error?, at: Bool) = (nil, false)

        /// The save returned; answers what to deliver when the group already committed.
        func entries(_ reply: RecordLogCommitReply) -> (RecordLogCommitReply, Error?)? {
            lock.withLock {
                saved = reply
                return heard.at ? (reply, heard.error) : nil
            }
        }

        /// The group committed or failed; answers the save's reply when the save already returned.
        func outcome(_ error: Error?) -> RecordLogCommitReply? {
            lock.withLock {
                heard = (error, true)
                return saved
            }
        }

        /// The group's failure, once it was heard.
        var failure: Error? { lock.withLock { heard.at ? heard.error : nil } }
    }

    /// A group of saves committed (or failed): runs on the provider's queue,
    /// so it takes only the leaf lock. A local-only store's entries were
    /// confirmed in the commit: they are acknowledged and settled here, and
    /// no sender hears them.
    private func groupCommitted(_ reply: RecordLogCommitReply, writer: String, error: Error?) {
        let entries = reply.entries
        guard !entries.isEmpty else { return }
        if let error {
            let failure = (error as? JsBaoError) ?? JsBaoError(
                code: .unavailable, message: error.localizedDescription,
                details: ["documentId": .string(documentId), "reason": "commit-failed"]
            )
            logger?.warn("[record-log]", documentId, "— a group of saves did not commit:", failure.message)
            let touched = handBack(entries.map(\.seq), error: failure)
            let listeners = state.withLock { Array(errorListeners.values) }
            for listener in listeners { listener(failure) }
            notify(touched, origin: .local)
            return
        }
        if let confirmed = reply.acknowledged {
            for alias in reply.aliases { noteAlias(alias) }
            acknowledged(confirmed.filter { $0.writer == writer }.map(\.seq))
            var settled = RecordLogChangeReply()
            settled.settled = reply.settled ?? []
            settled.settlements = reply.settlements ?? [:]
            noteSettled(settled)
            return
        }
        // Committed under a writer that has been re-minted since: the store
        // renumbered these entries, and the open that follows the re-mint
        // sends them under their new numbers.
        let listeners = state.withLock { _writer == writer ? Array(commitListeners.values) : [] }
        for listener in listeners { listener(entries) }
    }

    // MARK: - Acknowledgements

    /// Whether a record's writes have reached the room: `pending` while an entry
    /// of this writer touching it is unacknowledged, `refused` when the entry
    /// `lastSeq` names was handed back, `confirmed` otherwise. `ticket` names
    /// the save itself, which `lastSeq` alone does not once its number was
    /// minted again.
    func syncState(model: String, id: String, lastSeq: Int?, ticket: Int? = nil) -> RecordSyncState {
        state.withLock {
            if let ticket {
                if refusedTickets.contains(ticket) { return .refused }
            } else if let lastSeq, handedBack[lastSeq] != nil {
                return .refused
            }
            let key = RecordLogRecordKey(model: model, id: id)
            return unacked.values.contains { $0.contains(key) } ? .pending : .confirmed
        }
    }

    /// Returns when the room has acknowledged this writer's entry `seq`; throws
    /// the hand-back's error when it is refused, or when the document closes first.
    func whenAcknowledged(_ seq: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let outcome: Result<Void, Error>? = state.withLock {
                if let refused = handedBack[seq] { return .failure(refused) }
                if unacked[seq] == nil { return .success(()) }
                if closed { return .failure(Self.closedError(documentId)) }
                ackWaiters[seq, default: []].append(continuation)
                return nil
            }
            if let outcome { continuation.resume(with: outcome) }
        }
    }

    /// Returns once this writer's entry `seq` has left the pending log (its
    /// result applied, or the room moved past it), with the confirmed rows of
    /// the records it touched as they stood right after its result applied:
    /// the room's values, before any later result and without the guesses of
    /// other pending entries. Throws the hand-back's error when the entry was
    /// refused, or when the document closes first. An entry this binding did
    /// not commit, or one settled long before, answers at once with no rows.
    func whenSettled(_ seq: Int) async throws -> RecordLogSettlement {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RecordLogSettlement, Error>) in
            let outcome: Result<RecordLogSettlement, Error>? = state.withLock {
                if let refused = handedBack[seq] { return .failure(refused) }
                if let settled = settlements[seq] { return .success(settled) }
                if !unsettled.contains(seq) { return .success(RecordLogSettlement(rows: [])) }
                if closed { return .failure(Self.closedError(documentId)) }
                settleWaiters[seq, default: []].append(continuation)
                return nil
            }
            if let outcome { continuation.resume(with: outcome) }
        }
    }

    /// This writer's entries a reply settled: what waits on them returns with their rows.
    func noteSettled(_ reply: RecordLogChangeReply) {
        let own = writer
        let waiters = state.withLock { () -> [(CheckedContinuation<RecordLogSettlement, Error>, RecordLogSettlement)] in
            var out: [(CheckedContinuation<RecordLogSettlement, Error>, RecordLogSettlement)] = []
            for ref in reply.settled where ref.writer == own {
                unsettled.remove(ref.seq)
                let settlement = reply.settlements[ref] ?? RecordLogSettlement(rows: [])
                if settlements.updateValue(settlement, forKey: ref.seq) == nil { settlementOrder.append(ref.seq) }
                // Kept for a write that asks after its entry settled; the oldest go first.
                while settlementOrder.count > Self.settlementsKept {
                    settlements[settlementOrder.removeFirst()] = nil
                }
                for waiter in settleWaiters.removeValue(forKey: ref.seq) ?? [] { out.append((waiter, settlement)) }
            }
            return out
        }
        for (waiter, settlement) in waiters { waiter.resume(returning: settlement) }
    }

    /// The room acknowledged these entries of this writer: they stop being
    /// pending and what waits on them resolves. Answers the records they touched.
    @discardableResult
    func acknowledged(_ seqs: [Int]) -> [RecordLogRecordKey] {
        let (touched, waiters) = state.withLock { () -> ([RecordLogRecordKey], [CheckedContinuation<Void, Error>]) in
            var touched: [RecordLogRecordKey] = []
            var waiters: [CheckedContinuation<Void, Error>] = []
            for seq in seqs {
                if let keys = unacked.removeValue(forKey: seq) { touched.append(contentsOf: keys) }
                waiters.append(contentsOf: ackWaiters.removeValue(forKey: seq) ?? [])
            }
            return (touched, waiters)
        }
        for waiter in waiters { waiter.resume() }
        if !seqs.isEmpty { noticePending() }
        return touched
    }

    /// These entries of this writer were handed back with `error`: what waits on them throws it.
    @discardableResult
    func handBack(_ seqs: [Int], error: JsBaoError) -> [RecordLogRecordKey] {
        let (touched, waiters, settling) = state.withLock {
            () -> ([RecordLogRecordKey], [CheckedContinuation<Void, Error>], [CheckedContinuation<RecordLogSettlement, Error>]) in
            var touched: [RecordLogRecordKey] = []
            var waiters: [CheckedContinuation<Void, Error>] = []
            var settling: [CheckedContinuation<RecordLogSettlement, Error>] = []
            for seq in seqs {
                if let keys = unacked.removeValue(forKey: seq) { touched.append(contentsOf: keys) }
                unsettled.remove(seq)
                handedBack[seq] = error
                if let ticket = ticketOfSeq[seq] { refusedTickets.insert(ticket) }
                waiters.append(contentsOf: ackWaiters.removeValue(forKey: seq) ?? [])
                settling.append(contentsOf: settleWaiters.removeValue(forKey: seq) ?? [])
            }
            return (touched, waiters, settling)
        }
        for waiter in waiters { waiter.resume(throwing: error) }
        for waiter in settling { waiter.resume(throwing: error) }
        if !seqs.isEmpty { noticePending() }
        return touched
    }

    /// This writer was re-minted: its entries were renumbered, and what waits
    /// on them follows them.
    func reminted(writer: String, renumbered: [(from: Int, to: Int)]) {
        let (orphaned, orphanedSettling) = state.withLock {
            () -> ([CheckedContinuation<Void, Error>], [CheckedContinuation<RecordLogSettlement, Error>]) in
            _writer = writer
            let oldUnacked = unacked
            var oldWaiters = ackWaiters
            let oldTickets = ticketOfSeq
            let oldUnsettled = unsettled
            var oldSettleWaiters = settleWaiters
            unacked = [:]
            ackWaiters = [:]
            handedBack = [:]
            ticketOfSeq = [:]
            unsettled = []
            settleWaiters = [:]
            settlements = [:]
            settlementOrder = []
            for (from, to) in renumbered {
                if let keys = oldUnacked[from] { unacked[to] = keys }
                if oldUnsettled.contains(from) { unsettled.insert(to) }
                if let waiting = oldWaiters.removeValue(forKey: from) { ackWaiters[to] = waiting }
                if let waiting = oldSettleWaiters.removeValue(forKey: from) { settleWaiters[to] = waiting }
                if let ticket = oldTickets[from] { ticketOfSeq[to] = ticket }
            }
            return (oldWaiters.values.flatMap { $0 }, oldSettleWaiters.values.flatMap { $0 })
        }
        // A waiter on a void marker has nothing left to wait for.
        for waiter in orphaned { waiter.resume() }
        for waiter in orphanedSettling { waiter.resume(returning: RecordLogSettlement(rows: [])) }
    }

    /// The room applied an upsert of this writer's to an existing record.
    func noteAlias(_ alias: RecordLogAlias) {
        state.withLock { aliases[RecordLogRecordKey(model: alias.model, id: alias.from)] = alias.to }
    }

    /// The record an upsert's id was applied to, or `nil`.
    func aliasTarget(model: String, id: String) -> String? {
        state.withLock { aliases[RecordLogRecordKey(model: model, id: id)] }
    }

    // MARK: - Constraints and permission

    /// Whether the local pre-check holds a save to this constraint.
    func constraintInForce(_ name: String) -> Bool {
        state.withLock { !refusedConstraints.contains(name) }
    }

    /// The room keeps these declared constraints out of force: the local
    /// pre-check stops holding saves to them, and the store forgets them.
    func excludeConstraints(_ names: [String]) throws {
        let kept = state.withLock { () -> [RecordLogConstraint] in
            refusedConstraints.formUnion(names)
            return _marks.constraints.filter { !refusedConstraints.contains($0.name) }
        }
        try setState(constraints: kept)
    }

    /// Record what the room said about epochs, constraints, the db3's type,
    /// its head (`heard`, a `record.opened`'s) and this client's permission.
    @discardableResult
    func setState(
        notice: (current: Int, next: Int?, entries: Int?)? = nil,
        constraints: [RecordLogConstraint]? = nil, permission: String?? = nil, type: RecordLogTypeUpdate? = nil,
        localOnly: Bool? = nil, heard: RecordLogHeard? = nil
    ) throws -> RecordLogMarks {
        let writer = self.writer
        let marks = try withOperation {
            try store.setState(
                writer: writer, notice: notice, constraints: constraints, permission: permission, type: type, localOnly: localOnly,
                heard: heard
            )
        }
        state.withLock { _marks = marks }
        return marks
    }

    /// Whether this document's session is open now: a device read's
    /// drift is `live` only then. The session marks it as its phase changes.
    var isLive: Bool { store.isLive }

    /// Mark the document's session open (`true`) or not.
    func setLive(_ live: Bool) { store.setLive(live) }

    /// Take a permission the client heard for this db3 while it is bound:
    /// the store's mark follows it, `read` on `.reader` (saves are
    /// refused here from now) and lifted on a write-capable one, as the
    /// room's `WRITE_ACCESS_DENIED` and a connect with write access set and
    /// lift it. A `refused` mark is the room's to lift.
    func applyPermissionChange(_ permission: DocumentPermission) throws {
        // The mark is read and written under one hold of the operation lock,
        // which every other write of the mark takes too: a `refused` the
        // session records meanwhile is never overwritten.
        try withOperation {
            let mark = try refreshMarks().permission
            if permission == .reader {
                guard mark == nil else { return }
                logger?.log("[record-log]", documentId, "— the client may only read now; saves are refused here")
                _ = try setState(permission: .some(RecordLogPermission.read))
            } else if mark == RecordLogPermission.read {
                logger?.log("[record-log]", documentId, "— the client may write again; saves are allowed")
                _ = try setState(permission: .some(nil))
            }
        }
    }

    /// Take the type this db3 was created with here: a store the room
    /// has not yet told whether the db3 is typed is marked typed by `type`,
    /// so its first open declares nothing. A mark the room set is kept.
    func seedType(_ type: String) throws {
        guard try refreshMarks().typed == .unknown else { return }
        try setState(type: .typed(name: type, hash: nil, models: nil))
    }

    /// The type this db3's model writes are judged by on the device: the
    /// declarations the room sent with its open, or `nil` while none are held.
    var declaredType: RecordLogDeclaredType? {
        let marks = self.marks
        guard marks.typed == .yes, let name = marks.db3Type?.name, let models = marks.declarations else { return nil }
        return RecordLogDeclaredType(name: name, models: models, vectors: marks.vectors ?? [:], enums: marks.enums ?? [:])
    }

    /// The declarations a write is judged by before it reaches the store:
    /// ``declaredType`` for a db3 that syncs; `nil` for a typed local-only
    /// db3 (#6025), whose store judges each write inside the transaction
    /// that commits it by the declarations installed then. A copy of them
    /// held here may be older (another client of the store installed a
    /// build since), so it neither refuses what the installed ones take nor
    /// lets through what they refuse.
    var precommitDeclaredType: RecordLogDeclaredType? {
        let marks = self.marks
        if marks.localOnly && (marks.typed == .yes || marks.localTypeUnreadable) { return nil }
        return declaredType
    }

    /// Mark the copy of a db3 the server just created caught up, so it is
    /// resident; a copy already marked keeps its mark.
    func markCaughtUpAtCreate() throws {
        let at = Int64(Date().timeIntervalSince1970 * 1000)
        let marks = try withOperation { try store.markCaughtUpAtCreate(at: at) }
        state.withLock { _marks = marks }
    }

    /// Read the marks again.
    @discardableResult
    func refreshMarks() throws -> RecordLogMarks {
        let marks = try store.marks()
        state.withLock { _marks = marks }
        return marks
    }

    // MARK: - Transactions

    /// The saves a `transact` on one thread has made to this document, held
    /// for one entry: per record, every save as one mutation, planned against
    /// the record as the earlier saves left it.
    private final class Staged {
        var depth = 0
        var order: [RecordLogRecordKey] = []
        var writes: [RecordLogRecordKey: (held: RecordLogHeldWrites, upsertOn: String?, row: RecordLogRow?)] = [:]
    }

    private var staged: [UInt64: Staged] = [:]

    private static var threadId: UInt64 {
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        return id
    }

    /// Run `body` as one transaction: the format-3 saves it makes on this
    /// thread to this document land as ONE entry (`m` plus `also`), committed
    /// when the outermost transaction exits — even when `body` threw. A nested
    /// transaction joins the outer one.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        let thread = Self.threadId
        let outer = state.withLock { () -> Bool in
            let current = staged[thread] ?? Staged()
            staged[thread] = current
            current.depth += 1
            return current.depth == 1
        }
        let result = Result { try body() }
        var commitError: Error?
        let finished = state.withLock { () -> Staged? in
            guard let current = staged[thread] else { return nil }
            current.depth -= 1
            guard current.depth == 0 else { return nil }
            staged[thread] = nil
            return current
        }
        if outer, let finished, !finished.order.isEmpty {
            // Each record's absolute write, then its increment of the fields that write does not assign.
            let mutations = finished.order.flatMap { finished.writes[$0]?.held.mutations ?? [] }
            let upsertOn = finished.order.first.flatMap { finished.writes[$0]?.upsertOn }
            do {
                try assertRecordLogEntry(documentId: documentId, mutations: mutations, upsertOn: upsertOn) { [weak self] event in
                    self?.reportRefused(event)
                }
                // A typed db3's declarations, as the room judges the entry (#5020); a
                // typed local-only one's are judged in the store's commit (#6025).
                try assertRecordLogDeclaredTypes(documentId: documentId, mutations: mutations, type: precommitDeclaredType) { [weak self] event in
                    self?.reportRefused(event)
                }
                let committed = try commit([RecordLogWrite(mutations: mutations, upsertOn: upsertOn)])
                notify(committed.flatMap(\.keys), origin: nil)
            } catch {
                commitError = error
            }
        }
        switch result {
        case .success(let value):
            if let commitError { throw commitError }
            return value
        case .failure(let error):
            throw error
        }
    }

    /// Hold `mutation` for the transaction open on this thread, if there is
    /// one, folded per field into what the transaction holds of the record
    /// (``foldRecordLogIncrement(_:_:)``). `existing` is the record as the
    /// view (or the transaction so far) holds it. Answers whether it was held.
    func stage(_ mutation: RecordLogMutation, upsertOn: String?, existing: RecordLogRow?) -> Bool {
        let thread = Self.threadId
        return state.withLock {
            guard let current = staged[thread] else { return false }
            let key = mutation.key
            let table = RecordLogMapRowTable()
            if let existing { table.set(key, existing) }
            _ = try? recordLogApplyGuess(table, RecordLogPendingEntry(seq: 0, e: 0, k: 0, m: mutation))
            let row = table.row(key)
            if let held = current.writes[key] {
                current.writes[key] = (foldRecordLogIncrement(held.held, mutation), held.upsertOn ?? upsertOn, row)
            } else {
                current.order.append(key)
                current.writes[key] = (foldRecordLogIncrement(RecordLogHeldWrites(), mutation), upsertOn, row)
            }
            return true
        }
    }

    /// The record as the transaction open on this thread leaves it: `nil` when
    /// no save in it touched the record, `.some(nil)` when one deleted it.
    func stagedRow(_ key: RecordLogRecordKey) -> RecordLogRow?? {
        let thread = Self.threadId
        return state.withLock {
            guard let held = staged[thread]?.writes[key] else { return nil }
            return .some(held.row)
        }
    }

    /// The records of `model` the transaction open on this thread saved, in
    /// the order it first saved them, as it leaves them (`nil`: deleted).
    func stagedRows(model: String) -> [(id: String, row: RecordLogRow?)] {
        let thread = Self.threadId
        return state.withLock {
            guard let current = staged[thread] else { return [] }
            return current.order.filter { $0.model == model }.map { ($0.id, current.writes[$0]?.row ?? nil) }
        }
    }

    /// Whether a transaction on this thread is holding this document's saves:
    /// they reach the view, and the model's listeners, when it ends.
    var isStagingOnThisThread: Bool {
        let thread = Self.threadId
        return state.withLock { staged[thread] != nil }
    }

    /// The conversation with the room stopped without the document closing
    /// (the session's release): no acknowledgement is coming on it, so what
    /// waits on one throws. The entries stay, and a later open sends them.
    func releaseAcknowledgementWaiters() {
        let (waiters, settling) = state.withLock {
            () -> ([CheckedContinuation<Void, Error>], [CheckedContinuation<RecordLogSettlement, Error>]) in
            let all = ackWaiters.values.flatMap { $0 }
            let settling = settleWaiters.values.flatMap { $0 }
            ackWaiters = [:]
            settleWaiters = [:]
            return (all, settling)
        }
        guard !waiters.isEmpty || !settling.isEmpty else { return }
        let error = JsBaoError(
            code: .notFound,
            message: "Document `\(documentId)` closed before the room acknowledged the write.",
            details: ["documentId": .string(documentId)]
        )
        for waiter in waiters { waiter.resume(throwing: error) }
        for waiter in settling { waiter.resume(throwing: error) }
    }

    // MARK: - Closing

    /// Close: the open group commits, what waits on an acknowledgement throws,
    /// and nothing more is accepted. Removes nothing the store holds.
    func close() {
        let (waiters, settling) = state.withLock {
            () -> ([CheckedContinuation<Void, Error>], [CheckedContinuation<RecordLogSettlement, Error>]) in
            guard !closed else { return ([], []) }
            closed = true
            vectorListener = nil
            commitListeners = [:]
            modelListeners = [:]
            changeListeners = [:]
            pendingListeners = [:]
            let all = ackWaiters.values.flatMap { $0 }
            let settling = settleWaiters.values.flatMap { $0 }
            ackWaiters = [:]
            settleWaiters = [:]
            return (all, settling)
        }
        vectorJobs?.stop()
        try? store.flush()
        let error = JsBaoError(
            code: .notFound,
            message: "Document `\(documentId)` closed before the room acknowledged the write.",
            details: ["documentId": .string(documentId)]
        )
        for waiter in waiters { waiter.resume(throwing: error) }
        for waiter in settling { waiter.resume(throwing: error) }
    }

    var isClosed: Bool { state.withLock { closed } }
}
