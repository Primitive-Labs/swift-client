import Foundation

/// A read for ``DocumentRecords/explain(_:_:)`` to explain: the body the
/// server's `db3 records explain` takes, plus the root model's set fields.
///
/// ```swift
/// let request = Db3ExplainRequest(op: .query, filter: ["year": 2024], index: "none")
/// ```
public struct Db3ExplainRequest {
    /// The read an explain runs.
    public enum Operation: String, Sendable, Equatable {
        case query
        case count
        case aggregate
    }

    /// The read: a page of records, a count, or an aggregate.
    public var op: Operation
    /// A query's or a count's filter.
    public var filter: DocumentFilter?
    /// A query's sort and paging (`sort` or `sortOrder`, `limit`, `cursor`, `direction`).
    public var options: QueryOptions?
    /// A query's includes.
    public var include: [Include]?
    /// An aggregate's grouping, operations, filter, sort and limit.
    public var aggregate: AggregateOptions?
    /// Read through this index (its name, as `client.db3.indexes.list(_:)`
    /// names it), or `"none"` for no index; `nil`, as an ordinary read.
    public var index: String?
    /// The model's string-set fields, in place of the ones its db3's type
    /// declares: a `groupBy` level on one is a facet.
    public var setFields: [String]?

    public init(
        op: Operation, filter: DocumentFilter? = nil, options: QueryOptions? = nil, include: [Include]? = nil,
        aggregate: AggregateOptions? = nil, index: String? = nil, setFields: [String]? = nil
    ) {
        self.op = op
        self.filter = filter
        self.options = options
        self.include = include
        self.aggregate = aggregate
        self.index = index
        self.setFields = setFields
    }
}

/// One statement an explained read ran, with every run of the same text and plan merged.
public struct Db3ExplainedStatement: Sendable, Equatable {
    /// The model the statement reads: the read's, or an include's related model.
    public let model: String
    public let sql: String
    /// How many times the read ran it.
    public let runs: Int
    /// SQLite's `EXPLAIN QUERY PLAN` lines, taken with the run's values; `nil` when SQLite would not plan it.
    public let plan: [String]?
    /// Why the plan could not be taken, when it could not.
    public let planError: String?
    /// The indexes the plan used, by their names in the db3's index list, sorted.
    public let indexes: [String]
    /// Whether the plan reads the model's records by scanning them rather than through an index or the key.
    public let scan: Bool
}

/// The rows an explained read read and wrote: `nil` on every device, whose SQLite keeps no count of them.
public struct Db3ExplainCost: Sendable, Equatable {
    public let rowsRead: Int?
    public let rowsWritten: Int?
}

/// How a read was answered on this device, in the shape the server's
/// `db3 records explain` answers.
public struct Db3Explain: Sendable, Equatable {
    public let op: Db3ExplainRequest.Operation
    public let model: String
    /// The index the read was forced through, `"none"`, or `nil`.
    public let index: String?
    /// The indexes any statement used, by their names in the db3's index list, sorted.
    public let indexes: [String]
    /// The models a statement scanned, sorted.
    public let scanned: [String]
    public let statements: [Db3ExplainedStatement]
    /// The records the page answered, the count, or the groups.
    public let answered: Int
    public let cost: Db3ExplainCost
    /// Whether SQLite holds statistics for the copy's records table.
    public let stats: Bool
    /// SQLite's version, or `""`.
    public let sqlite: String
}

/// One explained read's force and recorder (#5241, js-bao's `ViewReadForce`):
/// what each model's statements read in place of what the store would pick,
/// and who hears each statement before it runs. A reader is given one only by
/// an explain, so an ordinary read never sees it; the read it serves runs on
/// the explain's own call, so it never crosses a task.
final class RecordLogReadForce {
    /// The device index `model`'s statements read through (`INDEXED BY`), or `nil`.
    let indexedBy: (String) -> String?
    /// The member tables `model`'s statements read in place of the store's (by field), or `nil` for the store's.
    let memberTables: (String) -> [String: String]?
    /// Hears each statement over the view or a device table, with the model whose statement it is and its bindings.
    let record: (String, String, [Format2SqlValue]) -> Void

