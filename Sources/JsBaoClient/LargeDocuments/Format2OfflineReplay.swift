import Foundation

/// Replaying what a client wrote while it was away (#3437, behavior 19).
///
/// A port of `packages/js-bao/src/models/format2OfflineReplay.ts`.
///
/// A client reconnecting into a later epoch replays its unacknowledged writes
/// onto the epoch it lands on. Doing that unconditionally silently overwrites
/// whatever anyone else wrote in between, including writes made days after the
/// offline one. Doing it with per-field timestamps would mean stamping every
/// field of every record, in the overlay, in `records` and in every snapshot
/// chunk, for a case that is rare by construction.
///
/// Neither is necessary, because the client already holds both halves of the
/// evidence by the time it replays:
///
/// - WHAT was written online: the sealed overlays it applies while catching up
///   are precisely the touched records and fields of the epochs it missed;
/// - WHEN: an epoch's window runs from the previous epoch's seal to its own,
///   and the open epoch's ends now.
///
/// So each op's own `ts` — stamped with the client's server-offset-corrected
/// clock — is placed against the window of the epoch that touched the same
/// field. Clearly after it, the offline write wins. Clearly before it, the
/// online write wins and the offline one is DROPPED AND SURFACED rather than
/// silently applied. Inside the window the order is genuinely unknown, so the
/// offline write wins and is surfaced too.
///
/// Two rules are not recency-gated:
///
/// - a patch is never replayed onto a record deleted meanwhile — resurrecting a
///   deleted record is worse than losing an edit to it, whatever the clock says
///   (a re-create is different: `_replace` states the record exists, so it is
///   resolved on recency like any other write);
/// - an op whose base-epoch chain is unavailable (retention pruned it) cannot
///   be checked at all, so it falls back to plain offline-wins — surfaced as
///   `unverifiable` rather than silently trusted.
///
/// And nothing is ever dropped on a clock this client has no reason to trust:
/// with no measured server offset, "clearly older" degrades to the ambiguous
/// case, which keeps the write (edge E9).
public enum Format2OfflineReplay {

    /// The key a conflict and a presence map are recorded under.
    ///
    /// Joined with a NUL, exactly as js-bao does it. A model name or a record
    /// id may contain a space, and two records whose joined keys collided would
    /// be judged as one — and a caller writing `"\(model) \(recordId)"` by hand
    /// compiles, looks right, and silently never matches.
    public static func recordKey(_ model: String, _ recordId: String) -> String {
        "\(model)\u{0}\(recordId)"
    }

    /// How an offline write compares with the epoch that raced it.
    private enum Recency {
        case newer
        case older
        case inWindow
    }

    private static func classify(
        ts: Int, window: EpochWindow, clockOffsetKnown: Bool
    ) -> Recency {
        // Without a measured offset the client's clock says nothing comparable,
        // so the only safe answer is "unknown" — which keeps the write.
        guard clockOffsetKnown else { return .inWindow }
        if let end = window.end, ts > end { return .newer }
        // An unknown start cannot make anything "clearly older": there is no
        // bound to be before.
        if let start = window.start, ts < start { return .older }
        return .inWindow
    }

