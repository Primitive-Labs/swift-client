import Foundation

/// The socket a client's record-log sessions send on.
protocol RecordLogConnection: AnyObject, Sendable {
    /// Send one frame, in the order frames are handed over; it carries its
    /// `type` and `documentId`.
    func send(_ frame: [String: JSONValue])
    /// Whether the socket is open and the client may use the network.
    func connected() -> Bool
    /// Whether ``fetchArtifact(_:)`` reads the room's artifacts. A connection
    /// that cannot is served rows: its opens declare no `accepts`.
    var fetchesArtifacts: Bool { get }
    /// Fetch one artifact the room granted (a load's manifest or chunk, a
    /// segment's chunk) at its origin-relative `path`; the path carries the
    /// grant, so no other credential is sent. Throws on any answer but 200.
    func fetchArtifact(_ path: String) async throws -> Data
}

extension RecordLogConnection {
    var fetchesArtifacts: Bool { false }

    func fetchArtifact(_ path: String) async throws -> Data {
        throw RecordLogReceiptFailure("the connection cannot fetch artifacts")
    }
}

/// What one document's session needs of the client it belongs to.
struct RecordLogSessionHost: Sendable {
    /// The connection, once the client has given one.
    var connection: @Sendable () -> (any RecordLogConnection)?
    /// Every registered model's declaration, as `record.declare` carries it.
    var declarations: @Sendable () -> [String: JSONValue]
    /// The document's open handshake and catch-up completed as this client's writer.
    var synced: @Sendable (String) -> Void
    /// An open attempt ended without a handshake; the client may try again.
    var syncFailed: @Sendable (String, String) -> Void
    /// A receipt of chunks or a catch-up page made progress: the client's open
    /// watchdog waits longer.
    var progress: @Sendable (String) -> Void = { _ in }
}

/// How long the session waits, in milliseconds: the JS client's numbers by
/// default, shorter in a test.
struct RecordLogSessionTimings: Sendable {
    var tickMs = RecordLogTransport.tickMs
    var resultGapMs = RecordLogTransport.resultGapMs
    var drainWaitMs = RecordLogTransport.drainWaitMs
    /// The first wait before a refused own writer is opened again; it doubles up to 30 s.
    var writerTakenRetryMs = 500
    /// The first wait before an open whose catch-up page failed starts over; it doubles up to 30 s.
    var catchUpRetryMs = 250
    /// How long an open another client's replacement of the store overtook
    /// waits for that replacement to complete; past it the other is taken to
    /// be gone.
    var replacementWaitMs = 30_000
    /// How often that wait looks whether the other replacement completed.
    var replacementPollMs = 100
}

/// What a connection that fetches artifacts declares it takes beside rows.
private let recordLogAccepts: JSONValue = ["load", "segment"]

/// Consecutive failed receipts after which the next open declares it takes rows only.
let recordLogReceiptFailuresBeforeRows = 2

/// A grant path as a log line shows it: the token is a credential, so it is left out.
func recordLogShownPath(_ path: String) -> String {
    guard let range = path.range(of: "/doc-artifact/") else { return path }
    let rest = path[range.upperBound...]
    let tail = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? ""
    return String(path[..<range.lowerBound]) + "/doc-artifact/…" + tail
}

