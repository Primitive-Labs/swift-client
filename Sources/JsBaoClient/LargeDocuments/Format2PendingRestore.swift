import Foundation

/// What a restore pass decided about one adopted op (#3437, behavior 5).
///
/// A verdict per op would be too coarse, because one op writes several keys
/// and they are not superseded together: a create of `{title, body}` followed
/// by a patch of `title` leaves the merged row holding the patch's title and
/// the create's body, so read key by key the create's title lost and its body
/// is still owed. Skipping the whole create would deliver the title and
/// silently drop the body — a write the app was told was saved, delivered to
/// nobody. Hence ``fragment(mutation:keep:)``.
public enum PendingRestoreVerdict: Equatable, Sendable {
    /// Re-apply the op whole.
    case restore
    /// The overlay already holds every key it wrote.
    case carried
    /// A later write owns every key it wrote.
    case superseded
    /// Part of it survived: apply exactly `mutation` instead of the whole op.
    ///
    /// `keep` names the overlay keys this fragment gave up, where giving them
    /// up is not enough on its own: a re-created record's create SWEEPS the
    /// keys of the record's earlier lifetime before it writes its own, and a
    /// create replayed LATE cannot tell a stale key from a peer's newer one
    /// (finding 3431-R14). The keys the classification decided against are
    /// exactly the ones it knows a later write owns, so it names them and the
    /// sweep leaves them where they are — otherwise `_replace`, which rebuilds
    /// the row from whatever keys remain, would carry the deletion to the
    /// server.
    case fragment(mutation: OverlayMutation, keep: [String])
}

/// What a restore pass has decided to write so far, per model (3431-R10).
///
/// A pass classifies a whole chain of adopted ops, and the earlier ones are
/// restored before the later ones are applied — so an op has to be weighed
/// against the overlay AS THE PASS WILL LEAVE IT, not as it arrived. Two saves
/// to one field is the ordinary case: v1 → v2 → v3 with neither update
/// persisted leaves the overlay holding v1, and reading v3's recorded prior
/// value (v2) against the raw overlay says "someone else wrote v1 after this",
/// which is false — v2 is the write this pass is about to put back.
public struct RestoreProjection: Sendable {
    /// `model → key → the value an earlier restore will write there`.
    var values: [String: [ByteKey: JSONValue]] = [:]
    /// `model → key prefixes an earlier restored CREATE will have emptied`.
    ///
    /// A re-create clears a record's stale overlay keys before it writes its
    /// own, so a later op of the same chain must read those keys as ABSENT —
    /// which is "still owed" — rather than as the values they held before.
    var cleared: [String: Set<String>] = [:]

    public init() {}
}

/// What a restore put back, for the log and for the tests.
public struct PendingRestoreResult: Equatable, Sendable {
    /// Sequences re-applied to the overlay.
    public let restored: [Int]
    /// Sequences the overlay does not carry and this client cannot reproduce
    /// — ops written by a build that did not record their mutation. Left
    /// PENDING rather than dropped: the ack path is what settles them, and a
    /// later write to the same record repairs the record itself.
    public let unreproducible: [Int]
    /// Sequences deliberately left OFF the overlay until a judgement has said
    /// which of them still stand — a bulk load's convergence, or a deferred
    /// replay a restart interrupted (#3437, finding 3437-SO-03).
    public let deferred: [Int]
}

/// Putting a restarted client's unsent writes back on its overlay (#3437,
/// behaviors 5 and 6; the Swift half of #2816's behaviors 8 and 9).
///
/// A format-2 save commits the merged row and its `_pending_ops` entry in one
/// SQLite transaction and returns behind it — that is the commit barrier. The
/// overlay mutation the same save writes into the epoch Y.Doc is persisted
/// separately, asynchronously and after the fact. A process that dies in
/// between therefore restarts holding a row and a pending sequence whose
/// overlay entry never reached disk.
///
/// That gap is not merely a lost edit. The catch-up frame a reconnecting
/// client sends is a diff of its epoch document against the server's state
/// vector, and it CLAIMS every sequence still pending — so a write missing
/// from the document would be acknowledged as durable on the strength of a
/// frame that does not contain it, and pruned. The write would exist on
/// exactly one machine, forever, with nothing left to say so.
public enum Format2PendingRestore {

