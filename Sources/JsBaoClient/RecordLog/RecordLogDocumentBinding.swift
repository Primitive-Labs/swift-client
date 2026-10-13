import Foundation

/// One open format-3 document: its store, this client's writer, the models
/// projected from its view, and what the app is waiting on — the entries the
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
    /// The engine every format-3 document's filtered reads run on.
    let engine: BaoModelQueryEngine
    private let host: any Format2SqlHost
    private let logger: Logger?

    private let operation = NSRecursiveLock()
    private let state = NSLock()

    private var _writer: String
    private var _marks: RecordLogMarks
    private var schemas: [String: PrimitiveSchema] = [:]
    private var specs: [String: RecordLogProjectionSpec] = [:]
    private var projected: Set<String> = []
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
    /// Unique constraints the room keeps out of force: the local pre-check skips them.
    private var refusedConstraints: Set<String> = []
    private var closed = false
    private var modelListeners: [String: [UUID: @Sendable () -> Void]] = [:]
    private var commitListeners: [UUID: @Sendable ([RecordLogPendingEntry]) -> Void] = [:]
    private var errorListeners: [UUID: @Sendable (JsBaoError) -> Void] = [:]
    private var refusalReporter: (@Sendable (DocumentWriteRefusedEvent) -> Void)?
    /// Records this writer upserted under one id that the room applied to
    /// another (its alias), so a handle on the first id reads the second.
    private var aliases: [RecordLogRecordKey: String] = [:]

    // MARK: - Opening

    /// Open `documentId`'s store over `host`: create the tables, mint this
    /// client's writer (a ULID per document and client id), read the marks.
    init(
        host: any Format2SqlHost, documentId: String, clientId: String,
        engine: BaoModelQueryEngine, logger: Logger? = nil
    ) throws {
        self.host = host
        self.documentId = documentId
        self.engine = engine
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
    var isReadOnly: Bool { marks.permission == "read" }

    /// Every registered model's projection spec.
    var projectionSpecs: [RecordLogProjectionSpec] {
        state.withLock { specs.keys.sorted().compactMap { specs[$0] } }
    }

    /// Every registered model's schema, by name.
    var registeredSchemas: [PrimitiveSchema] {
        state.withLock { schemas.keys.sorted().compactMap { schemas[$0] } }
    }

    /// Moves whenever a model is registered on this document.
    var declarationVersion: Int { state.withLock { _declarationVersion } }

    // MARK: - Models

    /// Bind a model to this document: its query tables prepared, its view
    /// lookup indexes built, and its query rows rebuilt from the view unless
    /// they already hold it. Called off the provider's queue.
    func registerModel(_ schema: PrimitiveSchema) throws {
        let already = state.withLock { () -> Bool in
            if schemas[schema.name] == schema, projected.contains(schema.name) { return true }
            if schemas[schema.name] != schema { _declarationVersion += 1 }
            schemas[schema.name] = schema
            specs[schema.name] = RecordLogProjectionSpec(schema: schema)
            return false
        }
        if already { return }
        try RecordLogQueryProjection.prepare(schema: schema, engine: engine, host: host)
        var fields: [String] = []
        var sets: [String] = []
        for (name, descriptor) in schema.fields.sorted(by: { $0.key < $1.key }) {
            if descriptor.type == .stringset {
                sets.append(name)
            } else if name != "id", descriptor.indexed || descriptor.unique {
                fields.append(name)
            }
        }
        let constraints = schema.constraints.values.sorted { $0.name < $1.name }.map { ($0.name, $0.fields) }
        store.ensureFieldIndexes(model: schema.name, fields: fields, constraints: constraints, stringSetFields: sets)
        let spec = RecordLogProjectionSpec(schema: schema)
        let rebuilt = try withOperation { try store.projectModel(spec: spec) }
        state.withLock { _ = projected.insert(schema.name) }
        if rebuilt {
            logger?.debug("[record-log] rebuilt the query tables of", schema.name, "in", documentId, "from its view")
        }
    }

    /// Whether `model`'s query tables hold this document's view.
    func isProjected(_ model: String) -> Bool { state.withLock { projected.contains(model) } }

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
    /// `records`, and `models` (those a chunk changed in bulk).
    func notify(_ records: [RecordLogRecordKey], models bulk: [String] = []) {
        let models = Set(records.map(\.model)).union(bulk)
        let listeners = state.withLock { models.flatMap { modelListeners[$0]?.values.map { $0 } ?? [] } }
        for listener in listeners { listener() }
    }

    /// Tell the listeners of what a chunk of a load or a segment changed, once
    /// per model: reads go to the store, so a listener re-reads the rows.
    func notify(_ reply: RecordLogChunkReply) {
        notify(reply.changed.map { RecordLogRecordKey(model: $0.model, id: $0.id) }, models: reply.models)
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
    /// them once their group commits. A save refused before it commits (the
    /// epoch budget) is reported with its writes and thrown.
    @discardableResult
    func commit(_ writes: [RecordLogWrite]) throws -> [RecordLogPendingEntry] {
        try assertOpen()
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
                try store.commitEntries(
                    writer: writer, writes: writes, project: projectionSpecs
                ) { [weak self] error in
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
            notify(touched)
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
        return touched
    }

    /// These entries of this writer were handed back with `error`: what waits on them throws it.
    @discardableResult
    func handBack(_ seqs: [Int], error: JsBaoError) -> [RecordLogRecordKey] {
        let (touched, waiters) = state.withLock { () -> ([RecordLogRecordKey], [CheckedContinuation<Void, Error>]) in
            var touched: [RecordLogRecordKey] = []
            var waiters: [CheckedContinuation<Void, Error>] = []
            for seq in seqs {
                if let keys = unacked.removeValue(forKey: seq) { touched.append(contentsOf: keys) }
                handedBack[seq] = error
                if let ticket = ticketOfSeq[seq] { refusedTickets.insert(ticket) }
                waiters.append(contentsOf: ackWaiters.removeValue(forKey: seq) ?? [])
            }
            return (touched, waiters)
        }
        for waiter in waiters { waiter.resume(throwing: error) }
        return touched
    }

    /// This writer was re-minted: its entries were renumbered, and what waits
    /// on them follows them.
    func reminted(writer: String, renumbered: [(from: Int, to: Int)]) {
        let orphaned = state.withLock { () -> [CheckedContinuation<Void, Error>] in
            _writer = writer
            let oldUnacked = unacked
            var oldWaiters = ackWaiters
            let oldTickets = ticketOfSeq
            unacked = [:]
            ackWaiters = [:]
            handedBack = [:]
            ticketOfSeq = [:]
            for (from, to) in renumbered {
                if let keys = oldUnacked[from] { unacked[to] = keys }
                if let waiting = oldWaiters.removeValue(forKey: from) { ackWaiters[to] = waiting }
                if let ticket = oldTickets[from] { ticketOfSeq[to] = ticket }
            }
            return oldWaiters.values.flatMap { $0 }
        }
        // A waiter on a void marker has nothing left to wait for.
        for waiter in orphaned { waiter.resume() }
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

    /// Record what the room said about epochs, constraints and this client's permission.
    @discardableResult
    func setState(
        notice: (current: Int, next: Int?, entries: Int?)? = nil,
        constraints: [RecordLogConstraint]? = nil, permission: String?? = nil
    ) throws -> RecordLogMarks {
        let writer = self.writer
        let marks = try withOperation {
            try store.setState(writer: writer, notice: notice, constraints: constraints, permission: permission)
        }
        state.withLock { _marks = marks }
        return marks
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
        var writes: [RecordLogRecordKey: (mutation: RecordLogMutation, upsertOn: String?, row: RecordLogRow?)] = [:]
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
            let mutations = finished.order.compactMap { finished.writes[$0]?.mutation }
            let upsertOn = finished.order.first.flatMap { finished.writes[$0]?.upsertOn }
            do {
                try assertRecordLogEntry(documentId: documentId, mutations: mutations) { [weak self] event in
                    self?.reportRefused(event)
                }
                let committed = try commit([RecordLogWrite(mutations: mutations, upsertOn: upsertOn)])
                notify(committed.flatMap(\.keys))
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
    /// one. `existing` is the record as the view (or the transaction so far)
    /// holds it. Answers whether it was held.
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
                current.writes[key] = (mergeRecordLogMutations(held.mutation, mutation), held.upsertOn ?? upsertOn, row)
            } else {
                current.order.append(key)
                current.writes[key] = (mutation, upsertOn, row)
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

    // MARK: - Closing

    /// Close: the open group commits, what waits on an acknowledgement throws,
    /// and nothing more is accepted. Removes nothing the store holds.
    func close() {
        let waiters = state.withLock { () -> [CheckedContinuation<Void, Error>] in
            guard !closed else { return [] }
            closed = true
            commitListeners = [:]
            modelListeners = [:]
            let all = ackWaiters.values.flatMap { $0 }
            ackWaiters = [:]
            return all
        }
        try? store.flush()
        let error = JsBaoError(
            code: .notFound,
            message: "Document `\(documentId)` closed before the room acknowledged the write.",
            details: ["documentId": .string(documentId)]
        )
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    var isClosed: Bool { state.withLock { closed } }
}