    init(
        indexedBy: @escaping (String) -> String? = { _ in nil },
        memberTables: @escaping (String) -> [String: String]? = { _ in nil },
        record: @escaping (String, String, [Format2SqlValue]) -> Void
    ) {
        self.indexedBy = indexedBy
        self.memberTables = memberTables
        self.record = record
    }
}

/// A db3 read explained on the device (#5241), the port of js-bao's
/// `record-log-client/explain.ts`: the store's own query, count or aggregate
/// over one db3's copy, run for real through a reader carrying a
/// ``RecordLogReadForce``, then each statement it ran planned with its run's
/// bindings, the registry indexes named by the explained db3's own names.
///
/// - A scalar force puts `INDEXED BY "<device index>"` at the reader's FROM
///   for the read's model, whose `_type` is then written as a literal so the
///   partial index proves at prepare time; include legs plan freely.
/// - A member force reads that member table for its field and no other.
/// - `none` reads through the view's primary-key autoindex with no member or
///   text table; a `$search` is refused, and a `$near` under any force.
///
/// Nothing is written.
enum RecordLogExplain {

    /// The index SQLite keeps for the view's primary key `(doc_id, _type, _id)`.
    static let primaryKeyIndex = "sqlite_autoindex_record_log_view_1"

    private struct Run {
        var model: String
        var sql: String
        var bindings: [Format2SqlValue]
    }

    private struct Planned {
        var indexedBy: (String) -> String? = { _ in nil }
        var memberTables: (String) -> [String: String]? = { _ in nil }
        var memberTable: String?
        var scalarIndex: String?
    }

    private static func cannotServe(_ index: String, _ model: String, _ reason: String, _ message: String, _ extra: [String: JSONValue] = [:]) -> JsBaoError {
        var details: [String: JSONValue] = ["index": .string(index), "model": .string(model), "reason": .string(reason)]
        for (key, value) in extra { details[key] = value }
        return JsBaoError(code: .db3IndexCannotServe, message: message, details: details)
    }

    /// The fields a filter names, at any depth of `$and`, `$or`, `$nor` and `$not`.
    private static func filterFields(_ value: JSONValue?, _ into: inout Set<String>) {
        switch value {
        case .array(let members)?:
            for member in members { filterFields(member, &into) }
        case .object(let object)?:
            for (key, member) in object where key != "$search" {
                if key.hasPrefix("$") { filterFields(member, &into) } else { into.insert(key) }
            }
        default:
            break
        }
    }

    /// The fields a read filters, sorts or groups on: what a scalar index could serve.
    private static func fieldsOfRead(_ request: Db3ExplainRequest) -> Set<String> {
        var fields = Set<String>()
        if request.op == .aggregate, let aggregate = request.aggregate {
            filterFields(aggregate.filter.map(JSONValue.object), &fields)
            var outputs: Set<String> = ["count"]
            for operation in aggregate.operations { outputs.insert(operation.resultKey) }
            for level in aggregate.groupBy {
                switch level {
                case .field(let name): fields.insert(name)
                case .stringSetMembership(let field, let contains):
                    fields.insert(field)
                    outputs.insert(QueryTranslator.aggregationGroupKey(level))
                    outputs.insert("\(field)::\(contains)")
                case .datePeriod(let field, _):
                    fields.insert(field)
                    outputs.insert(QueryTranslator.aggregationGroupKey(level))
                }
            }
            if let sort = aggregate.sort?.field, !outputs.contains(sort) { fields.insert(sort) }
            return fields
        }
        filterFields(request.filter.map(JSONValue.object), &fields)
        if request.op == .query {
            for field in (request.options?.sort ?? [:]).keys { fields.insert(field) }
            for (field, _) in request.options?.sortOrder ?? [] { fields.insert(field) }
        }
        return fields
    }

