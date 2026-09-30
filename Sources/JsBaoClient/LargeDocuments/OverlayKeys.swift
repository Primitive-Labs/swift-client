import Foundation

/// A string compared and hashed by its UTF-8 BYTES.
///
/// Swift's `String` is equal under canonical equivalence: `"a\u{0301}"` and
/// `"\u{00E1}"` are ONE `Set` element and ONE dictionary key. SQLite, yrs and
/// the JS client all keep them as two — which is exactly why
/// ``compareRecordIds(_:_:)`` orders by bytes, and why the id it says are two
/// different records must not become one on the way through a Swift
/// collection. Anything keyed by a record id, an overlay key or a stringset
/// member is keyed by this.
///
/// Storing the bytes rather than recomputing them: these keys are compared
/// once per fold per key, on the declared hot path.
public struct ByteKey: Hashable, Sendable, CustomStringConvertible {

    /// The text itself, for the caller that has to hand it on.
    public let value: String
    private let bytes: [UInt8]

    public init(_ value: String) {
        self.value = value
        self.bytes = Array(value.utf8)
    }

    public static func == (left: ByteKey, right: ByteKey) -> Bool {
        left.bytes == right.bytes
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(bytes) }

    public var description: String { value }
}

/// The format-2 epoch overlay's on-the-wire grammar (#3436).
///
/// A large document is no longer "one Y.Doc": the authoritative document is a
/// persisted SQLite `records` table on both ends, and the Y.Doc shrinks to a
/// bounded per-epoch **state overlay** of the records and fields touched
/// during the current epoch. Each model map holds FLAT entries:
///
/// ```
/// ⟨recordId⟩/⟨field⟩            → value      ordinary field (null = unset)
/// ⟨recordId⟩/⟨field⟩/⟨member⟩   → true|false stringset member / tombstone
/// ⟨recordId⟩/_replace           → true       discard the base row
/// ⟨recordId⟩/_deleted           → true|false record tombstone
/// ```
///
/// A nested `Y.Map` per record cannot work under epochs: two clients that both
/// touch a record ABSENT from the current epoch each mint a fresh map at the
/// same model-map key, and Yjs resolves that parent-key conflict as
/// last-writer-wins, silently dropping the loser's fields. With flat keys
/// concurrency resolves per field, so a concurrent create-and-patch merges to
/// the union of fields with last-writer-wins only on genuinely colliding ones.
///
/// This is a port of `packages/js-bao/src/utils/largeDocuments.ts`, and it is
/// held to it by the parity suite rather than by review: the DO's
/// authoritative table, the JS client's merged view and this one all have to
/// read the same overlay the same way.
public enum OverlayKeys {

    /// Separator between the record-id, field and member segments.
    public static let separator = "/"

    /// Marker key: the create discards the base row and writes exactly its
    /// fields.
    public static let markerReplace = "_replace"

    /// Marker key: the record is deleted (a bare Yjs key delete is invisible
    /// to a peer that never saw the key).
    public static let markerDeleted = "_deleted"

    private static let markers: Set<String> = [markerReplace, markerDeleted]

    // MARK: - Segment escaping

    /// Escape one key segment so the key stays unambiguous.
    ///
    /// Record ids are ULIDs and always safe, but field and member names are
    /// user data: they may contain the separator, the escape character, or
    /// start with the `_` that marks a marker key. RFC 6901-flavoured:
    ///
    /// - `~` → `~0`
    /// - `/` → `~1`
    /// - a LEADING `_` → `~2` (so a field literally named `_replace` can never
    ///   be read back as the marker, which is written unescaped)
    ///
    /// Order matters: `~` is escaped first, or the `~1` written for a slash
    /// would itself be escaped to `~01`.
    public static func encodeSegment(_ segment: String) -> String {
        let escaped = segment
            .replacingOccurrences(of: "~", with: "~0")
            .replacingOccurrences(of: "/", with: "~1")
        guard escaped.hasPrefix("_") else { return escaped }
        return "~2" + escaped.dropFirst()
    }

