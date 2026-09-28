import Foundation
import YSwift
import Yniffi

/// The epoch overlay held in a Y.Doc: one top-level `YMap` per model, keyed by
/// the flat grammar in ``OverlayKeys`` (#3436).
///
/// A format-2 document's Y.Doc is NOT the document — it is a bounded overlay
/// of the records and fields the current epoch touched. This wrapper is the
/// only place that reads or writes it, so the "what is in the overlay"
/// question has one answer on the write path, in the observer's completion of
/// a `_replace`, and in a catch-up fold.
///
/// The map's element type is ``JSONValue``, and that is a parity requirement
/// rather than a convenience. yswift's `YMap<T>` JSON-encodes `T` into the
/// yrs value, so a `YMap<String>` would store the TEXT `"true"` where the JS
/// client stores the JSON `true` — and reading a JS-written key back as a
/// `String` traps in yswift's decoder (`try!` in `Coder.decoded`). One
/// `JSONValue` map stores exactly what `largeDocuments.ts` stores: strings,
/// numbers, bools and explicit nulls, each as itself.
public final class OverlayDocument {

    /// The Y.Doc this overlay lives in. A format-2 document's own document.
    public let document: YDocument

    private let lock = NSLock()
    private var maps: [String: YMap<JSONValue>] = [:]

    public init(document: YDocument = YDocument()) {
        self.document = document
    }

    /// The model's overlay map, created on first use.
    ///
    /// Memoized because `getOrCreateMap` is an FFI call and the write path
    /// takes it per mutation; the map handle itself is stable for the life of
    /// the document.
    public func map(for model: String) -> YMap<JSONValue> {
        lock.withLock {
            if let existing = maps[model] { return existing }
            let created: YMap<JSONValue> = document.getOrCreateMap(named: model)
            maps[model] = created
            return created
        }
    }

    /// Every model this overlay has a map for. Only the models something has
    /// touched through this wrapper — an arriving update's models are
    /// registered by the binding, which knows the schema.
    public func knownModels() -> [String] {
        lock.withLock { Array(maps.keys) }.sorted()
    }

    // MARK: - Reading

    /// One key's value, or `nil` when the overlay does not hold the key.
    ///
    /// "Absent" and "held as null" are different states of an overlay — an
    /// explicit unset IS a null the fold applies, while a key that is gone is
    /// cleanup carrying no meaning of its own — so the two must never collapse
    /// into one answer. `map.get` alone DOES collapse them (a stored JSON null
    /// decodes to `nil`, measured), so presence is asked for separately and a
    /// key the map holds is never reported absent.
    public func value(model: String, key: String) -> JSONValue? {
        let map = self.map(for: model)
        return document.transactSync { transaction in
            guard map.containsKey(key, transaction: transaction) else { return nil }
            return map.get(key: key, transaction: transaction) ?? .null
        }
    }

    /// Every overlay entry of one model.
    ///
    /// Accumulated into an ARRAY, never through a `[String: JSONValue]`: a
    /// Swift dictionary keyed by the raw key would merge two keys yrs keeps
    /// apart the moment they are canonically equivalent — the same collapse
    /// ``ByteKey`` exists to stop, one layer lower down, where the fold could
    /// not see it.
    public func entries(model: String) -> [(String, JSONValue)] {
        let map = self.map(for: model)
        return document.transactSync { transaction in
            var out: [(String, JSONValue)] = []
            map.each(transaction: transaction) { key, value in
                out.append((key, value))
            }
            return out
        }
    }

    /// One record's WHOLE overlay entry (#3437, behavior 8).
    ///
    /// What the epoch handoff carries: the converged state of that record in
    /// the epoch being left, markers and all. Read off the overlay rather than
    /// rebuilt from the merged row, because the overlay is the only place an
    /// owed write's exact shape survives — an explicit null unset, a member
    /// tombstone, and the difference between a patch and a `_replace` create
    /// all vanish once a row has been materialized.
    ///
    /// Matched on the ESCAPED id's BYTES, exactly as ``complete(_:model:)``
    /// does: two canonically equivalent ids are two records here as they are
    /// everywhere else, and matching the first segment is what lets one record
    /// be found without decoding every key in the map.
    ///
    /// - Returns: an empty entry for a record the overlay says nothing about,
    ///   which is what a carry of an already-acknowledged record reads.
    public func recordEntry(model: String, recordId: String) -> OverlayRecordEntry {
        let wanted = ByteKey(OverlayKeys.encodeSegment(recordId))
        let map = self.map(for: model)
        var own: [(String, JSONValue)] = []
        document.transactSync { transaction in
            map.each(transaction: transaction) { key, value in
                guard let separator = key.firstIndex(of: "/"),
                      separator != key.startIndex,
                      ByteKey(String(key[key.startIndex..<separator])) == wanted
                else { return }
                own.append((key, value))
            }
        }
        return OverlayKeys.group(own)[ByteKey(recordId)]
            ?? OverlayRecordEntry(id: recordId)
    }

