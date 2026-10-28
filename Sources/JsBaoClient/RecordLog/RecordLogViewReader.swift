import Foundation

/// The limits every db3 read on this client applies: js-bao's
/// `query/db3Limits.ts`, figure for figure, so the Swift store pages, cuts and
/// refuses where the room and the JS client do.
enum Db3Limits {
    /// Records a page answers when the caller sends no `limit`.
    static let pageDefault = 100
    /// The largest `limit` a page, or an aggregate under an explicit `limit`, accepts.
    static let pageMax = 10_000
    /// The most JSON (UTF-8 bytes) one answer carries.
    static let responseMaxBytes = 8 * 1024 * 1024
    /// The deepest include resolved.
    static let includeMaxDepth = 3
    /// The most related rows one `hasMany` include leg reads per request.
    static let includeMaxRelatedRows = 1_000

    /// `limit`, refused outside 1 to `max` with the room's message.
    @discardableResult
    static func checkedLimit(_ limit: Int, max: Int = pageMax) throws -> Int {
        guard limit >= 1, limit <= max else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "Invalid options.limit: must be an integer from 1 to \(max)",
                details: ["limit": .number(Double(limit))]
            )
        }
        return limit
    }

    /// An answer that would pass the byte budget and cannot be shortened
    /// without changing it. js-bao's `Db3PageTooLargeError`, message and all.
    static func pageTooLarge(bytes: Int, limit: Int) -> JsBaoError {
        JsBaoError(
            code: .db3PageTooLarge,
            message: "this response would carry \(bytes) bytes; the limit is \(limit) bytes per db3 response. "
                + "Narrow the filter, group more coarsely, or pass sort and a smaller limit.",
            details: ["bytes": .number(Double(bytes)), "limit": .number(Double(limit))]
        )
    }

    /// A `hasMany` leg past its rows per request. js-bao's `Db3IncludeTooLargeError`.
    static func includeTooLarge(include: String, rows: Int, limit: Int) -> JsBaoError {
        JsBaoError(
            code: .db3PageTooLarge,
            message: "the include \"\(include)\" would read more than \(limit) related rows for this page; "
                + "the limit is \(limit) related rows per hasMany include per request. Narrow the page with a "
                + "smaller limit, add a filter or a per-parent limit to the include.",
            details: ["include": .string(include), "rows": .number(Double(rows)), "limit": .number(Double(limit))]
        )
    }

    /// An include spec refused before any statement. js-bao's `IncludeSpecError`.
    static func invalidInclude(_ reason: String) -> JsBaoError {
        JsBaoError(code: .invalidArgument, message: "Invalid include: \(reason)")
    }
}

/// A db3's reads over the client store's view (`record_log_view`): the query,
/// count and aggregate the model API and the model-free records answer from,
/// with the statements the record room runs for the same request. The Swift
/// port of js-bao's `record-log-client/viewReader.ts`.
///
/// - Fields are read from each record's stored JSON with `json_extract` and the
///   stored JSON type decides a comparison (`["n": 5]` does not match a stored
///   `"5"`), the room's translator over the view (`QueryTranslator.translateView`).
/// - A query orders by its sort, then `_id`, then `doc_id`, so a statement over
///   several db3s holding the same id has a total order; the cursor carries the
///   document under `_tiebreak:doc_id`, the JS client's key.
/// - The db3 limits hold (``Db3Limits``).
/// - Includes resolve within each parent's own db3, by this reader's own
///   statements: the public page never cuts a leg.
///
/// Its statements run on `store`'s connection as the store reads, so they see
/// what an open group of saves has written. `documents` is the scope: every
/// statement names it.
struct RecordLogViewReader {

    let store: RecordLogStore
    let documents: [String]

    /// The key the document tie-break takes in a cursor and its sort fields.
    static let documentTieBreak = "_tiebreak:doc_id"

    /// How a page answers a record.
    enum RowShape {
        /// As the view holds it: the model-free records.
        case stored
        /// As the model API reads it: each declared set field an array of its
        /// members in canonical order (`[]` when the record holds none), and
        /// the record's document under `_meta_doc_id`.
        case model(setFields: Set<String>)
    }

    struct Page {
        var rows: [RecordLogRow]
        /// Each row's document, in row order.
        var documents: [String]
        var nextCursor: String?
        var prevCursor: String?
        var hasMore: Bool
    }

    // MARK: - Query