    // MARK: - The overlay as the pass will leave it

    /// The overlay, with what earlier ops of this pass will have written over
    /// it (3431-R10).
    struct OverlayView {
        let overlay: OverlayDocument
        let model: String
        let values: [ByteKey: JSONValue]
        let cleared: Set<String>

        private func emptied(_ key: String) -> Bool {
            for prefix in cleared where key.hasPrefix(prefix) { return true }
            return false
        }

        /// `nil` when the overlay will not hold the key at all. An explicit
        /// null answers `.null`, which is a different state and must not
        /// collapse into absence.
        func value(_ key: String) -> JSONValue? {
            if let projected = values[ByteKey(key)] { return projected }
            if emptied(key) { return nil }
            return overlay.value(model: model, key: key)
        }

        func has(_ key: String) -> Bool { value(key) != nil }
    }

    static func view(
        _ overlay: OverlayDocument, model: String, projection: RestoreProjection?
    ) -> OverlayView {
        OverlayView(
            overlay: overlay,
            model: model,
            values: projection?.values[model] ?? [:],
            cleared: projection?.cleared[model] ?? []
        )
    }

    /// JSON-shaped comparison, because SQLite round-trips booleans and numbers
    /// loosely and the overlay's values come back through JSON either way.
    static func sameOverlayValue(_ left: JSONValue?, _ right: JSONValue?) -> Bool {
        let a = left ?? .null
        let b = right ?? .null
        if case .null = a, case .null = b { return true }
        return a == b
    }

    /// Whether the overlay already holds every key this op wrote.
    static func overlayCarries(_ overlay: OverlayDocument, _ op: PendingOp) -> Bool {
        guard let mutation = op.mutation else { return false }
        for (key, _) in OverlayKeys.encode(mutation) {
            if overlay.value(model: op.model, key: key) == nil { return false }
        }
        return true
    }

    // MARK: - Classifying one adopted op

    /// Classify an ADOPTED op against the overlay and its merged row
    /// (#3431's rule, the sponsor's decision on finding 3431-R02).
    ///
    /// An op that recorded what the overlay held before it was written is
    /// decided against THAT, and the merged row is not consulted at all. What
    /// remains is the merged-row rule, which is still the answer for an op
    /// that recorded no prior values — a row written by an earlier build.
    ///
    /// For a client's OWN ops a key the overlay holds is proof enough: it
    /// wrote the key and its own later writes are in the same document. For an
    /// op adopted from an INSTANCE THAT IS GONE it is not. That instance's
    /// SQLite commit is what survived; the Yjs update the same save wrote is
    /// persisted separately, so it may never have reached disk — and the key
    /// the overlay holds is then the OLDER value, from before the orphan's
    /// write. Treating it as carried would skip the op, and the adopter's next
    /// catch-up would claim its sequence and have it pruned: a write the app
    /// was told was saved, existing on no machine at all.
    public static func classifyAdoptedOp(
        overlay: OverlayDocument,
        op: PendingOp,
        mergedRow: [String: JSONValue]?,
        projection: RestoreProjection? = nil
    ) -> PendingRestoreVerdict {
        guard let mutation = op.mutation else { return .restore }
        let view = view(overlay, model: op.model, projection: projection)

        // What the overlay held before this op was written, when the op
        // recorded it: then the OVERLAY alone answers.
        if let prior = op.priorOverlay {
            return classifyAgainstPriorOverlay(view, mutation, prior)
        }
        return classifyAgainstMergedRow(view, mutation, mergedRow)
    }

