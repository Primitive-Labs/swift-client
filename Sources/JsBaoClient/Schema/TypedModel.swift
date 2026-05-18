import Foundation
import YSwift

/// A typed Swift struct backed by a `_meta_*`-described model.
///
/// Conformers declare a static schema and define how to (de)serialize
/// to/from a `PrimitiveRecord`. The `init(record:)` is failable so the
/// typed layer degrades gracefully when the underlying record drifts
/// from the typed expectation — the dynamic record is still readable
/// via `TypedModel.dynamic`.
public protocol PrimitiveModel {
    static var modelName: String { get }
    static var primitiveSchema: PrimitiveSchema { get }

    var id: String { get }

    /// Reconstruct a typed value from a dynamic record. Return nil if
    /// any required field is missing or has the wrong type — the typed
    /// `find` will surface that as `nil`, and the caller can drop down
    /// to the dynamic layer to inspect raw values.
    init?(record: PrimitiveRecord)

    /// Project the typed value into a value dictionary that the dynamic
    /// model can persist. Omit `id` — the dynamic layer writes that
    /// separately.
    func primitiveValues() -> [String: PrimitiveValue]
}

/// A thin façade over `DynamicModel` that surfaces a typed record API.
/// Reads/writes go through `PrimitiveRecord` so the wire format is
/// identical to what a dynamic-only caller would produce — typed and
/// dynamic are not two separate storage paths, just two views.
public final class TypedModel<T: PrimitiveModel> {
    public let dynamic: DynamicModel

    public init(doc: YDocument) {
        self.dynamic = DynamicModel(doc: doc, schema: T.primitiveSchema)
    }

    /// Unwrap escape hatch for callers that need to share a single
    /// `DynamicModel` (e.g. when re-using its observers in Work Item 2).
    public init(dynamic: DynamicModel) {
        precondition(dynamic.schema.name == T.modelName,
                     "DynamicModel schema name must match T.modelName")
        self.dynamic = dynamic
    }

    /// Persist a typed value. Throws `UniqueConstraintViolationError`
    /// if the record collides with an existing one on a unique
    /// constraint — propagated directly from the dynamic layer.
    @discardableResult
    public func create(_ value: T) throws -> T {
        _ = try dynamic.create(id: value.id, values: value.primitiveValues())
        return value
    }

    public func find(id: String) -> T? {
        guard let record = dynamic.find(id: id) else { return nil }
        return T(record: record)
    }

    public func findAll() -> [T] {
        return dynamic.findAll().compactMap { T(record: $0) }
    }

    public func delete(id: String) {
        dynamic.delete(id: id)
    }
}