    /// One page of `model`'s records in the scope matching `filter`.
    ///
    /// The page ends at `options.limit` records (100 when none is sent), or
    /// before the record whose JSON takes it past 8 MiB (the first is always
    /// answered); `hasMore` is exact. With `include`, each parent's legs
    /// resolve within its own db3 and a projection applies once they have.
    /// Every input is checked before any statement runs: a `limit` outside 1 to
    /// 10,000, an invalid include tree and a name that is not an identifier
    /// throw `JsBaoError(.invalidArgument)`.
    func page(
        _ model: String, _ filter: DocumentFilter, options: QueryOptions?, shape: RowShape, include: [Include]? = nil
    ) throws -> Page {
        let options = options ?? QueryOptions()
        try QueryTranslator.requireViewIdentifier(model, context: "query model")
        let limit = try options.limit.map { try Db3Limits.checkedLimit($0) } ?? Db3Limits.pageDefault
        let includes = try RecordLogIncludeTree.validated(include)
        let (clause, params) = try QueryTranslator.translateView(filter)
        let sort = options.pagingSort
        let fields = sort.fields + [Self.documentTieBreak]
        let directions = sort.directions + [1]
        var columns = [Self.documentTieBreak: "doc_id"]
        for field in sort.fields { columns[field] = try QueryTranslator.viewField(field) }
        let keep = try Self.projection(options.projection)
        guard !documents.isEmpty else { return Page(rows: [], documents: [], nextCursor: nil, prevCursor: nil, hasMore: false) }

        var conditions = ["_type = ?", "(\(clause))"]
        var bindings: [Format2SqlValue] = [.text(model)] + params.map(Format2SqlValue.init(bindable:))
        if let cursor = options.cursor {
            let (paging, cursorParams) = try CursorManager.buildJSONPaginationConditions(
                cursor: cursor, currentSortFields: fields, sortDirections: directions, direction: options.direction,
                fieldFormatter: { columns[$0] ?? "NULL" }, nonNullFields: [Self.documentTieBreak]
            )
            conditions.append(paging)
            bindings += cursorParams.map(Format2SqlValue.init(bindable:))
        }
        conditions.append(Self.scopeClause(documents.count))
        bindings += documents.map { .text($0) }
        // A backward page is read nearest the cursor first.
        let backward = options.direction == .backward
        let order = zip(fields, directions).map { field, direction in
            "\(columns[field] ?? "NULL") \((backward ? -direction : direction) == 1 ? "ASC" : "DESC")"
        }
        // One row past the page says whether a further one exists.
        let statement = "SELECT _data, _id, _type, doc_id FROM record_log_view WHERE "
            + conditions.joined(separator: " AND ") + " ORDER BY " + order.joined(separator: ", ")
            + " LIMIT \(limit + 1)"

        var rows: [RecordLogRow] = []
        var rowDocuments: [String] = []
        var minting: [RecordLogRow] = []
        var used = 0
        var hasMore = false
        try store.readView { sql in
            try sql.connection.eachRow(statement, bindings) { raw in
                if rows.count >= limit {
                    hasMore = true
                    return false
                }
                let stored = raw["_data"].stringValue
                let parsed = RecordLogJSON.row(stored)
                let (record, reshaped) = Self.shaped(parsed, shape)
                // With includes, a parent is read whole: a leg may need a field
                // the projection leaves out. It applies once the legs resolved.
                let answered = includes == nil ? keep(record) : record
                let bytes = !reshaped && options.projection == nil
                    ? stored?.utf8.count ?? 2 : RecordLogJSON.bytes(.object(answered))
                if !rows.isEmpty && used + bytes > Db3Limits.responseMaxBytes {
                    hasMore = true
                    return false
                }
                used += bytes
                let document = raw["doc_id"].stringValue ?? ""
                // A cursor carries the stored values the statement sorts (a set
                // the model answers `[]` or reorders is NULL or its stored
                // array there), `id` and `type` as the columns a page sorts
                // them by hold them, and the document under its tie-break key.
                var mint = parsed
                if let id = raw["_id"].stringValue { mint["id"] = .string(id) }
                if let type = raw["_type"].stringValue { mint["type"] = .string(type) }
                mint[Self.documentTieBreak] = .string(document)
                rows.append(answered)
                rowDocuments.append(document)
                minting.append(mint)
                return true
            }
        }

        if let includes {
            try RecordLogIncludeResolution(reader: self).resolve(&rows, documents: rowDocuments, includes: includes, used: used)
            rows = rows.map(keep)
        }
        let (next, prev) = try CursorManager.generateJSONResultCursors(
            rows: minting, sortFields: fields, direction: options.direction, hasMore: hasMore,
            isFirstPage: options.cursor == nil, sortDirections: directions
        )
        if case .model = shape {
            for index in rows.indices { rows[index]["_meta_doc_id"] = .string(rowDocuments[index]) }
        }
        if backward {
            rows.reverse()
            rowDocuments.reverse()
        }
        return Page(rows: rows, documents: rowDocuments, nextCursor: next, prevCursor: prev, hasMore: hasMore)
    }

