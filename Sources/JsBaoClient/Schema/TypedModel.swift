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

    // MARK: - Filtered query (typed)

    /// Mongo-style filtered query, hydrated back into `T`. Routes
    /// through `dynamic.query(...)` for the SQL-mirror filter +
    /// pagination, then re-reads each row via `T.init?(record:)` so
    /// the typed surface uses the protocol-required initializer
    /// (independent of whether the model has a `init?(row:)`).
    /// Rows whose required fields are missing (schema drift) drop
    /// out via the `compactMap`.
    ///
    /// One SQL query + N record-finds. The lookup is in-memory on
    /// the SQLite mirror so the N+1 is cheaper than its name; if the
    /// asymptotic cost becomes a problem, lift `init?(row:)` into
    /// `PrimitiveModel` and switch to a one-pass row cast.
    public func query(
        _ filter: DocumentFilter? = nil,
        options: QueryOptions? = nil
    ) -> [T] {
        return dynamic.query(filter, options: options).compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return find(id: id)
        }
    }

    // MARK: - Positional-arg / dict-shaped ergonomics

    /// Positional-arg `find` for callers that prefer the argumentless
    /// label. Identical to `find(id:)`.
    public func find(_ id: String) -> T? {
        find(id: id)
    }

    /// Positional-arg `delete`.
    public func delete(_ id: String) {
        delete(id: id)
    }

    /// Apply a partial update expressed as a `[String: Any]` dict —
    /// the shape app callers tend to have on hand from JSON / form
    /// state. Unknown keys (typos, fields removed from the schema)
    /// are silently dropped so a misspelled key is a loud no-op
    /// instead of a wire-format error. Coercion failures are also
    /// dropped.
    ///
    /// Failures from the underlying write are *logged* rather than
    /// thrown so call sites that don't own a unique constraint don't
    /// have to wrap every update in `try?`. Use the throwing
    /// `dynamic.update(id:values:)` directly when you need explicit
    /// error handling.
    public func update(_ id: String, _ updates: [String: Any]) {
        var values: [String: PrimitiveValue] = [:]
        for (key, raw) in updates {
            guard let desc = T.primitiveSchema.fields[key] else { continue }
            if let pv = PrimitiveValueBridge.wrap(raw, type: desc.type) {
                values[key] = pv
            }
        }
        do {
            try dynamic.update(id: id, values: values)
        } catch {
            print("[TypedModel] update(\(T.modelName):\(id)) failed: \(error)")
        }
    }

    /// Fire-and-forget create — same as `create(_:)` but doesn't
    /// throw. Use this when the model has no unique constraints (so
    /// the only thing `create` could throw is a schema-drift
    /// misconfiguration) and you don't want every call site on
    /// `try?`. Failures are logged.
    public func insert(_ value: T) {
        do {
            _ = try self.create(value)
        } catch {
            print("[TypedModel] insert(\(T.modelName):\(value.id)) failed: \(error)")
        }
    }
}

// MARK: - [String: Any] ⇄ [String: PrimitiveValue] bridge

/// Coerces raw `[String: Any]` values (e.g. from JSON, form state,
/// untyped legacy code) into the `PrimitiveValue` cases the schema
/// expects. Used by `TypedModel.update(_:_:)`. Returns `nil` for
/// `NSNull` and for values that can't be sensibly coerced — callers
/// drop those rather than writing a nonsensical value.
internal enum PrimitiveValueBridge {

    static func wrap(_ value: Any, type: PrimitiveFieldType) -> PrimitiveValue? {
        if value is NSNull { return nil }
        switch type {
        case .string:
            if let s = value as? String { return .string(s) }
        case .number:
            if let d = value as? Double { return .number(d) }
            if let i = value as? Int    { return .number(Double(i)) }
            if let i = value as? Int64  { return .number(Double(i)) }
        case .boolean:
            if let b = value as? Bool { return .boolean(b) }
        case .id:
            if let s = value as? String, !s.isEmpty { return .id(s) }
        case .date:
            if let s = value as? String { return .date(s) }
        case .stringset:
            if let set = value as? Set<String> { return .stringset(set) }
            if let arr = value as? [String]    { return .stringset(Set(arr)) }
        case .json:
            if let s = value as? String { return .json(Data(s.utf8)) }
            if let d = value as? Data   { return .json(d) }
        }
        return nil
    }
}
