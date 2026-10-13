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
            if key == "$and", let arr = subFilters(value) {
                let sub = try arr.map { try translate($0, stringsetFields: stringsetFields, stringFields: stringFields, fieldTypes: fieldTypes, tableName: tableName) }
                let joined = sub.map { "(\($0.0))" }.joined(separator: " AND ")
                if !joined.isEmpty {
                    conditions.append("(\(joined))")
                    for s in sub { params.append(contentsOf: s.1) }
                }
            } else if key == "$or", let arr = subFilters(value) {
                let sub = try arr.map { try translate($0, stringsetFields: stringsetFields, stringFields: stringFields, fieldTypes: fieldTypes, tableName: tableName) }
                let joined = sub.map { "(\($0.0))" }.joined(separator: " OR ")
                if !joined.isEmpty {
                    conditions.append("(\(joined))")
                    for s in sub { params.append(contentsOf: s.1) }
                }
            } else if let ops = value.objectValue {
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
                if value.isNull {
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
        value: JSONValue,
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
            guard let raw = value.stringValue else {
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
            if value.isNull { return ("\(col) IS NULL", []) }
            return ("\(col) = ?", [sqlValue(value)])

        case "$ne":
            if value.isNull { return ("\(col) IS NOT NULL", []) }
            // Include NULL rows (#3166): a record that never wrote the field
            // is not equal to any value, which is what MongoDB does and what
            // js-bao does since the same release. `col != ?` alone is UNKNOWN
            // for a NULL column, so the row needs its own wing — parenthesized
            // because sibling operators on the same field AND-join.
            return ("(\(col) IS NULL OR \(col) != ?)", [sqlValue(value)])

        case "$gt":
            return ("\(col) > ?", [sqlValue(value)])
        case "$gte":
            return ("\(col) >= ?", [sqlValue(value)])
        case "$lt":
            return ("\(col) < ?", [sqlValue(value)])
        case "$lte":
            return ("\(col) <= ?", [sqlValue(value)])

        case "$in":
            if let arr = value.arrayValue, !arr.isEmpty {
                let placeholders = arr.map { _ in "?" }.joined(separator: ",")
                return ("\(col) IN (\(placeholders))", arr.map { sqlValue($0) })
            }
            return ("0", []) // empty $in matches nothing

        case "$nin":
            if let arr = value.arrayValue, !arr.isEmpty {
                // Same absent-field semantics as `$ne` above (#3166). A null
                // entry in the list means "exclude missing/null" in MongoDB;
                // binding it into `NOT IN` would make the whole comparison
                // UNKNOWN, so it is split out into an IS NOT NULL wing.
                let values = arr.filter { !$0.isNull }
                let placeholders = values.map { _ in "?" }.joined(separator: ",")
                if values.count < arr.count {
                    if values.isEmpty { return ("\(col) IS NOT NULL", []) }
                    return (
                        "(\(col) IS NOT NULL AND \(col) NOT IN (\(placeholders)))",
                        values.map { sqlValue($0) }
                    )
                }
                return (
                    "(\(col) IS NULL OR \(col) NOT IN (\(placeholders)))",
                    values.map { sqlValue($0) }
                )
            }
            return ("1", []) // empty $nin matches everything

        case "$exists":
            let exists = value.boolValue ?? true
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
            guard let member = value.stringValue, !member.isEmpty else {
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
    ///     CASE on whether the member is present;
    ///   - **date period** (`.datePeriod`) → group by the bucket expression
    ///     `periodBucketSQL` emits over the field's stored text.
    ///
    /// Every group level is selected under its positional alias (`_g<i>`, `i`
    /// its index in `groupBy`) and every operation under its own (`_o<i>`, `i`
    /// its index in `operations`), so no group column shares a name with an
    /// operation, whatever its `resultKey`; `aggregationRows` turns the SQL
    /// rows into js-bao's `["group": …, <op keys>]` rows. Two levels that
    /// would share a key in `group`, or an operation whose `resultKey` is
    /// `group`, are refused here, before any SQL is built
    /// (`ambiguousGroupKeysMessage`, `reservedOperationKeyMessage`).
    ///
    /// `scopedToDocIds`, when set, scopes the query to those documents — woven into the WHERE here (not spliced by
    /// the caller) so its bind params land after any JOIN params. An empty
    /// list is a scope that admits nothing, not one that admits everything:
    /// it is what a model with no connected document of the kind being read
    /// asks for (#3436).
    public static func buildAggregation(
        tableName: String,
        options: AggregateOptions,
        stringsetFields: Set<String> = [],
        stringFields: Set<String>? = nil,
        fieldTypes: [String: String]? = nil,
        scopedToDocIds: [String]? = nil
    ) throws -> (String, [Any]) {
        if let key = ambiguousGroupKey(options.groupBy) {
            throw JsBaoError(code: .invalidArgument, message: ambiguousGroupKeysMessage(key))
        }
        if options.operations.contains(where: { $0.resultKey == groupRowKey }) {
            throw JsBaoError(code: .invalidArgument, message: reservedOperationKeyMessage)
        }

        var regularFields: [(index: Int, name: String)] = []
        var facetFields: [(index: Int, name: String)] = []
        var memberships: [(index: Int, field: String, contains: String)] = []
        var periods: [(index: Int, field: String, period: DatePeriod)] = []
        for (index, clause) in options.groupBy.enumerated() {
            switch clause {
            case let .field(name):
                if stringsetFields.contains(name) { facetFields.append((index, name)) }
                else { regularFields.append((index, name)) }
            case let .stringSetMembership(field, contains):
                memberships.append((index, field, contains))
            case let .datePeriod(field, period):
                periods.append((index, field, period))
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
        // The whole aggregate surface is non-throwing (`-> [[String: JSONValue]]` at
        // every layer), so we DEGRADE here rather than crash the host app: a
        // pure single facet runs; a pure multi-facet returns no rows; anything
        // mixed drops the facet and proceeds as regular aggregation.
        if regularFields.isEmpty && memberships.isEmpty && periods.isEmpty && !facetFields.isEmpty {
            if facetFields.count == 1 {
                return try buildFacetAggregation(
                    tableName: tableName, facet: facetFields[0],
                    options: options, stringsetFields: stringsetFields,
                    stringFields: stringFields, fieldTypes: fieldTypes,
                    scopedToDocIds: scopedToDocIds
                )
            }
            // 2+ pure facet fields: unsupported shape (js-bao 400s here). Return
            // a guaranteed-empty result instead of aborting the caller.
            log.warn(
                "aggregate: grouping by multiple stringset facet fields is "
                + "unsupported (\(facetFields.map(\.name))); returning no rows. Group by a "
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
            memberships: memberships, periods: periods, options: options,
            stringsetFields: stringsetFields, stringFields: stringFields,
            fieldTypes: fieldTypes, scopedToDocIds: scopedToDocIds
        )
    }

    /// The `_meta_doc_id` predicate for a scope of `ids`. An EMPTY scope
    /// admits nothing (`IN ()` is not valid SQL, so it is spelled as a false
    /// predicate): a read scoped to no document answers with no rows, which is
    /// what a model whose documents of that kind have all been closed means.
    static func docScopeClause(_ table: String, _ ids: [String]) -> String {
        guard !ids.isEmpty else { return "0" }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        return "\(table).\"_meta_doc_id\" IN (\(placeholders))"
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
        regularFields: [(index: Int, name: String)],
        memberships: [(index: Int, field: String, contains: String)],
        periods: [(index: Int, field: String, period: DatePeriod)],
        options: AggregateOptions,
        stringsetFields: Set<String>,
        stringFields: Set<String>?,
        fieldTypes: [String: String]?,
        scopedToDocIds: [String]?
    ) throws -> (String, [Any]) {
        let t = quoted(tableName)
        var params: [Any] = []
        var selectClauses: [String] = []
        var groupByClauses: [String] = []
        var joinClauses: [String] = []

        // The expression `sort` orders by when it names a group key.
        var sortExpressions: [String: String] = [:]

        for (index, field) in regularFields {
            let column = "\(t).\(quoted(field))"
            selectClauses.append("\(column) AS \(quoted(positionalGroupAlias(index)))")
            groupByClauses.append(column)
            sortExpressions[field] = column
        }

        for (index, field, contains) in memberships {
            let a = quoted(membershipJoinAlias(tableName: tableName, index: index))
            let groupAlias = quoted(positionalGroupAlias(index))
            let junction = quoted("\(tableName)__\(field)")
            // Correlate on parent_id AND _meta_doc_id (shared multi-doc
            // engine) and the specific member value — at most one match
            // per record, so COUNT(*) doesn't multiply.
            joinClauses.append(
                "LEFT JOIN \(junction) AS \(a) ON \(a).\"parent_id\" = \(t).\"id\""
                + " AND \(a).\"_meta_doc_id\" = \(t).\"_meta_doc_id\""
                + " AND \(a).\"value\" = ?"
            )
            params.append(contains)
            let caseExpr = "CASE WHEN \(a).\"parent_id\" IS NOT NULL THEN 'true' ELSE 'false' END"
            selectClauses.append("\(caseExpr) AS \(groupAlias)")
            groupByClauses.append(caseExpr)
            sortExpressions[aggregationGroupKey(.stringSetMembership(field: field, contains: contains))] = groupAlias
        }

        for (index, field, period) in periods {
            let bucket = periodBucketSQL(column: "\(t).\(quoted(field))", period: period)
            let groupAlias = quoted(positionalGroupAlias(index))
            selectClauses.append("\(bucket) AS \(groupAlias)")
            groupByClauses.append(bucket)
            sortExpressions[aggregationGroupKey(.datePeriod(field: field, period: period))] = groupAlias
        }

        appendOperations(options.operations, table: t, into: &selectClauses)
        if selectClauses.isEmpty { selectClauses.append("COUNT(*) AS \"count\"") }

        var sql = "SELECT \(selectClauses.joined(separator: ", ")) FROM \(t)"
        if !joinClauses.isEmpty { sql += " " + joinClauses.joined(separator: " ") }

        // WHERE: doc-scope predicate (param after the JOIN params) then filter.
        var whereParts: [String] = []
        if let ids = scopedToDocIds { whereParts.append(docScopeClause(t, ids)) }
        var filterParts: (String, [Any])? = nil
        if let filter = options.filter, !filter.isEmpty {
            filterParts = try translate(
                filter, stringsetFields: stringsetFields,
                stringFields: stringFields, fieldTypes: fieldTypes,
                tableName: tableName
            )
        }
        if let ids = scopedToDocIds { params.append(contentsOf: ids) }
        if let (clause, fParams) = filterParts {
            whereParts.append(clause)
            params.append(contentsOf: fParams)
        }
        if !whereParts.isEmpty { sql += " WHERE " + whereParts.joined(separator: " AND ") }

        if !groupByClauses.isEmpty {
            sql += " GROUP BY \(groupByClauses.joined(separator: ", "))"
        }
        sql += aggregateOrderLimit(options, sortExpressions: sortExpressions)
        return (sql, params)
    }

    /// StringSet facet grouping: one row per distinct member value of the
    /// faceted field, with the count (and any ops) of records carrying it.
    private static func buildFacetAggregation(
        tableName: String,
        facet: (index: Int, name: String),
        options: AggregateOptions,
        stringsetFields: Set<String>,
        stringFields: Set<String>?,
        fieldTypes: [String: String]?,
        scopedToDocIds: [String]?
    ) throws -> (String, [Any]) {
        let t = quoted(tableName)
        let junction = quoted("\(tableName)__\(facet.name)")
        let member = "\(junction).\"value\""
        var params: [Any] = []
        var selectClauses: [String] = ["\(member) AS \(quoted(positionalGroupAlias(facet.index)))"]
        appendOperations(options.operations, table: t, into: &selectClauses)
        if options.operations.isEmpty { selectClauses.append("COUNT(*) AS \"count\"") }

        var sql = "SELECT \(selectClauses.joined(separator: ", ")) FROM \(junction)"
            + " INNER JOIN \(t) ON \(junction).\"parent_id\" = \(t).\"id\""
            + " AND \(junction).\"_meta_doc_id\" = \(t).\"_meta_doc_id\""

        var whereParts: [String] = []
        if let ids = scopedToDocIds { whereParts.append(docScopeClause(t, ids)) }
        var filterParts: (String, [Any])? = nil
        if let filter = options.filter, !filter.isEmpty {
            filterParts = try translate(
                filter, stringsetFields: stringsetFields,
                stringFields: stringFields, fieldTypes: fieldTypes,
                tableName: tableName
            )
        }
        if let ids = scopedToDocIds { params.append(contentsOf: ids) }
        if let (clause, fParams) = filterParts {
            whereParts.append(clause)
            params.append(contentsOf: fParams)
        }
        if !whereParts.isEmpty { sql += " WHERE " + whereParts.joined(separator: " AND ") }

        sql += " GROUP BY \(member)"
        sql += aggregateOrderLimit(options, sortExpressions: [facet.name: member])
        return (sql, params)
    }

    /// Append `count`/`sum`/`avg`/`min`/`max` SELECT clauses, qualifying
    /// each operand field with the main table `t`. Each is selected under its
    /// positional alias; `aggregationRows` puts it back under its `resultKey`.
    private static func appendOperations(
        _ operations: [AggregateOperation],
        table t: String,
        into clauses: inout [String]
    ) {
        for (index, op) in operations.enumerated() {
            let alias = quoted(positionalOperationAlias(index))
            switch op.type {
            case .count:
                clauses.append("COUNT(*) AS \(alias)")
            case .sum:
                if let field = op.field {
                    clauses.append("SUM(CAST(\(t).\(quoted(field)) AS REAL)) AS \(alias)")
                }
            case .avg:
                if let field = op.field {
                    clauses.append("AVG(CAST(\(t).\(quoted(field)) AS REAL)) AS \(alias)")
                }
            case .min:
                if let field = op.field {
                    clauses.append("MIN(\(t).\(quoted(field))) AS \(alias)")
                }
            case .max:
                if let field = op.field {
                    clauses.append("MAX(\(t).\(quoted(field))) AS \(alias)")
                }
            }
        }
    }

    /// ORDER BY + LIMIT. `sort.field` names an operation's result key first
    /// (as in js-bao, where a group field named `count` does not shadow the
    /// count), then a group key, by the expression in `sortExpressions`.
    private static func aggregateOrderLimit(
        _ options: AggregateOptions,
        sortExpressions: [String: String]
    ) -> String {
        var sql = ""
        if let sort = options.sort {
            let dir = sort.direction == -1 ? "DESC" : "ASC"
            let expression = options.operations.firstIndex { $0.resultKey == sort.field }
                .map { quoted(positionalOperationAlias($0)) }
                ?? sortExpressions[sort.field] ?? quoted(sort.field)
            sql += " ORDER BY \(expression) \(dir)"
        }
        if let limit = options.limit, limit >= 0 {
            sql += " LIMIT \(limit)"
        }
        return sql
    }

    // MARK: - Aggregate rows

    /// The key a `groupBy` level takes in a row's `group`: the field name for
    /// a plain field or a StringSet facet, `has_<field>_<contains>` for a
    /// membership check, with `field` and `contains` written as given.
    static func aggregationGroupKey(_ level: AggregateGroupBy) -> String {
        switch level {
        case let .field(name): return name
        case let .stringSetMembership(field, contains): return "has_\(field)_\(contains)"
        case let .datePeriod(field, period): return "\(field)_\(period.rawValue)"
        }
    }

    /// The expression bucketing `column` by `period`, read from the stored
    /// text with no time-zone conversion: `YYYY-MM`, `YYYY-Qn` or `YYYY`, and
    /// `NULL` for a missing value or text that does not begin `YYYY-MM`.
    /// Digits are not range-checked. The same text js-bao's `periodBucketSql`
    /// emits, so the two clients bucket the same stored strings alike.
    static func periodBucketSQL(column: String, period: DatePeriod) -> String {
        let bucket: String
        switch period {
        case .month:
            bucket = "substr(\(column), 1, 7)"
        case .quarter:
            bucket = "substr(\(column), 1, 4) || '-Q' || ((CAST(substr(\(column), 6, 2) AS INTEGER) + 2) / 3)"
        case .year:
            bucket = "substr(\(column), 1, 4)"
        }
        return "CASE WHEN \(column) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]*' THEN \(bucket) ELSE NULL END"
    }

    /// Refuses a `.datePeriod` level whose field is not in `fields` or is not
    /// a `.date` or `.string` field, with js-bao's messages, before any SQL.
    static func validatePeriodLevels(
        _ groupBy: [AggregateGroupBy], fields: [String: FieldDescriptor]
    ) throws {
        for case let .datePeriod(field, _) in groupBy {
            guard let descriptor = fields[field] else {
                throw JsBaoError(
                    code: .invalidArgument,
                    message: "Unknown field '\(field)' in period groupBy"
                )
            }
            guard descriptor.type == .date || descriptor.type == .string else {
                throw JsBaoError(
                    code: .invalidArgument,
                    message: "Field '\(field)' is not a date or string field but used in period groupBy"
                )
            }
        }
    }

    /// The SQL alias the level at `index` of `groupBy` is selected under. It
    /// never appears in a returned row.
    static func positionalGroupAlias(_ index: Int) -> String { "_g\(index)" }

    /// The SQL alias the operation at `index` of `operations` is selected
    /// under. Disjoint from every group alias, so a custom `outputField` (even
    /// `_g0`) cannot take a group column's name. It never appears in a
    /// returned row.
    static func positionalOperationAlias(_ index: Int) -> String { "_o\(index)" }

    /// The alias the membership level at `index` joins its junction table
    /// under. Built on the model's table name and longer than it, so it can
    /// never name the main table (SQLite compares identifiers ignoring case),
    /// and never a junction (`<table>__<field>`).
    static func membershipJoinAlias(tableName: String, index: Int) -> String {
        "\(tableName)_m\(index)"
    }

    /// The row key holding the group values, so no operation may take it.
    static let groupRowKey = "group"

    /// The refusal for an operation whose `resultKey` is the row's `group`.
    static let reservedOperationKeyMessage =
        "Aggregation operation result key 'group' is reserved for the row's group values"

    /// The first group key more than one `groupBy` level would take, or nil.
    static func ambiguousGroupKey(_ groupBy: [AggregateGroupBy]) -> String? {
        var seen = Set<String>()
        for level in groupBy {
            let key = aggregationGroupKey(level)
            if !seen.insert(key).inserted { return key }
        }
        return nil
    }

    /// The refusal for two `groupBy` levels that would share one row key —
    /// js-bao's message, word for word.
    static func ambiguousGroupKeysMessage(_ key: String) -> String {
        "Ambiguous aggregation group keys: '\(key)' names more than one groupBy level"
    }

    /// The rows of a statement `buildAggregation` built, as js-bao answers
    /// them: each level's value as stored under its key in `group` (`null`
    /// for a missing value or a level the statement did not select), and every
    /// operation's value beside it under its result key, `null` when SQL had
    /// none to give.
    static func aggregationRows(
        _ sqlRows: [[String: JSONValue]],
        options: AggregateOptions
    ) -> [[String: JSONValue]] {
        sqlRows.map { sqlRow in
            var row = sqlRow
            var group: [String: JSONValue] = [:]
            for (index, level) in options.groupBy.enumerated() {
                group[aggregationGroupKey(level)] =
                    row.removeValue(forKey: positionalGroupAlias(index)) ?? .null
            }
            for (index, operation) in options.operations.enumerated() {
                let value = row.removeValue(forKey: positionalOperationAlias(index))
                if value != nil || row[operation.resultKey] == nil {
                    row[operation.resultKey] = value ?? .null
                }
            }
            row[groupRowKey] = .object(group)
            return row
        }
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

    /// The `$and` / `$or` operand: an array of sub-filters. Anything that
    /// isn't an array of objects reads as "not a logical operator", which is
    /// what the `as? [DocumentFilter]` cast expressed before the row currency
    /// became `JSONValue` — a `$or` whose operand is a scalar falls through to
    /// the equality branch exactly as it did.
    private static func subFilters(_ value: JSONValue) -> [DocumentFilter]? {
        guard let items = value.arrayValue else { return nil }
        let objects = items.compactMap { $0.objectValue }
        return objects.count == items.count ? objects : nil
    }

    /// One filter value as a SQLite bind parameter. Booleans bind as 0/1
    /// (SQLite has no boolean type). An integral number binds as `Int64` and
    /// anything else as `Double`: only `number` fields get a REAL column, so a
    /// numeric operand compared against a `string`/`date`/`id`/`json` column
    /// (all TEXT) is converted with that column's TEXT affinity, where
    /// `CAST(5 AS TEXT)` is `'5'` but `CAST(5.0 AS TEXT)` is `'5.0'`. Binding
    /// `5` as REAL would therefore stop matching a stored `"5"` — the JS
    /// client binds an integral number as INTEGER for the same reason.
    /// Containers can't be bound — they only reach here through a malformed
    /// filter — so they bind as SQL NULL, which matches nothing rather than
    /// matching by accident.
    private static func sqlValue(_ value: JSONValue) -> Any {
        switch value {
        case let .string(s):        return s
        case let .number(n):
            if let integral = Int64(exactly: n) { return integral }
            return n
        case let .bool(b):          return b ? 1 : 0
        case .null:                 return NSNull()
        case .array, .object:       return NSNull()
        }
    }
}