    /// How many of `model`'s records in the scope match `filter`, matched as
    /// ``page(_:_:options:shape:include:)`` matches them. Consumes every row.
    func count(_ model: String, _ filter: DocumentFilter) throws -> Int {
        try QueryTranslator.requireViewIdentifier(model, context: "query model")
        let (clause, params) = try QueryTranslator.translateView(filter)
        guard !documents.isEmpty else { return 0 }
        return try store.readView { sql in
            try sql.first(
                "SELECT COUNT(*) AS n FROM record_log_view WHERE _type = ? AND (\(clause)) AND \(Self.scopeClause(documents.count))",
                [.text(model)] + params.map(Format2SqlValue.init(bindable:)) + documents.map { .text($0) }
            )?["n"].intValue ?? 0
        }
    }

    // MARK: - Aggregate

    /// Aggregate `model`'s records in the scope, as the room aggregates them
    /// (js-bao's `buildAggregate` over the view): a plain level groups by the
    /// stored value, a level naming one of `setFields` is a facet (one row per
    /// member, when it is the only level; `null` beside other levels), a
    /// membership groups by whether the array holds the member, a period
    /// buckets the stored text; the operations read the stored values.
    /// `limit` (1 to 10,000) and `sort` as the room applies them. Rows whose
    /// JSON passes 8 MiB are refused `DB3_PAGE_TOO_LARGE`, never cut.
    func aggregate(_ model: String, _ options: AggregateOptions, setFields: Set<String>) throws -> [[String: JSONValue]] {
        try QueryTranslator.requireViewIdentifier(model, context: "query model")
        if let limit = options.limit { try Db3Limits.checkedLimit(limit) }
        if let key = QueryTranslator.ambiguousGroupKey(options.groupBy) {
            throw JsBaoError(code: .invalidArgument, message: QueryTranslator.ambiguousGroupKeysMessage(key))
        }
        if options.operations.contains(where: { $0.resultKey == QueryTranslator.groupRowKey }) {
            throw JsBaoError(code: .invalidArgument, message: QueryTranslator.reservedOperationKeyMessage)
        }
        for operation in options.operations where operation.type != .count {
            guard let field = operation.field, !field.isEmpty else {
                throw JsBaoError(
                    code: .invalidArgument, message: "Operation '\(operation.type.rawValue)' requires a field parameter"
                )
            }
            try QueryTranslator.requireViewIdentifier(field)
        }
        let statement = try aggregateStatement(model, options, setFields: setFields)
        let rows = try store.readView { sql in
            try sql.rows(statement.sql, statement.bindings).map(Self.aggregateRow)
        }
        let shaped = QueryTranslator.aggregationRows(rows, options: options)
        // The array's brackets, then each row and the comma before every row but the first.
        var bytes = 2
        for (index, row) in shaped.enumerated() {
            bytes += RecordLogJSON.bytes(.object(row)) + (index > 0 ? 1 : 0)
            if bytes > Db3Limits.responseMaxBytes {
                throw Db3Limits.pageTooLarge(bytes: bytes, limit: Db3Limits.responseMaxBytes)
            }
        }
        return shaped
    }