    /// Decide what a reconnecting client replays onto the epoch it landed on.
    ///
    /// Ops are returned in their original local order — a later op of the same
    /// record must not overtake an earlier one — with their `fields` narrowed to
    /// what survived. An op that lost everything is absent entirely.
    ///
    /// - Parameters:
    ///   - currentEpoch: the epoch being replayed onto (its window ends now).
    ///   - clockOffsetKnown: whether the op timestamps were corrected against
    ///     server time.
    ///   - ingest: what a bulk load did to these ops' records (#3435).
    public static func resolveOfflineReplay(
        ops: [PendingOp],
        ledger: OfflineConflictLedger,
        currentEpoch: Int,
        now: Int,
        clockOffsetKnown: Bool = true,
        ingest: OfflineReplayIngest? = nil
    ) -> OfflineReplayPlan {
        var kept: [PendingOp] = []
        var notices: [OfflineReplayNotice] = []
        var suppressed: [String: SuppressedDelete] = [:]
        var suppressedOrder: [String] = []
        var narrowed: [PendingOp] = []
        var rebuildRequired = false

        func windowOf(_ epoch: Int) -> EpochWindow {
            let window = ledger.window(epoch: epoch, currentEpoch: currentEpoch)
            return EpochWindow(start: window.start, end: window.end ?? now)
        }

        func notice(
            _ op: PendingOp,
            field: String? = nil,
            outcome: OfflineReplayNotice.Outcome,
            reason: OfflineReplayNotice.Reason,
            epoch: Int
        ) -> OfflineReplayNotice {
            OfflineReplayNotice(
                model: op.model, recordId: op.recordId, field: field, op: op.op,
                outcome: outcome, reason: reason, epoch: epoch, ts: op.ts
            )
        }

        for op in ops.sorted(by: { $0.seq < $1.seq }) {
            // A bulk load stands between this op and now (#3435). Asked FIRST,
            // because every such op also fails the `covers` check below — the
            // ingest's changes are in no overlay the ledger holds — and would
            // otherwise replay whole as `unverifiable`, which is precisely what
            // puts a write back onto a record the ingest deleted.
            if let ingest, op.baseEpoch <= ingest.through {
                let presence = ingest.records[recordKey(op.model, op.recordId)]
                // Under `ranges`, absent from the map means the artifact did
                // not carry this record and the ordinary rules own it. Under
                // `all` the map was meant to be complete, so a miss is missing
                // information, never a licence to drop.
                let verdict = presence ?? (ingest.scope == .all ? .present : nil)
                if verdict == .present {
                    // Kept WHOLE: the ingest replaced a range, so there is no
                    // per-field online write to weigh this one against and
                    // narrowing would drop fields on a guess.
                    kept.append(op)
                    notices.append(notice(
                        op, outcome: .keptAmbiguous, reason: .bulkIngest,
                        epoch: ingest.through
                    ))
                    continue
                }
                if verdict == .absent {
                    // A CREATE on an absent record is absent because the server
                    // never held it — an offline create at an id between two
                    // ingested ids — not because the ingest deleted it.
                    // Dropping it would discard a valid write on the strength
                    // of where its id sorts.
                    if op.op == .create {
                        kept.append(op)
                        notices.append(notice(
                            op, outcome: .keptAmbiguous, reason: .bulkIngest,
                            epoch: ingest.through
                        ))
                        continue
                    }
                    // A patch or a delete on a record that is gone. Dropped,
                    // and NOT a rebuild: a dropped delete asks for one because
                    // the local row went when it was written, but here the
                    // convergence has already replaced the whole range and the
                    // merged view is correct.
                    notices.append(notice(
                        op, outcome: .dropped, reason: .bulkIngest,
                        epoch: ingest.through
                    ))
                    continue
                }
            }

            // No chain back to where this op was written: nothing available
            // says who else touched the field, so the op replays whole (plain
            // offline-wins) and the app is told the check could not be made.
            guard ledger.covers(from: op.baseEpoch, to: currentEpoch) else {
                kept.append(op)
                notices.append(notice(
                    op, outcome: .keptAmbiguous, reason: .unverifiable, epoch: 0
                ))
                continue
            }

            if op.op == .delete {
                guard let conflict = ledger.recordConflict(
                    model: op.model, recordId: op.recordId, afterEpoch: op.baseEpoch
                ) else {
                    kept.append(op)
                    continue
                }
                let recency = classify(
                    ts: op.ts, window: windowOf(conflict.epoch),
                    clockOffsetKnown: clockOffsetKnown
                )
                if recency == .older {
                    // The record was written after this delete: the delete is
                    // dropped, and the tombstone must not ride along on the
                    // carried overlay either.
                    let key = recordKey(op.model, op.recordId)
                    if suppressed[key] == nil {
                        suppressed[key] = SuppressedDelete(
                            model: op.model, recordId: op.recordId
                        )
                        suppressedOrder.append(key)
                    }
                    // The local row went when the delete was written, so what
                    // this client now holds for the record is only what the
                    // later epochs happened to write — not the record. It needs
                    // a base to be right again.
                    rebuildRequired = true
                    notices.append(notice(
                        op, outcome: .dropped, reason: .outdated,
                        epoch: conflict.epoch
                    ))
                    continue
                }
                kept.append(op)
                if recency == .inWindow {
                    notices.append(notice(
                        op, outcome: .keptAmbiguous, reason: .inWindow,
                        epoch: conflict.epoch
                    ))
                }
                continue
            }

            // A patch onto a record deleted meanwhile is dropped whatever its
            // time: an edit lost is recoverable, a resurrected record is not.
            if op.op == .patch,
               let deleted = ledger.deletedAfter(
                   model: op.model, recordId: op.recordId, afterEpoch: op.baseEpoch
               ) {
                notices.append(notice(
                    op, outcome: .dropped, reason: .recordDeleted,
                    epoch: deleted.epoch
                ))
                continue
            }

            var survivors: [String] = []
            for field in op.fields {
                guard let conflict = ledger.conflictFor(
                    model: op.model, recordId: op.recordId, field: field,
                    afterEpoch: op.baseEpoch
                ) else {
                    survivors.append(field)
                    continue
                }
                let recency = classify(
                    ts: op.ts, window: windowOf(conflict.epoch),
                    clockOffsetKnown: clockOffsetKnown
                )
                if recency == .older {
                    notices.append(notice(
                        op, field: field, outcome: .dropped, reason: .outdated,
                        epoch: conflict.epoch
                    ))
                    continue
                }
                survivors.append(field)
                if recency == .inWindow {
                    notices.append(notice(
                        op, field: field, outcome: .keptAmbiguous,
                        reason: .inWindow, epoch: conflict.epoch
                    ))
                }
            }

            // A create carries the record whole (`_replace` discards the base
            // row), so it survives as long as the record-level race went its
            // way; a patch with nothing left to say is simply gone.
            if op.op == .create {
                let conflict = ledger.recordConflict(
                    model: op.model, recordId: op.recordId, afterEpoch: op.baseEpoch
                )
                let recency = conflict.map {
                    classify(
                        ts: op.ts, window: windowOf($0.epoch),
                        clockOffsetKnown: clockOffsetKnown
                    )
                } ?? .newer
                if conflict != nil, recency == .older {
                    notices.append(notice(
                        op, outcome: .dropped, reason: .outdated,
                        epoch: conflict?.epoch ?? 0
                    ))
                    continue
                }
                kept.append(op)
                continue
            }

            if survivors.isEmpty { continue }
            if survivors.count == op.fields.count {
                kept.append(op)
                continue
            }
            // Part of this write lost. The durable row has to say so too, or a
            // crash before the replay is acknowledged would restore the WHOLE
            // mutation — the write that lost would come back, quietly, and only
            // on the machines that crashed at the wrong moment.
            let narrowedOp = narrow(op, to: survivors)
            kept.append(narrowedOp)
            narrowed.append(narrowedOp)
        }

        return OfflineReplayPlan(
            ops: kept,
            suppressedDeletes: suppressedOrder.compactMap { suppressed[$0] },
            notices: notices,
            narrowed: narrowed,
            rebuildRequired: rebuildRequired
        )
    }

