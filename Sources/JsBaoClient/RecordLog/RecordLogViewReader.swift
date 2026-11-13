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
/// - A read of one db3 holding a member table on this device reads as its
///   room would (a local-only db3's, #5156, or a synced db3's placed on the
///   device, #5223): a field holding a member index has `$contains`, any-of,
///   membership levels and unfiltered facets read from the device table, and
///   a sorted facet orders the members its sort leaves tied by the member (on
///   a local-only db3 always). A read over several db3s reads `_data`.
/// - A `$search` reads the db3's text index on this device (#5223): a page
///   joins its matches ranked by `-bm25` as `_score`, which every row
///   carries; count and an aggregate keep the rows it matches.
/// - A `$near` reads the db3's vector index on this device (#5230): a page
///   joins its `k` nearest rows with their exact `_distance`, which every
///   row carries, nearest first with no sort given; count and an aggregate
///   keep its rows.
///
/// Its statements run on `store`'s connection as the store reads, so they see
/// what an open group of saves has written. `documents` is the scope: every
/// statement names it, but a facet read from a member table, which holds
/// exactly the one db3's rows.
struct RecordLogViewReader {

    let store: RecordLogStore
    let documents: [String]
    /// An explain's force and recorder (#5241): `nil` for every ordinary read.
    var force: RecordLogReadForce? = nil

    /// `record_log_view` at a FROM position, with the index an explain forces
    /// `model`'s statements through (#5241).
    private func viewFrom(_ model: String) -> String {
        guard let index = force?.indexedBy(model) else { return "record_log_view" }
        return "record_log_view INDEXED BY \(Self.quoted(index))"
    }

    /// The condition that a row is `model`'s: bound, or under a forced index
    /// the model as a literal, so the partial index proves at prepare time (#5241).
    private func typeCondition(_ model: String, table: String? = nil) -> (sql: String, bindings: [Format2SqlValue]) {
        let column = table.map { "\($0).\"_type\"" } ?? "_type"
        if force?.indexedBy(model) != nil { return ("\(column) = \(RecordLogSchema.quoteLiteral(model))", []) }
        return ("\(column) = ?", [.text(model)])
    }

    /// Tell an explain's recorder a statement of `model`'s is about to run (#5241).
    private func noteRun(_ model: String, _ statement: String, _ bindings: [Format2SqlValue]) {
        force?.record(model, statement, bindings)
    }

    /// The key the document tie-break takes in a cursor and its sort fields.
    static let documentTieBreak = "_tiebreak:doc_id"

    /// How a page answers a record.
    enum RowShape {
        /// As the view holds it: the model-free records.
        case stored
        /// As the model API reads it: each declared set field an array of its
        /// members in canonical order (`[]` when the record holds none), and
        /// the record's document under `_meta_doc_id`. `decode`, given a
        /// record's model, the row and its document, reads each vector field
        /// as its numbers (#5225), once the page is cut: the page's rows as
        /// the queried model's, each included row as its include's model's.
        case model(setFields: Set<String>, decode: RowDecode? = nil)
        /// As the model-free records read it (#5225): as stored, each vector
        /// field this device knows read as its numbers by `decode`.
        case decoded(RowDecode)

        /// Reads a row of a model (the first argument) in a document (the last) as the caller answers it.
        typealias RowDecode = (String, RecordLogRow, String) -> RecordLogRow

        var decode: RowDecode? {
            switch self {
            case .stored: return nil
            case .model(_, let decode): return decode
            case .decoded(let decode): return decode
            }
        }
    }

    /// The models a read with `include` answers rows of: `model` and each
    /// include's target, nested includes too.
    static func models(_ model: String, _ include: [Include]?) -> Set<String> {
        var out: Set<String> = [model]
        for spec in include ?? [] { out.formUnion(models(spec.target.modelName, spec.include)) }
        return out
    }

    /// `row` with each record its includes attached under `_related` read by
    /// `decode` as its include's model's, nested includes too (#5225). A key
    /// two specs share holds the later spec's records, as the resolution
    /// attaches them.
    static func decodedIncludes(
        _ row: RecordLogRow, _ includes: [Include], document: String, _ decode: @escaping RowShape.RowDecode
    ) -> RecordLogRow {
        guard var related = row["_related"]?.objectValue else { return row }
        var specs: [String: Include] = [:]
        for spec in includes { specs[spec.resultKey ?? spec.target.modelName] = spec }
        for (key, spec) in specs {
            guard let attached = related[key] else { continue }
            let read = { (value: JSONValue) -> JSONValue in
                guard let included = value.objectValue else { return value }
                var out = decode(spec.target.modelName, included, document)
                if let nested = spec.include, !nested.isEmpty {
                    out = decodedIncludes(out, nested, document: document, decode)
                }
                return .object(out)
            }
            if let rows = attached.arrayValue {
                related[key] = .array(rows.map(read))
            } else {
                related[key] = read(attached)
            }
        }
        var out = row
        out["_related"] = .object(related)
        return out
    }