    /// The one statement an aggregate runs, every level selected under its
    /// positional alias (`_g<i>`, `i` its index in `groupBy`) and every
    /// operation under its own (`_o<i>`), so ``QueryTranslator/aggregationRows(_:options:)``
    /// shapes the rows as it shapes the typed tables'.
    private func aggregateStatement(
        _ model: String, _ options: AggregateOptions, setFields: Set<String>
    ) throws -> (sql: String, bindings: [Format2SqlValue]) {
        var plain: [(index: Int, field: String)] = []
        var facets: [(index: Int, field: String)] = []
        var periods: [(index: Int, field: String, period: DatePeriod)] = []
        var memberships: [(index: Int, field: String, contains: String)] = []
        for (index, level) in options.groupBy.enumerated() {
            switch level {
            case let .field(name):
                if setFields.contains(name) { facets.append((index, name)) } else { plain.append((index, name)) }
            case let .stringSetMembership(field, contains):
                memberships.append((index, field, contains))
            case let .datePeriod(field, period):
                periods.append((index, field, period))
            }
        }
        let table = "record_log_view"
        let (clause, filterParams) = try QueryTranslator.translateView(options.filter ?? [:])
        let scope = Self.scopeClause(documents.count, table: table)
        let scopeParams = documents.map { Format2SqlValue.text($0) }
        let filterBindings = filterParams.map(Format2SqlValue.init(bindable:))

        func operations(_ inFacet: Bool) throws -> [String] {
            var selected: [String] = []
            for (index, operation) in options.operations.enumerated() {
                let alias = Self.quoted(QueryTranslator.positionalOperationAlias(index))
                if operation.type == .count {
                    selected.append("COUNT(*) AS \(alias)")
                } else {
                    let column = try QueryTranslator.viewField(operation.field ?? "")
                    selected.append("\(operation.type.rawValue.uppercased())(\(column)) AS \(alias)")
                }
            }
            if inFacet && selected.isEmpty { selected.append("COUNT(*) AS \"count\"") }
            return selected
        }
        func operationAlias(_ field: String) -> String? {
            options.operations.firstIndex { $0.resultKey == field }.map { Self.quoted(QueryTranslator.positionalOperationAlias($0)) }
        }
        func orderAndLimit(_ sortExpression: (String) throws -> String) throws -> String {
            var sql = ""
            if let sort = options.sort {
                sql += " ORDER BY \(try sortExpression(sort.field)) \(sort.direction == -1 ? "DESC" : "ASC")"
            }
            if let limit = options.limit { sql += " LIMIT \(limit)" }
            return sql
        }

        if !facets.isEmpty && plain.isEmpty && periods.isEmpty && memberships.isEmpty {
            guard facets.count == 1, let facet = facets.first else {
                throw JsBaoError(
                    code: .invalidArgument, message: "Multiple StringSet facet fields not supported in single aggregation"
                )
            }
            try QueryTranslator.requireViewIdentifier(facet.field)
            let path = "\(table)._data, '$.\(facet.field)'"
            let member = "_facet.value"
            let select = ["\(member) AS \(Self.quoted(QueryTranslator.positionalGroupAlias(facet.index)))"] + (try operations(true))
            var sql = "SELECT \(select.joined(separator: ", ")) FROM \(table), json_each(\(path)) AS _facet"
                + " WHERE \(table).\"_type\" = ? AND json_type(\(path)) = 'array' AND (\(clause)) AND \(scope)"
                + " GROUP BY \(member)"
            sql += try orderAndLimit { field in
                if field == "count" { return "COUNT(*)" }
                if let alias = operationAlias(field) { return alias }
                // The facet's own field sorts by the member: the record has no column of that name.
                if field == facet.field { return member }
                return Self.quoted(field)
            }
            return (sql, [.text(model)] + filterBindings + scopeParams)
        }

        var select: [String] = []
        var group: [String] = []
        var selectBindings: [Format2SqlValue] = []
        var membershipSort: [String: String] = [:]
        var periodSort: [String: String] = [:]
        for (index, field) in plain {
            let column = try QueryTranslator.viewField(field)
            select.append("\(column) AS \(Self.quoted(QueryTranslator.positionalGroupAlias(index)))")
            group.append(column)
        }
        for (index, field, period) in periods {
            let bucket = QueryTranslator.periodBucketSQL(column: try QueryTranslator.viewField(field), period: period)
            let alias = Self.quoted(QueryTranslator.positionalGroupAlias(index))
            select.append("\(bucket) AS \(alias)")
            group.append(bucket)
            periodSort[QueryTranslator.aggregationGroupKey(.datePeriod(field: field, period: period))] = alias
        }
        for (index, field, contains) in memberships {
            try QueryTranslator.requireViewIdentifier(field, context: "aggregation groupBy field")
            let path = "\(table)._data, '$.\(field)'"
            let alias = Self.quoted(QueryTranslator.positionalGroupAlias(index))
            select.append(
                "CASE WHEN (json_type(\(path)) = 'array' AND EXISTS (SELECT 1 FROM json_each(\(path)) AS _set "
                    + "WHERE _set.value = ?)) THEN 'true' ELSE 'false' END AS \(alias)"
            )
            selectBindings.append(.text(contains))
            // The presence binds its member, so the level groups by its alias.
            group.append(alias)
            membershipSort[QueryTranslator.aggregationGroupKey(.stringSetMembership(field: field, contains: contains))] = alias
            membershipSort["\(field)::\(contains)"] = alias
        }
        select += try operations(false)
        if select.isEmpty { select.append("COUNT(*) AS \"count\"") }
        var sql = "SELECT \(select.joined(separator: ", ")) FROM \(table) WHERE \(table).\"_type\" = ? AND (\(clause)) AND \(scope)"
        if !group.isEmpty { sql += " GROUP BY \(group.joined(separator: ", "))" }
        sql += try orderAndLimit { field in
            if field == "count" { return "COUNT(*)" }
            if let membership = membershipSort[field] { return membership }
            // An operation key wins over a period key of the same name.
            if let alias = operationAlias(field) { return alias }
            if let period = periodSort[field] { return period }
            // A plain field, by its own expression.
            return try QueryTranslator.viewField(field)
        }
        return (sql, selectBindings + [.text(model)] + filterBindings + scopeParams)
    }

    // MARK: - Helpers

    /// A page as the model API's paged reads answer it.
    static func paged(_ page: Page) -> PagedQueryResult<PrimitiveRow> {
        PagedQueryResult(
            data: page.rows.map(PrimitiveRow.init(raw:)), nextCursor: page.nextCursor, prevCursor: page.prevCursor,
            hasMore: page.hasMore
        )
    }