    /// The same op, restricted to the fields that survived resolution.
    static func narrow(_ op: PendingOp, to survivors: [String]) -> PendingOp {
        let keep = Set(survivors)
        guard let mutation = op.mutation else {
            return PendingOp(
                seq: op.seq, model: op.model, recordId: op.recordId, op: op.op,
                fields: survivors, baseEpoch: op.baseEpoch, ts: op.ts,
                mutation: nil, priorOverlay: op.priorOverlay
            )
        }
        return PendingOp(
            seq: op.seq, model: op.model, recordId: op.recordId, op: op.op,
            fields: survivors, baseEpoch: op.baseEpoch, ts: op.ts,
            mutation: OverlayMutation(
                id: mutation.id,
                kind: mutation.kind,
                fields: mutation.fields.filter { keep.contains($0.key) },
                stringSetDeltas: mutation.stringSetDeltas.filter {
                    keep.contains($0.key)
                }
            ),
            priorOverlay: op.priorOverlay
        )
    }
}

/// The window an epoch's writes fall in: `[start, end]`, inclusive.
public struct EpochWindow: Equatable, Sendable {
    /// The previous epoch's seal, or `nil` when it is not known.
    public let start: Int?
    /// This epoch's seal, or `nil` while it is still open.
    public let end: Int?