    /// What the overlay holds for the keys `mutation` is about to write.
    ///
    /// Taken on the save path, inside the same operation as the commit and
    /// before the mutation is published, so it describes the overlay the write
    /// is layered over. A key the overlay does not hold is left OUT rather
    /// than recorded as null, because an absent key has to compare equal to an
    /// absent key later.
    ///
    /// One lookup per key the mutation writes, never a walk: this runs on the
    /// declared hot path and a large document's model map holds every key the
    /// epoch has touched.
    ///
    /// Keyed on PRESENCE, as `captureOverlayPriorValues` is: a key the overlay
    /// holds as an explicit null is recorded as null, not left out — "the
    /// field was unset before this write" and "the overlay said nothing about
    /// it" are the two facts the adoption verdict is decided between.
    public func priorValues(model: String, mutation: OverlayMutation) -> [String: JSONValue] {
        let map = self.map(for: model)
        return document.transactSync { transaction in
            var prior: [String: JSONValue] = [:]
            for (key, _) in OverlayKeys.encode(mutation) {
                guard map.containsKey(key, transaction: transaction) else { continue }
                prior[key] = map.get(key: key, transaction: transaction) ?? .null
            }
            return prior
        }
    }

    // MARK: - Writing

    /// Apply a mutation's entries to the model map, returning the entries it
    /// wrote so the caller can fold exactly those keys.
    /// - Parameter keep: overlay keys a re-created record's sweep must NOT
    ///   take (#3437, finding 3431-R14). A create replayed LATE cannot tell a
    ///   stale key of the record's earlier lifetime from a peer's newer one,
    ///   and the adoption classification knows exactly which keys a later
    ///   write owns — so it names them and the sweep leaves them where they
    ///   are. Otherwise `_replace`, which rebuilds the row from whatever keys
    ///   remain, would carry the deletion on to the server.
    @discardableResult
    public func apply(
        _ mutation: OverlayMutation, model: String, keep: Set<String> = []
    ) -> [(String, JSONValue)] {
        let map = self.map(for: model)
        let entries = OverlayKeys.encode(mutation)
        document.transactSync { transaction in
            if mutation.kind == .create {
                Self.clearStaleRecordOverlay(
                    map: map, recordId: mutation.id, transaction: transaction, keep: keep
                )
            }
            for (key, value) in entries {
                map.updateValue(value, forKey: key, transaction: transaction)
            }
        }
        return entries
    }

    /// Write raw overlay entries, without a mutation's create semantics.
    ///
    /// The cold loader and the catch-up restore both have entries in hand
    /// already; going back through ``apply(_:model:)`` would make them invent
    /// a mutation to describe keys they were given.
    @discardableResult
    public func applyRawEntries(
        _ entries: [(String, JSONValue)],
        model: String
    ) -> [(String, JSONValue)] {
        let map = self.map(for: model)
        document.transactSync { transaction in
            for (key, value) in entries {
                map.updateValue(value, forKey: key, transaction: transaction)
            }
        }
        return entries
    }

    // MARK: - Update exchange

    /// Apply a Yjs update from a peer or from local persistence.
    ///
    /// `transactSync` is not throwing, so the failure is carried out rather
    /// than thrown across the FFI boundary — a `throws` closure inside a
    /// transaction would unwind through yrs.
    public func applyUpdate(_ update: [UInt8]) throws {
        let failure: Error? = document.transactSync { transaction in
            do {
                try transaction.transactionApplyUpdate(update: update)
                return nil
            } catch {
                return error
            }
        }
        if let failure { throw failure }
    }