    /// `row` with each record its includes attached under `_related` tagged
    /// with `document` under `_meta_doc_id`, nested includes too, as the
    /// model API tags a page's own rows: a leg resolves within the parent's
    /// db3, so an included record is that db3's, and a model built from it
    /// fills a defaulted field the record does not hold
    /// (`PrimitiveRecord.holds(_:in:)`) as one read directly does (#5896).
    static func taggedIncludes(_ row: RecordLogRow, _ includes: [Include], document: String) -> RecordLogRow {
        guard var related = row["_related"]?.objectValue else { return row }
        var specs: [String: Include] = [:]
        for spec in includes { specs[spec.resultKey ?? spec.target.modelName] = spec }
        for (key, spec) in specs {
            guard let attached = related[key] else { continue }
            let tag = { (value: JSONValue) -> JSONValue in
                guard var included = value.objectValue else { return value }
                included["_meta_doc_id"] = .string(document)
                if let nested = spec.include, !nested.isEmpty {
                    included = taggedIncludes(included, nested, document: document)
                }
                return .object(included)
            }
            if let rows = attached.arrayValue {
                related[key] = .array(rows.map(tag))
            } else {
                related[key] = tag(attached)
            }
        }
        var out = row
        out["_related"] = .object(related)
        return out
    }

    /// Refuse a device read whose filter, or any include spec's filter, uses
    /// `$near` at any depth (#5225): an include leg reads no vector index, so
    /// the read is refused `.queryIndexNotOnDevice` before any statement,
    /// naming the operator, the model whose filter used it and the field
    /// (`null` when it names none). A read's own filter is judged by
    /// ``nearIndex(_:_:)`` instead (#5230).
    static func refuseNear(_ model: String, _ filter: DocumentFilter?, include: [Include]? = nil) throws {
        if let filter, case .some(let field) = nearField(.object(filter)) {
            throw JsBaoError(
                code: .queryIndexNotOnDevice,
                message: "$near on \(model)\(field.map { ".\($0)" } ?? "") needs a vector index on this device, and this device holds none over the field",
                details: ["operator": "$near", "model": .string(model), "field": field.map { .string($0) } ?? .null]
            )
        }
        for spec in include ?? [] {
            try refuseNear(spec.target.modelName, spec.filter, include: spec.include)
        }
    }

    /// The field the first `$near` in `value` names, at any depth: `.some(nil)`
    /// for one naming none, `nil` when `value` uses no `$near`.
    private static func nearField(_ value: JSONValue) -> String?? {
        switch value {
        case .array(let members):
            for member in members { if case .some(let field) = nearField(member) { return .some(field) } }
            return nil
        case .object(let object):
            for (key, member) in object.sorted(by: { $0.key < $1.key }) {
                if key == "$near" { return .some(member.objectValue?["field"]?.stringValue) }
                if case .some(let field) = nearField(member) { return .some(field) }
            }
            return nil
        default:
            return nil
        }
    }

    struct Page {
        var rows: [RecordLogRow]
        /// Each row's document, in row order.
        var documents: [String]
        var nextCursor: String?
        var prevCursor: String?
        var hasMore: Bool
        /// How far behind each synced db3 of the scope whose head is known
        /// is (#5221), read in the rows' transaction; `nil` for a read of no document.
        var drift: [String: Db3Drift]? = nil
    }

    /// How a read of `model` reads as its room would (#5156, #5223): each
    /// field's member table, and whether a sorted facet orders tied members by
    /// the member. Both empty for a read over several db3s, or of a synced one
    /// holding no member table for the model.
    private struct DeviceIndexRead {
        var tables: [String: String] = [:]
        var tiesByMember = false

        func table(_ field: String) -> String? { tables[field] }
    }