/// A format-3 document's conversation with its room over the client's socket:
/// the port of js-bao's `session.ts`, rule for rule.
///
/// The session opens the document — first as each writer of the store that an
/// earlier session left entries under (it resubmits them so the room answers
/// each one, then moves on), then as this client's own writer. Each open
/// applies the catch-up the room sends, records the epochs and constraints, and
/// resubmits every unjudged entry of that writer in `seq` order. Once the own
/// writer is open, the models are declared, entries are sent as their group
/// commits, results and refusals are applied, and a refusal's withdrawn writes
/// are handed back.
///
/// **Concurrency.** An actor whose frame handlers contain no `await`: every
/// store call is synchronous (it runs on the storage provider's queue), and
/// frames go out through ``RecordLogConnection/send(_:)``, which keeps their
/// order. So a handler is one decision region, and a later frame or a
/// disconnect cannot interleave with it. Timers are tasks that hop back onto
/// the actor and check the connection generation they were armed under.
actor RecordLogSession {

    private enum Phase { case idle, opening, catchingUp, loading, draining, open, closed }

    /// The paged catch-up in progress. `released` once the room dropped the
    /// subscription while a page request was out: the open goes again when
    /// that request is answered.
    private struct Paging {
        var cursor: Int
        var upTo: Int
        /// The room walks its whole table (`record.catchUp {full: true}`).
        var full: Bool
        var high: Int
        var released = false
        /// The replacement's generation, when the pages complete a replacement of the table.
        var generation: Int?
        /// The receipt whose remainder these pages are.
        var receipt: Receipt?
    }

    /// A receipt of a load's or a segment's chunks in progress. Read and
    /// written only on the session; the task that runs it is isolated to the
    /// session and hops off it only to fetch and to read a chunk's bytes.
    private final class Receipt {
        let kind: RecordLogReceiptKind
        let id: String
        /// Received from `record.load complete` on an open document, not as an open's catch-up.
        let live: Bool
        /// The connection it runs on (`generation` when it began).
        let connection: Int
        /// The writer its store commands run as.
        let writer: String
        let rows: Int
        let chunks: Int
        let startedAt = Date()
        /// The store's id for it, once begun; its commands carry it.
        var attempt: String?
        var remainderRows = 0
        /// A `record.released` arrived while its chunks were fetched: it stops after the one in flight.
        var released = false
        var task: Task<Void, Never>?

        init(kind: RecordLogReceiptKind, id: String, live: Bool, connection: Int, writer: String, rows: Int, chunks: Int) {
            self.kind = kind
            self.id = id
            self.live = live
            self.connection = connection
            self.writer = writer
            self.rows = rows
            self.chunks = chunks
        }
    }

    let documentId: String
    private let binding: RecordLogDocumentBinding
    private let host: RecordLogSessionHost
    private let timings: RecordLogSessionTimings
    private let logger: Logger?

    private var phase: Phase = .idle
    private var current: (writer: String, orphan: Bool)?
    private var orphans: [(writer: String, lowestPending: Int)] = []
    private var ownSender: RecordLogSender?
    private var orphanSender: RecordLogSender?
    /// The orphan writer's entries the room has not answered yet.
    private var outstanding = Set<Int>()
    private var drainTimer: Task<Void, Never>?
    /// Result frames that arrived while a catch-up was being read.
    private var heldResults: [[RecordLogResultItem]] = []
    private var paging: Paging?
    private var takenRetryMs: Int
    private var catchUpRetryMs: Int
    /// Counts the connections this session has lost. A timer armed under one
    /// generation does nothing under another: the socket it was for is gone.
    private var generation = 0
    private var retryTimer: Task<Void, Never>?
    /// The highest log number received ahead of the cursor, and the timer that catches up past it.
    private var gapAhead = 0
    private var gapTimer: Task<Void, Never>?
    /// The room's `lastSeq` for the writer being opened, from its `record.opened`.
    private var lastSeq = 0
    private var clockWork: [Int: () -> Void] = [:]
    private var clockTasks: [Int: Task<Void, Never>] = [:]
    private var nextClockHandle = 0
    /// The binding's declaration version the room was last sent in `record.declare`.
    private var declaredVersion = -1
    private var commitToken: UUID?
    private var commitFeed: AsyncStream<[RecordLogPendingEntry]>.Continuation?
    private var commitConsumer: Task<Void, Never>?
    /// The load the room said is applying (`record.load started`): results stall behind its numbers on purpose.
    private var loadInProgress: String?
    /// Completed loads announced while the session was busy, received once it is open.
    private var queuedLoads: [RecordLogLoadPointer] = []
    /// The receipt of chunks in progress.
    private var receipt: Receipt?
    /// Receipts that failed in a row; at ``recordLogReceiptFailuresBeforeRows`` the next open takes rows only.
    private var failedReceipts = 0
    /// A load ended aborted or failed during a catch-up: open again once it completes.
    private var reopenAfterCatchUp = false
    /// Counts opens; a wait for another client's replacement opens again only if none was sent since.
    private var opens = 0
    private var replacementTimer: Task<Void, Never>?

    init(
        documentId: String, binding: RecordLogDocumentBinding, host: RecordLogSessionHost,
        timings: RecordLogSessionTimings = RecordLogSessionTimings(), logger: Logger? = nil
    ) {
        self.documentId = documentId
        self.binding = binding
        self.host = host
        self.timings = timings
        self.logger = logger
        self.takenRetryMs = timings.writerTakenRetryMs
        self.catchUpRetryMs = timings.catchUpRetryMs
    }

    /// Begin hearing this writer's committed entries. Called once after init.
    func attach() {
        guard commitFeed == nil else { return }
        // In commit order: one stream, consumed by one task.
        let (stream, feed) = AsyncStream.makeStream(of: [RecordLogPendingEntry].self)
        commitFeed = feed
        commitToken = binding.onCommitted { entries in feed.yield(entries) }
        commitConsumer = Task { [weak self] in
            for await entries in stream { await self?.committed(entries) }
        }
    }

    /// Whether the session has opened the document as this client's writer.
    var isOpen: Bool { phase == .open }

    /// The upstream queue of this client's writer.
    private var sender: RecordLogSender {
        if let ownSender { return ownSender }
        let made = makeSender(orphanWriter: nil)
        ownSender = made
        return made
    }

    /// A sender whose frames leave while this writer is the one open: the own
    /// writer's while the document is open, or an orphan's while it drains.
    /// Its closures are formed here, on the session, and run only here; they
    /// hold the session strongly until ``close()`` drops the senders.
    private func makeSender(orphanWriter: String?) -> RecordLogSender {
        let clock = RecordLogClosureClock(
            schedule: { milliseconds, work in self.schedule(milliseconds, work) },
            cancel: { handle in self.cancelScheduled(handle) }
        )
        return RecordLogSender(
            clock: clock, tickMs: timings.tickMs,
            connected: {
                guard let orphanWriter else { return self.phase == .open && self.connected() }
                return self.phase == .draining && self.current?.writer == orphanWriter && self.connected()
            },
            send: { frame in self.send(frame.json) }
        )
    }

    private func connected() -> Bool { host.connection()?.connected() == true }

    private func send(_ frame: JSONValue) {
        guard var object = frame.objectValue, let connection = host.connection() else { return }
        object["documentId"] = .string(documentId)
        connection.send(object)
    }

    // MARK: - Timers

    private func schedule(_ milliseconds: Int, _ work: @escaping () -> Void) -> Int {
        nextClockHandle += 1
        let handle = nextClockHandle
        clockWork[handle] = work
        clockTasks[handle] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
            await self?.fire(handle)
        }
        return handle
    }

    private func cancelScheduled(_ handle: Int) {
        clockWork[handle] = nil
        clockTasks.removeValue(forKey: handle)?.cancel()
    }

    private func fire(_ handle: Int) {
        clockTasks[handle] = nil
        guard let work = clockWork.removeValue(forKey: handle) else { return }
        work()
    }

    /// Run `body` on the session after `milliseconds`, unless the connection
    /// it was armed under is gone by then.
    private func after(_ milliseconds: Int, _ body: @escaping @Sendable (isolated RecordLogSession) -> Void) -> Task<Void, Never> {
        let armed = generation
        return Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.run(armed, body)
        }
    }

    private func run(_ armed: Int, _ body: @Sendable (isolated RecordLogSession) -> Void) {
        guard armed == generation, phase != .closed else { return }
        body(self)
    }

    // MARK: - Opening

    /// Open the document on the connection, unless an open is under way or
    /// done (a done one is reported again). Writers an earlier session left
    /// entries under are opened first.
    func start() {
        if phase == .open {
            host.synced(documentId)
            return
        }
        guard phase == .idle else { return }
        guard connected() else {
            host.syncFailed(documentId, "not connected")
            return
        }
        phase = .opening
        attempt("start") {
            let own = binding.writer
            let state = try binding.store.storedState()
            orphans = state.writers
                .filter { $0.writer != own && $0.pending > 0 }
                .map { ($0.writer, $0.lowestPending) }
            if !orphans.isEmpty {
                logger?.log("[record-log]", documentId, "— draining", orphans.count, "earlier writer(s) before opening")
            }
            try openNext()
        }
    }

    /// Run one step of an open; a store failure ends the attempt.
    private func attempt(_ what: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            logger?.warn("[record-log]", documentId, "—", what, "failed:", error.localizedDescription)
            if phase == .opening || phase == .catchingUp || phase == .loading || phase == .draining {
                phase = .idle
                current = nil
                paging = nil
                stopReceipt()
                host.syncFailed(documentId, error.localizedDescription)
            }
        }
    }

    private func openNext() throws {
        if !orphans.isEmpty {
            let orphan = orphans.removeFirst()
            current = (orphan.writer, true)
        } else {
            current = (binding.writer, false)
        }
        try sendOpen()
    }

    private func sendOpen() throws {
        guard let current else { return }
        let marks = try binding.refreshMarks()
        let pending = try binding.store.pendingOf(current.writer)
        let unacked = pending.filter { $0.acked == nil }
        // The next number the room will receive from this writer: its lowest
        // unacknowledged entry, or the one it would mint next.
        let nextSeq = unacked.first?.seq
            ?? (current.orphan ? max(1, (pending.map(\.seq).max() ?? 0) + 1) : marks.nextSeq)
        phase = .opening
        opens += 1
        // The room tells a reopened subscriber again of a load still applying.
        loadInProgress = nil
        replacementTimer?.cancel()
        replacementTimer = nil
        var open: [String: JSONValue] = [
            "type": "record.open",
            "writer": .string(current.writer),
            "cursor": .number(Double(marks.cursor)),
            "nextSeq": .number(Double(nextSeq)),
            "open": .number(Double(marks.open)),
            "formats": [3],
            "documentFormat": 3,
        ]
        if host.connection()?.fetchesArtifacts == true {
            open["accepts"] = failedReceipts >= recordLogReceiptFailuresBeforeRows ? [] : recordLogAccepts
        }
        send(.object(open))
    }

    /// The socket closed: everything in flight is gone, and the next open starts over.
    func disconnected() {
        guard phase != .closed else { return }
        generation += 1
        phase = .idle
        current = nil
        orphans = []
        paging = nil
        heldResults = []
        ownSender?.reset()
        orphanSender?.reset()
        orphanSender = nil
        outstanding = []
        drainTimer?.cancel()
        drainTimer = nil
        retryTimer?.cancel()
        retryTimer = nil
        replacementTimer?.cancel()
        replacementTimer = nil
        stopReceipt()
        queuedLoads = []
        loadInProgress = nil
        reopenAfterCatchUp = false
        clearGap()
    }

    /// The receipt in progress stops: its task is cancelled, and nothing it
    /// was fetching is applied.
    private func stopReceipt() {
        receipt?.task?.cancel()
        receipt = nil
    }

    /// The document closed: stop, and stop hearing its commits.
    func close() {
        disconnected()
        phase = .closed
        ownSender = nil
        if let commitToken { binding.removeCommitListener(commitToken) }
        commitToken = nil
        commitFeed?.finish()
        commitFeed = nil
        commitConsumer?.cancel()
        for task in clockTasks.values { task.cancel() }
        clockTasks = [:]
        clockWork = [:]
    }

    /// The socket may carry frames again: queued entries leave at the next tick.
    func kick() { ownSender?.kick() }

    /// The room said this client may write again (a connect with write access):
    /// a `read` the room set earlier is lifted.
    func adoptWriteAccess() {
        guard binding.isReadOnly else { return }
        logger?.log("[record-log]", documentId, "— connected with write access again; saves are allowed")
        _ = try? binding.setState(permission: .some(nil))
    }

    private func clearGap() {
        gapTimer?.cancel()
        gapTimer = nil
        gapAhead = 0
    }

    /// Results arrived past a missing one. If the missing one has not come
    /// within the result-gap wait, the writer is opened again from its cursor:
    /// the catch-up carries what the lost result changed.
    private func watchGap(cursor: Int, items: [RecordLogResultItem]) {
        // A load applying: its rows are never relayed, so the results after
        // them wait on purpose until its pointer is received.
        if loadInProgress != nil {
            clearGap()
            return
        }
        for item in items {
            if case .result(let result) = item, result.l > cursor { gapAhead = max(gapAhead, result.l) }
        }
        if gapAhead <= cursor {
            clearGap()
            return
        }
        guard gapTimer == nil else { return }
        gapTimer = after(timings.resultGapMs) { session in
            session.gapTimer = nil
            session.attempt("result gap") {
                let marks = try session.binding.refreshMarks()
                guard session.phase == .open, session.loadInProgress == nil, session.gapAhead > marks.cursor else { return }
                session.logger?.warn(
                    "[record-log] result gap", session.documentId, "— results up to", session.gapAhead,
                    "wait behind", marks.cursor + 1, "; catching up from the cursor"
                )
                session.gapAhead = 0
                try session.sendOpen()
            }
        }
    }

    // MARK: - Frames

    /// One frame the room sent about this document.
    func receive(_ frame: [String: JSONValue]) {
        guard phase != .closed else { return }
        let type = frame["type"]?.stringValue ?? ""
        switch type {
        case "record.opened": attempt("record.opened") { try opened(frame) }
        case "record.catchUpPage": attempt("record.catchUpPage") { try catchUpPage(frame) }
        case "record.results":
            let items = (frame["results"]?.arrayValue ?? []).compactMap { RecordLogResultItem(json: $0) }
            attempt("record.results") { try results(items) }
        case "record.refused":
            guard let refusal = RecordLogRefusal(json: .object(frame)) else { return }
            attempt("record.refused") { try refused(refusal) }
        case "record.gap":
            guard let expected = frame["expected"]?.wholeNumber else { return }
            attempt("record.gap") { try gap(expected) }
        case "record.released": attempt("record.released") { try released(frame) }
        case "record.load": attempt("record.load") { try load(frame) }
        case "record.epoch":
            guard let current = frame["current"]?.wholeNumber else { return }
            attempt("record.epoch") {
                try binding.setState(notice: (current, frame["next"]?.wholeNumber ?? current + 1, frame["entries"]?.wholeNumber))
            }
        case "record.declared":
            let refused = (frame["refused"]?.arrayValue ?? []).compactMap(\.stringValue)
            guard !refused.isEmpty else { return }
            logger?.warn(
                "[record-log] constraint refused", documentId, "— the room keeps", refused.joined(separator: ", "),
                "out of force (live records already share the key); saves are no longer pre-checked against it"
            )
            attempt("record.declared") { try binding.excludeConstraints(refused) }
        case "error": attempt("error") { try error(frame) }
        default:
            logger?.debug("[record-log]", documentId, "— ignored", type)
        }
    }

    private func opened(_ frame: [String: JSONValue]) throws {
        guard phase == .opening, let current else {
            logger?.debug("[record-log]", documentId, "— record.opened outside an open; ignored")
            return
        }
        takenRetryMs = timings.writerTakenRetryMs
        let epochs = frame["epochs"]?.objectValue ?? [:]
        let currentEpoch = epochs["current"]?.wholeNumber ?? RecordLogTransport.firstEpoch
        let high = epochs["high"]?.wholeNumber ?? currentEpoch
        let constraints = frame["constraints"]?.arrayValue?.compactMap { RecordLogConstraint(json: $0) }
        let marks = try binding.setState(
            notice: (currentEpoch, epochs["next"]?.wholeNumber ?? currentEpoch + 1, epochs["entries"]?.wholeNumber),
            constraints: constraints.map { list in list.filter { binding.constraintInForce($0.name) } }
        )
        lastSeq = frame["lastSeq"]?.wholeNumber ?? 0
        if !current.orphan && lastSeq >= marks.nextSeq {
            // The room judged numbers this writer never minted: the store is an
            // older copy of itself. Continuing would reuse those numbers.
            logger?.warn(
                "[record-log]", documentId, "— the room has judged writer", current.writer, "up to", lastSeq,
                "past the", marks.nextSeq - 1, "it minted (a restored store); re-minting"
            )
            try remint(current.writer, orphan: false)
            try sendOpen()
            return
        }
        let catchUp = frame["catchUp"]?.objectValue ?? ["mode": "inline", "lsn": frame["lsn"] ?? 0]
        let mode = catchUp["mode"]?.stringValue
        phase = .catchingUp
        if mode == "load" {
            guard let pointer = RecordLogLoadPointer(json: catchUp["load"]) else {
                return try openFailedReceipt(.load, "the load pointer does not validate")
            }
            return try startLoadReceipt(
                pointer, live: false, cursor: catchUp["cursor"]?.wholeNumber ?? marks.cursor,
                upTo: catchUp["upTo"]?.wholeNumber ?? frame["lsn"]?.wholeNumber ?? 0, high: high
            )
        }
        if mode == "segment" {
            guard let segment = RecordLogSegmentPointer(json: catchUp["segment"]) else {
                return try openFailedReceipt(.segment, "the segment pointer does not validate")
            }
            return startSegmentReceipt(segment, upTo: catchUp["upTo"]?.wholeNumber ?? frame["lsn"]?.wholeNumber ?? 0, high: high)
        }
        if let marker = marks.receipt, mode != "full" {
            // A receipt did not complete: its committed chunks may hold a row the
            // room refused, which rows changed after the cursor never correct. The
            // whole table replaces them.
            let upTo = catchUp["upTo"]?.wholeNumber ?? catchUp["lsn"]?.wholeNumber ?? frame["lsn"]?.wholeNumber ?? 0
            logger?.log(
                "[record-log] \(documentId): the \(marker.kind.rawValue) receipt \(marker.id) did not complete; "
                    + "walking the room's whole table (to \(upTo))"
            )
            let replacing = try binding.withOperation { try binding.store.beginFencedCatchUp(writer: current.writer, full: true) }
            let paging = Paging(cursor: 0, upTo: upTo, full: true, high: high, generation: replacing)
            self.paging = paging
            send(catchUpRequest(paging, after: nil))
            return
        }
        if mode == "paged" {
            let full = catchUp["full"]?.boolValue == true
            let replacing = try binding.withOperation { try binding.store.beginFencedCatchUp(writer: current.writer, full: full) }
            let paging = Paging(
                cursor: catchUp["cursor"]?.wholeNumber ?? 0, upTo: catchUp["upTo"]?.wholeNumber ?? 0, full: full, high: high,
                generation: replacing
            )
            self.paging = paging
            send(catchUpRequest(paging, after: nil))
            return
        }
        let full = mode == "full"
        let lsn = catchUp["lsn"]?.wholeNumber ?? frame["lsn"]?.wholeNumber ?? 0
        let replacing = try binding.withOperation { try binding.store.beginFencedCatchUp(writer: current.writer, full: full) }
        let page = try applyPage(catchUp, lsn: lsn, writer: current.writer, generation: replacing)
        if page.stale { return try overtaken(lsn: lsn, cursor: page.cursor, replacing: replacing) }
        let done = try complete(lsn: lsn, high: high, full: full, writer: current.writer, generation: replacing)
        if done.stale { return try overtaken(lsn: lsn, cursor: done.cursor, replacing: replacing) }
        if full { failedReceipts = 0 }
        try caughtUp(done.acknowledged)
    }

    private func catchUpRequest(_ paging: Paging, after: JSONValue?) -> JSONValue {
        var request: [String: JSONValue] = [
            "type": "record.catchUp", "cursor": .number(Double(paging.cursor)), "upTo": .number(Double(paging.upTo)),
        ]
        if paging.full { request["full"] = true }
        if let receipt = paging.receipt, receipt.kind == .load { request["load"] = .string(receipt.id) }
        if let after { request["after"] = after }
        return .object(request)
    }

    private func applyPage(
        _ page: [String: JSONValue], lsn: Int, writer: String, generation: Int?
    ) throws -> RecordLogChangeReply {
        let rows = (page["rows"]?.arrayValue ?? []).compactMap { row -> RecordLogCatchUpRow? in
            guard let model = row["model"]?.stringValue, let id = row["id"]?.stringValue else { return nil }
            return RecordLogCatchUpRow(model: model, id: id, row: row["row"]?.objectValue ?? ["id": .string(id)])
        }
        let gone = (page["gone"]?.arrayValue ?? []).compactMap(RecordLogRecordKey.init(json:))
        let reply = try binding.withOperation {
            try binding.store.applyCatchUpPage(
                writer: writer, rows: rows, gone: gone, lsn: lsn, generation: generation, project: binding.projectionSpecs
            )
        }
        notify(reply.changed)
        return reply
    }

    private func complete(
        lsn: Int, high: Int, full: Bool, writer: String, generation: Int?, receipt: String? = nil
    ) throws -> RecordLogChangeReply {
        let reply = try binding.withOperation {
            try binding.store.completeCatchUp(
                writer: writer, lsn: lsn, high: high, full: full, generation: generation, receipt: receipt,
                project: binding.projectionSpecs
            )
        }
        notify(reply.changed)
        return reply
    }

    private func notify(_ changed: [RecordLogRowChange]) {
        guard !changed.isEmpty else { return }
        binding.notify(changed.map { RecordLogRecordKey(model: $0.model, id: $0.id) })
    }

    /// Another client of this store applied results past the log number the
    /// room read this catch-up at, or began a replacement of its own: its rows
    /// are older than the store's, and nothing of it was applied. The open
    /// starts over from the store's cursor (`replacing` was this catch-up's
    /// replacement generation).
    private func overtaken(lsn: Int, cursor: Int, replacing: Int?) throws {
        logger?.log(
            "[record-log] \(documentId): the store's cursor \(cursor) passed this catch-up's \(lsn), or another client of "
                + "the store began replacing it; opening again from the cursor"
        )
        paging = nil
        stopReceipt()
        try openAfterReplacement(replacing)
    }

    /// Open again from the cursor, once another client's replacement of the
    /// store that overtook this one (`replacing` was this one's generation) has
    /// completed: beginning a replacement now would overtake that one in turn,
    /// and the two could go on overtaking each other. The wait reports
    /// progress, and ends after ``RecordLogSessionTimings/replacementWaitMs``
    /// with the other taken to be gone. A disconnect or any other open ends it.
    private func openAfterReplacement(_ replacing: Int?) throws {
        let marks = try binding.refreshMarks()
        guard marks.replacing, marks.replacement != replacing else { return try sendOpen() }
        logger?.log(
            "[record-log] \(documentId): waiting for another client of the store to complete its replacement before opening again"
        )
        let deadline = Date().addingTimeInterval(Double(timings.replacementWaitMs) / 1000)
        waitForReplacement(replacing, opens: opens, deadline: deadline)
    }

    private func waitForReplacement(_ replacing: Int?, opens waiting: Int, deadline: Date) {
        replacementTimer?.cancel()
        replacementTimer = after(timings.replacementPollMs) { session in
            session.replacementTimer = nil
            // Another open went (or the connection went, which `after` checks): the wait is over.
            guard session.opens == waiting, session.current != nil else { return }
            session.attempt("replacement wait") {
                let now = try session.binding.refreshMarks()
                let other = now.replacing && now.replacement != replacing
                if other && Date() < deadline {
                    session.host.progress(session.documentId)
                    session.waitForReplacement(replacing, opens: waiting, deadline: deadline)
                    return
                }
                if other {
                    session.logger?.warn(
                        "[record-log] \(session.documentId): the other client's replacement did not complete within "
                            + "\(session.timings.replacementWaitMs) ms; it is taken to be gone, opening again from the cursor"
                    )
                }
                try session.sendOpen()
            }
        }
    }

    private func catchUpPage(_ frame: [String: JSONValue]) throws {
        guard phase == .catchingUp || phase == .loading, let paging, let current else { return }
        let receipt = paging.receipt
        if paging.released {
            logger?.log("[record-log]", documentId, "— a catch-up page requested before the room released the subscription; discarded")
            self.paging = nil
            stopReceipt()
            return try sendOpen()
        }
        if frame["restart"]?.boolValue == true {
            if let receipt {
                return try receiptFailed(receipt, "the room answered the remainder restart (its floor passed the cursor)")
            }
            logger?.log("[record-log]", documentId, "— catch-up restarts; the room's floor passed the cursor")
            self.paging = nil
            return try sendOpen()
        }
        let lsn = frame["lsn"]?.wholeNumber ?? 0
        let page = try applyPage(frame, lsn: lsn, writer: current.writer, generation: paging.generation)
        if page.stale { return try overtaken(lsn: lsn, cursor: page.cursor, replacing: paging.generation) }
        receipt?.remainderRows += (frame["rows"]?.arrayValue?.count ?? 0) + (frame["gone"]?.arrayValue?.count ?? 0)
        host.progress(documentId)
        if let next = frame["next"] {
            send(catchUpRequest(paging, after: next))
            return
        }
        self.paging = nil
        let full = paging.generation != nil
        let done = try complete(
            lsn: lsn, high: paging.high, full: full, writer: current.writer, generation: paging.generation,
            receipt: receipt?.attempt
        )
        if done.stale { return try overtaken(lsn: lsn, cursor: done.cursor, replacing: paging.generation) }
        if full { failedReceipts = 0 }
        if let receipt { receiptDone(receipt) }
        try caughtUp(done.acknowledged)
    }

    /// The room answered a catch-up page request with an error: no page is
    /// coming, so the open starts over from the unchanged cursor after a backoff.
    private func catchUpFailed(_ frame: [String: JSONValue]) {
        let wait = catchUpRetryMs
        catchUpRetryMs = min(catchUpRetryMs * 2, 30_000)
        logger?.warn(
            "[record-log] catch-up failed", documentId, "— record.catchUp answered",
            frame["code"]?.stringValue ?? "an error", "; opening again from the cursor in", wait, "ms"
        )
        paging = nil
        heldResults = []
        phase = .idle
        current = nil
        retryTimer?.cancel()
        retryTimer = after(wait) { session in
            session.retryTimer = nil
            session.start()
        }
    }

    /// The catch-up is complete: results held meanwhile apply, then the writer's entries go.
    private func caughtUp(_ acknowledged: [RecordLogEntryRef]) throws {
        guard let current else { return }
        catchUpRetryMs = timings.catchUpRetryMs
        clearGap()
        settleAcknowledged(acknowledged)
        let held = heldResults
        heldResults = []
        phase = current.orphan ? .draining : .open
        for items in held { try applyResults(items) }
        let unsent = try binding.store.pendingOf(current.writer).filter { $0.acked == nil }
        // Entries handed back without the room hearing of it leave a gap the
        // room would wait on; tell it where this writer goes on from.
        let first = try unsent.first?.seq ?? binding.refreshMarks().nextSeq
        let resumeAt = current.orphan ? (unsent.isEmpty ? 0 : first) : first
        if resumeAt > lastSeq + 1 {
            send(RecordLogUpFrame.resume(nextSeq: resumeAt, records: nil).json)
        }
        if current.orphan {
            try drain(current.writer, unsent)
            return
        }
        // Opened again on this connection (a gap, a restart): what was in flight
        // is sent again, so the room answers it with what it made of it.
        sender.requeueInFlight(unsent.map(\.wire))
        declaredVersion = binding.declarationVersion
        sender.enqueueControl(.declare(models: host.declarations()))
        for entry in unsent { sender.enqueue(entry.wire) }
        sender.kick()
        host.synced(documentId)
        if reopenAfterCatchUp {
            // A load aborted or failed while this catch-up ran: the rows it
            // applied before it stopped come with the next.
            reopenAfterCatchUp = false
            return try sendOpen()
        }
        try nextQueuedLoad()
    }

    /// Resubmit an orphan writer's entries, wait for the room to answer each,
    /// then open the next writer.
    private func drain(_ writer: String, _ unsent: [RecordLogPendingEntry]) throws {
        outstanding = Set(unsent.map(\.seq))
        let drainSender = makeSender(orphanWriter: writer)
        orphanSender = drainSender
        for entry in unsent { drainSender.enqueue(entry.wire) }
        drainSender.kick()
        guard !outstanding.isEmpty else {
            orphanSender = nil
            return try openNext()
        }
        drainTimer = after(timings.drainWaitMs) { session in
            session.finishDrain(writer)
        }
    }

    private func finishDrain(_ writer: String) {
        drainTimer?.cancel()
        drainTimer = nil
        guard phase == .draining, current?.writer == writer else { return }
        if !outstanding.isEmpty {
            logger?.warn(
                "[record-log]", documentId, "— the room did not answer", outstanding.count,
                "entr(ies) of earlier writer", writer, "; they stay for the next session"
            )
        }
        orphanSender = nil
        attempt("drain") { try openNext() }
    }

    /// Answers for an orphan writer's entries arrived.
    private func answered(_ seqs: [Int]) {
        guard let current, current.orphan else { return }
        for seq in seqs { outstanding.remove(seq) }
        if outstanding.isEmpty, phase == .draining { finishDrain(current.writer) }
    }

    private func senderOf(_ writer: String) -> RecordLogSender? {
        guard let current, current.writer == writer else { return nil }
        return current.orphan ? orphanSender : sender
    }

    private func results(_ items: [RecordLogResultItem]) throws {
        guard !items.isEmpty else { return }
        if phase == .catchingUp || phase == .loading {
            heldResults.append(items)
            return
        }
        guard phase == .open || phase == .draining else { return }
        try applyResults(items)
    }

    private func applyResults(_ items: [RecordLogResultItem]) throws {
        let writer = current?.writer ?? binding.writer
        let reply = try binding.withOperation {
            try binding.store.receive(writer: writer, items: items, project: binding.projectionSpecs)
        }
        notify(reply.changed)
        // Every number the room answered is one its frame no longer owes.
        var seqs: [Int] = []
        for item in items {
            switch item {
            case .void(let seq), .duplicate(let seq): seqs.append(seq)
            case .result(let result):
                if result.w == writer, let seq = result.seq { seqs.append(seq) }
            }
        }
        for item in items {
            if case .result(let result) = item, result.w == binding.writer, let alias = result.alias {
                binding.noteAlias(alias)
            }
        }
        let sender = senderOf(writer)
        for seq in seqs { sender?.acknowledged(seq) }
        answered(seqs)
        settleAcknowledged(reply.acknowledged)
        watchGap(cursor: reply.cursor, items: items)
    }

    /// This client's writer's entries the room acknowledged: confirmed, and their waiters resolve.
    private func settleAcknowledged(_ acknowledged: [RecordLogEntryRef]) {
        let own = binding.writer
        let seqs = acknowledged.filter { $0.writer == own }.map(\.seq)
        guard !seqs.isEmpty else { return }
        let touched = binding.acknowledged(seqs)
        if !touched.isEmpty { binding.notify(touched) }
    }

    private func refused(_ refusal: RecordLogRefusal) throws {
        guard let current else { return }
        if phase == .opening || phase == .idle {
            // Sent for the subscription this open replaces: its numbers are not
            // the ones the next open resubmits, and a resubmission replays a
            // real refusal.
            logger?.debug("[record-log]", documentId, "— dropped a refusal of", refusal.seq, "that arrived before record.opened")
            return
        }
        let writer = current.writer
        let reply = try binding.withOperation {
            try binding.store.refused(writer: writer, refusal: refusal, project: binding.projectionSpecs)
        }
        notify(reply.changed)
        let sender = senderOf(writer)
        var after: [Int: RecordLogPendingEntry] = [:]
        for entry in try binding.store.pendingOf(writer) { after[entry.seq] = entry }
        // The refusal is the room's answer to the refused number: the marker left
        // in its place, or a withdrawn entry's marker it answers, waits on nothing.
        if after[refusal.seq]?.isVoid == true {
            try binding.withOperation { try binding.store.settled(writer: writer, seq: refusal.seq) }
            after[refusal.seq] = nil
        }
        for frame in reply.frames { sender?.enqueueControl(frame) }
        for entry in reply.handedBack {
            let marker = after[entry.seq]
            sender?.withdraw(entry.seq, replacement: marker?.isVoid == true ? marker?.wire : nil)
        }
        sender?.acknowledged(refusal.seq)
        answered([refusal.seq] + reply.handedBack.map(\.seq))
        let handed = reply.handedBack.filter { !$0.isVoid }
        guard !handed.isEmpty else {
            logger?.debug("[record-log]", documentId, "— refusal of", refusal.seq, "(\(refusal.code)) withdrew nothing new")
            return
        }
        handBack(writer: writer, handed, refusal)
    }

    /// Writes the room or the client will not apply go back to the app, once per refusal.
    private func handBack(writer: String, _ handed: [RecordLogPendingEntry], _ refusal: RecordLogRefusal) {
        let codeText = RecordLogHandBackCode.all.contains(refusal.code) ? refusal.code : codeOfScope(refusal)
        let code = JsBaoErrorCode(rawValue: codeText) ?? .documentConstraintViolated
        var details: [String: JSONValue] = [
            "documentId": .string(documentId), "scope": .string(refusal.scope.rawValue),
            "from": .number(Double(refusal.from)), "seq": .number(Double(refusal.seq)),
        ]
        if let constraint = refusal.constraint { details["constraint"] = .string(constraint) }
        if let conflicting = refusal.conflicting { details["conflicting"] = conflicting.json }
        let error = JsBaoError(
            code: code, message: refusal.message ?? Self.message(code: code, documentId: documentId), details: details
        )
        let writes = handed.flatMap(\.refusedWrites)
        logger?.warn(
            "[record-log] write-refused", documentId, "—", code.rawValue, "handed back", handed.count,
            "entr(ies) of writer", writer, "from", refusal.from
        )
        if writer == binding.writer {
            let touched = binding.handBack(handed.map(\.seq), error: error)
            binding.notify(touched)
        }
        guard let first = writes.first else { return }
        binding.reportRefused(DocumentWriteRefusedEvent(
            documentId: documentId, model: first.model, recordId: first.recordId, error: error,
            writes: writes, conflictingRecord: refusal.conflicting
        ))
    }

    /// The code to hand back with when the room's refusal names a run it refused
    /// only because an earlier entry was: a record's run is a constraint's, a
    /// writer's run is the window's.
    private func codeOfScope(_ refusal: RecordLogRefusal) -> String {
        logger?.warn("[record-log]", documentId, "— refusal", refusal.code, "of", refusal.seq, "handed back writes its first refusal never did")
        return refusal.scope == .record ? "DOCUMENT_CONSTRAINT_VIOLATED" : "DOCUMENT_OFFLINE_WINDOW_EXPIRED"
    }

    private static func message(code: JsBaoErrorCode, documentId: String) -> String {
        switch code {
        case .documentConstraintViolated:
            return "A write to '\(documentId)' broke a unique constraint another write holds; it was withdrawn."
        case .documentOfflineWindowExpired:
            return "This client was away from '\(documentId)' longer than its offline window; its unsent writes were not applied."
        case .documentEpochFrozen:
            return "The writes to '\(documentId)' were made in an epoch the room has frozen; they were not applied."
        default:
            return "Writes to '\(documentId)' were refused (\(code.rawValue))."
        }
    }

    private func gap(_ expected: Int) throws {
        guard let current else { return }
        logger?.log("[record-log]", documentId, "— the room is missing entries from", expected, "; resending")
        let unjudged = try binding.store.pendingOf(current.writer).filter { $0.acked == nil }.map(\.wire)
        senderOf(current.writer)?.resendFrom(expected, entries: unjudged)
    }

    /// The room dropped this connection's subscription (a delivery to it
    /// failed): nothing more is coming, so the writer is opened again from the
    /// cursor. Mid paged catch-up, a page request is out: the open goes again
    /// once that answer is in, and the page is discarded.
    private func released(_ frame: [String: JSONValue]) throws {
        guard current != nil, phase != .idle, phase != .closed else { return }
        logger?.warn(
            "[record-log]", documentId, "— the room released this connection's subscription (",
            frame["reason"]?.stringValue ?? "no reason given", "); opening again from the cursor"
        )
        clearGap()
        if phase == .catchingUp || phase == .loading, paging != nil {
            paging?.released = true
            return
        }
        if let receipt, paging == nil {
            // Its chunks are being fetched: the one in flight completes, then
            // the receipt stops and the document opens again.
            receipt.released = true
            return
        }
        paging = nil
        try sendOpen()
    }

    private func error(_ frame: [String: JSONValue]) throws {
        let code = frame["code"]?.stringValue ?? ""
        logger?.warn(
            "[record-log]", documentId, "—", frame["messageType"]?.stringValue ?? "record frame", "answered", code,
            ":", frame["message"]?.stringValue ?? ""
        )
        guard let current else { return }
        if frame["messageType"]?.stringValue == "record.catchUp", let receipt = paging?.receipt {
            return try receiptFailed(receipt, "the remainder was answered \(code.isEmpty ? "an error" : code)")
        }
        if frame["messageType"]?.stringValue == "record.catchUp", phase == .catchingUp {
            return catchUpFailed(frame)
        }
        switch code {
        case "WRITER_UNKNOWN":
            guard phase == .opening else { return }
            try remint(current.writer, orphan: current.orphan)
            try sendOpen()
        case "WRITER_ID_TAKEN":
            guard phase == .opening else { return }
            if current.orphan {
                logger?.log("[record-log]", documentId, "— earlier writer", current.writer, "is held by another connection; skipped")
                return try openNext()
            }
            let wait = takenRetryMs
            takenRetryMs = min(takenRetryMs * 2, 30_000)
            phase = .idle
            self.current = nil
            retryTimer?.cancel()
            retryTimer = after(wait) { session in
                session.retryTimer = nil
                session.start()
            }
        case "DOCUMENT_NOT_OPEN":
            if phase == .open || phase == .draining { try sendOpen() }
        case "WRITE_ACCESS_DENIED":
            try binding.setState(permission: .some("read"))
            let pending = try binding.store.pendingOf(current.writer).filter { !$0.isVoid && $0.acked == nil }
            guard let from = frame["from"]?.wholeNumber ?? pending.first?.seq else { return }
            let refusal = RecordLogRefusal(
                seq: from, code: "WRITE_ACCESS_DENIED", scope: .writer, from: from,
                message: "This document is read-only for you now; the writes were not applied."
            )
            let reply = try binding.withOperation {
                try binding.store.refused(writer: current.writer, refusal: refusal, project: binding.projectionSpecs)
            }
            notify(reply.changed)
            let sender = senderOf(current.writer)
            for entry in reply.handedBack {
                sender?.withdraw(entry.seq)
                sender?.acknowledged(entry.seq)
            }
            answered(reply.handedBack.map(\.seq))
            let handed = reply.handedBack.filter { !$0.isVoid }
            if !handed.isEmpty { handBack(writer: current.writer, handed, refusal) }
        default:
            if phase == .opening {
                phase = .idle
                self.current = nil
                host.syncFailed(documentId, code.isEmpty ? "error" : code)
            }
        }
    }

    // MARK: - Receipts of chunks

    /// A `record.load` frame. `started`: a load is applying, so results wait
    /// behind its numbers and no gap re-open is due. `complete`: its pointer is
    /// received now when the document is open, after the open in progress
    /// otherwise. `aborted` / `failed`: the room never points across it, so the
    /// document opens again from the cursor and takes rows.
    private func load(_ frame: [String: JSONValue]) throws {
        guard let sessionId = frame["sessionId"]?.stringValue, !sessionId.isEmpty else { return }
        let stage = frame["phase"]?.stringValue ?? ""
        switch stage {
        case "started":
            if loadInProgress == sessionId { return }
            if receipt?.id == sessionId {
                logger?.debug("[record-log] \(documentId): load \(sessionId) is being received; started ignored")
                return
            }
            loadInProgress = sessionId
            clearGap()
            logger?.log("[record-log] \(documentId): load \(sessionId) is applying; results wait behind it")
        case "complete":
            guard let pointer = RecordLogLoadPointer(json: .object(frame)) else { return }
            if receipt?.id == sessionId || queuedLoads.contains(where: { $0.sessionId == sessionId }) {
                logger?.debug("[record-log] \(documentId): load \(sessionId) is already being received; duplicate dropped")
                return
            }
            queuedLoads.append(pointer)
            try nextQueuedLoad()
        case "aborted", "failed":
            if loadInProgress == sessionId { loadInProgress = nil }
            queuedLoads.removeAll { $0.sessionId == sessionId }
            logger?.log("[record-log] \(documentId): load \(sessionId) \(stage); opening again from the cursor")
            if phase == .open || phase == .draining {
                clearGap()
                try sendOpen()
            } else if phase == .catchingUp || phase == .loading {
                reopenAfterCatchUp = true
            }
        default:
            logger?.debug("[record-log] \(documentId): ignored record.load \(stage)")
        }
    }

    /// Receive the next completed load announced while the session was busy,
    /// if the cursor is still below it.
    private func nextQueuedLoad() throws {
        while phase == .open && receipt == nil && !queuedLoads.isEmpty {
            try startLoadReceipt(queuedLoads.removeFirst(), live: true, cursor: 0, upTo: 0, high: 0)
        }
    }

    /// Whether `receipt` is still the one in progress on this connection.
    private func receiving(_ receipt: Receipt) -> Bool {
        self.receipt === receipt && generation == receipt.connection && phase != .closed
    }

    /// The connection, when it can fetch artifacts; a receipt fails without one.
    private func fetcher() throws -> any RecordLogConnection {
        guard let connection = host.connection(), connection.fetchesArtifacts else {
            throw RecordLogReceiptFailure("the connection cannot fetch artifacts")
        }
        return connection
    }

    /// Begin receiving a completed load: live, from `record.load complete` on an
    /// open document, or as an open's `load` catch-up (from `cursor` to `upTo`,
    /// seeing `high`). The chunks are fetched and applied by the receipt's task
    /// (results that arrive meanwhile are held); the remainder is then paged
    /// from the cursor through it.
    private func startLoadReceipt(_ pointer: RecordLogLoadPointer, live: Bool, cursor openCursor: Int, upTo: Int, high: Int) throws {
        guard let current else { return }
        let cursor = live ? try binding.refreshMarks().cursor : openCursor
        if live {
            guard let lastLsn = pointer.lastLsn, cursor < lastLsn else {
                logger?.debug("[record-log] \(documentId): load \(pointer.sessionId) is behind the cursor \(cursor); nothing to receive")
                if loadInProgress == pointer.sessionId { loadInProgress = nil }
                return
            }
            phase = .loading
        }
        let receipt = Receipt(
            kind: .load, id: pointer.sessionId, live: live, connection: generation, writer: current.writer,
            rows: pointer.rows, chunks: pointer.chunkCount
        )
        self.receipt = receipt
        logger?.log(
            "[record-log] load receipt \(documentId): \(pointer.sessionId) \(pointer.rows) rows in \(pointer.chunkCount) chunks "
                + "(\(live ? "live" : "on reconnect")), from cursor \(cursor)"
        )
        let remainder = (cursor: cursor, upTo: live ? (pointer.lastLsn ?? cursor) : upTo, high: live ? pointer.epoch : high)
        host.progress(documentId)
        receipt.task = spawnLoadReceipt(receipt, pointer, remainder)
    }

    /// Begin receiving a segment, an open's `segment` catch-up: a replacement
    /// of the table with its chunks, its corrections, then the pages of what
    /// changed after its `completedLsn`, completed at the last page.
    private func startSegmentReceipt(_ segment: RecordLogSegmentPointer, upTo: Int, high: Int) {
        guard let current else { return }
        let receipt = Receipt(
            kind: .segment, id: segment.segmentId, live: false, connection: generation, writer: current.writer,
            rows: segment.rows, chunks: segment.chunks.count
        )
        self.receipt = receipt
        logger?.log(
            "[record-log] segment receipt \(documentId): \(segment.segmentId) \(segment.rows) rows in \(segment.chunks.count) "
                + "chunks at \(segment.lsn), corrections to \(segment.completedLsn)"
        )
        host.progress(documentId)
        receipt.task = spawnSegmentReceipt(receipt, segment, upTo: upTo, high: high)
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? RecordLogReceiptFailure { return failure.reason }
        if let chunk = error as? RecordLogChunkError { return chunk.description }
        if let artifact = error as? RecordLogArtifactError { return artifact.description }
        if let jsBao = error as? JsBaoError { return jsBao.message }
        return error.localizedDescription
    }

    /// A receipt completed: the failure count resets, and its end is logged.
    private func receiptDone(_ receipt: Receipt) {
        if self.receipt === receipt { self.receipt = nil }
        failedReceipts = 0
        if loadInProgress == receipt.id { loadInProgress = nil }
        let ms = Int(Date().timeIntervalSince(receipt.startedAt) * 1000)
        logger?.log(
            "[record-log] \(receipt.kind.rawValue) received \(documentId): \(receipt.id) \(receipt.rows) rows in "
                + "\(receipt.chunks) chunks, remainder \(receipt.remainderRows) rows, \(ms) ms"
        )
    }

    /// A receipt cannot go on: what it committed stays (the store's marker says
    /// so), and the session opens again from the unchanged cursor. Two failures
    /// in a row make the next open take rows only.
    private func receiptFailed(_ receipt: Receipt, _ reason: String) throws {
        guard receiving(receipt) else { return }
        failedReceipts += 1
        logger?.warn(
            "[record-log] \(receipt.kind.rawValue) receipt failed \(documentId): \(receipt.id) \(reason); opening again from the cursor"
        )
        self.receipt = nil
        paging = nil
        heldResults = []
        if loadInProgress == receipt.id { loadInProgress = nil }
        if current != nil { try sendOpen() }
    }

    /// A pointer an open's catch-up named does not validate: a failed receipt.
    private func openFailedReceipt(_ kind: RecordLogReceiptKind, _ reason: String) throws {
        failedReceipts += 1
        logger?.warn("[record-log] \(kind.rawValue) receipt failed \(documentId): \(reason); opening again from the cursor")
        heldResults = []
        try sendOpen()
    }

    /// A receipt was overtaken, ended by the store or released: no failure is
    /// counted, and the open goes again from the cursor; one another client's
    /// replacement overtook (`replacing` was its generation) waits for that
    /// replacement first.
    private func abandonReceipt(_ receipt: Receipt, _ why: String, replacing: Int? = nil) throws {
        guard receiving(receipt) else { return }
        logger?.log(
            "[record-log] \(documentId): \(receipt.kind.rawValue) receipt \(receipt.id) abandoned (\(why)); opening again from the cursor"
        )
        self.receipt = nil
        paging = nil
        heldResults = []
        guard current != nil else { return }
        if let replacing {
            try openAfterReplacement(replacing)
        } else {
            try sendOpen()
        }
    }

    /// Replace a writer the room does not know (or a restored store's): a new
    /// id, its entries renumbered from 1, what waits on them following them.
    private func remint(_ writer: String, orphan: Bool) throws {
        let reminted = try binding.withOperation { try binding.store.remintWriter(writer) }
        let fresh = reminted.writer
        let renumbered = reminted.renumbered
        logger?.log("[record-log]", documentId, "— writer", writer, "re-minted as", fresh)
        if !orphan {
            // What the sender holds carries the old numbers: queued entries
            // would go under the new writer with another entry's number, and
            // in-flight numbers would hold a frame no answer frees. The open
            // that follows sends every renumbered entry again.
            ownSender?.reset()
            binding.reminted(writer: fresh, renumbered: renumbered)
            try binding.refreshMarks()
        }
        current = (fresh, orphan)
    }

    /// A model was registered on the open document: the room hears its
    /// declaration before any entry of it.
    func declare() {
        declareIfChanged()
    }

    private func declareIfChanged() {
        guard phase == .open else { return }
        let version = binding.declarationVersion
        guard version != declaredVersion else { return }
        declaredVersion = version
        sender.enqueueControl(.declare(models: host.declarations()))
    }

    /// This writer's entries committed: they go to the room once the document is open.
    private func committed(_ entries: [RecordLogPendingEntry]) {
        guard phase == .open else { return }
        declareIfChanged()
        for entry in entries { sender.enqueue(entry.wire) }
    }

    // MARK: - The receipt's task

    // Everything a receipt does that suspends lives here, outside the frame
    // handlers: its task fetches and reads chunks off the session and comes
    // back to it for each store step, checking that the receipt and its
    // connection are still current after every suspension.

    private func spawnLoadReceipt(
        _ receipt: Receipt, _ pointer: RecordLogLoadPointer, _ remainder: (cursor: Int, upTo: Int, high: Int)
    ) -> Task<Void, Never> {
        Task { await self.receiveLoadChunks(receipt, pointer, remainder) }
    }

    private func spawnSegmentReceipt(_ receipt: Receipt, _ segment: RecordLogSegmentPointer, upTo: Int, high: Int) -> Task<Void, Never> {
        Task { await self.receiveSegment(receipt, segment, upTo: upTo, high: high) }
    }

    private func receiveLoadChunks(
        _ receipt: Receipt, _ pointer: RecordLogLoadPointer, _ remainder: (cursor: Int, upTo: Int, high: Int)
    ) async {
        guard receiving(receipt), !Task.isCancelled else { return }
        do {
            // A load that wrote no row has nothing to fetch; its remainder is the rows.
            if pointer.firstLsn != nil && pointer.lastLsn != nil {
                guard let download = pointer.download else { throw RecordLogReceiptFailure("the pointer carries no grant") }
                let base = download.path
                let connection = try fetcher()
                let bytes: Data
                do {
                    bytes = try await connection.fetchArtifact(base)
                } catch {
                    guard receiving(receipt) else { return }
                    throw RecordLogReceiptFailure("fetching the manifest failed: \(Self.describe(error))")
                }
                guard receiving(receipt) else { return }
                host.progress(documentId)
                let manifest = try recordLogLoadManifest(bytes, pointer: pointer)
                if receipt.released { return try abandonReceipt(receipt, "the room released the subscription") }
                let attempt = try binding.withOperation {
                    try binding.store.beginReceipt(writer: receipt.writer, kind: .load, id: pointer.sessionId).attempt
                }
                receipt.attempt = attempt
                let writer = receipt.writer
                for chunk in manifest {
                    guard receiving(receipt) else { return }
                    let applied = try await applyChunk(receipt, path: "\(base)/\(chunk.path)", read: {
                        try RecordLogChunkReader.readLoadChunk($0, chunk)
                    }, apply: { session, lines in
                        try session.binding.withOperation {
                            try session.binding.store.applyLoadChunk(
                                writer: writer, sessionId: pointer.sessionId, attempt: attempt, model: chunk.model,
                                lines: lines, project: session.binding.projectionSpecs
                            )
                        }
                    })
                    guard let reply = applied, receiving(receipt) else { return }
                    if reply.stale {
                        return try abandonReceipt(receipt, "the store ended it: another client's catch-up made its rows right")
                    }
                    binding.notify(reply)
                    host.progress(documentId)
                    logger?.debug("[record-log] \(documentId): load \(pointer.sessionId) chunk \(chunk.place) applied (\(chunk.rows) rows)")
                    if receipt.released { return try abandonReceipt(receipt, "the room released the subscription") }
                }
                let completed = try binding.withOperation {
                    try binding.store.completeLoad(
                        writer: receipt.writer, sessionId: pointer.sessionId, attempt: attempt, mode: pointer.mode,
                        models: pointer.models, project: binding.projectionSpecs
                    )
                }
                if completed.stale {
                    return try abandonReceipt(receipt, "the store ended it: another client's catch-up made its rows right")
                }
                binding.notify(completed)
            }
            guard receiving(receipt) else { return }
            if receipt.released { return try abandonReceipt(receipt, "the room released the subscription") }
            let paging = Paging(cursor: remainder.cursor, upTo: remainder.upTo, full: false, high: remainder.high, receipt: receipt)
            self.paging = paging
            send(catchUpRequest(paging, after: nil))
        } catch {
            attempt("load receipt") { try receiptFailed(receipt, Self.describe(error)) }
        }
    }

    private func receiveSegment(_ receipt: Receipt, _ segment: RecordLogSegmentPointer, upTo: Int, high: Int) async {
        // The task starts after the frame handler that scheduled it returned;
        // a disconnect or a close in between leaves the store untouched.
        guard receiving(receipt), !Task.isCancelled else { return }
        do {
            guard let download = segment.download else { throw RecordLogReceiptFailure("the pointer carries no grant") }
            let base = download.path
            _ = try fetcher()
            guard segment.chunks.allSatisfy(\.pathIsRelative), !segment.corrections.path.isEmpty,
                  !segment.corrections.path.hasPrefix("/"), !segment.corrections.path.contains("..")
            else { throw RecordLogReceiptFailure("a segment chunk's path leaves the grant") }
            // The receipt is begun before its replacement, so a replacement that
            // overtakes this one counts every change this one made.
            let (attempt, generation) = try binding.withOperation { () -> (String, Int?) in
                let attempt = try binding.store.beginReceipt(writer: receipt.writer, kind: .segment, id: segment.segmentId).attempt
                return (attempt, try binding.store.beginFencedCatchUp(writer: receipt.writer, full: true))
            }
            receipt.attempt = attempt
            let writer = receipt.writer
            guard let generation else { throw RecordLogReceiptFailure("the store handed out no replacement generation") }
            for chunk in segment.chunks {
                guard receiving(receipt) else { return }
                let applied = try await applyChunk(receipt, path: "\(base)/\(chunk.path)", read: {
                    try RecordLogChunkReader.readSegmentChunk($0, chunk)
                }, apply: { session, rows in
                    try session.binding.withOperation {
                        try session.binding.store.applySegmentChunk(
                            writer: writer, generation: generation, attempt: attempt, rows: rows,
                            project: session.binding.projectionSpecs
                        )
                    }
                })
                guard let reply = applied, receiving(receipt) else { return }
                if reply.stale {
                    return try abandonReceipt(receipt, "another client of the store began replacing it", replacing: generation)
                }
                binding.notify(reply)
                host.progress(documentId)
                if receipt.released { return try abandonReceipt(receipt, "the room released the subscription") }
            }
            let corrections = segment.corrections
            let applied = try await applyChunk(receipt, path: "\(base)/\(corrections.path)", read: {
                try RecordLogChunkReader.readCorrectionsChunk($0, corrections)
            }, apply: { session, lines in
                try session.binding.withOperation {
                    try session.binding.store.applySegmentCorrections(
                        writer: writer, generation: generation, attempt: attempt, lines: lines,
                        project: session.binding.projectionSpecs
                    )
                }
            })
            guard let reply = applied, receiving(receipt) else { return }
            if reply.stale {
                return try abandonReceipt(receipt, "another client of the store began replacing it", replacing: generation)
            }
            binding.notify(reply)
            host.progress(documentId)
            // The pages from `C` belong to the replacement and to the receipt: it
            // completes at the last of them (so no result held meanwhile is
            // replayed over rows older than it), and a page that fails fails it.
            guard current != nil else { return }
            if receipt.released { return try abandonReceipt(receipt, "the room released the subscription") }
            let paging = Paging(
                cursor: segment.completedLsn, upTo: upTo, full: false, high: high, generation: generation, receipt: receipt
            )
            self.paging = paging
            send(catchUpRequest(paging, after: nil))
        } catch {
            attempt("segment receipt") { try receiptFailed(receipt, Self.describe(error)) }
        }
    }

    /// Fetch one chunk, read it off the session, and apply it on the session;
    /// a chunk failing its check is fetched once more, and a second failure
    /// fails the receipt. `nil` when the receipt stopped while the bytes were
    /// on their way: whatever corrected the store since must not be undone.
    private func applyChunk<Item: Sendable>(
        _ receipt: Receipt, path: String, read: @escaping @Sendable (Data) throws -> Item,
        apply: (isolated RecordLogSession, Item) throws -> RecordLogChunkReply
    ) async throws -> RecordLogChunkReply? {
        let connection = try fetcher()
        var tries = 1
        while true {
            let bytes: Data
            do {
                bytes = try await connection.fetchArtifact(path)
            } catch {
                guard receiving(receipt) else { return nil }
                throw RecordLogReceiptFailure("fetching \(recordLogShownPath(path)) failed: \(Self.describe(error))")
            }
            guard receiving(receipt) else { return nil }
            // Each step of a chunk is progress: a long receipt keeps the
            // client's handshake watchdog from timing out between chunks.
            host.progress(documentId)
            let decoded = await Self.decode(bytes, read)
            guard receiving(receipt) else { return nil }
            host.progress(documentId)
            switch decoded {
            case .success(let item):
                return try apply(self, item)
            case .failure(let error):
                guard error is RecordLogChunkError else { throw error }
                if tries >= 2 {
                    throw RecordLogReceiptFailure(
                        "the chunk at \(recordLogShownPath(path)) failed its check twice: \(Self.describe(error))"
                    )
                }
                logger?.warn(
                    "[record-log] \(documentId): the chunk at \(recordLogShownPath(path)) failed its check "
                        + "(\(Self.describe(error))); fetching it again"
                )
                tries += 1
            }
        }
    }

    /// Read a chunk's bytes off the session: inflating and parsing a chunk is
    /// the receipt's heaviest work, and frames keep being handled meanwhile.
    private nonisolated static func decode<Item: Sendable>(
        _ bytes: Data, _ read: @Sendable (Data) throws -> Item
    ) async -> Result<Item, Error> {
        Result { try read(bytes) }
    }

}