    /// Classify by KEY PRESENCE alone (#3437, edge E10).
    ///
    /// For an op whose model this device does not hold: a capped load left it
    /// out, so the rows the store has for it are whatever a later overlay
    /// happened to touch rather than the model, and neither "the row is gone"
    /// nor "the row disagrees" means what the merged-row rule would take it to
    /// mean. No read is made. What is left is the question the overlay can
    /// answer on its own — is this write still on it? — and a write that is
    /// not is still owed.
    public static func classifyByKeyPresence(
        overlay: OverlayDocument,
        op: PendingOp,
        projection: RestoreProjection? = nil
    ) -> PendingRestoreVerdict {
        guard let mutation = op.mutation else { return .restore }
        let view = view(overlay, model: op.model, projection: projection)
        let missing = OverlayKeys.encode(mutation).contains {
            !(view.has($0.key) && sameOverlayValue(view.value($0.key), $0.value))
        }
        return missing ? .restore : .carried
    }

    /// The merged-row rule, key by key.
    ///
    /// The overlay carries no clock, so the merged row is the arbiter — it is
    /// what the orphan committed, and any later peer write to the key has
    /// already been folded over it by the time this runs (the restore follows
    /// the catch-up fold's settlement).
    private static func classifyAgainstMergedRow(
        _ view: OverlayView,
        _ mutation: OverlayMutation,
        _ mergedRow: [String: JSONValue]?
    ) -> PendingRestoreVerdict {
        func carries(_ key: String, _ value: JSONValue) -> Bool {
            view.has(key) && sameOverlayValue(view.value(key), value)
        }

        if mutation.kind == .delete {
            // The delete stands exactly while the row is gone.
            if mergedRow != nil { return .superseded }
            let key = OverlayKeys.markerKey(
                recordId: mutation.id, marker: OverlayKeys.markerDeleted
            )
            return carries(key, .bool(true)) ? .carried : .restore
        }
        // A create or a patch whose row is no longer there lost to a delete.
        guard let mergedRow else { return .superseded }

        var fields: [String: JSONValue] = [:]
        var stringSetDeltas: [String: [String: Bool]] = [:]
        var arbitrated = 0
        var survivors = 0
        var owed = 0
        var lost: [String] = []

        for (field, raw) in mutation.fields.sorted(by: { $0.key < $1.key }) {
            arbitrated += 1
            let key = OverlayKeys.fieldKey(recordId: mutation.id, field: field)
            if !sameOverlayValue(mergedRow[field], raw) {
                lost.append(key)
                continue
            }
            survivors += 1
            fields[field] = raw
            if !carries(key, raw) { owed += 1 }
        }
        for (field, members) in mutation.stringSetDeltas.sorted(by: { $0.key < $1.key }) {
            let held: [String]
            if case .array(let values)? = mergedRow[field] {
                held = values.compactMap { $0.stringValue }
            } else {
                held = []
            }
            for (member, present) in members.sorted(by: { $0.key < $1.key }) {
                arbitrated += 1
                let key = OverlayKeys.memberKey(
                    recordId: mutation.id, field: field, member: member
                )
                // An add survives while the member is in the row, a removal
                // while it is not. Anything else is a later write.
                if held.contains(member) != present {
                    lost.append(key)
                    continue
                }
                survivors += 1
                stringSetDeltas[field, default: [:]][member] = present
                if !carries(key, .bool(present)) { owed += 1 }
            }
        }

        if arbitrated == 0 {
            // Markers only — a create of a record with no fields. Nothing the
            // merged row can weigh, so key presence stands for it.
            let missing = OverlayKeys.encode(mutation).contains { !carries($0.key, $0.value) }
            return missing ? .restore : .carried
        }
        if survivors == 0 { return .superseded }
        if owed == 0 { return .carried }
        if survivors == arbitrated { return .restore }
        return fragment(view, mutation, fields, stringSetDeltas, lost)
    }

