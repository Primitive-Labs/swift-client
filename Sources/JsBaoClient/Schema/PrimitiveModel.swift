import Foundation

/// A codegen'd model type — the one app-facing model, like `BaseModel` in the
/// JS client. `swift-bao-codegen` emits one conforming struct per
/// `schema.toml` model, plus the static `Model.*` facade (`query` / `create`
/// / `update` / `delete` / `find` / `count` / `subscribe`) that reads and
/// writes the client's shared cross-document store.
///
/// Conformers declare their schema and how to (de)serialize to/from a
/// `PrimitiveRecord`. `init?(record:)` is failable so the typed layer degrades
/// gracefully when a stored record drifts from the typed expectation.
public protocol PrimitiveModel {
    static var modelName: String { get }
    static var primitiveSchema: PrimitiveSchema { get }

    var id: String { get }

    /// Reconstruct a typed value from a dynamic record. Return nil if any
    /// required field is missing or has the wrong type.
    init?(record: PrimitiveRecord)

    /// Project the typed value into a value dictionary the storage layer can
    /// persist. Omit `id` — it's written separately.
    func primitiveValues() -> [String: PrimitiveValue]
}
