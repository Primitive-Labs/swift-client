import Foundation

/// Forward or backward through a sorted query. Passed to
/// `DynamicModel.queryPaged` alongside a cursor string.
public enum CursorDirection: Sendable, Equatable {
    case forward
    case backward

    /// js-bao encodes direction as 1 or -1 in the cursor JSON. We
    /// round-trip through this representation so our cursors are
    /// byte-compatible with js-bao on the JSON layer.
    var jsBaoValue: Int { self == .forward ? 1 : -1 }

    init?(jsBaoValue: Int) {
        switch jsBaoValue {
        case 1:  self = .forward
        case -1: self = .backward
        default: return nil
        }
    }
}

/// Decoded cursor payload. Mirrors js-bao's `CursorData` exactly —
/// `{ values: { field: val }, sortFields: [field], direction: 1|-1 }`
/// base64-encoded as the on-wire token.
///
/// A sort field whose value is SQL NULL — absent from the record, or stored as
/// null — is represented by the ABSENCE of its key in `values` (#3228).
/// `PrimitiveValue` has no null case, and it needs none: the payload's null is
/// written and read off `sortFields`, and `buildPaginationConditions` already
/// looks values up optionally. On the wire the key is always present and
/// carries an explicit JSON `null`, byte-compatible with js-bao.
public struct CursorData: Equatable, Sendable {
    public var values: [String: PrimitiveValue]
    public var sortFields: [String]
    public var direction: Int   // 1 or -1

    public init(
        values: [String: PrimitiveValue],
        sortFields: [String],
        direction: Int
    ) {
        self.values = values
        self.sortFields = sortFields
        self.direction = direction
    }
}

/// Thrown when a cursor string is malformed, its values don't decode,
/// or its encoded sort fields don't match the query's current sort.
public struct InvalidCursorError: Error, CustomStringConvertible {
    public let reason: String
    public let cursorText: String?
    public init(reason: String, cursor: String? = nil) {
        self.reason = reason
        self.cursorText = cursor
    }
    public var description: String {
        cursorText.map { "InvalidCursorError(\(reason); cursor=\($0))" }
            ?? "InvalidCursorError(\(reason))"
    }
}

/// Encode / decode / WHERE-clause generation for opaque pagination
/// cursors. Ported from js-bao's `src/query/CursorManager.ts`
/// — semantics match exactly, including the lexicographic pagination
/// conditions and sort-mismatch validation.
public enum CursorManager {

    // MARK: - Encode / decode

    /// Serialize a `CursorData` to a base64-encoded JSON string.
    /// Byte-compatible with js-bao's `encodeCursor` — the JSON is
    /// UTF-8 and uses standard base64.
    public static func encodeCursor(_ data: CursorData) throws -> String {
        // The JSON shape is fixed:
        //   {"values":{...},"sortFields":[...],"direction":1|-1}
        // Keyed off `sortFields`, not off `values`: a field with no value is a
        // SQL NULL and has to reach the wire as an explicit `null` (#3228), the
        // way js-bao's `generateCursor` writes it. Any extra key `values`
        // carries is preserved so the payload stays a superset, as before.
        var valueObject: [String: JSONValue] = [:]
        for field in data.sortFields {
            valueObject[field] = data.values[field].map(primitiveToJSON) ?? .null
        }
        for (k, v) in data.values where valueObject[k] == nil {
            valueObject[k] = primitiveToJSON(v)
        }
        let payload: JSONValue = .object([
            "values":     .object(valueObject),
            "sortFields": .array(data.sortFields.map { .string($0) }),
            "direction":  .number(Double(data.direction)),
        ])
        guard let jsonData = try? JSONCoding.encodeData(payload) else {
            throw InvalidCursorError(reason: "Unencodable cursor values")
        }
        return jsonData.base64EncodedString()
    }

