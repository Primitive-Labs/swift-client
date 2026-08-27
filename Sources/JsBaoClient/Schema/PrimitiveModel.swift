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
/// nested value enums, and `RelatedRecords` — a spelling of the shared
/// `PrimitiveRow` bag, whose `[String: JSONValue]` contents are `Sendable`),
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
    init?(row: [String: JSONValue])
}

public extension PrimitiveRowDecodable {
    /// Decode from the shared row bag. Same decode as `init?(row:)` — the bag
    /// is a wrapper around exactly that dictionary — so generated
    /// `compactMap { Model(row: $0) }` call sites bind unchanged whether the
    /// page hands them `[String: JSONValue]` or a `PrimitiveRow` (#1992).
    init?(row: PrimitiveRow) {
        self.init(row: row.raw)
    }
}

/// The one schemaless row representation in the client: a bag of the
/// `[String: JSONValue]` a storage-layer row is, with typed accessors for
/// query-time includes.
///
/// This is a generalization of what used to be `RelatedRecords` (the
/// `_related` attachment on generated models), promoted to cover paginated
/// query results as well. `RelatedRecords` remains as a spelling of the same
/// type — deliberately ONE abstraction rather than two competing row
/// wrappers.
///
/// ## Row values are `JSONValue`
///
/// Every leaf is a `JSONValue`, so the bag is `Sendable` by checked
/// conformance rather than by argument (#2546). Read a column with the typed
/// accessors — `row["title"]?.stringValue`, `row["priority"]?.numberValue`,
/// `row["done"]?.rowBoolValue`, `row["tags"]?.stringArrayValue` — or reach
/// `raw` for the dictionary itself.
///
/// Numbers arrive as `.number(Double)`: SQLite INTEGER and REAL columns both
/// land there, matching how the typed model layer already reads every numeric
/// field as `Double`.
public struct PrimitiveRow: Sendable, Codable, Equatable, Hashable {
    public static let empty = PrimitiveRow(raw: [:])

    /// The underlying row. Treat as read-only.
    public let raw: [String: JSONValue]

    public init(raw: [String: JSONValue] = [:]) {
        self.raw = raw
    }

    public subscript(key: String) -> JSONValue? {
        raw[key]
    }

    public func contains(_ key: String) -> Bool {
        raw[key] != nil
    }

    public func one<T: PrimitiveRowDecodable>(_ key: String, as type: T.Type = T.self) -> T? {
        guard let row = raw[key]?.objectValue else { return nil }
        return T(row: row)
    }

    public func many<T: PrimitiveRowDecodable>(_ key: String, as type: T.Type = T.self) -> [T] {
        guard let rows = raw[key]?.arrayValue else { return [] }
        return rows.compactMap { $0.objectValue.flatMap { T(row: $0) } }
    }

    // MARK: - Codable / Equatable / Hashable are deliberately content-free
    //
    // A row bag is a query-result attachment, not persisted model data: it is
    // never encoded, and a generated model's synthesized `==` / `hash` must
    // not vary with an include payload that was or wasn't requested. So
    // decoding yields an empty bag, encoding writes nothing, any two bags
    // compare equal, and every bag hashes the same. To compare row CONTENTS,
    // compare the fields you care about out of `raw` — do not use `==`.

    public init(from decoder: Decoder) throws {
        self.raw = [:]
    }

    public func encode(to encoder: Encoder) throws {
        // `_related` is a query result attachment, not persisted model data.
    }

    public static func == (lhs: PrimitiveRow, rhs: PrimitiveRow) -> Bool {
        true
    }

    public func hash(into hasher: inout Hasher) {}
}

/// Related records attached by query-time includes. Mirrors JS rows' `_related`
/// bag while keeping the generated Swift model surface typed through
/// `one(_:as:)` and `many(_:as:)`.
///
/// The `_related` spelling of the shared `PrimitiveRow` bag — same type, kept
/// so generated models and existing call sites read as before (#1992).
public typealias RelatedRecords = PrimitiveRow

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
    /// The required field(s) the row could not supply — missing, NULL, or
    /// holding a value the declared type can't read. Sorted, and empty when
    /// the error was built without a schema to check against (#2825).
    public let fields: [String]

    public init(
        modelName: String,
        recordId: String,
        documentId: String? = nil,
        fields: [String] = []
    ) {
        self.modelName = modelName
        self.recordId = recordId
        self.documentId = documentId
        self.fields = fields
    }

    /// Build from a shared-store row dictionary (reads `id` and the
    /// `_meta_doc_id` routing column the cross-document store adds).
    public init(modelName: String, row: [String: JSONValue]) {
        self.init(
            modelName: modelName,
            recordId: row["id"]?.stringValue ?? "",
            documentId: row["_meta_doc_id"]?.stringValue
        )
    }

    /// Build from a row plus the schema it failed against, so the error names
    /// the offending field(s) — the difference between "a row vanished" and a
    /// one-line diagnosis (#2825).
    public init(modelName: String, row: [String: JSONValue], schema: PrimitiveSchema) {
        self.init(
            modelName: modelName,
            recordId: row["id"]?.stringValue ?? "",
            documentId: row["_meta_doc_id"]?.stringValue,
            fields: PrimitiveDecodeError.unreadableFields(row: row, schema: schema)
        )
    }

    /// The required fields of `schema` that `row` can't supply, under the same
    /// read rules the generated `init?(row:)` uses (`rowBoolValue` for
    /// booleans, `stringArrayValue` for stringsets, the matching accessor
    /// otherwise). `id` is always required and always reads as a string.
    ///
    /// This is a diagnosis of a decode that already failed, not a second
    /// gate: an optional field that reads as nil is not why the row dropped,
    /// so optionals never appear.
    static func unreadableFields(row: [String: JSONValue], schema: PrimitiveSchema) -> [String] {
        var out: [String] = []
        if row["id"]?.stringValue == nil { out.append("id") }
        for (name, descriptor) in schema.fields where name != "id" && descriptor.required {
            if !canRead(row[name], as: descriptor.type) { out.append(name) }
        }
        return out.sorted()
    }

    private static func canRead(_ value: JSONValue?, as type: PrimitiveFieldType) -> Bool {
        guard let value else { return false }
        switch type {
        case .string, .id, .date, .json: return value.stringValue != nil
        case .number:                    return value.numberValue != nil
        case .boolean:                   return value.rowBoolValue != nil
        case .stringset:                 return value.stringArrayValue != nil
        }
    }
}

extension PrimitiveDecodeError: LocalizedError {
    public var errorDescription: String? {
        var msg = "Stored record"
        if !recordId.isEmpty { msg += " `\(recordId)`" }
        msg += " of model `\(modelName)` failed to decode as its generated typed model — the stored data has drifted from the typed schema."
        if !fields.isEmpty {
            msg += " Unreadable required field(s): \(fields.joined(separator: ", "))."
        }
        if let documentId { msg += " (document: \(documentId))" }
        return msg
    }
}