    /// The force `request.index` asks for, or its refusal, judged before any statement of the read runs.
    private static func planForce(_ store: RecordLogStore, _ model: String, _ request: Db3ExplainRequest) throws -> Planned? {
        guard let index = request.index else { return nil }
        let filter = request.op == .aggregate ? request.aggregate?.filter : request.filter
        if filter?["$near"] != nil {
            throw cannotServe(index, model, "near", "A $near reads its vector index, so it cannot be forced onto another index or none")
        }
        if index == "none" {
            if RecordLogTextSearch.has(filter) {
                throw cannotServe(index, model, "search", "A $search reads its text index, so it cannot be read with no index")
            }
            return Planned(indexedBy: { _ in primaryKeyIndex }, memberTables: { _ in [:] })
        }
        let documentId = store.documentId
        let (named, skipped, elsewhere) = try store.readView { sql in
            (
                try RecordLogIndexes.namedIndex(sql, documentId: documentId, name: index, deviceIndexes: store.deviceIndexes),
                try RecordLogIndexes.skips(sql, documentId: documentId).first { $0.name == index },
                try RecordLogIndexes.registryModel(sql, documentId: documentId, name: index)
            )
        }
        let entryModel = named?.status.model ?? skipped?.model
        guard entryModel == model else {
            let message = (entryModel ?? elsewhere).map { "The index \(index) is an index of \($0), not of \(model)" }
                ?? "No index of \(model) is named \(index) in \(documentId)"
            throw JsBaoError(code: .db3IndexNotFound, message: message, details: ["index": .string(index), "model": .string(model)])
        }
        let kind = named?.status.kind ?? skipped?.kind ?? .scalar
        guard kind == .scalar || kind == .members else {
            throw cannotServe(index, model, "kind", "A \(kind.rawValue) index cannot be forced: only a field or member index can")
        }
        if let skipped {
            if skipped.reason == RecordLogIndexes.skipServerOnly {
                throw cannotServe(index, model, "placement", "The index \(index) is placed on the server only, so this device holds none to read")
            }
            throw cannotServe(
                index, model, "unbuilt", "The index \(index) is not built on this device: \(skipped.reason)",
                ["status": "skipped", "why": .string(skipped.reason)]
            )
        }
        guard let named, named.status.status == .built, let object = named.object else {
            let status = named?.status.status.rawValue ?? Db3LocalIndexStatus.unbuilt.rawValue
            let why = named?.status.reason ?? "it is not built on this device"
            throw cannotServe(
                index, model, "unbuilt", "The index \(index) is \(status) on this device (\(why)), so no statement can read it",
                ["status": .string(status), "why": .string(why)]
            )
        }
        if kind == .members {
            let field = named.status.fields.first ?? ""
            return Planned(memberTables: { name in name == model ? [field: object] : [:] }, memberTable: object)
        }
        let fields = fieldsOfRead(request)
        guard named.status.fields.contains(where: fields.contains) else {
            throw cannotServe(
                index, model, "fields",
                "The index \(index) is on \(named.status.fields.joined(separator: ", ")), which this read neither filters, sorts nor groups on"
            )
        }
        return Planned(indexedBy: { name in name == model ? object : nil }, scalarIndex: object)
    }

