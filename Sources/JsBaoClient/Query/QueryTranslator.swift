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
    ///   (which throws — and now so do we: a substring op on a
    ///   non-string/-stringset field throws `JsBaoError(.invalidArgument)`).
    ///   Nil keeps the legacy value-driven path for callers that don't
    ///   supply schema info.
    /// - Parameter fieldTypes: per-field type name (`"number"`, `"string"`,
    ///   `"stringset"`, …) used only to fill the `fieldType` detail on a
    ///   thrown substring error, mirroring js-bao's `InvalidOperatorError`.
    ///
    /// Throws `JsBaoError(.invalidArgument)` when a `$startsWith` /
    /// `$endsWith` / `$containsText` operator targets a non-string/-stringset
    /// field, is given a non-string value, exceeds 1024 characters, or when
    /// more than one substring operator is used on the same field — matching
    /// js-bao's `DocumentQueryTranslator` throw points.
    public static func translate(
        _ filter: DocumentFilter,
        stringsetFields: Set<String> = [],
        stringFields: Set<String>? = nil,
        fieldTypes: [String: String]? = nil,
        tableName: String? = nil
    ) throws -> (String, [Any]) {
        var conditions: [String] = []
        var params: [Any] = []

        for (key, value) in filter {
            if key == "$and", let arr = value as? [DocumentFilter] {
                let sub = try arr.map { try translate($0, stringsetFields: stringsetFields, stringFields: stringFields, fieldTypes: fieldTypes, tableName: tableName) }
                let joined = sub.map { "(\($0.0))" }.joined(separator: " AND ")
                if !joined.isEmpty {
                    conditions.append("(\(joined))")
                    for s in sub { params.append(contentsOf: s.1) }
                }
            } else if key == "$or", let arr = value as? [DocumentFilter] {
                let sub = try arr.map { try translate($0, stringsetFields: stringsetFields, stringFields: stringFields, fieldTypes: fieldTypes, tableName: tableName) }
                let joined = sub.map { "(\($0.0))" }.joined(separator: " OR ")
                if !joined.isEmpty {
                    conditions.append("(\(joined))")
                    for s in sub { params.append(contentsOf: s.1) }
                }
            } else if let ops = value as? [String: Any] {
                // Operator expression: { "field": { "$gt": 5 } }.
                //
                // Validate "at most one substring op per field" BEFORE the
                // per-op loop. Swift processes each field operator
                // independently, so the loop alone can't enforce js-bao's
                // `DocumentQueryTranslator.ts:296-303` rule — hoist it here.
                let present = substringOpNames.filter { ops.keys.contains($0) }
                if present.count > 1 {
                    let type = fieldTypeName(
                        key, fieldTypes: fieldTypes, stringsetFields: stringsetFields
                    )
                    throw substringError(
                        "Only one of $startsWith, $endsWith, $containsText may be used per field",
                        field: key, op: present[1], fieldType: type
                    )
                }
                for (op, opVal) in ops {
                    // A substring op on a whitespace-only value contributes
                    // NO condition (js-bao `buildLikePattern` returns null) —
                    // `translateOperator` returns nil for that case, so we
                    // skip it rather than appending a false `0` clause.
                    if let (cond, p) = try translateOperator(
                        field: key, op: op, value: opVal,
                        stringsetFields: stringsetFields,
                        stringFields: stringFields,
                        fieldTypes: fieldTypes,
                        tableName: tableName
                    ) {
                        conditions.append(cond)
                        params.append(contentsOf: p)
                    }
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

    /// Translate one `{ field: { op: value } }` operator into a SQL
    /// condition. Returns `nil` when the operator contributes no condition
    /// (a substring op on a whitespace-only value — js-bao's
    /// `buildLikePattern` null no-op). Throws `JsBaoError(.invalidArgument)`
    /// on the substring-op error cases js-bao throws on.
    private static func translateOperator(
        field: String,
        op: String,
        value: Any,
        stringsetFields: Set<String> = [],
        stringFields: Set<String>? = nil,
        fieldTypes: [String: String]? = nil,
        tableName: String? = nil
    ) throws -> (String, [Any])? {
        let col = quoted(field)

        // Substring operators ($startsWith / $endsWith / $containsText)
        // share one validate-then-build path so the scalar and stringset
        // sides apply the same field-type gate, value-type check, trimming,
        // empty no-op, escaping, and oversize throw — matching js-bao's
        // `DocumentQueryTranslator.ts:308-341`.
        if let mode = SubstringPattern(operatorName: op) {
            let type = fieldTypeName(
                field, fieldTypes: fieldTypes, stringsetFields: stringsetFields
            )
            // Field-type gate (js-bao DocumentQueryTranslator.ts:308-315).
            // When the caller supplied `stringFields`, a substring op's
            // target must be a string or stringset field; otherwise throw
            // rather than let SQLite coerce a numeric/boolean column to text.
            if let stringFields,
               !stringFields.contains(field),
               !stringsetFields.contains(field) {
                throw substringError(
                    "\(op) operator is only supported for string and stringset fields, field \(field) is type \(type)",
                    field: field, op: op, fieldType: type
                )
            }
            // Value-type check (js-bao DocumentQueryTranslator.ts:316-323).
            guard let raw = value as? String else {
                throw substringError(
                    "\(op) operator requires a string value for field \(field)",
                    field: field, op: op, fieldType: type
                )
            }
            // Build the LIKE pattern (trims, throws on oversize). A nil
            // pattern means whitespace-only input → no condition at all.
            guard let pattern = try buildSubstringPattern(
                raw, mode: mode, field: field, op: op, fieldType: type
            ) else {
                return nil
            }
            if stringsetFields.contains(field) {
                return stringsetSubstringSQL(
                    field: field, pattern: pattern, tableName: tableName
                )
            }
            return ("\(col) LIKE ? ESCAPE '\\' COLLATE NOCASE", [pattern])
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
        fieldTypes: [String: String]? = nil,
        scopedToDocId: String? = nil
    ) throws -> (String, [Any]) {
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
                return try buildFacetAggregation(
                    tableName: tableName, facetField: facetFields[0],
                    options: options, stringsetFields: stringsetFields,
                    stringFields: stringFields, fieldTypes: fieldTypes,
                    scopedToDocId: scopedToDocId
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
        return try buildRegularAggregation(
            tableName: tableName, regularFields: regularFields,
            memberships: memberships, options: options,
            stringsetFields: stringsetFields, stringFields: stringFields,
            fieldTypes: fieldTypes, scopedToDocId: scopedToDocId
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
        fieldTypes: [String: String]?,
        scopedToDocId: String?
    ) throws -> (String, [Any]) {
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
            filterParts = try translate(
                filter, stringsetFields: stringsetFields,
                stringFields: stringFields, fieldTypes: fieldTypes,
                tableName: tableName
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
        fieldTypes: [String: String]?,
        scopedToDocId: String?
    ) throws -> (String, [Any]) {
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
            filterParts = try translate(
                filter, stringsetFields: stringsetFields,
                stringFields: stringFields, fieldTypes: fieldTypes,
                tableName: tableName
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

    /// The three substring-operator names, in the fixed order js-bao
    /// reports them (`DocumentQueryTranslator.ts:291`). Used both to
    /// detect a substring op and to pick the deterministic
    /// "second op" for the more-than-one-per-field error.
    private static let substringOpNames = ["$startsWith", "$endsWith", "$containsText"]

    /// How a substring op wraps the (already-escaped) search text as a
    /// `LIKE` pattern.
    private enum SubstringPattern {
        case startsWith, endsWith, contains

        /// Map an operator name to its pattern shape, or `nil` if the
        /// operator isn't a substring op.
        init?(operatorName op: String) {
            switch op {
            case "$startsWith":   self = .startsWith
            case "$endsWith":     self = .endsWith
            case "$containsText": self = .contains
            default:              return nil
            }
        }

        func likeValue(_ text: String) -> String {
            let e = escapeLikeStatic(text)
            switch self {
            case .startsWith: return "\(e)%"
            case .endsWith:   return "%\(e)"
            case .contains:   return "%\(e)%"
            }
        }
    }

    /// Single shared LIKE-pattern builder for both scalar and stringset
    /// substring ops. Mirrors js-bao's `buildLikePattern`
    /// (`utils/patterns.ts:8-23`): trims, returns `nil` (no-op, no
    /// condition) for whitespace-only input, **throws**
    /// `JsBaoError(.invalidArgument)` when the trimmed value exceeds 1024
    /// characters, and otherwise returns the escaped, wrapped pattern.
    /// Strictly over 1024 throws; exactly 1024 does not.
    private static func buildSubstringPattern(
        _ raw: String,
        mode: SubstringPattern,
        field: String,
        op: String,
        fieldType: String
    ) throws -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil } // js-bao buildLikePattern → null
        if trimmed.count > 1024 {
            throw substringError(
                "substring value exceeds 1024 characters",
                field: field, op: op, fieldType: fieldType
            )
        }
        return mode.likeValue(trimmed)
    }

    /// EXISTS subquery against the stringset junction table: matches
    /// when ANY member's `value` column satisfies the prepared LIKE
    /// pattern. Correlates on both `parent_id` and `_meta_doc_id` so a
    /// shared-engine multi-doc query can't match a different doc's rows.
    /// The `pattern` is already trimmed/escaped/wrapped by
    /// `buildSubstringPattern`.
    private static func stringsetSubstringSQL(
        field: String,
        pattern: String,
        tableName: String?
    ) -> (String, [Any]) {
        guard let tableName else {
            // Engine always supplies the table name; a missing one is an
            // internal wiring bug, not bad query input.
            assertionFailure("QueryTranslator: substring op on stringset needs tableName context")
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
        return (sql, [pattern])
    }

    /// Build the structured `JsBaoError(.invalidArgument)` a substring-op
    /// validation failure throws. Carries `field` / `operator` /
    /// `fieldType` in `details`, mirroring js-bao's `InvalidOperatorError`
    /// structured fields and reusing the `.invalidArgument` code the
    /// projection precedent (#1118) chose for query-input errors.
    private static func substringError(
        _ message: String, field: String, op: String, fieldType: String
    ) -> JsBaoError {
        JsBaoError(
            code: .invalidArgument,
            message: message,
            details: [
                "field": .string(field),
                "operator": .string(op),
                "fieldType": .string(fieldType),
            ]
        )
    }

    /// Best-effort type name for a field, for the `fieldType` error
    /// detail. Stringset fields are tracked separately; everything else
    /// comes from the caller-supplied `fieldTypes` map (derived from the
    /// engine's column types). Falls back to `"unknown"` when no schema
    /// info was threaded through.
    private static func fieldTypeName(
        _ field: String,
        fieldTypes: [String: String]?,
        stringsetFields: Set<String>
    ) -> String {
        if stringsetFields.contains(field) { return "stringset" }
        return fieldTypes?[field] ?? "unknown"
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