    /// Inverse of ``encodeSegment(_:)``.
    public static func decodeSegment(_ segment: String) -> String {
        let withUnderscore = segment.hasPrefix("~2")
            ? "_" + segment.dropFirst(2)
            : segment
        return withUnderscore
            .replacingOccurrences(of: "~1", with: "/")
            .replacingOccurrences(of: "~0", with: "~")
    }

    // MARK: - Key construction

    /// Overlay key for an ordinary field of a record.
    public static func fieldKey(recordId: String, field: String) -> String {
        "\(encodeSegment(recordId))\(separator)\(encodeSegment(field))"
    }

    /// Overlay key for one stringset member of a record's field.
    public static func memberKey(recordId: String, field: String, member: String) -> String {
        "\(fieldKey(recordId: recordId, field: field))\(separator)\(encodeSegment(member))"
    }

    /// Overlay key for a record-level marker, written unescaped by
    /// construction — that is what ``encodeSegment(_:)``'s `~2` rule protects.
    public static func markerKey(recordId: String, marker: String) -> String {
        "\(encodeSegment(recordId))\(separator)\(marker)"
    }

    /// What every overlay key of one record starts with.
    public static func recordPrefix(_ recordId: String) -> String {
        "\(encodeSegment(recordId))\(separator)"
    }

    // MARK: - Parsing

    /// The parts an overlay key decodes to.
    public struct Parsed: Equatable, Sendable {
        public let recordId: String
        public let field: String?
        public let member: String?
        public let marker: String?
    }

    /// Decode an overlay key back into its parts; `nil` when it is malformed.
    ///
    /// Two segments is a field or a marker, three is a stringset member, and
    /// anything else is not an overlay key — a model map may hold keys this
    /// grammar did not write, and reading one as a record would mint a row.
    public static func parse(_ key: String) -> Parsed? {
        let parts = key.components(separatedBy: separator)
        if parts.count == 2 {
            let recordId = decodeSegment(parts[0])
            if markers.contains(parts[1]) {
                return Parsed(recordId: recordId, field: nil, member: nil, marker: parts[1])
            }
            return Parsed(
                recordId: recordId, field: decodeSegment(parts[1]), member: nil, marker: nil
            )
        }
        if parts.count == 3 {
            return Parsed(
                recordId: decodeSegment(parts[0]),
                field: decodeSegment(parts[1]),
                member: decodeSegment(parts[2]),
                marker: nil
            )
        }
        return nil
    }

    // MARK: - Grouping

    /// Regroup a model map's flat entries into one ``OverlayRecordEntry`` per
    /// record. Keys this grammar does not recognize are skipped.
    ///
    /// Keyed by ``ByteKey``, not by `String`: two record ids that Swift calls
    /// equal because they are canonically equivalent are two records
    /// everywhere else in this system, and grouping them under one `String`
    /// key would merge one record's fields into the other's — silently, and
    /// with no later check able to notice.
    ///
    /// One signature, deliberately: an overload taking the labelled
    /// `(key:value:)` tuple looks like a convenience and is a trap — Swift
    /// converts labelled and unlabelled tuples freely, so the two resolve to
    /// each other and the pair recurses until the stack ends.
    public static func group<S: Sequence>(
        _ entries: S
    ) -> [ByteKey: OverlayRecordEntry] where S.Element == (String, JSONValue) {
        var out: [ByteKey: OverlayRecordEntry] = [:]
        for (key, value) in entries {
            guard let parsed = parse(key) else { continue }
            let recordKey = ByteKey(parsed.recordId)
            var entry = out[recordKey] ?? OverlayRecordEntry(id: parsed.recordId)
            if parsed.marker == markerReplace {
                entry.replace = (value == .bool(true))
            } else if parsed.marker == markerDeleted {
                entry.deleted = (value == .bool(true))
            } else if let member = parsed.member, let field = parsed.field {
                entry.stringSets[field, default: [:]][member] = (value == .bool(true))
            } else if let field = parsed.field {
                entry.fields[field] = value
            }
            out[recordKey] = entry
        }
        return out
    }