    public init(start: Int?, end: Int?) {
        self.start = start
        self.end = end
    }
}

/// What one epoch did to one record, from that epoch's sealed overlay.
public struct RecordTouch: Equatable, Sendable {
    /// The epoch, for reporting which write the offline one raced.
    public let epoch: Int
    public let fields: Set<String>
    public let deleted: Bool
    /// A `_replace` create: it replaced the whole row, so it touched every
    /// field.
    public let replaced: Bool

    public init(epoch: Int, fields: Set<String>, deleted: Bool, replaced: Bool) {
        self.epoch = epoch
        self.fields = fields
        self.deleted = deleted
        self.replaced = replaced
    }
}

/// What the sealed overlays a catch-up applied say about the online side.
///
/// Built as the chain is applied — the overlays are already decoded there — so
/// conflict detection costs one walk of artifacts the client was downloading
/// anyway.
public final class OfflineConflictLedger: @unchecked Sendable {

    private let lock = NSLock()
    /// Latest touch per record per epoch, newest epoch last.
    private var touches: [String: [RecordTouch]] = [:]
    private var sealedAt: [Int: Int] = [:]
    private var notedEpochs: Set<Int> = []

    public init() {}

    /// Record the seal times the handshake reported.
    public func noteSealTimes(_ times: [(epoch: Int, sealedAt: Int?)]) {
        lock.withLock {
            for entry in times {
                guard let at = entry.sealedAt else { continue }
                sealedAt[entry.epoch] = at
            }
        }
    }

    /// Record that this epoch's whole overlay was read through this ledger,
    /// whether or not it touched anything.
    ///
    /// What makes ``covers(from:to:)`` true for it: an epoch that was applied
    /// and changed nothing is as much a covered link of the chain as one that
    /// rewrote every record.
    public func noteEpoch(_ epoch: Int) {
        lock.withLock { _ = notedEpochs.insert(epoch) }
    }

    /// Note one record's overlay entry from `epoch`.
    public func noteEntry(epoch: Int, model: String, entry: OverlayRecordEntry) {
        lock.withLock {
            notedEpochs.insert(epoch)
            let key = Format2OfflineReplay.recordKey(model, entry.id)
            var list = touches[key] ?? []
            var fields: Set<String> = []
            var deleted = false
            var replaced = false
            if let index = list.firstIndex(where: { $0.epoch == epoch }) {
                fields = list[index].fields
                deleted = list[index].deleted
                replaced = list[index].replaced
                list.remove(at: index)
            }
            fields.formUnion(entry.fields.keys)
            fields.formUnion(entry.stringSets.keys)
            if entry.deleted { deleted = true }
            if entry.replace { replaced = true }
            list.append(RecordTouch(
                epoch: epoch, fields: fields, deleted: deleted, replaced: replaced
            ))
            list.sort { $0.epoch < $1.epoch }
            touches[key] = list
        }
    }

