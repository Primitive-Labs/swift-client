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

    // MARK: - Snapshot

    /// Snapshot every known field into a dictionary of `PrimitiveValue`.
    /// Unknown fields are omitted; use `rawValue(for:)` for those.
    public func snapshot() -> [String: PrimitiveValue] {
        return model.snapshot(recordId: id)
    }
}