    /// Decode a base64-encoded cursor back into a `CursorData`.
    public static func decodeCursor(_ cursor: String) throws -> CursorData {
        guard let raw = Data(base64Encoded: cursor) else {
            throw InvalidCursorError(
                reason: "Not valid base64",
                cursor: cursor
            )
        }
        guard let payload = try? JSONCoding.decodeData(JSONValue.self, from: raw) else {
            throw InvalidCursorError(
                reason: "Base64 payload isn't JSON",
                cursor: cursor
            )
        }
        guard let dict = payload.objectValue else {
            throw InvalidCursorError(
                reason: "Cursor JSON must be an object",
                cursor: cursor
            )
        }
        guard let rawValues = dict["values"]?.objectValue else {
            throw InvalidCursorError(
                reason: "Cursor missing 'values' object",
                cursor: cursor
            )
        }
        guard let sortFields = dict["sortFields"]?.stringArrayValue else {
            throw InvalidCursorError(
                reason: "Cursor missing 'sortFields' array",
                cursor: cursor
            )
        }
        guard let rawDirection = dict["direction"]?.numberValue,
              rawDirection == 1 || rawDirection == -1 else {
            throw InvalidCursorError(
                reason: "Cursor 'direction' must be 1 or -1",
                cursor: cursor
            )
        }
        var values: [String: PrimitiveValue] = [:]
        for (k, v) in rawValues {
            // An explicit JSON `null` is a SQL NULL, recorded as an absent key
            // (#3228). It must NOT go through `jsonToPrimitive`, whose fallback
            // would turn it into `.string("")` and compare `field = ''` — a
            // js-bao-minted null cursor would then match nothing here.
            if case .null = v { continue }
            values[k] = jsonToPrimitive(v)
        }
        return CursorData(
            values: values, sortFields: sortFields, direction: Int(rawDirection)
        )
    }

    // MARK: - Lexicographic WHERE

    /// Build the lexicographic pagination clause. Mirrors
    /// `CursorManager.buildPaginationConditions` in js-bao.
    ///
    /// For `sortFields = [a, b, c]` with per-field directions, forward
    /// pagination produces:
    ///
    ///   (a > ?) OR (a = ? AND b > ?) OR (a = ? AND b = ? AND c > ?)
    ///
    /// Backward flips `>` to `<`. Per-field `DESC` also flips `>` to `<`
    /// for that level. Values bound to `?` come from the cursor's
    /// `values` dict.
    ///
    /// NULL-aware (#3228), matching js-bao rule for rule. SQLite orders NULL
    /// before every value, so absent and null sort values sit at the FRONT of
    /// an ascending output order and at the TAIL of a descending one — here,
    /// in the Cloudflare DO's SQLite and in better-sqlite3 alike, which is why
    /// the ORDER BY does not change. What changes is that a null cursor value
    /// no longer binds `NSNull` into a comparison, which SQLite evaluates as
    /// UNKNOWN so the next page matched nothing:
    ///
    ///   - equality level, null value      → `field IS NULL`      (no parameter)
    ///   - `>` (nulls at the front), value → `field > ?`          (unchanged)
    ///   - `>` (nulls at the front), null  → `field IS NOT NULL`  (no parameter)
    ///   - `<` (nulls at the tail), value  → `(field < ? OR field IS NULL)`
    ///   - `<` (nulls at the tail), null   → the level matches nothing and is
    ///     dropped; the deeper `field IS NULL AND <tiebreak>` levels carry the
    ///     walk through the null run.
    ///
    /// `id` is exempt — a non-null primary key on every engine — so the default
    /// `sort: [id]` SQL and every non-null `>` level are byte-identical to what
    /// they were.
    public static func buildPaginationConditions(
        cursor: CursorData,
        currentSortFields: [String],
        sortDirections: [Int],
        direction: CursorDirection,
        fieldFormatter: (String) -> String = { $0 }
    ) throws -> (sql: String, params: [Any]) {
        guard cursor.sortFields == currentSortFields else {
            throw InvalidCursorError(
                reason:
                    "Cursor sort fields [\(cursor.sortFields.joined(separator: ", "))] "
                    + "don't match query sort fields "
                    + "[\(currentSortFields.joined(separator: ", "))]"
            )
        }

        var conditions: [String] = []
        var params: [Any] = []

        // `id` is the always-appended tiebreaker and a non-null primary key on
        // every engine, so it never receives NULL handling.
        func nullable(_ field: String) -> Bool { field != "id" }
        func isNull(_ field: String) -> Bool {
            nullable(field) && cursor.values[field] == nil
        }

        for i in 0..<cursor.sortFields.count {
            var parts: [String] = []
            var levelParams: [Any] = []

            // Equality on every earlier field.
            for j in 0..<i {
                let f = cursor.sortFields[j]
                if isNull(f) {
                    parts.append("\(fieldFormatter(f)) IS NULL")
                    continue
                }
                parts.append("\(fieldFormatter(f)) = ?")
                levelParams.append(sqlValue(cursor.values[f]))
            }

            // Comparison on the current field.
            let currentField = cursor.sortFields[i]
            let currentSql = fieldFormatter(currentField)
            let fieldDir = sortDirections[safe: i] ?? 1
            let forwardOp = fieldDir == 1 ? ">" : "<"
            let op: String = {
                switch direction {
                case .forward:  return forwardOp
                case .backward: return forwardOp == ">" ? "<" : ">"
                }
            }()

            if isNull(currentField) {
                if op == "<" {
                    // Nulls are at the tail and the cursor is already inside
                    // that run: no row is "less than" NULL, so this level
                    // matches nothing and the deeper levels walk the run.
                    continue
                }
                // Nulls are at the front and the cursor is inside that run:
                // every non-null row is later in the output order.
                parts.append("\(currentSql) IS NOT NULL")
            } else if op == "<" && nullable(currentField) {
                // Nulls are at the tail, so they are later in the output order
                // than any real value and must be matched alongside the
                // smaller ones. The disjunction only needs its own parens when
                // this level also carries equality conditions to AND it with.
                let disjunction = "\(currentSql) < ? OR \(currentSql) IS NULL"
                parts.append(parts.isEmpty ? disjunction : "(\(disjunction))")
                levelParams.append(sqlValue(cursor.values[currentField]))
            } else {
                parts.append("\(currentSql) \(op) ?")
                levelParams.append(sqlValue(cursor.values[currentField]))
            }

            conditions.append("(" + parts.joined(separator: " AND ") + ")")
            params.append(contentsOf: levelParams)
        }

        // Every sort ends in the non-nullable `id` tiebreaker, so at least one
        // level always survives; `1 = 0` keeps the clause valid SQL rather than
        // emitting an empty `()`.
        let sql = conditions.isEmpty
            ? "(1 = 0)"
            : "(" + conditions.joined(separator: " OR ") + ")"
        return (sql, params)
    }