    /// Classify against what the overlay held BEFORE this op was written (the
    /// sponsor's decision on finding 3431-R02).
    ///
    /// The merged-row rule cannot reach the case that decision was taken for:
    /// the bind folds the whole persisted overlay into the merged view before
    /// adoption runs, so the row holds whatever the overlay holds and "the
    /// orphan's update was never persisted" and "a peer wrote later" become
    /// the same three values. With the prior value recorded there is nothing
    /// left to guess — key by key:
    ///
    /// - the overlay holds the op's new value → already carried;
    /// - it holds what the op recorded as the prior value, or is absent →
    ///   nothing has touched the key since, so the write is still owed;
    /// - it holds anything else → someone wrote the key after this op.
    private static func classifyAgainstPriorOverlay(
        _ view: OverlayView,
        _ mutation: OverlayMutation,
        _ prior: [String: JSONValue]
    ) -> PendingRestoreVerdict {
        enum KeyVerdict { case carried, owed, lost }

        func verdictFor(_ key: String, _ value: JSONValue) -> KeyVerdict {
            guard let held = view.value(key) else {
                // Absent, so this write is not on the overlay and nothing that
                // stands is either. It stays OWED whether or not the key was
                // there before: an overlay that was never persisted at all is
                // the ordinary crash case, and the only later write that
                // REMOVES a record's keys is a re-create, which sets every one
                // of them again in the same transaction.
                return .owed
            }
            if sameOverlayValue(held, value) { return .carried }
            guard let recorded = prior[key] else { return .lost }
            return sameOverlayValue(held, recorded) ? .owed : .lost
        }

        if mutation.kind == .delete {
            // A delete writes one key, and the record's create wrote the same
            // key as `false`, so "the tombstone key still reads what it read
            // before this delete" is what says the delete never landed.
            //
            // The residue: a delete that DID land and was then followed by
            // another instance's re-create of the same id also leaves that key
            // reading false, and no clock in the overlay separates the two. It
            // resolves in favour of the delete being owed — the write the
            // intent promises to deliver — and the restore is an ordinary
            // key-level Yjs write, so a re-create after it still wins.
            switch verdictFor(
                OverlayKeys.markerKey(
                    recordId: mutation.id, marker: OverlayKeys.markerDeleted
                ),
                .bool(true)
            ) {
            case .carried: return .carried
            case .owed: return .restore
            case .lost: return .superseded
            }
        }

        var fields: [String: JSONValue] = [:]
        var stringSetDeltas: [String: [String: Bool]] = [:]
        var weighed = 0
        var survivors = 0
        var owed = 0
        var lost: [String] = []

        for (field, raw) in mutation.fields.sorted(by: { $0.key < $1.key }) {
            weighed += 1
            let key = OverlayKeys.fieldKey(recordId: mutation.id, field: field)
            switch verdictFor(key, raw) {
            case .lost:
                lost.append(key)
            case .carried:
                survivors += 1
                fields[field] = raw
            case .owed:
                survivors += 1
                owed += 1
                fields[field] = raw
            }
        }
        for (field, members) in mutation.stringSetDeltas.sorted(by: { $0.key < $1.key }) {
            for (member, present) in members.sorted(by: { $0.key < $1.key }) {
                weighed += 1
                let key = OverlayKeys.memberKey(
                    recordId: mutation.id, field: field, member: member
                )
                switch verdictFor(key, .bool(present)) {
                case .lost:
                    lost.append(key)
                case .carried:
                    survivors += 1
                    stringSetDeltas[field, default: [:]][member] = present
                case .owed:
                    survivors += 1
                    owed += 1
                    stringSetDeltas[field, default: [:]][member] = present
                }
            }
        }

        if weighed == 0 {
            // Markers only. Its own keys are what the verdict rests on.
            let verdicts = OverlayKeys.encode(mutation).map { verdictFor($0.key, $0.value) }
            if verdicts.contains(where: { $0 == .owed }) { return .restore }
            return verdicts.allSatisfy { $0 == .carried } ? .carried : .superseded
        }
        if survivors == 0 { return .superseded }
        if owed == 0 { return .carried }
        if survivors == weighed { return .restore }
        return fragment(view, mutation, fields, stringSetDeltas, lost)
    }

