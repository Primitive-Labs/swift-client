import Foundation

/// Translates MongoDB-style DocumentFilter into SQL WHERE clauses.
///
/// Supports: $eq, $ne, $gt, $gte, $lt, $lte, $in, $nin,
///           $containsText, $startsWith, $endsWith, $exists, $and, $or,
///           $contains (stringset-only)
///
/// Stringset fields need special handling because the SQLite mirror
/// stores them as a comma-joined CSV string in a TEXT column. The
/// translator detects stringset columns via the `stringsetFields`
/// set passed by the engine and routes `$contains` through a
/// delimiter-padded LIKE so we get boundary-safe membership checks.
public struct QueryTranslator {

    /// Translate a DocumentFilter into a SQL WHERE clause and parameter bindings.
    /// Returns (whereClause, parameters). The whereClause does NOT include "WHERE".
    ///
    /// - Parameter stringsetFields: names of fields whose column stores a
    ///   comma-joined stringset. The `$contains` operator dispatches
    ///   differently for these.
    /// - Parameter stringFields: when non-nil, scalar substring operators
    ///   (`$startsWith`, `$endsWith`, `$containsText`) require their
    ///   target field to be in this set (or in `stringsetFields`).
    ///   Filters that violate the rule emit `0` (match nothing) instead
    ///   of silently running LIKE against a non-string column (which
    ///   SQLite would coerce, producing surprising matches like
    ///   `priority $startsWith "1"` matching `priority = 10`). Matches
    ///   js-bao's `DocumentQueryTranslator.ts:309` field-type gate
    ///   (which throws there; we emit `0` because the Swift surface
    ///   is non-throwing). Nil keeps the legacy value-driven path for
    ///   callers that don't supply schema info.
    public static func translate(
        _ filter: DocumentFilter,
        stringsetFields: Set<String> = [],
        stringFields: Set<String>? = nil,
        tableName: String? = nil
    ) -> (String, [Any]) {
        var conditions: [String] = []
        var params: [Any] = []

        for (key, value) in filter {
            if key == "$and", let arr = value as? [DocumentFilter] {
                let sub = arr.map { translate($0, stringsetFields: stringsetFields, stringFields: stringFields, tableName: tableName) }
                let joined = sub.map { "(\($0.0))" }.joined(separator: " AND ")
                if !joined.isEmpty {
                    conditions.append("(\(joined))")
                    for s in sub { params.append(contentsOf: s.1) }
                }
            } else if key == "$or", let arr = value as? [DocumentFilter] {
                let sub = arr.map { translate($0, stringsetFields: stringsetFields, stringFields: stringFields, tableName: tableName) }
                let joined = sub.map { "(\($0.0))" }.joined(separator: " OR ")
                if !joined.isEmpty {
                    conditions.append("(\(joined))")
                    for s in sub { params.append(contentsOf: s.1) }
                }
            } else if let ops = value as? [String: Any] {
                // Operator expression: { "field": { "$gt": 5 } }
                for (op, opVal) in ops {
                    let (cond, p) = translateOperator(
                        field: key, op: op, value: opVal,
                        stringsetFields: stringsetFields,
                        stringFields: stringFields,
                        tableName: tableName
                    )
                    conditions.append(cond)
                    params.append(contentsOf: p)
                }
            } else {
                // Simple equality: { "field": value }
                if value is NSNull {
                    conditions.append("\(quoted(key)) IS NULL")
                } else {
                    conditions.append("\(quoted(key)) = ?")
                    params.append(sqlValue(value))
                }
            }
        }

        if conditions.isEmpty {
            return ("1=1", [])
        }
        return (conditions.joined(separator: " AND "), params)
    }