    /// Note everything one sealed epoch's decoded overlay touched.
    ///
    /// - Parameter models: the model maps to read. The Swift overlay wrapper
    ///   knows only the models something has asked it for, so the caller —
    ///   which holds the schema — names them, exactly as the fold does.
    public func noteOverlay(
        epoch: Int, _ overlay: OverlayDocument, models: [String]
    ) {
        noteEpoch(epoch)
        for model in models {
            let entries = overlay.entries(model: model)
            guard !entries.isEmpty else { continue }
            for entry in OverlayKeys.group(entries).values {
                noteEntry(epoch: epoch, model: model, entry: entry)
            }
        }
    }

    /// Whether every epoch from `from` up to (but not including) `to` was
    /// applied through this ledger — the chain an op's conflicts would have to
    /// be in.
    public func covers(from: Int, to: Int) -> Bool {
        guard from > 0 else { return false }
        return lock.withLock {
            var epoch = from
            while epoch < to {
                if !notedEpochs.contains(epoch) { return false }
                epoch += 1
            }
            return true
        }
    }

    /// The window `epoch`'s writes fall in; `end` is `nil` while it is open.
    public func window(epoch: Int, currentEpoch: Int) -> EpochWindow {
        lock.withLock {
            EpochWindow(
                start: sealedAt[epoch - 1],
                end: epoch >= currentEpoch ? nil : sealedAt[epoch]
            )
        }
    }

    /// The latest epoch after `afterEpoch` that touched `field` of a record.
    public func conflictFor(
        model: String, recordId: String, field: String, afterEpoch: Int
    ) -> RecordTouch? {
        lock.withLock {
            guard let list = touches[Format2OfflineReplay.recordKey(model, recordId)]
            else { return nil }
            for touch in list.reversed() {
                if touch.epoch <= afterEpoch { break }
                if touch.replaced || touch.deleted || touch.fields.contains(field) {
                    return touch
                }
            }
            return nil
        }
    }

    /// The latest epoch after `afterEpoch` that touched a record at all.
    public func recordConflict(
        model: String, recordId: String, afterEpoch: Int
    ) -> RecordTouch? {
        lock.withLock {
            guard let list = touches[Format2OfflineReplay.recordKey(model, recordId)]
            else { return nil }
            for touch in list.reversed() {
                if touch.epoch <= afterEpoch { break }
                return touch
            }
            return nil
        }
    }

    /// The latest epoch after `afterEpoch` that DELETED a record.
    public func deletedAfter(
        model: String, recordId: String, afterEpoch: Int
    ) -> RecordTouch? {
        lock.withLock {
            guard let list = touches[Format2OfflineReplay.recordKey(model, recordId)]
            else { return nil }
            for touch in list.reversed() {
                if touch.epoch <= afterEpoch { break }
                if touch.deleted { return touch }
            }
            return nil
        }
    }
}

/// What the app is told about an offline write that did not simply apply.
public struct OfflineReplayNotice: Equatable, Sendable {

    public enum Outcome: String, Equatable, Sendable {
        case dropped
        case keptAmbiguous = "kept-ambiguous"
    }

    public enum Reason: String, Equatable, Sendable {
        /// An online write to the same field is clearly newer.
        case outdated
        /// The record was deleted meanwhile.
        case recordDeleted = "record-deleted"
        /// The order is genuinely unknown, so the offline write won.
        case inWindow = "in-window"
        /// Retention pruned the chain this op would have been checked against.
        case unverifiable
        /// A bulk load replaced the range this record sits in (#3435).
        ///
        /// One reason for both outcomes, because the fact is the same one: the
        /// server's rows over this range were replaced wholesale and no overlay
        /// describes it. The OUTCOME says what happened — `dropped` when the
        /// record is gone afterwards, `keptAmbiguous` when it is still there
        /// and the write was replayed over it.
        case bulkIngest
    }