    /// The text index a `$search` of `model` reads (#5223), refused before
    /// any statement: over other than one db3 `.invalidArgument`; with no text
    /// entry cached for the model `.queryIndexNotOnDevice`; with one this
    /// device declined `.db3IndexDeclinedOnDevice` (#5322); with one this
    /// device holds no table for `.db3IndexPlacementUnsupported`, naming the
    /// engine and why. `nil` for a filter without `$search`.
    private func searchIndex(_ model: String, _ filter: DocumentFilter?) throws -> QueryTranslator.ViewTextIndex? {
        guard RecordLogTextSearch.has(filter) else { return nil }
        guard documents.count == 1, let documentId = documents.first else {
            throw JsBaoError(
                code: .invalidArgument, message: "$search reads one db3's text index: give exactly one db3, not \(documents.count)"
            )
        }
        guard let index = try store.readView({
            try RecordLogIndexes.textIndex($0, documentId: documentId, model: model, deviceIndexes: store.deviceIndexes)
        }) else {
            throw RecordLogTextSearch.notOnDevice(model: model)
        }
        // Declined here (#5322): refused ahead of why a build failed.
        if let declined = index.declined { throw RecordLogTextSearch.declined(model: model, index: index.roomName, reason: declined) }
        guard let table = index.table else {
            throw RecordLogTextSearch.notBuilt(
                model: model, on: index.options.on, reason: index.options.unbuilt ?? "the text index is not built on this device"
            )
        }
        let weights = index.fields.map { field -> Double in
            let weight = index.options.weights[field] ?? 1
            return weight.isFinite && weight > 0 ? weight : 1
        }
        return QueryTranslator.ViewTextIndex(table: table, fields: index.fields, weights: weights)
    }

    /// The key a search's rank is selected, sorted and paged by (#5223).
    static let scoreKey = "_score"

    /// The key a `$near`'s distance is selected, sorted and paged by (#5230).
    static let distanceKey = RecordLogNearSearch.distanceKey

    /// The vector index a `$near` of `model` reads (#5230, js-bao's
    /// `nearIndexOf`), its query checked, refused before any statement reads
    /// a record, in this order: a `$near` the grammar does not admit
    /// (`.invalidArgument`); more than one db3 (`.invalidArgument`); a field
    /// the db3's type does not declare a vector, or a query vector of another
    /// length than the field's or holding a member that is not a finite
    /// number (`.db3VectorInvalid`); no vector entry cached for the field
    /// (`.queryIndexNotOnDevice`); one this device declined
    /// (`.db3IndexDeclinedOnDevice`); one this device holds no table for
    /// (`.db3IndexPlacementUnsupported`, naming the engine and why). `nil` for
    /// a filter without `$near`.
    func nearIndex(_ model: String, _ filter: DocumentFilter?) throws -> RecordLogNearSearch.Read? {
        guard let near = try RecordLogNearSearch.parse(filter) else { return nil }
        try QueryTranslator.requireViewIdentifier(model, context: "query model")
        guard documents.count == 1, let documentId = documents.first else {
            throw JsBaoError(code: .invalidArgument, message: "$near reads one db3's vector index: give exactly one db3, not \(documents.count)")
        }
        return try store.readView { sql in
            let declared = try RecordLogNearSearch.declaredField(sql, documentId: documentId, model: model, field: near.field)
            if let declared, declared.kind != "vector" {
                throw RecordLogNearSearch.vectorInvalid(
                    model: model, field: near.field,
                    "\(model).\(near.field) is \(declared.kind.map { "a \($0) field" } ?? "not declared"), not a vector field: $near reads a vector field's index"
                )
            }
            let index = try RecordLogIndexes.vectorIndex(sql, documentId: documentId, model: model, field: near.field, deviceIndexes: store.deviceIndexes)
            let vector = try RecordLogNearSearch.vectorBytes(near, model: model, dims: declared?.dims ?? index?.vector?.dims)
            guard let index else { throw RecordLogNearSearch.notOnDevice(model: model, field: near.field) }
            if let declined = index.declined { throw RecordLogNearSearch.declined(model: model, index: index.roomName, reason: declined) }
            guard let table = index.table, let options = index.vector else {
                throw RecordLogNearSearch.notBuilt(model: model, reason: index.unbuilt ?? "the vector index is not built on this device")
            }
            return RecordLogNearSearch.Read(
                table: table, annTable: index.annTable, distance: options.distance, vector: vector, k: near.k, filter: near.filter
            )
        }
    }

