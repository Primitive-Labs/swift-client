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
    ///
    /// Group-by clauses are partitioned three ways (mirroring js-bao):
    ///   - **regular** field → plain `GROUP BY "table"."field"`;
    ///   - **stringset facet** (a `.field` whose name is a stringset) →
    ///     INNER JOIN the member junction and group by member `value`;
    ///   - **stringset membership** (`.stringSetMembership`) → LEFT JOIN
    ///     the junction on a specific value and group by a `true`/`false`
    ///     CASE on whether the member is present.
    ///
    /// Output stays flat `[[String: Any]]` rows (Swift's idiom) rather
    /// than js-bao's nested map. `scopedToDocId`, when set, scopes the
    /// query to one document — woven into the WHERE here (not spliced by
    /// the caller) so its bind param lands after any JOIN params.
    public static func buildAggregation(
        tableName: String,
        options: AggregateOptions,
        stringsetFields: Set<String> = [],
        stringFields: Set<String>? = nil,
        scopedToDocId: String? = nil
    ) -> (String, [Any]) {
        var regularFields: [String] = []
        var facetFields: [String] = []
        var memberships: [(field: String, contains: String)] = []
        for clause in options.groupBy {
            switch clause {
            case let .field(name):
                if stringsetFields.contains(name) { facetFields.append(name) }
                else { regularFields.append(name) }
            case let .stringSetMembership(field, contains):
                memberships.append((field, contains))
            }
        }

        // StringSet *facet* grouping (group by a stringset field's member
        // values) only applies as a pure, single-facet group-by — mirroring
        // js-bao's `BaseModel.buildAggregationQuery`:
        //   - exactly one facet, no other clauses → facet query;
        //   - a facet combined with regular/membership clauses → js-bao falls
        //     through to its "regular" branch, which DROPS the facet field;
        //   - two or more facet fields → js-bao rejects it (a *recoverable*
        //     400, "Multiple StringSet facet fields not supported").
        // The whole aggregate surface is non-throwing (`-> [[String: Any]]` at
        // every layer), so we DEGRADE here rather than crash the host app: a
        // pure single facet runs; a pure multi-facet returns no rows; anything
        // mixed drops the facet and proceeds as regular aggregation.
        if regularFields.isEmpty && memberships.isEmpty && !facetFields.isEmpty {
            if facetFields.count == 1 {
                return buildFacetAggregation(
                    tableName: tableName, facetField: facetFields[0],
                    options: options, stringsetFields: stringsetFields,
                    stringFields: stringFields, scopedToDocId: scopedToDocId
                )
            }
            // 2+ pure facet fields: unsupported shape (js-bao 400s here). Return
            // a guaranteed-empty result instead of aborting the caller.
            log.warn(
                "aggregate: grouping by multiple stringset facet fields is "
                + "unsupported (\(facetFields)); returning no rows. Group by a "
                + "single facet field, or combine facets with regular / "
                + "membership group-bys."
            )
            return ("SELECT NULL WHERE 0", [])
        }

        // No facet, or a facet mixed with regular/membership clauses. In the
        // mixed case the facet fields are intentionally dropped (matches
        // js-bao's regular branch); regular + membership grouping (or a global
        // rollup when both are empty) proceeds normally.
        return buildRegularAggregation(
            tableName: tableName, regularFields: regularFields,
            memberships: memberships, options: options,
            stringsetFields: stringsetFields, stringFields: stringFields,
            scopedToDocId: scopedToDocId
        )
    }

    /// Warn-level logger for recoverable-but-degraded aggregate shapes
    /// (e.g. an unsupported multi-facet group-by). Always emits warnings;
    /// the aggregate surface is non-throwing, so this is how those cases
    /// surface instead of an exception.
    private static let log = Logger(level: .warn, scope: "QueryTranslator")

    /// Regular field grouping (qualified) plus zero-or-more StringSet
    /// membership group keys via correlated LEFT JOINs.
    private static func buildRegularAggregation(
        tableName: String,
        regularFields: [String],
        memberships: [(field: String, contains: String)],
        options: AggregateOptions,
        stringsetFields: Set<String>,
        stringFields: Set<String>?,
        scopedToDocId: String?
    ) -> (String, [Any]) {
        let t = quoted(tableName)
        var params: [Any] = []
        var selectClauses: [String] = []
        var groupByClauses: [String] = []
        var joinClauses: [String] = []

        for field in regularFields {
            selectClauses.append("\(t).\(quoted(field))")
            groupByClauses.append("\(t).\(quoted(field))")
        }

        var usedAliases = Set<String>()
        for membership in memberships {
            var alias = membershipAlias(field: membership.field, contains: membership.contains)
            var n = 1
            while usedAliases.contains(alias) {
                alias = membershipAlias(field: membership.field, contains: membership.contains) + "_\(n)"
                n += 1
            }
            usedAliases.insert(alias)
            let a = quoted(alias)
            let junction = quoted("\(tableName)__\(membership.field)")
            // Correlate on parent_id AND _meta_doc_id (shared multi-doc
            // engine) and the specific member value — at most one match
            // per record, so COUNT(*) doesn't multiply.
            joinClauses.append(
                "LEFT JOIN \(junction) AS \(a) ON \(a).\"parent_id\" = \(t).\"id\""
                + " AND \(a).\"_meta_doc_id\" = \(t).\"_meta_doc_id\""
                + " AND \(a).\"value\" = ?"
            )
            params.append(membership.contains)
            let caseExpr = "CASE WHEN \(a).\"parent_id\" IS NOT NULL THEN 'true' ELSE 'false' END"
            selectClauses.append("\(caseExpr) AS \(a)")
            groupByClauses.append(caseExpr)
        }

        appendOperations(options.operations, table: t, into: &selectClauses)
        if selectClauses.isEmpty { selectClauses.append("COUNT(*) AS \"count\"") }

        var sql = "SELECT \(selectClauses.joined(separator: ", ")) FROM \(t)"
        if !joinClauses.isEmpty { sql += " " + joinClauses.joined(separator: " ") }

        // WHERE: doc-scope predicate (param after the JOIN params) then filter.
        var whereParts: [String] = []
        if scopedToDocId != nil { whereParts.append("\(t).\"_meta_doc_id\" = ?") }
        var filterParts: (String, [Any])? = nil
        if let filter = options.filter, !filter.isEmpty {
            filterParts = translate(
                filter, stringsetFields: stringsetFields,
                stringFields: stringFields, tableName: tableName
            )
        }
        if let docId = scopedToDocId { params.append(docId) }
        if let (clause, fParams) = filterParts {
            whereParts.append(clause)
            params.append(contentsOf: fParams)
        }
        if !whereParts.isEmpty { sql += " WHERE " + whereParts.joined(separator: " AND ") }

        if !groupByClauses.isEmpty {
            sql += " GROUP BY \(groupByClauses.joined(separator: ", "))"
        }
        sql += aggregateOrderLimit(options)
        return (sql, params)
    }

    /// StringSet facet grouping: one row per distinct member value of the
    /// faceted field, with the count (and any ops) of records carrying it.
    private static func buildFacetAggregation(
        tableName: String,
        facetField: String,
        options: AggregateOptions,
        stringsetFields: Set<String>,
        stringFields: Set<String>?,
        scopedToDocId: String?
    ) -> (String, [Any]) {
        let t = quoted(tableName)
        let junction = quoted("\(tableName)__\(facetField)")
        var params: [Any] = []
        var selectClauses: [String] = ["\(junction).\"value\" AS \(quoted(facetField))"]
        appendOperations(options.operations, table: t, into: &selectClauses)
        if options.operations.isEmpty { selectClauses.append("COUNT(*) AS \"count\"") }

        var sql = "SELECT \(selectClauses.joined(separator: ", ")) FROM \(junction)"
            + " INNER JOIN \(t) ON \(junction).\"parent_id\" = \(t).\"id\""
            + " AND \(junction).\"_meta_doc_id\" = \(t).\"_meta_doc_id\""

        var whereParts: [String] = []
        if scopedToDocId != nil { whereParts.append("\(t).\"_meta_doc_id\" = ?") }
        var filterParts: (String, [Any])? = nil
        if let filter = options.filter, !filter.isEmpty {
            filterParts = translate(
                filter, stringsetFields: stringsetFields,
                stringFields: stringFields, tableName: tableName
            )
        }
        if let docId = scopedToDocId { params.append(docId) }
        if let (clause, fParams) = filterParts {
            whereParts.append(clause)
            params.append(contentsOf: fParams)
        }
        if !whereParts.isEmpty { sql += " WHERE " + whereParts.joined(separator: " AND ") }

        sql += " GROUP BY \(junction).\"value\""
        sql += aggregateOrderLimit(options)
        return (sql, params)
    }

    /// Append `count`/`sum`/`avg`/`min`/`max` SELECT clauses, qualifying
    /// each operand field with the main table `t`.
    private static func appendOperations(
        _ operations: [AggregateOperation],
        table t: String,
        into clauses: inout [String]
    ) {
        for op in operations {
            switch op.type {
            case .count:
                clauses.append("COUNT(*) AS \(quoted(op.resultKey))")
            case .sum:
                if let field = op.field {
                    clauses.append("SUM(CAST(\(t).\(quoted(field)) AS REAL)) AS \(quoted(op.resultKey))")
                }
            case .avg:
                if let field = op.field {
                    clauses.append("AVG(CAST(\(t).\(quoted(field)) AS REAL)) AS \(quoted(op.resultKey))")
                }
            case .min:
                if let field = op.field {
                    clauses.append("MIN(\(t).\(quoted(field))) AS \(quoted(op.resultKey))")
                }
            case .max:
                if let field = op.field {
                    clauses.append("MAX(\(t).\(quoted(field))) AS \(quoted(op.resultKey))")
                }
            }
        }
    }

    /// ORDER BY (by group-by field or an op's output alias — SQLite
    /// resolves the identifier either way) + LIMIT.
    private static func aggregateOrderLimit(_ options: AggregateOptions) -> String {
        var sql = ""
        if let sort = options.sort {
            let dir = sort.direction == -1 ? "DESC" : "ASC"
            sql += " ORDER BY \(quoted(sort.field)) \(dir)"
        }
        if let limit = options.limit, limit >= 0 {
            sql += " LIMIT \(limit)"
        }
        return sql
    }

    /// Deterministic, SQL-safe alias for a membership group key. The
    /// actual match value is bound as a parameter, so alias sanitization
    /// only affects the output column name (`has_<field>_<contains>`).
    private static func membershipAlias(field: String, contains: String) -> String {
        func san(_ s: String) -> String {
            String(s.map { ($0.isLetter || $0.isNumber) ? $0 : "_" })
        }
        return "has_\(san(field))_\(san(contains))"
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
