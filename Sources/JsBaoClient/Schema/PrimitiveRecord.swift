import Foundation
import YSwift
import Yniffi

/// A single record living inside a model's top-level Y.Map. Identity is
/// the inner Y.Map — the same Y.Map you can attach a per-record observer
/// to (Work Item 2). Subscript reads/writes go straight through the CRDT.
///
/// The record holds a reference to its parent `DynamicModel` so writes
/// are scoped to the same transaction dispatch policy (sync or
/// client-integrated) the model was set up with.
///
/// ## `Sendable` — plain and checked (#1992, Phase C)
///
/// No `@unchecked` here, and none is needed: every stored property is `let`
/// and `Sendable` (`String`s, `Int?`s, and `DynamicModel`, which is
/// `@unchecked Sendable` behind its documented lock invariants). The compiler
/// verifies this conformance, so the type carries no safety-argument debt of
/// its own — that debt is `DynamicModel`'s, stated once there.
///
/// It stays a **live handle**, not a value snapshot: a subscript read goes
/// through the model to the CRDT and so reflects concurrent writes, and the
/// subscript setter writes through (#1156). Sending a `PrimitiveRecord` across
/// an isolation boundary sends the handle; the data it reads through stays
/// serialized by the model's locks.
public final class PrimitiveRecord: Sendable {
    public let modelName: String
    public let id: String

    // Strong ref: the record must remain usable even if the caller
    // drops its handle to the DynamicModel immediately after `create`.
    internal let model: DynamicModel

    /// On a record-log (format-3) document, the writer's sequence number of
    /// the entry the save that returned this handle committed; `nil` for any
    /// other handle (a lookup, another format, a save inside `transact`).
    public let recordLogSeq: Int?

    /// The save that returned this handle, as its document's binding names it:
    /// `recordLogSeq` is minted again after a group of saves failed to commit,
    /// and a later save under the same number is not this one.
    internal let recordLogTicket: Int?

    internal init(modelName: String, id: String, model: DynamicModel, recordLogSeq: Int? = nil) {
        self.modelName = modelName
        self.id = id
        self.model = model
        self.recordLogSeq = recordLogSeq
        self.recordLogTicket = recordLogSeq.flatMap { model.recordLog?.binding.ticket(of: $0) }
    }

    /// Whether this record's writes from this client have reached the room,
    /// on a record-log (format-3) document: `pending` while an entry of this
    /// client touching the record is unacknowledged, `refused` when the save
    /// that produced this handle was handed back, `confirmed` otherwise. `nil`
    /// on any other document. The model's listeners hear a record move to
    /// `confirmed`.
    public var syncState: RecordSyncState? {
        model.recordLog?.binding.syncState(model: modelName, id: id, lastSeq: recordLogSeq, ticket: recordLogTicket)
    }

    // MARK: - Subscript

    public subscript(field: String) -> PrimitiveValue? {
        get { model.readField(recordId: id, field: field) }
        set {
            // Route through the throwing update path so unique
            // constraints are enforced. A violation leaves the record
            // untouched; callers that need the error surface should
            // use `DynamicModel.update(id:values:)` directly.
            if let v = newValue {
                model.assignFieldFromRecord(recordId: id, field: field, value: v)
            } else {
                model.clearField(recordId: id, field: field)
            }
        }
    }

    // MARK: - Escape hatch for unknown fields

    /// Raw JSON string as the Yrs FFI hands it back. Use for fields the
    /// schema doesn't know about; otherwise prefer the subscript.
    public func rawValue(for field: String) -> String? {
        model.readRaw(recordId: id, field: field)
    }

    /// Every field name currently present on the underlying Y.Map — includes
    /// fields Swift's schema doesn't know about. Used by callers doing
    /// schema-evolution work; matches `Object.keys(record)` in js-bao.
    public func fieldNames() -> Set<String> {
        return model.fieldNames(recordId: id)
    }

    /// Whether the stored record holds `field`, a stored `null` included.
    ///
    /// `false` means the record was never written with the field, so a read
    /// fills the field's `default`, as js-bao's getter does; a cleared field
    /// (stored `null`) answers `true`. Answered on a db3 (record-log)
    /// document, where clearing a field stores `null`; `nil` on a Y.Map
    /// document, where clearing a field removes it, so a missing field there
    /// may be a cleared one.
    ///
    /// ```swift
    /// let points = record.holds("points") == false ? 3 : record["points"]?.asNumber
    /// ```
    public func holds(_ field: String) -> Bool? {
        model.holds(recordId: id, field: field)
    }

    /// Whether the record a query row answers holds `field`, a stored `null`
    /// included, as ``holds(_:)`` answers for a record.
    ///
    /// A row from a db3 (record-log) document carries a cleared field as
    /// `null` and leaves out a field never written, so a row lacking `field`
    /// answers `false` when the row's document (`_meta_doc_id`) is one a
    /// client in this process opened as a db3. The answer depends on the row
    /// alone, not on which client is the default or whether the document is
    /// still open, so a row kept and read later reads the same. Any other row
    /// lacking it answers `nil`: a Y.Map document's rows leave out a cleared
    /// field too. A row read with a projection leaves out the fields it did
    /// not ask for, so build a model from a whole row.
    ///
    /// A row carries every string set field, as `[]` when the set has no
    /// members; a db3 row lists the ones its record does not hold under
    /// `_meta_unheld`, so those answer `false` too.
    ///
    /// ```swift
    /// let points = PrimitiveRecord.holds("points", in: row) == false ? 3 : row["points"]?.numberValue
    /// ```
    public static func holds(_ field: String, in row: [String: JSONValue]) -> Bool? {
        if case .array(let unheld)? = row[unheldFieldsKey], unheld.contains(.string(field)) { return false }
        if row[field] != nil { return true }
        guard let document = row["_meta_doc_id"]?.stringValue,
              RecordLogDocumentIds.contains(document)
        else { return nil }
        return false
    }

    /// The key under which a db3 row lists the string set fields its record
    /// does not hold. A row carries each such field as `[]`, as it carries a
    /// set with no members, so ``holds(_:in:)`` reads presence from the list.
    static let unheldFieldsKey = "_meta_unheld"

    /// Record in `row` that its record does not hold the string set fields
    /// `fields`; nothing when there are none, so a row whose record holds
    /// every set keeps the keys it carried.
    static func markUnheld(_ fields: some Collection<String>, in row: inout [String: JSONValue]) {
        guard !fields.isEmpty else { return }
        row[unheldFieldsKey] = .array(fields.sorted().map { .string($0) })
    }

    // MARK: - Snapshot

    /// Snapshot every known field into a dictionary of `PrimitiveValue`.
    /// Unknown fields are omitted; use `rawValue(for:)` for those.
    public func snapshot() -> [String: PrimitiveValue] {
        return model.snapshot(recordId: id)
    }
}