    // MARK: - Generate cursors from results

    /// Produce `nextCursor` and `prevCursor` tokens from the first /
    /// last rows of a result page.
    ///
    /// - `isFirstPage`: `prevCursor` is nil on the first page by
    ///   convention (matches js-bao).
    /// - `hasMore`: `nextCursor` is only emitted when there could be
    ///   another page.
    /// - `aliasedSortFields`: the sort fields this SELECT carried under an
    ///   internal alias because the projection omits them (#3228). Only these
    ///   are read from their alias, so nothing a caller stored under a
    ///   similar-looking name is mistaken for a sort value.
    public static func generateResultCursors(
        rows: [[String: JSONValue]],
        sortFields: [String],
        direction: CursorDirection,
        hasMore: Bool,
        isFirstPage: Bool,
        aliasedSortFields: [String] = []
    ) throws -> (next: String?, prev: String?) {
        guard let first = rows.first, let last = rows.last else {
            return (nil, nil)
        }
        let aliased = Set(aliasedSortFields)
        let next: String? = hasMore
            ? try cursorFromRow(
                last,
                sortFields: sortFields,
                direction: direction,
                aliasedSortFields: aliased
              )
            : nil
        let prev: String? = isFirstPage
            ? nil
            : try cursorFromRow(
                first,
                sortFields: sortFields,
                direction: direction == .forward ? .backward : .forward,
                aliasedSortFields: aliased
              )
        return (next, prev)
    }

