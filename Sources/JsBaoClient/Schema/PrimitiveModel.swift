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
/// `PrimitiveRow` bag, which is `@unchecked Sendable` with a written safety
/// argument),
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

public extension PrimitiveRowDecodable {
    /// Decode from the shared row bag. Same decode as `init?(row:)` — the bag
    /// is a `Sendable` wrapper around exactly that dictionary — so generated
    /// `compactMap { Model(row: $0) }` call sites bind unchanged whether the
    /// page hands them `[String: Any]` or a `PrimitiveRow` (#1992).
    init?(row: PrimitiveRow) {
        self.init(row: row.raw)
    }
}

/// The one untyped row representation in the client: a `Sendable` bag of the
/// `[String: Any]` a storage-layer row actually is, with typed accessors for
/// query-time includes.
///
/// This is a generalization of what used to be `RelatedRecords` (the
/// `_related` attachment on generated models), promoted to cover paginated
/// query results as well. `RelatedRecords` remains as a spelling of the same
/// type — deliberately ONE abstraction rather than two competing unchecked
/// dictionary wrappers.
///
/// ## `@unchecked Sendable` — safety argument (#1992, Phase C)
///
/// The bag's `Sendable` claim rests on the value domain being **recursively
/// immutable value types**, not on any lock:
///
/// - `raw` is a `let`, set once at construction and never mutated afterwards.
///   Include resolution mutates `[[String: Any]]` *before* the rows are
///   wrapped (`IncludeResolver.resolve(rows:includes:depth:)` takes an
///   `inout` array), never through the bag.
/// - Every leaf value comes from one of two producers and both produce Swift
///   value types only: `BaoModelQueryEngine.executeQuery` emits `Int`,
///   `Double`, and `String` (SQL NULLs are omitted, not boxed), and the
///   stringset population pass emits `[String]`.
/// - The nested case is the point Codex raised on the design: after
///   `IncludeResolver` runs, a row also carries `_related`, itself a
///   `[String: Any]` whose values are a related row (`[String: Any]`) or an
///   array of them (`[[String: Any]]`), nested up to the depth-3 cap. Those
///   nested rows are produced by the same two producers, so the domain closes
///   over itself: **the transitive contents are `Int` / `Double` / `String` /
///   `[String]` / `[String: Any]` / `[[String: Any]]` and nothing else.**
///   `Dictionary`, `Array`, and `String` are copy-on-write value types, so two
///   threads reading the same bag either read distinct copies or an immutable
///   shared buffer.
/// - No reference type ever enters a row. In particular no `YDocument`, no
///   `DynamicModel`, no `PrimitiveRecord`, and no mutable Foundation object
///   (`NSMutableDictionary`/`NSMutableArray`) is ever written into one. An
///   `NSNull` sentinel, if a caller puts one in, is an immutable singleton and
///   does not weaken the argument.
///
/// The claim is therefore checkable by inspecting the row producers, which is
/// the honesty bar this phase set. It would be broken by writing a mutable
/// reference type into a row dictionary before wrapping it — don't.
public struct PrimitiveRow: @unchecked Sendable, Codable, Equatable, Hashable {
    public static let empty = PrimitiveRow(raw: [:])

    /// The underlying row. Treat as read-only — see the safety argument.
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