    /// The fragment verdict for a partly superseded op, with the keys its own
    /// sweep must not take (finding 3431-R14).
    ///
    /// `keep` is named only where it changes anything: a create over a record
    /// the overlay still holds a `_deleted` key for is the one case
    /// ``OverlayDocument/apply(_:model:keep:)`` sweeps at all.
    private static func fragment(
        _ view: OverlayView,
        _ mutation: OverlayMutation,
        _ fields: [String: JSONValue],
        _ stringSetDeltas: [String: [String: Bool]],
        _ lost: [String]
    ) -> PendingRestoreVerdict {
        let sweeps = mutation.kind == .create
            && !lost.isEmpty
            && view.has(OverlayKeys.markerKey(
                recordId: mutation.id, marker: OverlayKeys.markerDeleted
            ))
        return .fragment(
            mutation: OverlayMutation(
                id: mutation.id,
                kind: mutation.kind,
                fields: fields,
                stringSetDeltas: stringSetDeltas
            ),
            keep: sweeps ? lost : []
        )
    }

    // MARK: - Carrying a pass's earlier verdicts forward

    /// Fold what `verdict` will put on the overlay into `projection`, so the
    /// next op of the same chain is weighed against it (finding 3431-R10).
    ///
    /// Only a restore writes anything: "carried" means the key is already
    /// there and "superseded" means this op writes nothing at all.
    public static func projectRestoredKeys(
        overlay: OverlayDocument,
        op: PendingOp,
        verdict: PendingRestoreVerdict,
        projection: inout RestoreProjection
    ) {
        if verdict == .carried || verdict == .superseded { return }
        let mutation: OverlayMutation?
        var keep: [String] = []
        if case .fragment(let fragmentMutation, let fragmentKeep) = verdict {
            mutation = fragmentMutation
            keep = fragmentKeep
        } else {
            mutation = op.mutation
        }
        // An op with no recorded mutation is unreproducible: it is left
        // pending rather than applied, so it changes nothing the next op
        // should see.
        guard let mutation else { return }

        // A re-create empties the record's stale keys before writing its own,
        // so anything an earlier op of this pass put there is gone with them.
        if mutation.kind == .create {
            let view = view(overlay, model: op.model, projection: projection)
            let tombstone = OverlayKeys.markerKey(
                recordId: mutation.id, marker: OverlayKeys.markerDeleted
            )
            if view.has(tombstone) {
                let prefix = OverlayKeys.recordPrefix(mutation.id)
                projection.cleared[op.model, default: []].insert(prefix)
                var values = projection.values[op.model] ?? [:]
                for key in values.keys where key.value.hasPrefix(prefix) {
                    values.removeValue(forKey: key)
                }
                // The keys this fragment spared survive its sweep, so a later
                // op of the same chain must still read them (3431-R14),
                // holding the values the sweep leaves behind.
                for key in keep {
                    if let held = view.value(key) { values[ByteKey(key)] = held }
                }
                projection.values[op.model] = values
            }
        }

        var values = projection.values[op.model] ?? [:]
        for (key, value) in OverlayKeys.encode(mutation) {
            values[ByteKey(key)] = value
        }
        projection.values[op.model] = values
    }

    // MARK: - The restore itself