    /// Build a cursor from one result row.
    ///
    /// A sort field the row does not carry is a SQL NULL and is recorded as
    /// such (#3228) instead of throwing: `executeQuery` omits NULL columns from
    /// its row dictionaries, so every record that never wrote the sort field
    /// arrives here with no key, and a page that had already been read was
    /// failing at cursor-minting time.
    ///
    /// A value the caller's projection omitted is read from the internal alias
    /// the SELECT carried it under (see ``sortValueAlias(_:)``), so a projected
    /// query's cursor holds the row's REAL value rather than a false null.
    /// `aliasedSortFields` names exactly the fields that got that treatment, so
    /// a row key is never interpreted by its shape.
    private static func cursorFromRow(
        _ row: [String: JSONValue],
        sortFields: [String],
        direction: CursorDirection,
        aliasedSortFields: Set<String> = []
    ) throws -> String {
        var values: [String: PrimitiveValue] = [:]
        for f in sortFields {
            let key = aliasedSortFields.contains(f) ? sortValueAlias(f) : f
            guard let raw = row[key] else { continue }
            if case .null = raw { continue }
            values[f] = jsonToPrimitive(raw)
        }
        return try encodeCursor(CursorData(
            values: values,
            sortFields: sortFields,
            direction: direction.jsBaoValue
        ))
    }

    // MARK: - Internal sort-value aliases (#3228)

    /// Column-alias prefix under which `BaoModelQueryEngine` selects a sort
    /// field the caller's inclusion projection omits.
    ///
    /// Sorting on an unprojected field is a permitted query shape, and the
    /// boundary row would otherwise arrive with no sort-field key —
    /// indistinguishable from a record that never wrote one. A cursor minted
    /// from it would carry a false null and the next page's `IS NOT NULL`
    /// predicate would replay the page just returned.
    ///
    /// The prefix ends in `:`, which no field name may contain, so the alias can
    /// never be the name of a column a caller stored — a `_`-prefixed-only
    /// alias was not enough, since a model schema declares its own columns and
    /// the reserved-name rule is not enforced at declaration time. The JS side
    /// uses the same string.
    public static let sortValueAliasPrefix = "_cursor:"

    /// Column alias under which a sort field's value is selected internally.
    public static func sortValueAlias(_ field: String) -> String {
        sortValueAliasPrefix + field
    }

    /// Drop the internally selected sort values from a row before it is handed
    /// to the caller, so response shapes are unchanged. `aliasedSortFields`
    /// names exactly the fields this SELECT aliased, so a column the caller
    /// asked for is never dropped.
    public static func stripSortValueAliases(
        _ row: [String: JSONValue],
        aliasedSortFields: [String]
    ) -> [String: JSONValue] {
        guard !aliasedSortFields.isEmpty else { return row }
        var stripped = row
        for field in aliasedSortFields {
            stripped.removeValue(forKey: sortValueAlias(field))
        }
        return stripped
    }

    // MARK: - Value conversion

    /// `PrimitiveValue → JSONValue` for encoding.
    private static func primitiveToJSON(_ v: PrimitiveValue) -> JSONValue {
        switch v {
        case let .string(s):    return .string(s)
        case let .number(n):    return .number(n)
        case let .boolean(b):   return .bool(b)
        case let .id(s):        return .string(s)
        case let .date(s):      return .string(s)
        case let .stringset(s): return .array(Array(s).sorted().map { .string($0) })
        case let .json(d):      return .string(String(data: d, encoding: .utf8) ?? "")
        }
    }

    /// `JSONValue → PrimitiveValue` for decoding. Reconstructs a
    /// best-guess type from raw JSON — we don't have field-type info at
    /// the cursor layer, only the value.
    private static func jsonToPrimitive(_ v: JSONValue) -> PrimitiveValue {
        switch v {
        case let .string(s):  return .string(s)
        case let .bool(b):    return .boolean(b)
        case let .number(n):  return .number(n)
        case let .array(a):   return .stringset(Set(a.compactMap { $0.stringValue }))
        // Fallback — treat unknown as an empty string.
        case .object, .null:  return .string("")
        }
    }

    /// `PrimitiveValue → SQLite-bind-friendly Any` used when binding
    /// cursor values as SQL params. Uses raw scalar types (String,
    /// Double, Bool) matching `BaoModelQueryEngine.bindValue`.
    private static func sqlValue(_ v: PrimitiveValue?) -> Any {
        guard let v else { return NSNull() }
        switch v {
        case let .string(s):    return s
        case let .number(n):    return n
        case let .boolean(b):   return b
        case let .id(s):        return s
        case let .date(s):      return s
        case let .stringset(s): return Array(s).joined(separator: ",")
        case let .json(d):      return String(data: d, encoding: .utf8) ?? ""
        }
    }
}

// MARK: - Helpers

private extension Array {
    subscript(safe i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}