    /// This overlay's state vector, as `clientId → clock` with the client ids
    /// as decimal strings (#3782) — the shape the folded-state mark stores on
    /// both clients.
    ///
    /// yrs hands the vector over lib0-encoded: a varUint count, then that many
    /// varUint `(client, clock)` pairs. Decoded here rather than compared as
    /// bytes, because the encoder walks its client map in no fixed order, so
    /// the same vector can encode to different bytes.
    public func stateVector() -> [String: Int] {
        let bytes = document.transactSync { transaction in
            transaction.transactionStateVector()
        }
        var position = 0
        func readVarUint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        var vector: [String: Int] = [:]
        guard let count = readVarUint() else { return vector }
        for _ in 0..<count {
            guard let client = readVarUint(), let clock = readVarUint() else { break }
            vector[String(client)] = Int(clock)
        }
        return vector
    }

    /// This overlay's whole state as one Yjs update.
    public func encodeStateAsUpdate() -> [UInt8] {
        document.transactSync { transaction in
            transaction.transactionEncodeStateAsUpdate()
        }
    }

    /// Drop the overlay keys a record's EARLIER lifetime left in this epoch,
    /// so a re-create starts from nothing.
    ///
    /// Without this, patch → delete → re-create inside one epoch leaves the
    /// patched field key behind: the incremental fold is still right (the
    /// delete removed the row before the `_replace` wrote the new one), but
    /// materializing the ACCUMULATED overlay — what a snapshot build and a
    /// fast-forward do — would resurrect a field the re-created record never
    /// had. Applying an overlay has to stay order-free at the record level.
    ///
    /// Guarded by the tombstone the earlier lifetime must have written, so the
    /// common case — a create of a brand-new id — never walks the map.
    private static func clearStaleRecordOverlay(
        map: YMap<JSONValue>,
        recordId: String,
        transaction: YrsTransaction,
        keep: Set<String> = []
    ) {
        let tombstone = OverlayKeys.markerKey(
            recordId: recordId, marker: OverlayKeys.markerDeleted
        )
        guard map.containsKey(tombstone, transaction: transaction) else { return }
        let prefix = OverlayKeys.recordPrefix(recordId)
        var stale: [String] = []
        map.keys(transaction: transaction) { key in
            if key.hasPrefix(prefix), !keep.contains(key) { stale.append(key) }
        }
        for key in stale { _ = map.removeValue(forKey: key, transaction: transaction) }
    }

    // MARK: - Completing a delta fold

    /// Complete the entries of a delta fold that need the record's WHOLE
    /// overlay.
    ///
    /// A delta fold — projecting exactly the keys an update touched — is right
    /// for a patch, which merges over the stored row. It is wrong for
    /// `_replace`: that marker discards the row entirely, so the record has to
    /// be rebuilt from every key it currently has. Concurrency is where the
    /// two differ: when one client patches a record while another deletes and
    /// re-creates it, Yjs merges their keys per key, and folding the
    /// `_replace` update alone would drop the concurrent patch the overlay
    /// still holds.
    ///
    /// The map is walked ONCE however many records were replaced — every
    /// create carries `_replace`, so a walk per record would make one bulk
    /// create quadratic in the records it writes.
    public func complete(
        _ entries: inout [ByteKey: OverlayRecordEntry],
        model: String
    ) {
        // A tombstone deletes the row whatever else the overlay holds, and a
        // patch merges over it — only `_replace` reads the row away.
        let rebuild = Set(
            entries.values.filter { $0.replace && !$0.deleted }.map { ByteKey($0.id) }
        )
        guard !rebuild.isEmpty else { return }

        // Keys carry the ESCAPED id, which is what lets the first segment be
        // matched without decoding (or even splitting) every key in the map.
        // Every one of these lookups is on the id's BYTES: two canonically
        // equivalent ids are two records here as they are everywhere else.
        var wanted: [ByteKey: ByteKey] = [:]
        for id in rebuild { wanted[ByteKey(OverlayKeys.encodeSegment(id.value))] = id }

        let map = self.map(for: model)
        var own: [ByteKey: [(String, JSONValue)]] = [:]
        document.transactSync { transaction in
            map.each(transaction: transaction) { key, value in
                guard let separator = key.firstIndex(of: "/"), separator != key.startIndex
                else { return }
                guard let id = wanted[ByteKey(String(key[key.startIndex..<separator]))]
                else { return }
                guard OverlayKeys.parse(key) != nil else { return }
                own[id, default: []].append((key, value))
            }
        }

        for id in rebuild {
            let rebuilt = OverlayKeys.group(own[id] ?? [])[id]
                ?? OverlayRecordEntry(id: id.value)
            entries[id] = rebuilt
        }
    }
}