    /// Re-apply the unacknowledged writes `overlay` is missing.
    ///
    /// Called when a large document's overlay is bound — a fresh session, or
    /// an epoch document restored from local persistence — before anything is
    /// sent to the server.
    ///
    /// - Parameters:
    ///   - verdicts: a verdict per SEQUENCE, decided by the caller before this
    ///     ran. Only ADOPTED ops get one: the bind reads their merged rows
    ///     after the catch-up fold settles and classifies them there. A
    ///     sequence with no verdict keeps the key-presence rule exactly.
    ///   - deferAtOrBelowEpoch: leave the writes made at or below this epoch
    ///     off the overlay — the bulk-load boundary this document has crossed
    ///     and not yet converged past. Set only where something WILL state
    ///     them.
    ///   - deferAtOrBelowSeq: leave the writes at or below this sequence off
    ///     the overlay — a deferred replay a restart interrupted, whose
    ///     judgement has not run (finding 3437-SO-03). Without it a restart
    ///     between an epoch move and its replay would put an outdated write
    ///     straight back onto the joined epoch and publish it, with recency
    ///     never consulted.
    @discardableResult
    public static func restorePendingOverlay(
        overlay: OverlayDocument,
        ops: [PendingOp],
        verdicts: [Int: PendingRestoreVerdict] = [:],
        deferAtOrBelowEpoch: Int = 0,
        deferAtOrBelowSeq: Int = 0
    ) -> PendingRestoreResult {
        var restored: [Int] = []
        var unreproducible: [Int] = []
        var deferred: [Int] = []
        var missing: [(op: PendingOp, mutation: OverlayMutation, keep: [String])] = []

        for op in ops.sorted(by: { $0.seq < $1.seq }) {
            if deferAtOrBelowSeq > 0, op.seq <= deferAtOrBelowSeq {
                deferred.append(op.seq)
                continue
            }
            if deferAtOrBelowEpoch > 0, op.baseEpoch > 0,
               op.baseEpoch <= deferAtOrBelowEpoch {
                deferred.append(op.seq)
                continue
            }
            let verdict = verdicts[op.seq]
            if verdict == .carried || verdict == .superseded { continue }
            if verdict == nil, overlayCarries(overlay, op) { continue }
            guard let recorded = op.mutation else {
                unreproducible.append(op.seq)
                continue
            }
            if case .fragment(let mutation, let keep) = verdict {
                missing.append((op, mutation, keep))
            } else {
                missing.append((op, recorded, []))
            }
        }

        // In the order they were written: a later op of the same record must
        // not be overtaken by the earlier one it superseded.
        for entry in missing {
            overlay.apply(entry.mutation, model: entry.op.model, keep: Set(entry.keep))
            restored.append(entry.op.seq)
        }

        return PendingRestoreResult(
            restored: restored, unreproducible: unreproducible, deferred: deferred
        )
    }

    /// State the writes a judgement left standing onto the live overlay.
    ///
    /// The counterpart of ``restorePendingOverlay(overlay:ops:verdicts:deferAtOrBelowEpoch:deferAtOrBelowSeq:)``'s
    /// deferral: a restarted client's owed writes were kept off the overlay
    /// until the judgement had run, and this is where the survivors are said.
    /// They travel as ordinary local writes, so the observer folds them into
    /// the merged view and the transport sends them.
    ///
    /// A record whose delete lost is skipped rather than narrowed: a tombstone
    /// has no fields to keep.
    ///
    /// - Parameter keep: per sequence, the overlay keys a `create` among these
    ///   ops must NOT sweep — the ones a later local write already owns. Empty
    ///   for every op that is not a create over a tombstoned record, where the
    ///   sweep does nothing anyway.
    @discardableResult
    public static func statePendingOps(
        overlay: OverlayDocument,
        ops: [PendingOp],
        suppressDeletes: [(model: String, recordId: String)] = [],
        keep: [Int: Set<String>] = [:]
    ) -> Int {
        let suppressed = Set(suppressDeletes.map { "\($0.model)\u{0}\($0.recordId)" })
        let stated = ops
            .sorted(by: { $0.seq < $1.seq })
            .filter { op in
                guard op.mutation != nil else { return false }
                if op.op == .delete,
                   suppressed.contains("\(op.model)\u{0}\(op.recordId)") {
                    return false
                }
                return true
            }
        for op in stated {
            guard let mutation = op.mutation else { continue }
            overlay.apply(mutation, model: op.model, keep: keep[op.seq] ?? [])
        }
        return stated.count
    }
}
