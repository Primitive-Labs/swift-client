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
public final class PrimitiveRecord {
    public let modelName: String
    public let id: String

    // Strong ref: the record must remain usable even if the caller
    // drops its handle to the DynamicModel immediately after `create`.
    internal let model: DynamicModel

    internal init(modelName: String, id: String, model: DynamicModel) {
        self.modelName = modelName
        self.id = id
        self.model = model
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
                try? model.update(id: id, values: [field: v])
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