    /// Run `request`'s read of `model` over `store`'s copy, forced as it asks,
    /// and explain every statement it ran.
    ///
    /// - Parameter setFields: The root model's string-set fields.
    /// - Throws: `JsBaoError` `.db3IndexNotFound`, `.db3IndexCannotServe` or
    ///   `.invalidArgument` for a force that cannot serve the read; the read's own refusals.
    static func explain(store: RecordLogStore, model: String, request: Db3ExplainRequest, setFields: Set<String>) throws -> Db3Explain {
        if let index = request.index, index.isEmpty {
            throw JsBaoError(code: .invalidArgument, message: "index must be an index name or none", details: ["index": ""])
        }
        let planned = try planForce(store, model, request)
        let runs = RecordedRuns()
        let force = RecordLogReadForce(
            indexedBy: planned?.indexedBy ?? { _ in nil }, memberTables: planned?.memberTables ?? { _ in nil },
            record: { model, sql, bindings in runs.append(Run(model: model, sql: sql, bindings: bindings)) }
        )
        let reader = RecordLogViewReader(store: store, documents: [store.documentId], force: force)
        let answered: Int
        do {
            switch request.op {
            case .count:
                answered = try reader.count(model, request.filter ?? [:])
            case .aggregate:
                answered = try reader.aggregate(model, request.aggregate ?? AggregateOptions(operations: []), setFields: setFields).count
            case .query:
                var options = request.options ?? QueryOptions()
                options.documents = nil
                options.maxDrift = nil
                answered = try reader.page(model, request.filter ?? [:], options: options, shape: .stored, include: request.include).rows.count
            }
        } catch {
            if let index = request.index, planned != nil, RecordLogIndexes.message(error).localizedCaseInsensitiveContains("no query solution") {
                throw cannotServe(index, model, "plan", "SQLite found no plan that reads this query through \(index)")
            }
            throw error
        }
        let ran = runs.all
        let quoted = { (name: String) in "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        if let table = planned?.memberTable, let index = request.index, !ran.contains(where: { $0.sql.contains(quoted(table)) }) {
            throw cannotServe(
                index, model, "shape",
                "The member index \(index) serves $contains, any-of, a membership level or an unfiltered facet on its field; this read has none"
            )
        }
        if let object = planned?.scalarIndex, let index = request.index, !ran.contains(where: { $0.sql.contains("INDEXED BY \(quoted(object))") }) {
            throw cannotServe(index, model, "shape", "The index \(index) is a field index, and no statement of this read reads \(model)'s records to take it")
        }
        return try store.readView { sql in
            let registry = try RecordLogIndexes.registryNames(sql, documentId: store.documentId)
            var statements: [Db3ExplainedStatement] = []
            var keys: [String: Int] = [:]
            for run in ran {
                var plan: [String]?
                var planError: String?
                do {
                    plan = try sql.rows("EXPLAIN QUERY PLAN \(run.sql)", run.bindings).map { $0["detail"].stringValue ?? "" }
                } catch {
                    planError = RecordLogIndexes.message(error)
                }
                let key = "\(run.model)\u{0}\(run.sql)\u{0}\((plan ?? []).joined(separator: "\u{1}"))\u{0}\(plan == nil)"
                if let at = keys[key] {
                    let merged = statements[at]
                    statements[at] = Db3ExplainedStatement(
                        model: merged.model, sql: merged.sql, runs: merged.runs + 1, plan: merged.plan, planError: merged.planError,
                        indexes: merged.indexes, scan: merged.scan
                    )
                    continue
                }
                keys[key] = statements.count
                statements.append(Db3ExplainedStatement(
                    model: run.model, sql: run.sql, runs: 1, plan: plan, planError: planError,
                    indexes: registryIndexes(run.sql, plan, registry), scan: scansView(run.sql, plan)
                ))
            }
            let stats = (try? sql.first("SELECT 1 AS hit FROM sqlite_master WHERE name = 'sqlite_stat1'")) != nil
                && ((try? sql.first("SELECT 1 AS hit FROM sqlite_stat1 WHERE tbl = 'record_log_view' LIMIT 1")) ?? nil) != nil
            let version = ((try? sql.first("SELECT sqlite_version() AS v")) ?? nil)?["v"].stringValue ?? ""
            return Db3Explain(
                op: request.op, model: model, index: request.index,
                indexes: Array(Set(statements.flatMap(\.indexes))).sorted(by: utf8Order),
                scanned: Array(Set(statements.filter(\.scan).map(\.model))).sorted(by: utf8Order),
                statements: statements, answered: answered, cost: Db3ExplainCost(rowsRead: nil, rowsWritten: nil), stats: stats, sqlite: version
            )
        }
    }