    private static func translateOperator(
        field: String,
        op: String,
        value: Any,
        stringsetFields: Set<String> = [],
        stringFields: Set<String>? = nil,
        tableName: String? = nil
    ) -> (String, [Any]) {
        let col = quoted(field)

        // Substring-op field-type gate (matches js-bao
        // DocumentQueryTranslator.ts:309). If the caller supplied
        // `stringFields` and this is a substring op, the target field
        // must be a string or stringset. Otherwise we emit `0` rather
        // than letting SQLite coerce a numeric/boolean column to text
        // and silently match digits.
        if let stringFields,
           op == "$startsWith" || op == "$endsWith" || op == "$containsText",
           !stringFields.contains(field),
           !stringsetFields.contains(field) {
            return ("0", [])
        }

        switch op {
        case "$eq":
            if value is NSNull { return ("\(col) IS NULL", []) }
            return ("\(col) = ?", [sqlValue(value)])

        case "$ne":
            if value is NSNull { return ("\(col) IS NOT NULL", []) }
            // Exclude NULL rows so the result set matches js-bao
            // (browser.ts `$ne` emits `col != ?`, which SQLite evaluates
            // as UNKNOWN for NULL → row excluded). The earlier OR-NULL
            // wing made `field $ne X` behave like "anything except X,
            // including missing", which silently disagreed with the JS
            // client on a very common query shape.
            return ("\(col) != ?", [sqlValue(value)])

        case "$gt":
            return ("\(col) > ?", [sqlValue(value)])
        case "$gte":
            return ("\(col) >= ?", [sqlValue(value)])
        case "$lt":
            return ("\(col) < ?", [sqlValue(value)])
        case "$lte":
            return ("\(col) <= ?", [sqlValue(value)])

        case "$in":
            if let arr = value as? [Any], !arr.isEmpty {
                let placeholders = arr.map { _ in "?" }.joined(separator: ",")
                return ("\(col) IN (\(placeholders))", arr.map { sqlValue($0) })
            }
            return ("0", []) // empty $in matches nothing

        case "$nin":
            if let arr = value as? [Any], !arr.isEmpty {
                let placeholders = arr.map { _ in "?" }.joined(separator: ",")
                // Same NULL-handling alignment as `$ne` above — exclude
                // missing values so result sets match js-bao.
                return ("\(col) NOT IN (\(placeholders))", arr.map { sqlValue($0) })
            }
            return ("1", []) // empty $nin matches everything

        case "$containsText":
            // On a stringset field the substring ops match ANY member
            // via EXISTS against the junction — mirrors js-bao
            // browser.js:703-769. On a scalar string column they
            // continue to match the column value directly.
            if stringsetFields.contains(field) {
                return stringsetSubstringSQL(field: field, value: value,
                                              pattern: .contains,
                                              tableName: tableName)
            }
            if let text = value as? String {
                let prepared = prepareSubstringQuery(text)
                return ("\(col) LIKE ? ESCAPE '\\' COLLATE NOCASE", ["%\(escapeLike(prepared))%"])
            }
            // Non-string value on a substring operator: js-bao throws.
            // Translator can't throw with this API, so emit a clause
            // that matches nothing — the practical analogue ("invalid
            // input → no rows"). Strictly better than the prior `1=1`,
            // which silently returned every row.
            return ("0", [])

        case "$startsWith":
            if stringsetFields.contains(field) {
                return stringsetSubstringSQL(field: field, value: value,
                                              pattern: .startsWith,
                                              tableName: tableName)
            }
            if let text = value as? String {
                let prepared = prepareSubstringQuery(text)
                return ("\(col) LIKE ? ESCAPE '\\' COLLATE NOCASE", ["\(escapeLike(prepared))%"])
            }
            return ("0", [])

        case "$endsWith":
            if stringsetFields.contains(field) {
                return stringsetSubstringSQL(field: field, value: value,
                                              pattern: .endsWith,
                                              tableName: tableName)
            }
            if let text = value as? String {
                let prepared = prepareSubstringQuery(text)
                return ("\(col) LIKE ? ESCAPE '\\' COLLATE NOCASE", ["%\(escapeLike(prepared))"])
            }
            return ("0", [])

        case "$exists":
            let exists = (value as? Bool) ?? true
            return (exists ? "\(col) IS NOT NULL" : "\(col) IS NULL", [])

        case "$contains":
            // Stringset membership via EXISTS against the per-field
            // junction table `{main}__{field}`. Exact equality on
            // `value`, so any member alphabet works (commas, unicode,
            // etc.). Matches js-bao's browser.js design.
            guard stringsetFields.contains(field) else {
                assertionFailure("QueryTranslator: $contains is only valid on stringset fields (got '\(field)')")
                NSLog("[QueryTranslator] WARNING: $contains on non-stringset field '\(field)' — filter dropped")
                return ("0", [])
            }
            guard let member = value as? String, !member.isEmpty else {
                assertionFailure("QueryTranslator: $contains requires a non-empty string value (field '\(field)')")
                return ("0", [])
            }
            guard let tableName else {
                // Engine didn't supply the main-table name — can't
                // reference the outer row's id in the EXISTS subquery.
                assertionFailure("QueryTranslator: $contains needs tableName context from the caller")
                return ("0", [])
            }
            let junction = "\(tableName)__\(field)"
            // Correlated EXISTS against the junction. Outer query is
            // `SELECT ... FROM "{tableName}"` unaliased, so we
            // reference `"{tableName}".id` directly. Also correlate on
            // `_meta_doc_id` so a shared-engine (multi-doc) query
            // can't match a different doc's junction rows whose
            // `parent_id` happens to collide. DynamicModel and
            // MultiDocModel always ensure the junction with
            // `_meta_doc_id` (via withDocIdColumn: true), so this is
            // always safe.
            return (
                """
                EXISTS (
                    SELECT 1 FROM \(quoted(junction))
                    WHERE \(quoted(junction))."parent_id" = \(quoted(tableName))."id"
                      AND \(quoted(junction))."_meta_doc_id" = \(quoted(tableName))."_meta_doc_id"
                      AND \(quoted(junction))."value" = ?
                )
                """,
                [member]
            )

        default:
            // Unknown operator: trap in debug builds so typos surface during
            // development, and in release builds fall back to "0" (matches
            // nothing). Returning "1=1" (the previous behavior) silently
            // matched all rows, which produced very confusing query results
            // when the caller had a typo.
            assertionFailure("QueryTranslator: unknown operator '\(op)' on field '\(field)'")
            NSLog("[QueryTranslator] WARNING: unknown operator '\(op)' on field '\(field)' — filter dropped")
            return ("0", [])
        }
    }