    /// `doc_id IN (?, …)` for `count` documents; a scope of none admits nothing.
    static func scopeClause(_ count: Int, table: String? = nil) -> String {
        guard count > 0 else { return "0" }
        let column = table.map { "\($0).doc_id" } ?? "doc_id"
        return "\(column) IN (\(Array(repeating: "?", count: count).joined(separator: ", ")))"
    }

    private static func quoted(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// `record` as `shape` answers it, and whether that changed it.
    static func shaped(_ record: RecordLogRow, _ shape: RowShape) -> (RecordLogRow, Bool) {
        guard case .model(let setFields) = shape, !setFields.isEmpty else { return (record, false) }
        var row = record
        var changed = false
        for field in setFields {
            switch row[field] {
            case .array(let items)?:
                let members = items.compactMap(\.stringValue)
                guard members.count == items.count else { continue }
                let canonical = recordLogCanonicalStringSet(members)
                if !canonical.elementsEqual(members, by: recordLogSameText) {
                    row[field] = .array(canonical.map { .string($0) })
                    changed = true
                }
            case nil, .null?:
                row[field] = .array([])
                changed = true
            default:
                continue
            }
        }
        return (row, changed)
    }

    /// A projection over an answered record: inclusion keeps `id`, `_related`
    /// and the listed fields; exclusion drops the listed fields but never
    /// `id`. Mixed modes are refused before any statement.
    static func projection(_ projection: [String: Int]?) throws -> (RecordLogRow) -> RecordLogRow {
        guard let projection, !projection.isEmpty else { return { $0 } }
        let included = Set(projection.filter { $0.value != 0 }.keys)
        let excluded = Set(projection.filter { $0.value == 0 }.keys)
        if !included.isEmpty && !excluded.isEmpty {
            throw JsBaoError(code: .invalidArgument, message: "Cannot mix inclusion and exclusion in projection")
        }
        let kept: Set<String> = ["id", "_related"]
        if !included.isEmpty {
            return { row in row.filter { kept.contains($0.key) || included.contains($0.key) } }
        }
        return { row in row.filter { kept.contains($0.key) || !excluded.contains($0.key) } }
    }

    /// An aggregate statement's row as the shaper reads it: SQL NULL as `.null`.
    private static func aggregateRow(_ row: Format2SqlRow) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (name, value) in row.columns {
            switch value {
            case .null: out[name] = .null
            case .text(let text): out[name] = .string(text)
            case .integer(let number): out[name] = .number(Double(number))
            case .real(let number): out[name] = .number(number)
            }
        }
        return out
    }

    /// Run `statement` within `document`, a row at a time, each as a record.
    fileprivate func readLeg(
        _ statement: String, _ bindings: [Format2SqlValue], _ row: (RecordLogRow) throws -> Void
    ) throws {
        try store.readView { sql in
            try sql.connection.eachRow(statement, bindings) { raw in
                try row(RecordLogJSON.row(raw["_data"].stringValue))
                return true
            }
        }
    }
}

// MARK: - Includes

/// An include tree checked whole before any statement runs, as the room and
/// js-bao's view reader check it (`validateIncludeSpec`, strict): the target's
/// model, the fields each kind needs, the alias and the sort fields as
/// identifiers, sort directions 1 or -1, a positive `limit`, projection fields
/// as identifiers, and at most three levels. A target that is a model bound to
/// a format-1 document is refused too: a leg resolves within the parent's own
/// db3, which a format-1 document's rows never are.
struct RecordLogIncludeTree {

    /// `include` checked, or `nil` when it names nothing.
    static func validated(_ include: [Include]?) throws -> [Include]? {
        guard let include, !include.isEmpty else { return nil }
        for spec in include {
            if let reason = reason(spec, depth: 0) { throw Db3Limits.invalidInclude(reason) }
        }
        return include
    }

