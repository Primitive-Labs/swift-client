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
/// Refines `Sendable`: every codegen'd conformer is a value struct whose
/// stored properties are all `Sendable` (scalars, `String`, `Set<String>`,
/// nested value enums, and `RelatedRecords`, which is `@unchecked Sendable`),
/// so the conformance is satisfied automatically. This makes the metatype
/// `any PrimitiveModel.Type` `Sendable`, which lets it be stored on the
/// `Sendable` `CsvImportOptions.model` field without an escape hatch.
public protocol PrimitiveModel: Sendable {
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

/// A generated model that can decode directly from a SQLite-backed query row.
/// The codegen'd facade uses this for query-time includes: the base row and
/// any `_related` rows are all row dictionaries at the storage boundary.
public protocol PrimitiveRowDecodable {
    init?(row: [String: Any])
}

/// Related records attached by query-time includes. Mirrors JS rows' `_related`
/// bag while keeping the generated Swift model surface typed through
/// `one(_:as:)` and `many(_:as:)`.
public struct RelatedRecords: @unchecked Sendable, Codable, Equatable, Hashable {
    public static let empty = RelatedRecords(raw: [:])

    public let raw: [String: Any]

    public init(raw: [String: Any] = [:]) {
        self.raw = raw
    }

    public subscript(key: String) -> Any? {
        raw[key]
    }

    public func contains(_ key: String) -> Bool {
        raw[key] != nil
    }

    public func one<T: PrimitiveRowDecodable>(_ key: String, as type: T.Type = T.self) -> T? {
        guard let row = raw[key] as? [String: Any] else { return nil }
        return T(row: row)
    }

    public func many<T: PrimitiveRowDecodable>(_ key: String, as type: T.Type = T.self) -> [T] {
        guard let rows = raw[key] as? [[String: Any]] else { return [] }
        return rows.compactMap { T(row: $0) }
    }

    public init(from decoder: Decoder) throws {
        self.raw = [:]
    }

    public func encode(to encoder: Encoder) throws {
        // `_related` is a query result attachment, not persisted model data.
    }

    public static func == (lhs: RelatedRecords, rhs: RelatedRecords) -> Bool {
        true
    }

    public func hash(into hasher: inout Hasher) {}
}

/// A stored row exists but no longer decodes as its generated typed model —
/// the persisted data has drifted from the typed schema (e.g. a required
/// field is missing or holds the wrong type).
///
/// Thrown by the generated `Model.find(_:)` / `Model.findAll()` facade
/// (#992). JS has no decode step — `Model.find` resolves `null` *only* for
/// "not found" and `Model.findAll` returns every stored row — so the Swift
/// facade keeps `nil`/omission strictly for "not found" and surfaces a
/// drifted row as this error instead of silently dropping it.
public struct PrimitiveDecodeError: Error, Sendable, Equatable {
    /// The model whose row failed to decode (TOML model name).
    public let modelName: String
    /// The id of the row that failed to decode. Empty when the stored row
    /// has no readable `id` at all.
    public let recordId: String
    /// The open document the row came from, when known.
    public let documentId: String?

    public init(modelName: String, recordId: String, documentId: String? = nil) {
        self.modelName = modelName
        self.recordId = recordId
        self.documentId = documentId
    }

    /// Build from a shared-store row dictionary (reads `id` and the
    /// `_meta_doc_id` routing column the cross-document store adds).
    public init(modelName: String, row: [String: Any]) {
        self.init(
            modelName: modelName,
            recordId: row["id"] as? String ?? "",
            documentId: row["_meta_doc_id"] as? String
        )
    }
}

extension PrimitiveDecodeError: LocalizedError {
    public var errorDescription: String? {
        var msg = "Stored record"
        if !recordId.isEmpty { msg += " `\(recordId)`" }
        msg += " of model `\(modelName)` failed to decode as its generated typed model — the stored data has drifted from the typed schema."
        if let documentId { msg += " (document: \(documentId))" }
        return msg
    }
}
