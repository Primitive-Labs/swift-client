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
        // Build a JSON object manually to control key order and
        // PrimitiveValue unwrapping. The JSON shape is fixed:
        //   {"values":{...},"sortFields":[...],"direction":1|-1}
        var valueDict: [String: Any] = [:]
        for (k, v) in data.values {
            valueDict[k] = primitiveToAny(v)
        }
        let dict: [String: Any] = [
            "values":     valueDict,
            "sortFields": data.sortFields,
            "direction":  data.direction,
        ]
        guard JSONSerialization.isValidJSONObject(dict) else {
            throw InvalidCursorError(reason: "Unencodable cursor values")
        }
        let jsonData = try JSONSerialization.data(
            withJSONObject: dict, options: []
        )
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
        guard let any = try? JSONSerialization.jsonObject(
            with: raw, options: []
        ) else {
            throw InvalidCursorError(
                reason: "Base64 payload isn't JSON",
                cursor: cursor
            )
        }
        guard let dict = any as? [String: Any] else {
            throw InvalidCursorError(
                reason: "Cursor JSON must be an object",
                cursor: cursor
            )
        }
        guard let rawValues = dict["values"] as? [String: Any] else {
            throw InvalidCursorError(
                reason: "Cursor missing 'values' object",
                cursor: cursor
            )
        }
        guard let sortFields = dict["sortFields"] as? [String] else {
            throw InvalidCursorError(
                reason: "Cursor missing 'sortFields' array",
                cursor: cursor
            )
        }
        guard let direction = dict["direction"] as? Int,
              direction == 1 || direction == -1 else {
            throw InvalidCursorError(
                reason: "Cursor 'direction' must be 1 or -1",
                cursor: cursor
            )
        }
        var values: [String: PrimitiveValue] = [:]
        for (k, v) in rawValues {
            values[k] = anyToPrimitive(v)
        }
        return CursorData(
            values: values, sortFields: sortFields, direction: direction
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

        for i in 0..<cursor.sortFields.count {
            var parts: [String] = []
            var levelParams: [Any] = []

            // Equality on every earlier field.
            for j in 0..<i {
                let f = cursor.sortFields[j]
                parts.append("\(fieldFormatter(f)) = ?")
                levelParams.append(sqlValue(cursor.values[f]))
            }

            // Comparison on the current field.
            let currentField = cursor.sortFields[i]
            let fieldDir = sortDirections[safe: i] ?? 1
            let forwardOp = fieldDir == 1 ? ">" : "<"
            let op: String = {
                switch direction {
                case .forward:  return forwardOp
                case .backward: return forwardOp == ">" ? "<" : ">"
                }
            }()
            parts.append("\(fieldFormatter(currentField)) \(op) ?")
            levelParams.append(sqlValue(cursor.values[currentField]))

            conditions.append("(" + parts.joined(separator: " AND ") + ")")
            params.append(contentsOf: levelParams)
        }

        let sql = "(" + conditions.joined(separator: " OR ") + ")"
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
    public static func generateResultCursors(
        rows: [[String: Any]],
        sortFields: [String],
        direction: CursorDirection,
        hasMore: Bool,
        isFirstPage: Bool
    ) throws -> (next: String?, prev: String?) {
        guard let first = rows.first, let last = rows.last else {
            return (nil, nil)
        }
        let next: String? = hasMore
            ? try cursorFromRow(last, sortFields: sortFields, direction: direction)
            : nil
        let prev: String? = isFirstPage
            ? nil
            : try cursorFromRow(
                first,
                sortFields: sortFields,
                direction: direction == .forward ? .backward : .forward
              )
        return (next, prev)
    }

    private static func cursorFromRow(
        _ row: [String: Any],
        sortFields: [String],
        direction: CursorDirection
    ) throws -> String {
        var values: [String: PrimitiveValue] = [:]
        for f in sortFields {
            guard let raw = row[f] else {
                throw InvalidCursorError(
                    reason:
                        "Row missing sort field '\(f)'; cannot generate cursor"
                )
            }
            values[f] = anyToPrimitive(raw)
        }
        return try encodeCursor(CursorData(
            values: values,
            sortFields: sortFields,
            direction: direction.jsBaoValue
        ))
    }

    // MARK: - Value conversion

    /// `PrimitiveValue → JSON-serializable` for encoding.
    private static func primitiveToAny(_ v: PrimitiveValue) -> Any {
        switch v {
        case let .string(s):    return s
        case let .number(n):    return n
        case let .boolean(b):   return b
        case let .id(s):        return s
        case let .date(s):      return s
        case let .stringset(s): return Array(s).sorted()
        case let .json(d):      return String(data: d, encoding: .utf8) ?? ""
        }
    }

    /// `JSON value → PrimitiveValue` for decoding. Reconstructs a
    /// best-guess type from raw JSON — we don't have field-type info at
    /// the cursor layer, only the value.
    private static func anyToPrimitive(_ v: Any) -> PrimitiveValue {
        if let s = v as? String      { return .string(s) }
        if let b = v as? Bool        { return .boolean(b) }
        if let n = v as? Double      { return .number(n) }
        if let n = v as? Int         { return .number(Double(n)) }
        if let n = v as? Int64       { return .number(Double(n)) }
        if let arr = v as? [String]  {
            return .stringset(Set(arr))
        }
        // Fallback — treat unknown as an empty string.
        return .string("")
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