    /// Why `spec` at `depth` is not a valid include, or `nil`. The reasons are
    /// js-bao's, after `IncludeSpecError` drops their `include:` prefix.
    static func reason(_ spec: Include, depth: Int) -> String? {
        let model = spec.target.modelName
        let valid = RecordLogSchema.isValidIdentifier
        guard valid(model) else { return "invalid model name '\(model)'" }
        if let member = spec.target as? DynamicModel, member.local == nil {
            return "target is not in the parent's document"
        }
        switch spec.type {
        case .refersTo, .refersToMany:
            guard let sourceField = spec.sourceField, !sourceField.isEmpty else {
                return "\(spec.type.rawValue): 'sourceField' is required"
            }
            guard valid(sourceField) else { return "\(spec.type.rawValue): invalid sourceField '\(sourceField)'" }
        case .hasMany:
            guard let foreignKey = spec.foreignKey, !foreignKey.isEmpty else { return "hasMany: 'foreignKey' is required" }
            guard valid(foreignKey) else { return "hasMany: invalid foreignKey '\(foreignKey)'" }
            if let localField = spec.localField, !valid(localField) { return "hasMany: invalid localField '\(localField)'" }
        }
        if let alias = spec.resultKey, !valid(alias) { return "invalid alias '\(alias)'" }
        for field in (spec.sort ?? [:]).keys.sorted() where !valid(field) { return "invalid sort field '\(field)'" }
        if let limit = spec.limit, limit <= 0 { return "hasMany limit must be a positive integer" }
        for field in (spec.projection ?? [:]).keys.sorted() where !valid(field) { return "invalid projection field '\(field)'" }
        if (spec.sort ?? [:]).values.contains(where: { $0 != 1 && $0 != -1 }) { return "sort directions must be 1 or -1" }
        if let nested = spec.include, !nested.isEmpty {
            if depth + 1 >= Db3Limits.includeMaxDepth {
                return "include nests deeper than \(Db3Limits.includeMaxDepth) levels"
            }
            for child in nested {
                if let reason = reason(child, depth: depth + 1) { return reason }
            }
        }
        return nil
    }
}

/// One page's includes, resolved over the view: the parents grouped by their
/// db3, each group's legs read within that db3 only, the `hasMany` cap and the
/// byte budget counted once for the whole request. js-bao's `resolveIncludes`
/// with the db3 limits and `invalidSpec: "refuse"`, as the JS view reader
/// calls it.
private final class RecordLogIncludeResolution {

    private let reader: RecordLogViewReader
    /// Related rows read per `hasMany` leg, by its path of `_related` keys.
    private var legRows: [String: Int] = [:]
    /// The answer's bytes so far, seeded with the page's own.
    private var used = 0

    init(reader: RecordLogViewReader) {
        self.reader = reader
    }

    /// `,"_related":{}` on a record that has fields of its own.
    private static let shellBytes = #","_related":{}"#.utf8.count
    /// The most values one leg statement binds, as js-bao's statement bound.
    private static let boundParams = 100

    func resolve(_ rows: inout [RecordLogRow], documents: [String], includes: [Include], used: Int) throws {
        self.used = used
        var order: [String] = []
        var groups: [String: [Int]] = [:]
        for (index, document) in documents.enumerated() {
            if groups[document] == nil { order.append(document) }
            groups[document, default: []].append(index)
        }
        for document in order {
            let indices = groups[document] ?? []
            var parents = indices.map { rows[$0] }
            try level(&parents, includes, depth: 0, document: document, path: "")
            for (offset, index) in indices.enumerated() { rows[index] = parents[offset] }
        }
        // The answer as it will be sent, measured again with `_related` attached.
        let bytes = rows.reduce(0) { $0 + RecordLogJSON.bytes(.object($1)) }
        if bytes > Db3Limits.responseMaxBytes {
            throw Db3Limits.pageTooLarge(bytes: bytes, limit: Db3Limits.responseMaxBytes)
        }
    }

    private func spend(_ bytes: Int) throws {
        guard bytes > 0 else { return }
        used += bytes
        if used > Db3Limits.responseMaxBytes {
            throw Db3Limits.pageTooLarge(bytes: used, limit: Db3Limits.responseMaxBytes)
        }
    }

    private func account(_ row: RecordLogRow) throws {
        try spend(RecordLogJSON.bytes(.object(row)))
    }

    private func level(
        _ records: inout [RecordLogRow], _ includes: [Include], depth: Int, document: String, path: String
    ) throws {
        if records.isEmpty || depth >= Db3Limits.includeMaxDepth { return }
        var keys = Set<String>()
        for spec in includes {
            let key = spec.resultKey ?? spec.target.modelName
            try spend(records.filter { $0["_related"] == nil }.count * Self.shellBytes)
            for index in records.indices where records[index]["_related"] == nil {
                records[index]["_related"] = .object([:])
            }
            // `"key":` once per record, after a comma unless it is the first key;
            // a key a sibling spec already took is replaced, not repeated.
            let keyBytes = keys.contains(key) ? 0 : (keys.isEmpty ? 0 : 1) + RecordLogJSON.bytes(.string(key)) + 1
            keys.insert(key)
            let legPath = path.isEmpty ? key : "\(path)/\(key)"
            switch spec.type {
            case .refersTo: try refersTo(&records, spec, key: key, keyBytes: keyBytes, document: document)
            case .refersToMany: try refersToMany(&records, spec, key: key, keyBytes: keyBytes, document: document)
            case .hasMany: try hasMany(&records, spec, key: key, keyBytes: keyBytes, path: legPath, document: document)
            }
            if let nested = spec.include, !nested.isEmpty {
                // A related row attached to several parents is resolved once and
                // attached again wherever it appears.
                var related: [RecordLogRow] = []
                var seen = Set<String>()
                for record in records {
                    let attached = record["_related"]?[key]
                    let rows = attached?.arrayValue?.compactMap(\.objectValue) ?? attached?.objectValue.map({ [$0] }) ?? []
                    for row in rows {
                        let id = row["id"]?.stringValue ?? ""
                        if seen.insert(id).inserted { related.append(row) }
                    }
                }
                guard !related.isEmpty else { continue }
                try level(&related, nested, depth: depth + 1, document: document, path: legPath)
                let byId = Dictionary(related.map { ($0["id"]?.stringValue ?? "", $0) }, uniquingKeysWith: { first, _ in first })
                let updated = { (value: JSONValue) -> JSONValue in
                    guard let id = value["id"]?.stringValue, let row = byId[id] else { return value }
                    return .object(row)
                }
                for index in records.indices {
                    guard var holder = records[index]["_related"]?.objectValue, let attached = holder[key] else { continue }
                    if let rows = attached.arrayValue {
                        holder[key] = .array(rows.map(updated))
                    } else if attached.objectValue != nil {
                        holder[key] = updated(attached)
                    }
                    records[index]["_related"] = .object(holder)
                }
            }
        }
    }

