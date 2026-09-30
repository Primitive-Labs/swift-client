import Foundation

/// One record's owed overlay, ready to be written on the new epoch's document.
public struct CarriedOverlay: Equatable, Sendable {
    public let model: String
    public var entry: OverlayRecordEntry

    public init(model: String, entry: OverlayRecordEntry) {
        self.model = model
        self.entry = entry
    }
}

/// Following a seal onto a fresh overlay — the carry (#3437, behavior 8).
///
/// When the room seals epoch E it replaces its overlay with an empty one, so a
/// client's further DELTAS against the sealed overlay cannot be integrated
/// there. The obvious answer — resync the whole document — is the wrong one on
/// a large document: a state-complete sync of the sealed overlay would seed
/// E+1 with everything E held, the new epoch would re-cross the rotation
/// threshold at once, and the overlay would never actually be bounded. That is
/// precisely why automatic rotation stayed opt-in until this path existed.
///
/// What a client owes the new epoch is narrow: the writes the server has not
/// acknowledged. Everything acknowledged is already in the server's `records`
/// table — the sealed overlay was archived and folded — and in this client's
/// own merged view, so re-sending it buys nothing and costs an epoch.
///
/// The owed writes are carried as OVERLAY entries taken from the sealed
/// document rather than rebuilt from the merged view, because the overlay is
/// the only place their exact shape survives: an explicit `null` unset, a
/// stringset member tombstone, and the difference between a patch and a
/// `_replace` create all vanish once a row has been materialized.
public enum Format2EpochHandoff {

    /// Reads a record's whole overlay entry out of the epoch being left.
    public typealias OverlayReader = (_ model: String, _ recordId: String)
        -> OverlayRecordEntry

    /// The overlay a client carries into the next epoch: one entry per record
    /// its unacknowledged ops touched, in the local order those ops were
    /// written.
    ///
    /// - Parameters:
    ///   - ops: the durable `_pending_ops` log, which is already exactly the
    ///     unacknowledged ones — an `update.ack` prunes at its contiguous
    ///     high-water mark.
    ///   - suppressDeletes: records whose tombstone must NOT travel: this
    ///     client's own delete lost to a write made online after it, and the
    ///     lifecycle read off the overlay still records that delete.
    public static func carryUnackedOverlay(
        ops: [PendingOp],
        read: OverlayReader,
        suppressDeletes: [(model: String, recordId: String)] = []
    ) -> [CarriedOverlay] {
        let suppressed = Set(suppressDeletes.map { key($0.model, $0.recordId) })
        var order: [String] = []
        var grouped: [String: (model: String, recordId: String, ops: [PendingOp])] = [:]
        for op in ops.sorted(by: { $0.seq < $1.seq }) {
            let identity = key(op.model, op.recordId)
            if grouped[identity] == nil {
                grouped[identity] = (op.model, op.recordId, [])
                order.append(identity)
            }
            grouped[identity]?.ops.append(op)
        }

        var carried: [CarriedOverlay] = []
        for identity in order {
            guard let group = grouped[identity] else { continue }
            let entry = carryRecord(
                read(group.model, group.recordId),
                ops: group.ops,
                deleteSuppressed: suppressed.contains(identity)
            )
            carried.append(CarriedOverlay(model: group.model, entry: entry))
        }
        return carried
    }

    /// One record's owed overlay.
    ///
    /// The record's LIFECYCLE is read off the overlay, not re-derived from the
    /// local ops. The overlay is the CONVERGED state of that record in the
    /// epoch being left: this client's ops wrote into it, and a peer's
    /// concurrent write merged on top under key-level LWW, so its markers are
    /// the answer both ends already agree on. Re-deriving the lifecycle from
    /// the ops alone would carry a local patch across a peer's delete —
    /// resurrecting, in the next epoch, a row the server has already dropped
    /// — and would re-delete a record a peer re-created after this client's
    /// delete lost the LWW race.
    ///
    /// The ops decide only WHICH FIELDS are owed, so replaying them cannot
    /// clobber a peer's concurrent write to another field of the same record.
    /// A `_replace` create is the exception: it discards the base row, so it
    /// travels whole.
    private static func carryRecord(
        _ overlay: OverlayRecordEntry,
        ops: [PendingOp],
        deleteSuppressed: Bool
    ) -> OverlayRecordEntry {
        if overlay.deleted, !deleteSuppressed {
            // A tombstone and nothing else: whatever was written before it —
            // here or by a peer — is moot, and the fields must not travel
            // alongside it.
            return OverlayRecordEntry(id: overlay.id, deleted: true)
        }

        if overlay.replace {
            // A create, or a re-create that won over a delete. `_replace` is
            // only meaningful with the fields it replaces the base by, so the
            // whole entry travels — including a peer's fields, which the
            // re-create's own `_replace` would otherwise discard on the next
            // materialization.
            var entry = overlay
            entry.replace = true
            entry.deleted = false
            return entry
        }

        var touched: Set<String> = []
        for op in ops { for field in op.fields { touched.insert(field) } }

        return OverlayRecordEntry(
            id: overlay.id,
            fields: overlay.fields.filter { touched.contains($0.key) },
            stringSets: overlay.stringSets.filter { touched.contains($0.key) },
            replace: false,
            deleted: false
        )
    }