    /// Build ORDER BY clause from sort options.
    public static func buildOrderBy(_ sort: [String: Int]) -> String {
        if sort.isEmpty { return "" }
        let clauses = sort.map { (field, dir) in
            "\(quoted(field)) \(dir >= 0 ? "ASC" : "DESC")"
        }
        return "ORDER BY \(clauses.joined(separator: ", "))"
    }

    /// Build LIMIT/OFFSET clause.
    public static func buildLimitOffset(limit: Int?, offset: Int?) -> String {
        var sql = ""
        if let limit { sql += "LIMIT \(limit)" }
        if let offset { sql += " OFFSET \(offset)" }
        return sql
    }

    /// Build a full aggregation query.
    public static func buildAggregation(
        tableName: String,
        options: AggregateOptions,
        stringsetFields: Set<String> = [],
        stringFields: Set<String>? = nil
    ) -> (String, [Any]) {
        var selectClauses: [String] = []
        var params: [Any] = []

        // Group by fields
        for field in options.groupBy {
            selectClauses.append("\(quoted(field))")
        }

        // Aggregation operations
        for op in options.operations {
            switch op.type {
            case .count:
                selectClauses.append("COUNT(*) AS \(quoted(op.resultKey))")
            case .sum:
                if let field = op.field {
                    selectClauses.append("SUM(CAST(\(quoted(field)) AS REAL)) AS \(quoted(op.resultKey))")
                }
            case .avg:
                if let field = op.field {
                    selectClauses.append("AVG(CAST(\(quoted(field)) AS REAL)) AS \(quoted(op.resultKey))")
                }
            case .min:
                if let field = op.field {
                    selectClauses.append("MIN(\(quoted(field))) AS \(quoted(op.resultKey))")
                }
            case .max:
                if let field = op.field {
                    selectClauses.append("MAX(\(quoted(field))) AS \(quoted(op.resultKey))")
                }
            }
        }

        if selectClauses.isEmpty {
            selectClauses.append("COUNT(*) AS count")
        }

        var sql = "SELECT \(selectClauses.joined(separator: ", ")) FROM \(quoted(tableName))"

        // WHERE clause from filter
        if let filter = options.filter, !filter.isEmpty {
            let (where_, whereParams) = translate(
                filter, stringsetFields: stringsetFields,
                stringFields: stringFields,
                tableName: tableName
            )
            sql += " WHERE \(where_)"
            params.append(contentsOf: whereParams)
        }

        // GROUP BY
        if !options.groupBy.isEmpty {
            sql += " GROUP BY \(options.groupBy.map { quoted($0) }.joined(separator: ", "))"
        }

        // ORDER BY. Aggregate sort can reference either a group-by
        // field or an operation's output alias — we sort on the alias
        // directly; SQLite resolves the identifier either way.
        if let sort = options.sort {
            let dir = sort.direction == -1 ? "DESC" : "ASC"
            sql += " ORDER BY \(quoted(sort.field)) \(dir)"
        }

        if let limit = options.limit, limit >= 0 {
            sql += " LIMIT \(limit)"
        }

        return (sql, params)
    }

