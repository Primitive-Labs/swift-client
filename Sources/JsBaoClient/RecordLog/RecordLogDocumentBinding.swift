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
    init(host: any Format2SqlHost, documentId: String, clientId: String, logger: Logger? = nil) throws {
        self.documentId = documentId
        self.logger = logger
        let store = RecordLogStore(host: host, documentId: documentId, clientId: clientId, logger: logger)
        try store.initialize()
        let writer = try store.mintWriter()
        let marks = try store.marks()
        self.store = store
        self._writer = writer
        self._marks = marks
        for (seq, records) in marks.unacked { unacked[seq] = records }
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
    /// `isRecordLogResident`): created here, or a load completed and no
    /// unstaged replacement is in progress. Answered from the mirrored marks;
    /// they are read again only when they say no.
    var isResident: Bool {
        let createdLocally = self.createdLocally
        if RecordLogStore.isResident(marks, createdLocally: createdLocally) { return true }
        guard let fresh = try? refreshMarks() else { return false }
        return RecordLogStore.isResident(fresh, createdLocally: createdLocally)
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
    /// room's list, which a declaration reaches through the room).
    func registerModel(_ schema: PrimitiveSchema) throws {
        state.withLock {
            if schemas[schema.name] != schema { _declarationVersion += 1 }
            schemas[schema.name] = schema
        }
    }

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
    /// or a hand-back, whether or not a row changed.
    @discardableResult
    func onPendingChanged(_ listener: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        state.withLock { pendingListeners[token] = listener }
        return token
    }

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
            throw JsBaoError(
                code: .accessDenied,
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
                try store.commitEntries(writer: writer, writes: writes) { [weak self] error in
                    if let entries = delivery.outcome(error) { self?.groupCommitted(entries, writer: writer, error: error) }
                }
            }
        } catch let error as JsBaoError where RecordLogHandBackCode.all.contains(error.code.rawValue) {
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
        if let (entries, error) = delivery.entries(reply.entries) { groupCommitted(entries, writer: writer, error: error) }
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

    /// A save's entries and its group's outcome, which arrive in either order:
    /// a group commits on the provider's queue after the save returned, and a
    /// host that cannot defer commits it before. Whichever comes second delivers.
    ///
    /// `@unchecked Sendable`: both fields are read and written only under
    /// `lock`, a leaf lock held for the assignment alone.
    private final class Delivery: @unchecked Sendable {
        private let lock = NSLock()
        private var saved: [RecordLogPendingEntry]?
        private var heard: (error: Error?, at: Bool) = (nil, false)

        /// The save returned; answers what to deliver when the group already committed.
        func entries(_ entries: [RecordLogPendingEntry]) -> ([RecordLogPendingEntry], Error?)? {
            lock.withLock {
                saved = entries
                return heard.at ? (entries, heard.error) : nil
            }
        }

        /// The group committed or failed; answers the entries when the save already returned.
        func outcome(_ error: Error?) -> [RecordLogPendingEntry]? {
            lock.withLock {
                heard = (error, true)
                return saved
            }
        }
    }

    /// A group of saves committed (or failed): runs on the provider's queue,
    /// so it takes only the leaf lock.
    private func groupCommitted(_ entries: [RecordLogPendingEntry], writer: String, error: Error?) {
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

    /// Record what the room said about epochs, constraints, the db3's type and this client's permission.
    @discardableResult
    func setState(
        notice: (current: Int, next: Int?, entries: Int?)? = nil,
        constraints: [RecordLogConstraint]? = nil, permission: String?? = nil, type: RecordLogTypeUpdate? = nil
    ) throws -> RecordLogMarks {
        let writer = self.writer
        let marks = try withOperation {
            try store.setState(writer: writer, notice: notice, constraints: constraints, permission: permission, type: type)
        }
        state.withLock { _marks = marks }
        return marks
    }

    /// Take a permission the client heard for this db3 while it is bound
    /// (#5020): the store's mark follows it, `read` on `.reader` (saves are
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

    /// Take the type this db3 was created with here (#5020): a store the room
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
        return RecordLogDeclaredType(name: name, models: models)
    }

    /// Mark the copy of a db3 the server just created caught up, so it is
    /// resident (#4806); a copy already marked keeps its mark.
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
                // A typed db3's declarations, as the room judges the entry (#5020).
                try assertRecordLogDeclaredTypes(documentId: documentId, mutations: mutations, type: declaredType) { [weak self] event in
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