    private static func utf8Order(_ a: String, _ b: String) -> Bool { Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8)) }

    /// The runs a recording reader heard, in the order they ran, on the explain's own call.
    private final class RecordedRuns {
        private var runs: [Run] = []
        func append(_ run: Run) { runs.append(run) }
        var all: [Run] { runs }
    }

    /// A plan line's access: the table or alias it scans or searches, an `AS` alias, and the index it names.
    private static let access = try! NSRegularExpression(
        pattern: #"^(?:SCAN|SEARCH)(?: TABLE)? ([^\s]+)(?: AS ([^\s]+))?(?: USING (?:COVERING )?INDEX ([^\s]+))?"#
    )

    /// The aliases a statement declares for a table: `"<table>" AS <alias>`
    /// and `<table> AS <alias>`, a table-valued call's arguments between them.
    private static func aliases(_ text: String) -> [String: String] {
        let pattern = try! NSRegularExpression(pattern: #"(?:"((?:[^"]|"")+)"|\b([A-Za-z_][A-Za-z0-9_]*))(?:\([^()]*\))?\s+AS\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        var out: [String: String] = [:]
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: range) {
            let quoted = Range(match.range(at: 1), in: text).map { String(text[$0]).replacingOccurrences(of: "\"\"", with: "\"") }
            let bare = Range(match.range(at: 2), in: text).map { String(text[$0]) }
            guard let alias = Range(match.range(at: 3), in: text).map({ String(text[$0]) }), let table = quoted ?? bare else { continue }
            out[alias] = table
        }
        return out
    }

    /// One plan line's access, or `nil`.
    private static func lineAccess(_ line: String) -> (table: String, alias: String?, index: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let match = access.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let table = Range(match.range(at: 1), in: trimmed).map({ String(trimmed[$0]) })
        else { return nil }
        return (table, Range(match.range(at: 2), in: trimmed).map { String(trimmed[$0]) }, Range(match.range(at: 3), in: trimmed).map { String(trimmed[$0]) })
    }

    /// The registry indexes `plan` used, by the names `registry` (device object
    /// → registry name) gives them: a view index where a line names it, a
    /// member, text or vector table where a line scans or searches it,
    /// directly or under an alias. An object `registry` does not name
    /// contributes nothing.
    static func registryIndexes(_ text: String, _ plan: [String]?, _ registry: [String: String]) -> [String] {
        guard let plan else { return [] }
        let declared = aliases(text)
        var used = Set<String>()
        for line in plan {
            guard let access = lineAccess(line) else { continue }
            let table = access.alias != nil ? access.table : (declared[access.table] ?? access.table)
            if let name = registry[table] { used.insert(name) }
            if let index = access.index, let name = registry[index] { used.insert(name) }
        }
        return used.sorted(by: utf8Order)
    }

    /// Whether `plan` reaches the view's rows by scanning a model: a `SCAN` of
    /// the view, or a search of its primary key whose terms are `doc_id` and
    /// `_type` alone.
    static func scansView(_ text: String, _ plan: [String]?) -> Bool {
        guard let plan else { return false }
        let declared = aliases(text)
        return plan.contains { line in
            guard let access = lineAccess(line) else { return false }
            let table = access.alias != nil ? access.table : (declared[access.table] ?? access.table)
            guard table == "record_log_view" else { return false }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SCAN") { return true }
            return access.index == primaryKeyIndex && trimmed.hasSuffix("(doc_id=? AND _type=?)")
        }
    }
}