    // MARK: - Helpers

    /// How a substring op wraps the search text as a `LIKE` pattern.
    private enum SubstringPattern {
        case startsWith, endsWith, contains

        func likeValue(_ text: String) -> String {
            let e = escapeLikeStatic(text)
            switch self {
            case .startsWith: return "\(e)%"
            case .endsWith:   return "%\(e)"
            case .contains:   return "%\(e)%"
            }
        }
    }

    /// EXISTS subquery against the stringset junction table: matches
    /// when ANY member's `value` column satisfies the LIKE pattern.
    /// Correlates on both `parent_id` and `_meta_doc_id` so a shared-
    /// engine multi-doc query can't match a different doc's rows.
    private static func stringsetSubstringSQL(
        field: String,
        value: Any,
        pattern: SubstringPattern,
        tableName: String?
    ) -> (String, [Any]) {
        guard let tableName else {
            assertionFailure("QueryTranslator: substring op on stringset needs tableName context")
            return ("0", [])
        }
        guard let raw = value as? String else {
            // Non-string value on a substring op: js-bao throws; we
            // can't throw from here, so emit a never-matches clause.
            return ("0", [])
        }
        let text = prepareSubstringQuery(raw)
        guard !text.isEmpty else {
            // Empty (or whitespace-only) input after trim: matches
            // nothing rather than the prior `1=1` everything-matches.
            return ("0", [])
        }
        let junction = "\(tableName)__\(field)"
        let sql = """
        EXISTS (
            SELECT 1 FROM \(quoted(junction))
            WHERE \(quoted(junction))."parent_id" = \(quoted(tableName))."id"
              AND \(quoted(junction))."_meta_doc_id" = \(quoted(tableName))."_meta_doc_id"
              AND \(quoted(junction))."value" LIKE ? ESCAPE '\\' COLLATE NOCASE
        )
        """
        return (sql, [pattern.likeValue(text)])
    }

    /// Trim whitespace + cap at 1024 chars to match js-bao's contract
    /// for `$containsText` / `$startsWith` / `$endsWith` inputs
    /// (browser.ts caps to 1024 and rejects whitespace-only). Strictly
    /// better than the previous "pass the raw caller string straight to
    /// SQLite as a LIKE pattern" — that path silently differed from JS
    /// for `"  widget  "` (Swift didn't match, JS did) and for over-1024
    /// inputs (Swift ran an oversize LIKE pattern, JS threw).
    ///
    /// We can't throw from this code path with the current non-throws
    /// translator API, so we cap silently. Strict-throws would be a
    /// follow-up tied to making `dynamic.query(...)` throws-aware.
    private static func prepareSubstringQuery(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 1024 { return trimmed }
        let cap = trimmed.index(trimmed.startIndex, offsetBy: 1024)
        return String(trimmed[..<cap])
    }

    /// `escapeLike` is a static helper on the type; the nested
    /// `SubstringPattern` enum needs a callable form without `self`.
    private static func escapeLikeStatic(_ text: String) -> String {
        escapeLike(text)
    }

    private static func quoted(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func escapeLike(_ text: String) -> String {
        // Escape backslash first so subsequent replacements don't double-escape.
        // The corresponding LIKE clause uses ESCAPE '\' to recognise this.
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func sqlValue(_ value: Any) -> Any {
        if let b = value as? Bool { return b ? 1 : 0 }
        return value
    }
}