    /// Write a carried entry's flat keys onto the new epoch's model map.
    ///
    /// Written key by key rather than through a mutation, because a carried
    /// entry IS already an overlay: its explicit nulls, its member tombstones
    /// and its markers travel verbatim, with no mutation semantics re-derived
    /// on top of them.
    public static func writeCarriedOverlay(
        into overlay: OverlayDocument, model: String, entry: OverlayRecordEntry
    ) {
        var raw: [(String, JSONValue)] = []
        if entry.deleted {
            raw.append((
                OverlayKeys.markerKey(
                    recordId: entry.id, marker: OverlayKeys.markerDeleted
                ),
                .bool(true)
            ))
            overlay.applyRawEntries(raw, model: model)
            return
        }
        if entry.replace {
            raw.append((
                OverlayKeys.markerKey(
                    recordId: entry.id, marker: OverlayKeys.markerReplace
                ),
                .bool(true)
            ))
            // The record may have been deleted earlier in the epoch being
            // left; the new epoch must not inherit that tombstone under
            // key-level LWW.
            raw.append((
                OverlayKeys.markerKey(
                    recordId: entry.id, marker: OverlayKeys.markerDeleted
                ),
                .bool(false)
            ))
        }
        for (field, value) in entry.fields {
            raw.append((OverlayKeys.fieldKey(recordId: entry.id, field: field), value))
        }
        for (field, members) in entry.stringSets {
            for (member, present) in members {
                raw.append((
                    OverlayKeys.memberKey(
                        recordId: entry.id, field: field, member: member
                    ),
                    .bool(present)
                ))
            }
        }
        overlay.applyRawEntries(raw, model: model)
    }

    /// Take back the keys a LATER local write already owns.
    ///
    /// A carried entry holds the values the owed writes had when they were
    /// read off the overlay they were written on. That is the right answer
    /// while nothing has happened since — an ordinary rotation states them at
    /// once. A DEFERRED carry is different: the client goes on writing onto
    /// the epoch it joined, and those writes publish as they always did, so by
    /// the time the deferral is settled the same field may hold a newer value
    /// of this user's own making. Writing the captured one back over it would
    /// revert an edit the application already reported as saved.
    ///
    /// So the ops still pending that the deferral did NOT hold — every local
    /// write made after it — name the keys they own, and those keys are left
    /// alone. An entry with nothing else in it does not travel at all. A
    /// tombstone is a whole record rather than a key: a later write that is
    /// not itself a delete means the record lives now, and the delete no
    /// longer describes anything.
    public static func suppressSupersededKeys(
        _ carried: [CarriedOverlay], later: [PendingOp]
    ) -> [CarriedOverlay] {
        guard !later.isEmpty, !carried.isEmpty else { return carried }
        var owned: [String: Set<String>] = [:]
        var revived: Set<String> = []
        for op in later {
            let identity = key(op.model, op.recordId)
            owned[identity, default: []].formUnion(op.fields)
            if op.op != .delete { revived.insert(identity) }
        }

        var kept: [CarriedOverlay] = []
        for each in carried {
            let identity = key(each.model, each.entry.id)
            guard let ownedFields = owned[identity] else {
                kept.append(each)
                continue
            }
            if each.entry.deleted {
                if !revived.contains(identity) { kept.append(each) }
                continue
            }
            let fields = each.entry.fields.filter { !ownedFields.contains($0.key) }
            let stringSets = each.entry.stringSets.filter { !ownedFields.contains($0.key) }
            if !each.entry.replace, fields.isEmpty, stringSets.isEmpty { continue }
            var entry = each.entry
            entry.fields = fields
            entry.stringSets = stringSets
            kept.append(CarriedOverlay(model: each.model, entry: entry))
        }
        return kept
    }

    /// The identity a record is grouped and looked up by.
    ///
    /// Separated by a NUL rather than a space: a model name or a record id may
    /// contain a space, and two records whose joined keys collided would be
    /// carried as one — the silent kind of loss (the same reason #3435's
    /// presence map is keyed this way).
    private static func key(_ model: String, _ recordId: String) -> String {
        "\(model)\u{0}\(recordId)"
    }
}