    /// Set `record._related[key]`, counting under the budget what it adds: the
    /// key, and `null` or an array's brackets and commas.
    private func attach(_ record: inout RecordLogRow, key: String, keyBytes: Int, _ value: JSONValue) throws {
        let container: Int
        switch value {
        case .null: container = 4
        case .array(let rows): container = 2 + max(0, rows.count - 1)
        default: container = 0
        }
        try spend(keyBytes + container)
        var holder = record["_related"]?.objectValue ?? [:]
        holder[key] = value
        record["_related"] = .object(holder)
    }

    /// The distinct values a leg looks up: present, not null, not empty, kept by their JSON.
    private static func present(_ values: [JSONValue?]) -> [JSONValue] {
        var seen = Set<String>()
        var out: [JSONValue] = []
        for case let value? in values where value != .null && value != .string("") {
            if seen.insert(RecordLogJSON.text(value)).inserted { out.append(value) }
        }
        return out
    }

    private static func lookupKey(_ value: JSONValue?) -> String? {
        guard let value, value != .null else { return nil }
        return RecordLogJSON.text(value)
    }

    private func applyProjection(_ spec: Include, _ row: RecordLogRow) -> RecordLogRow {
        guard let projection = spec.projection, !projection.isEmpty else { return row }
        if projection.values.contains(1) {
            return row.filter { $0.key == "id" || $0.key == "type" || $0.key == "_related" || projection[$0.key] == 1 }
        }
        return row.filter { $0.key == "id" || $0.key == "type" || projection[$0.key] != 0 }
    }

    // MARK: Legs

    private func refersTo(_ records: inout [RecordLogRow], _ spec: Include, key: String, keyBytes: Int, document: String) throws {
        let sourceField = spec.sourceField ?? ""
        let values = Self.present(records.map { $0[sourceField] })
        let byId = values.isEmpty ? [:] : try targetsById(spec, values, document: document)
        for index in records.indices {
            let target = Self.lookupKey(records[index][sourceField]).flatMap { byId[$0] }
            try attach(&records[index], key: key, keyBytes: keyBytes, target.map(JSONValue.object) ?? .null)
        }
    }

    private func refersToMany(_ records: inout [RecordLogRow], _ spec: Include, key: String, keyBytes: Int, document: String) throws {
        let sourceField = spec.sourceField ?? ""
        let values = Self.present(records.flatMap { $0[sourceField]?.arrayValue ?? [] })
        let byId = values.isEmpty ? [:] : try targetsById(spec, values, document: document)
        for index in records.indices {
            let members = records[index][sourceField]?.arrayValue ?? []
            let targets = members.compactMap { Self.lookupKey($0).flatMap { byId[$0] } }
            try attach(&records[index], key: key, keyBytes: keyBytes, .array(targets.map(JSONValue.object)))
        }
    }

    private func targetsById(_ spec: Include, _ ids: [JSONValue], document: String) throws -> [String: RecordLogRow] {
        var byId: [String: RecordLogRow] = [:]
        try readIn(spec.target.modelName, field: "id", ids, filter: spec.filter, sort: nil, document: document) { row in
            let target = self.applyProjection(spec, row)
            try self.account(target)
            if let key = Self.lookupKey(target["id"]) { byId[key] = target }
        }
        return byId
    }

