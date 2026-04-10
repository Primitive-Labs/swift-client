import Foundation

/// Translates MongoDB-style DocumentFilter into SQL WHERE clauses.
///
/// Supports: $eq, $ne, $gt, $gte, $lt, $lte, $in, $nin,
///           $containsText, $startsWith, $endsWith, $exists, $and, $or
public struct QueryTranslator {

    /// Translate a DocumentFilter into a SQL WHERE clause and parameter bindings.
    /// Returns (whereClause, parameters). The whereClause does NOT include "WHERE".
    public static func translate(_ filter: DocumentFilter) -> (String, [Any]) {
        var conditions: [String] = []
        var params: [Any] = []

        for (key, value) in filter {
            if key == "$and", let arr = value as? [DocumentFilter] {
                let sub = arr.map { translate($0) }
                let joined = sub.map { "(\($0.0))" }.joined(separator: " AND ")
                if !joined.isEmpty {
                    conditions.append("(\(joined))")
                    for s in sub { params.append(contentsOf: s.1) }
                }
            } else if key == "$or", let arr = value as? [DocumentFilter] {
                let sub = arr.map { translate($0) }
                let joined = sub.map { "(\($0.0))" }.joined(separator: " OR ")
                if !joined.isEmpty {
                    conditions.append("(\(joined))")
                    for s in sub { params.append(contentsOf: s.1) }
                }
            } else if let ops = value as? [String: Any] {
                // Operator expression: { "field": { "$gt": 5 } }
                for (op, opVal) in ops {
                    let (cond, p) = translateOperator(field: key, op: op, value: opVal)
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

    private static func translateOperator(field: String, op: String, value: Any) -> (String, [Any]) {
        let col = quoted(field)

        switch op {
        case "$eq":
            if value is NSNull { return ("\(col) IS NULL", []) }
            return ("\(col) = ?", [sqlValue(value)])

        case "$ne":
            if value is NSNull { return ("\(col) IS NOT NULL", []) }
            return ("(\(col) != ? OR \(col) IS NULL)", [sqlValue(value)])

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
                return ("(\(col) NOT IN (\(placeholders)) OR \(col) IS NULL)", arr.map { sqlValue($0) })
            }
            return ("1", []) // empty $nin matches everything

        case "$containsText":
            if let text = value as? String {
                return ("\(col) LIKE ? ESCAPE '\\' COLLATE NOCASE", ["%\(escapeLike(text))%"])
            }
            return ("1=1", [])

        case "$startsWith":
            if let text = value as? String {
                return ("\(col) LIKE ? ESCAPE '\\' COLLATE NOCASE", ["\(escapeLike(text))%"])
            }
            return ("1=1", [])

        case "$endsWith":
            if let text = value as? String {
                return ("\(col) LIKE ? ESCAPE '\\' COLLATE NOCASE", ["%\(escapeLike(text))"])
            }
            return ("1=1", [])

        case "$exists":
            let exists = (value as? Bool) ?? true
            return (exists ? "\(col) IS NOT NULL" : "\(col) IS NULL", [])

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
        options: AggregateOptions
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
            let (where_, whereParams) = translate(filter)
            sql += " WHERE \(where_)"
            params.append(contentsOf: whereParams)
        }

        // GROUP BY
        if !options.groupBy.isEmpty {
            sql += " GROUP BY \(options.groupBy.map { quoted($0) }.joined(separator: ", "))"
        }

        return (sql, params)
    }

    // MARK: - Helpers

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