    // MARK: - Encoding a mutation

    /// Encode a mutation into the flat entries it writes, in the order they
    /// must be written.
    public static func encode(_ mutation: OverlayMutation) -> [(key: String, value: JSONValue)] {
        var entries: [(key: String, value: JSONValue)] = []

        if mutation.kind == .delete {
            entries.append((markerKey(recordId: mutation.id, marker: markerDeleted), .bool(true)))
            return entries
        }

        if mutation.kind == .create {
            entries.append((markerKey(recordId: mutation.id, marker: markerReplace), .bool(true)))
            // A re-create must overwrite an earlier tombstone: under key-level
            // last-writer-wins a surviving `_deleted → true` would otherwise
            // outlive the re-created row.
            entries.append((markerKey(recordId: mutation.id, marker: markerDeleted), .bool(false)))
        }

        // Field order is the caller's; a Swift dictionary has none of its own,
        // so sort for a deterministic frame. The fold is order-free at the
        // record level, so this is about reproducibility, not correctness.
        for field in mutation.fields.keys.sorted() {
            entries.append((
                fieldKey(recordId: mutation.id, field: field),
                mutation.fields[field] ?? .null
            ))
        }
        for field in mutation.stringSetDeltas.keys.sorted() {
            let members = mutation.stringSetDeltas[field] ?? [:]
            for member in members.keys.sorted() {
                entries.append((
                    memberKey(recordId: mutation.id, field: field, member: member),
                    .bool(members[member] ?? false)
                ))
            }
        }
        return entries
    }
}

/// One record's overlay content, regrouped from its flat keys.
public struct OverlayRecordEntry: Equatable, Sendable {
    public let id: String
    /// Touched ordinary fields. A `.null` value is an explicit unset (RFC 7396).
    public var fields: [String: JSONValue]
    /// Touched stringset members per field: `member → true` add, `false`
    /// tombstone.
    public var stringSets: [String: [String: Bool]]
    /// The create discarded the base row.
    public var replace: Bool
    /// The record is tombstoned.
    public var deleted: Bool

    public init(
        id: String,
        fields: [String: JSONValue] = [:],
        stringSets: [String: [String: Bool]] = [:],
        replace: Bool = false,
        deleted: Bool = false
    ) {
        self.id = id
        self.fields = fields
        self.stringSets = stringSets
        self.replace = replace
        self.deleted = deleted
    }
}

/// A record mutation expressed in overlay terms, before it is encoded to keys.
public struct OverlayMutation: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// Writes `_replace` (the id is absent from the merged view) and
        /// clears any prior `_deleted`.
        case create
        /// Touches only the named fields.
        case patch
        /// Writes the `_deleted` tombstone.
        case delete
    }

    public let id: String
    public let kind: Kind
    /// Ordinary field values; `.null` is an explicit unset.
    public let fields: [String: JSONValue]
    /// Per-field stringset deltas: `member → true` add, `false` remove.
    public let stringSetDeltas: [String: [String: Bool]]

    public init(
        id: String,
        kind: Kind,
        fields: [String: JSONValue] = [:],
        stringSetDeltas: [String: [String: Bool]] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.fields = fields
        self.stringSetDeltas = stringSetDeltas
    }
}

/// The per-document table names a client's record store writes to.
///
/// One client database can hold several connected documents at once, and the
/// merged view of one must never be readable as another's — so the tables are
/// scoped by the document id. The id is hex-encoded **per UTF-16 code unit**,
/// four digits each, exactly as `format2TableNames` in js-bao does it: a
/// document id is user-supplied text and a table name is not, and a database
/// written by either client has to read on the other.
public struct Format2TableNames: Equatable, Sendable {
    public let records: String
    public let stringSetIndex: String

    public init(documentId: String) {
        let hex = documentId.utf16.map { String(format: "%04x", $0) }.joined()
        self.records = "records_f2_\(hex)"
        self.stringSetIndex = "stringset_index_f2_\(hex)"
    }
}