    private func hasMany(
        _ records: inout [RecordLogRow], _ spec: Include, key: String, keyBytes: Int, path: String, document: String
    ) throws {
        let localField = spec.localField ?? "id"
        let foreignKey = spec.foreignKey ?? ""
        let values = Self.present(records.map { $0[localField] })
        var grouped: [String: [JSONValue]] = [:]
        if !values.isEmpty {
            let cap = Db3Limits.includeMaxRelatedRows
            let onRow = { (row: RecordLogRow) throws in
                let read = (self.legRows[path] ?? 0) + 1
                self.legRows[path] = read
                if read > cap { throw Db3Limits.includeTooLarge(include: key, rows: read, limit: cap) }
                let related = self.applyProjection(spec, row)
                try self.account(related)
                if let fk = Self.lookupKey(row[foreignKey]) { grouped[fk, default: []].append(.object(related)) }
            }
            // Under the cap each statement asks for one row past what the leg
            // has left, so the row that passes it is the last one read.
            let rowLimit = { cap - (self.legRows[path] ?? 0) + 1 }
            if let perParent = spec.limit {
                try readPartitioned(spec, values, perParent: perParent, rowLimit: rowLimit, document: document, onRow)
            } else {
                try readIn(spec.target.modelName, field: foreignKey, values, filter: spec.filter, sort: spec.sort,
                           rowLimit: rowLimit, document: document, onRow)
            }
        }
        for index in records.indices {
            let related = Self.lookupKey(records[index][localField]).flatMap { grouped[$0] } ?? []
            try attach(&records[index], key: key, keyBytes: keyBytes, .array(related))
        }
    }

    /// `field IN (values)` over `model` within `document`, in chunks that fit a statement's binds.
    private func readIn(
        _ model: String, field: String, _ values: [JSONValue], filter extra: DocumentFilter?, sort: [String: Int]?,
        rowLimit: (() -> Int)? = nil, document: String, _ onRow: (RecordLogRow) throws -> Void
    ) throws {
        let extraParams = try extra.map { try QueryTranslator.translateView($0).1.count } ?? 0
        let chunkSize = max(1, Self.boundParams - 2 - extraParams)
        let order = try Self.order(sort)
        var start = 0
        while start < values.count {
            let chunk = Array(values[start..<min(start + chunkSize, values.count)])
            start += chunkSize
            var filter: DocumentFilter = [field: ["$in": .array(chunk)]]
            for (name, value) in extra ?? [:] { filter[name] = value }
            let (clause, params) = try QueryTranslator.translateView(filter)
            var statement = "SELECT _data FROM record_log_view WHERE _type = ? AND doc_id = ? AND (\(clause)) ORDER BY \(order)"
            if let rowLimit { statement += " LIMIT \(rowLimit())" }
            try reader.readLeg(statement, [.text(model), .text(document)] + params.map(Format2SqlValue.init(bindable:)), onRow)
        }
    }

    /// A `hasMany` leg with a per-parent `limit`: each parent's first rows in
    /// the leg's sort, read by one window statement per chunk.
    private func readPartitioned(
        _ spec: Include, _ values: [JSONValue], perParent: Int, rowLimit: @escaping () -> Int, document: String,
        _ onRow: (RecordLogRow) throws -> Void
    ) throws {
        let foreignKey = try QueryTranslator.viewField(spec.foreignKey ?? "")
        let (filterClause, filterParams) = try QueryTranslator.translateView(spec.filter ?? [:])
        let chunkSize = max(1, Self.boundParams - 4 - filterParams.count)
        let order: String
        if let sort = spec.sort, !sort.isEmpty {
            order = try sort.keys.sorted().map { "\(try QueryTranslator.viewField($0)) \(sort[$0] == -1 ? "DESC" : "ASC")" }
                .joined(separator: ", ")
        } else {
            order = "\"_id\" ASC"
        }
        var start = 0
        while start < values.count {
            let chunk = Array(values[start..<min(start + chunkSize, values.count)])
            start += chunkSize
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let statement = "SELECT _data FROM (SELECT _data, ROW_NUMBER() OVER (PARTITION BY \(foreignKey) ORDER BY \(order)) AS _rn"
                + " FROM record_log_view WHERE _type = ? AND doc_id = ? AND \(foreignKey) IN (\(placeholders))"
                + " AND (\(filterClause))) WHERE _rn <= ? LIMIT ?"
            let bindings: [Format2SqlValue] = [.text(spec.target.modelName), .text(document)]
                + chunk.map { Format2SqlValue(json: $0) } + filterParams.map(Format2SqlValue.init(bindable:))
                + [.integer(Int64(perParent)), .integer(Int64(rowLimit()))]
            try reader.readLeg(statement, bindings, onRow)
        }
    }

    /// A leg's order: its sort by field name, then `id`, as a page orders.
    private static func order(_ sort: [String: Int]?) throws -> String {
        var parts: [String] = []
        let fields = (sort ?? [:]).keys.sorted()
        for field in fields { parts.append("\(try QueryTranslator.viewField(field)) \(sort?[field] == -1 ? "DESC" : "ASC")") }
        if !fields.contains("id") { parts.append("\"_id\" ASC") }
        return parts.joined(separator: ", ")
    }
}