    /// The statement a `$near` reads its rows from, its filter translated
    /// with the db3's member tables, as `translateView` writes conditions.
    static func nearRows(_ read: RecordLogNearSearch.Read, memberIndexTable: ((String) -> String?)?, model: String) throws -> (sql: String, params: [Format2SqlValue]) {
        let (clause, params) = read.filter.isEmpty
            ? ("", [])
            : try QueryTranslator.translateView(read.filter, memberIndexTable: memberIndexTable, model: model)
        return RecordLogNearSearch.subquery(
            read, viewTable: "record_log_view", filterSQL: clause.isEmpty ? "" : "(\(clause))", filterParams: params.map(Format2SqlValue.init(bindable:))
        )
    }

    /// A weight as the statement writes it: as JavaScript writes the number,
    /// an integral weight past Int64 written as a double rather than trapping.
    private static func number(_ value: Double) -> String {
        if abs(value) < 1e21, let integral = Int64(exactly: value) { return String(integral) }
        return String(value)
    }

    /// How a read of `model` over one db3 reads its device indexes: the member
    /// tables the db3 holds for the model, and ties by member where it holds
    /// one (always for a db3 that lives only on this device, as its room would).
    /// Asked once the read's names were judged, so a refused name runs no statement.
    private func deviceIndexRead(_ model: String) throws -> DeviceIndexRead {
        guard documents.count == 1, let documentId = documents.first else { return DeviceIndexRead() }
        return try store.readView { sql in
            let localOnly = try sql.first(
                "SELECT local_only FROM record_log_state WHERE doc_id = ?", [.text(documentId)]
            )?["local_only"].intValue == 1
            var read = DeviceIndexRead()
            for row in try sql.rows(
                "SELECT fields, members FROM record_log_indexes WHERE doc_id = ? AND model = ? AND members IS NOT NULL",
                [.text(documentId), .text(model)]
            ) {
                guard let field = (row["fields"].stringValue.flatMap(RecordLogJSON.parse)?.arrayValue ?? []).first?.stringValue,
                      let table = row["members"].stringValue
                else { continue }
                read.tables[field] = table
            }
            read.tiesByMember = localOnly || !read.tables.isEmpty
            // An explain's force reads its own member tables (#5241).
            if let forced = force?.memberTables(model) { read.tables = forced }
            return read
        }
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
        try Self.refuseNear(model, nil, include: include)
        // A `$near` is judged first: its own refusals name what it got wrong (#5230).
        let near = try nearIndex(model, filter)
        if near != nil { try store.vectorEntryReadForTest?() }
        let options = options ?? QueryOptions()
        try QueryTranslator.requireViewIdentifier(model, context: "query model")
        let limit = try options.limit.map { try Db3Limits.checkedLimit($0) } ?? Db3Limits.pageDefault
        let includes = try RecordLogIncludeTree.validated(include)
        // A text search joins its index's matches, ranked (#5223); the rest of
        // the filter is translated as any filter is.
        let search = try searchIndex(model, filter)
        var rest = filter
        var join = ""
        var joinBindings: [Format2SqlValue] = []
        if let search, let value = rest.removeValue(forKey: RecordLogTextSearch.key) {
            let match = try RecordLogTextSearch.match(try RecordLogTextSearch.parse(value), indexFields: search.fields)
            let fts = Self.quoted(search.table)
            let weights = search.weights.map { ", \(Self.number($0))" }.joined()
            join = " JOIN (SELECT rowid, -bm25(\(fts)\(weights)) AS \(Self.scoreKey) FROM \(fts) WHERE \(fts) MATCH ?) AS _search"
                + " ON _search.rowid = record_log_view.rowid"
            joinBindings = [.text(match)]
        }
        // A `$near` is its filter's only key: its k nearest rows are joined, nearest first (#5230).
        if near != nil { rest = [:] }
        var (clause, params) = try QueryTranslator.translateView(rest, model: model)
        // A search with no sort answers the best match first, then by id; a `$near` the nearest first.
        var ordered = options
        let unsorted = (options.sortOrder ?? []).isEmpty && (options.sort ?? [:]).isEmpty
        if search != nil, unsorted { ordered.sortOrder = [(Self.scoreKey, -1)] }
        if near != nil, unsorted { ordered.sortOrder = [(Self.distanceKey, 1)] }
        let sort = ordered.pagingSort
        let fields = sort.fields + [Self.documentTieBreak]
        let directions = sort.directions + [1]
        var columns = [Self.documentTieBreak: "doc_id"]
        for field in sort.fields {
            if search != nil && field == Self.scoreKey {
                columns[field] = "_search.\(Self.scoreKey)"
            } else if near != nil && field == Self.distanceKey {
                columns[field] = "_near.\(Self.distanceKey)"
            } else {
                columns[field] = try QueryTranslator.viewField(field)
            }
        }
        let keep = try Self.projection(options.projection)
        let maxDrift = try Db3DriftJudge.checked(options.maxDrift)
        guard !documents.isEmpty else { return Page(rows: [], documents: [], nextCursor: nil, prevCursor: nil, hasMore: false) }
        // One read transaction (#5221): the rows, their include legs and each
        // document's sync state, read last, are one snapshot of the store.
        return try store.readView { _ in
            // Every name judged, the db3's member tables are read (#5156, #5223).
            let local = try deviceIndexRead(model)
            if !local.tables.isEmpty { (clause, params) = try QueryTranslator.translateView(rest, memberIndexTable: local.table, model: model) }
            // The vector index read again in the rows' transaction: an index list applied since may have dropped the ANN table judged above.
            if near != nil, let near = try nearIndex(model, filter) {
                let members: ((String) -> String?)? = local.tables.isEmpty ? nil : { local.table($0) }
                let rows = try Self.nearRows(near, memberIndexTable: members, model: model)
                join = " JOIN (\(rows.sql)) AS _near ON _near.rowid = record_log_view.rowid"
                joinBindings = rows.params
            }

            let type = typeCondition(model)
            var conditions = [type.sql, "(\(clause))"]
            var bindings: [Format2SqlValue] = joinBindings + type.bindings + params.map(Format2SqlValue.init(bindable:))
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
            let statement = "SELECT json(_data) AS _data, _id, _type, doc_id"
                + (search != nil ? ", _search.\(Self.scoreKey) AS \(Self.scoreKey)" : "")
                + (near != nil ? ", _near.\(Self.distanceKey) AS \(Self.distanceKey)" : "") + " FROM \(viewFrom(model))\(join) WHERE "
                + conditions.joined(separator: " AND ") + " ORDER BY " + order.joined(separator: ", ")
                + " LIMIT \(limit + 1)"

            var rows: [RecordLogRow] = []
            var rowDocuments: [String] = []
            var minting: [RecordLogRow] = []
            var used = 0
            var hasMore = false
            noteRun(model, statement, bindings)
            try store.readView { sql in
                try sql.connection.eachRow(statement, bindings) { raw in
                    if rows.count >= limit {
                        hasMore = true
                        return false
                    }
                    let stored = raw["_data"].stringValue ?? "{}"
                    let id = raw["_id"].stringValue ?? ""
                    var parsed = RecordLogJSON.row(stored)
                    let holdsId = parsed["id"] != nil
                    if !holdsId { parsed["id"] = .string(id) }
                    let (record, reshaped) = Self.shaped(parsed, shape)
                    // With includes, a parent is read whole: a leg may need a field
                    // the projection leaves out. It applies once the legs resolved.
                    var answered = includes == nil ? keep(record) : record
                    // A search's rank rides every row it answers, whatever the projection (#5223).
                    let score = search == nil ? nil : Self.scoreValue(raw[Self.scoreKey])
                    if let score { answered[Self.scoreKey] = score }
                    // As does a `$near`'s exact distance (#5230).
                    let distance = near == nil ? nil : Self.scoreValue(raw[Self.distanceKey])
                    if let distance { answered[Self.distanceKey] = distance }
                    // A row counts as it is answered: its stored text with its `id` restored.
                    let bytes = !reshaped && options.projection == nil && score == nil && distance == nil
                        ? stored.utf8.count + RecordLogJSON.restoredIdBytes(stored: stored, id: id, holdsId: holdsId)
                        : RecordLogJSON.bytes(.object(answered))
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
                    if let score { mint[Self.scoreKey] = score }
                    if let distance { mint[Self.distanceKey] = distance }
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
            if let decode = shape.decode {
                for index in rows.indices {
                    rows[index] = decode(model, rows[index], rowDocuments[index])
                    if let includes {
                        rows[index] = Self.decodedIncludes(rows[index], includes, document: rowDocuments[index], decode)
                    }
                }
            }
            if case .model = shape {
                for index in rows.indices {
                    rows[index]["_meta_doc_id"] = .string(rowDocuments[index])
                    if let includes {
                        rows[index] = Self.taggedIncludes(rows[index], includes, document: rowDocuments[index])
                    }
                }
            }
            if backward {
                rows.reverse()
                rowDocuments.reverse()
            }
            var page = Page(rows: rows, documents: rowDocuments, nextCursor: next, prevCursor: prev, hasMore: hasMore)
            page.drift = try judgedDrift(maxDrift, options)
            return page
        }
    }

    /// The scope's drift (#5221) from each document's sync state, read now in
    /// the caller's read, judged against `maxDrift` in scope order: the order
    /// `options` names its db3s in, then the reader's.
    private func judgedDrift(_ maxDrift: Db3MaxDrift?, _ options: QueryOptions?) throws -> [String: Db3Drift] {
        let sync = try store.readView { sql in try RecordLogStore.documentSync(sql, documents) }
        let host = store.host
        let drift = Db3DriftJudge.drift(documents, sync) { RecordLogLiveness.isLive(host, $0) }
        let named = (try? options?.documentScope()) ?? nil
        let order = (named ?? []).filter(documents.contains) + documents.filter { !(named ?? []).contains($0) }
        try Db3DriftJudge.judge(maxDrift, order: order, sync: sync, drift: drift)
        return drift
    }

    /// How many of `model`'s records in the scope match `filter`, matched as
    /// ``page(_:_:options:shape:include:)`` matches them. Consumes every row.
    /// With `maxDrift`, the count and the scope's sync state are read in one
    /// read transaction and refused `DB3_DRIFT_EXCEEDED` as a page is (#5221).
    func count(_ model: String, _ filter: DocumentFilter, maxDrift: Db3MaxDrift? = nil, options: QueryOptions? = nil) throws -> Int {
        // A `$near` keeps its rows (#5230), judged first.
        let near = try nearIndex(model, filter)
        if near != nil { try store.vectorEntryReadForTest?() }
        try QueryTranslator.requireViewIdentifier(model, context: "query model")
        // A text search keeps the rows its index matches (#5223).
        let search = try searchIndex(model, filter)
        var (clause, params) = try QueryTranslator.translateView(filter, textIndex: search, vectorIndex: near, model: model)
        let maxDrift = try Db3DriftJudge.checked(maxDrift)
        guard !documents.isEmpty else { return 0 }
        return try store.readView { sql in
            let local = try deviceIndexRead(model)
            // The vector index read again in the count's transaction, as a page reads it.
            let near = near == nil ? nil : try nearIndex(model, filter)
            if !local.tables.isEmpty || near != nil {
                let members: ((String) -> String?)? = local.tables.isEmpty ? nil : { local.table($0) }
                (clause, params) = try QueryTranslator.translateView(
                    filter, memberIndexTable: members, textIndex: search, vectorIndex: near, model: model
                )
            }
            let type = typeCondition(model)
            let statement = "SELECT COUNT(*) AS n FROM \(viewFrom(model)) WHERE \(type.sql) AND (\(clause)) AND \(Self.scopeClause(documents.count))"
            let bindings = type.bindings + params.map(Format2SqlValue.init(bindable:)) + documents.map { .text($0) }
            noteRun(model, statement, bindings)
            let count = try sql.first(statement, bindings)?["n"].intValue ?? 0
            if maxDrift != nil { _ = try judgedDrift(maxDrift, options) }
            return count
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
        // A `$near` in the filter keeps its rows (#5230), judged first.
        let near = try nearIndex(model, options.filter)
        if near != nil { try store.vectorEntryReadForTest?() }
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
        // A text search in the filter keeps the rows its index matches (#5223).
        let search = try searchIndex(model, options.filter)
        // Judged with today's statement first, so a refused name runs no statement (#5156).
        _ = try aggregateStatement(model, options, setFields: setFields, local: DeviceIndexRead(), textIndex: search, vectorIndex: near)
        let rows = try store.readView { sql in
            // The vector index read again in the statement's transaction, as a page reads it.
            let near = near == nil ? nil : try nearIndex(model, options.filter)
            let statement = try aggregateStatement(
                model, options, setFields: setFields, local: try deviceIndexRead(model), textIndex: search, vectorIndex: near
            )
            noteRun(model, statement.sql, statement.bindings)
            return try sql.rows(statement.sql, statement.bindings).map(Self.aggregateRow)
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
        _ model: String, _ options: AggregateOptions, setFields: Set<String>, local: DeviceIndexRead,
        textIndex: QueryTranslator.ViewTextIndex?, vectorIndex: RecordLogNearSearch.Read? = nil
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
        let (clause, filterParams) = try QueryTranslator.translateView(
            options.filter ?? [:], memberIndexTable: local.table, textIndex: textIndex, vectorIndex: vectorIndex, model: model
        )
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
        func orderAndLimit(tieBreak: String? = nil, _ sortExpression: (String) throws -> String) throws -> String {
            var sql = ""
            if let sort = options.sort {
                sql += " ORDER BY \(try sortExpression(sort.field)) \(sort.direction == -1 ? "DESC" : "ASC")"
                if let tieBreak { sql += ", \(tieBreak) ASC" }
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
            // A db3 holding a member table orders the members a sort leaves tied by the member, as its room does.
            let tieBreak = local.tiesByMember && options.sort?.field != facet.field ? member : nil
            let order = { (field: String) -> String in
                if field == "count" { return "COUNT(*)" }
                if let alias = operationAlias(field) { return alias }
                // The facet's own field sorts by the member: the record has no column of that name.
                if field == facet.field { return member }
                return Self.quoted(field)
            }
            if let index = local.table(facet.field), (options.filter ?? [:]).isEmpty {
                // An unfiltered facet reads the member table (#5156): it holds exactly this
                // db3's live rows of the model, so it takes no condition, and a facet that
                // counts reads no record at all.
                let readsRecords = options.operations.contains { $0.type != .count }
                var sql = "SELECT \(select.joined(separator: ", ")) FROM \(Self.quoted(index)) AS _facet"
                    + (readsRecords ? " JOIN \(table) ON \(table).rowid = _facet.rid" : "")
                    + " GROUP BY \(member)"
                sql += try orderAndLimit(tieBreak: tieBreak, order)
                return (sql, [])
            }
            let type = typeCondition(model, table: table)
            var sql = "SELECT \(select.joined(separator: ", ")) FROM \(viewFrom(model)), json_each(\(path)) AS _facet"
                + " WHERE \(type.sql) AND json_type(\(path)) = 'array' AND (\(clause)) AND \(scope)"
                + " GROUP BY \(member)"
            sql += try orderAndLimit(tieBreak: tieBreak, order)
            return (sql, type.bindings + filterBindings + scopeParams)
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
            if let member = local.table(field) {
                // An opted-in field's level is a probe of its member table (#5156).
                select.append("CASE WHEN \(QueryTranslator.viewMemberProbe(member, table: table)) THEN 'true' ELSE 'false' END AS \(alias)")
            } else {
                select.append(
                    "CASE WHEN (json_type(\(path)) = 'array' AND EXISTS (SELECT 1 FROM json_each(\(path)) AS _set "
                        + "WHERE _set.value = ?)) THEN 'true' ELSE 'false' END AS \(alias)"
                )
            }
            selectBindings.append(.text(contains))
            // The presence binds its member, so the level groups by its alias.
            group.append(alias)
            membershipSort[QueryTranslator.aggregationGroupKey(.stringSetMembership(field: field, contains: contains))] = alias
            membershipSort["\(field)::\(contains)"] = alias
        }
        select += try operations(false)
        if select.isEmpty { select.append("COUNT(*) AS \"count\"") }
        let type = typeCondition(model, table: table)
        var sql = "SELECT \(select.joined(separator: ", ")) FROM \(viewFrom(model)) WHERE \(type.sql) AND (\(clause)) AND \(scope)"
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
        return (sql, selectBindings + type.bindings + filterBindings + scopeParams)
    }

    // MARK: - Helpers

    /// A page as the model API's paged reads answer it.
    static func paged(_ page: Page) -> PagedQueryResult<PrimitiveRow> {
        PagedQueryResult(
            data: page.rows.map(PrimitiveRow.init(raw:)), nextCursor: page.nextCursor, prevCursor: page.prevCursor,
            hasMore: page.hasMore, drift: page.drift
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

    /// `record` as `shape` answers it, and whether that changed it. A set
    /// field the record does not hold reads `[]`, as one held as `null` does,
    /// and is listed as unheld (`PrimitiveRecord.holds(_:in:)`), so a model
    /// fills its default as js-bao's getter does.
    static func shaped(_ record: RecordLogRow, _ shape: RowShape) -> (RecordLogRow, Bool) {
        guard case .model(let setFields, _) = shape, !setFields.isEmpty else { return (record, false) }
        var row = record
        var changed = false
        PrimitiveRecord.markUnheld(setFields.filter { record[$0] == nil }, in: &row)
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

    /// A search's `_score` column as a row carries it: a number.
    private static func scoreValue(_ value: Format2SqlValue) -> JSONValue? {
        switch value {
        case .real(let number): return .number(number)
        case .integer(let number): return .number(Double(number))
        default: return nil
        }
    }

    /// A projection over an answered record: inclusion keeps `id`, `_related`,
    /// a search's `_score` (#5223), a `$near`'s `_distance` (#5230) and the listed fields; exclusion drops the
    /// listed fields but never those. Mixed modes are refused before any
    /// statement.
    static func projection(_ projection: [String: Int]?) throws -> (RecordLogRow) -> RecordLogRow {
        guard let projection, !projection.isEmpty else { return { $0 } }
        let included = Set(projection.filter { $0.value != 0 }.keys)
        let excluded = Set(projection.filter { $0.value == 0 }.keys)
        if !included.isEmpty && !excluded.isEmpty {
            throw JsBaoError(code: .invalidArgument, message: "Cannot mix inclusion and exclusion in projection")
        }
        let kept: Set<String> = ["id", "_related", scoreKey, distanceKey]
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
            // No aggregate selects bytes: a record's fields are JSON.
            case .blob: out[name] = .null
            }
        }
        return out
    }

    /// ``viewFrom(_:)`` for an include leg's statement (#5241).
    fileprivate func legFrom(_ model: String) -> String { viewFrom(model) }

    /// ``typeCondition(_:table:)`` for an include leg's statement (#5241).
    fileprivate func legType(_ model: String) -> (sql: String, bindings: [Format2SqlValue]) { typeCondition(model) }

    /// Run `statement` within `document`, a row at a time, each as a record
    /// (its `_data` read as `json(_data)`, its `id` restored from `_id`).
    fileprivate func readLeg(
        _ model: String, _ statement: String, _ bindings: [Format2SqlValue], _ row: (RecordLogRow) throws -> Void
    ) throws {
        noteRun(model, statement, bindings)
        try store.readView { sql in
            try sql.connection.eachRow(statement, bindings) { raw in
                try row(RecordLogJSON.row(raw["_data"].stringValue, id: raw["_id"].stringValue))
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
        let extraParams = try extra.map { try QueryTranslator.translateView($0, model: model).1.count } ?? 0
        let chunkSize = max(1, Self.boundParams - 2 - extraParams)
        let order = try Self.order(sort)
        var start = 0
        while start < values.count {
            let chunk = Array(values[start..<min(start + chunkSize, values.count)])
            start += chunkSize
            var filter: DocumentFilter = [field: ["$in": .array(chunk)]]
            for (name, value) in extra ?? [:] { filter[name] = value }
            let (clause, params) = try QueryTranslator.translateView(filter, model: model)
            let type = reader.legType(model)
            var statement = "SELECT json(_data) AS _data, _id FROM \(reader.legFrom(model)) WHERE \(type.sql) AND doc_id = ? AND (\(clause)) ORDER BY \(order)"
            if let rowLimit { statement += " LIMIT \(rowLimit())" }
            try reader.readLeg(model, statement, type.bindings + [.text(document)] + params.map(Format2SqlValue.init(bindable:)), onRow)
        }
    }

    /// A `hasMany` leg with a per-parent `limit`: each parent's first rows in
    /// the leg's sort, read by one window statement per chunk.
    private func readPartitioned(
        _ spec: Include, _ values: [JSONValue], perParent: Int, rowLimit: @escaping () -> Int, document: String,
        _ onRow: (RecordLogRow) throws -> Void
    ) throws {
        let foreignKey = try QueryTranslator.viewField(spec.foreignKey ?? "")
        let (filterClause, filterParams) = try QueryTranslator.translateView(spec.filter ?? [:], model: spec.target.modelName)
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
            let statement = "SELECT json(_data) AS _data, _id FROM (SELECT _data, _id, ROW_NUMBER() OVER (PARTITION BY \(foreignKey) ORDER BY \(order)) AS _rn"
                + " FROM \(reader.legFrom(spec.target.modelName)) WHERE \(reader.legType(spec.target.modelName).sql) AND doc_id = ? AND \(foreignKey) IN (\(placeholders))"
                + " AND (\(filterClause))) WHERE _rn <= ? LIMIT ?"
            let bindings: [Format2SqlValue] = reader.legType(spec.target.modelName).bindings + [.text(document)]
                + chunk.map { Format2SqlValue(json: $0) } + filterParams.map(Format2SqlValue.init(bindable:))
                + [.integer(Int64(perParent)), .integer(Int64(rowLimit()))]
            try reader.readLeg(spec.target.modelName, statement, bindings, onRow)
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