    public let model: String
    public let recordId: String
    /// Absent for a whole-record outcome (a delete, or a dropped patch).
    public let field: String?
    public let op: PendingOp.Kind
    public let outcome: Outcome
    public let reason: Reason
    /// The epoch whose write it raced; `0` when there was no chain to check.
    public let epoch: Int
    /// The offline write's own time, as the client stamped it.
    public let ts: Int

    public init(
        model: String,
        recordId: String,
        field: String?,
        op: PendingOp.Kind,
        outcome: Outcome,
        reason: Reason,
        epoch: Int,
        ts: Int
    ) {
        self.model = model
        self.recordId = recordId
        self.field = field
        self.op = op
        self.outcome = outcome
        self.reason = reason
        self.epoch = epoch
        self.ts = ts
    }
}

/// A record whose carried overlay must NOT bring its tombstone along.
public struct SuppressedDelete: Equatable, Sendable {
    public let model: String
    public let recordId: String

    public init(model: String, recordId: String) {
        self.model = model
        self.recordId = recordId
    }
}

/// What the epoch handoff replays, after recency has had its say.
public struct OfflineReplayPlan: Equatable, Sendable {
    /// The surviving ops, in the client's original local order.
    public let ops: [PendingOp]
    public let suppressedDeletes: [SuppressedDelete]
    public let notices: [OfflineReplayNotice]
    /// Ops that survived in PART — the durable `_pending_ops` row still records
    /// the whole write and has to be rewritten to what survived.
    public let narrowed: [PendingOp]
    /// Whether a dropped write leaves this client's merged view unable to state
    /// the record correctly.
    ///
    /// A dropped DELETE is the case: the row was removed locally when the
    /// delete was written, and the online writes folded on top of that absence
    /// created the record again from their own fields alone. The fields the
    /// delete removed live only in the base and the epochs before it, so no
    /// artifact this client still holds can restore them — the merged view has
    /// to be rebuilt from a base before the delete is abandoned.
    public let rebuildRequired: Bool

    public init(
        ops: [PendingOp],
        suppressedDeletes: [SuppressedDelete],
        notices: [OfflineReplayNotice],
        narrowed: [PendingOp],
        rebuildRequired: Bool
    ) {
        self.ops = ops
        self.suppressedDeletes = suppressedDeletes
        self.notices = notices
        self.narrowed = narrowed
        self.rebuildRequired = rebuildRequired
    }
}

/// What a bulk load did to the records a client's owed writes name (#3435).
///
/// Built by the caller AFTER the convergence has landed, because presence is
/// only a fact once the ranges have been replaced. The recency machinery cannot
/// answer for these ops at all: it works from the sealed overlays the catch-up
/// folded, and an ingest's changes are in none of them.
public struct OfflineReplayIngest: Sendable {

    public enum Presence: String, Equatable, Sendable {
        case absent
        case present
    }

    /// What `records` covers.
    public enum Scope: String, Equatable, Sendable {
        /// Only the records inside a touched range, so one that is ABSENT from
        /// the map is one the artifact provably did not carry and the ordinary
        /// rules own it.
        case ranges
        /// Every pending op's record, because the caller could not name the
        /// ranges of every ingest it crossed. A record missing from that map is
        /// a fact nobody has, and a write is never discarded on missing
        /// information.
        case all
    }

    /// The HIGHEST bulk-load epoch this client crossed. An op written at or
    /// below it may have raced the ingest; one above it cannot.
    public let through: Int
    public let scope: Scope
    /// Presence per ``Format2OfflineReplay/recordKey(_:_:)``, read once for
    /// exactly the records these ops name.
    public let records: [String: Presence]

    public init(through: Int, scope: Scope, records: [String: Presence]) {
        self.through = through
        self.scope = scope
        self.records = records
    }
}
