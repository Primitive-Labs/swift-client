import Foundation

/// A db3's device vector indexes (#5230): what every part of them agrees on,
/// with no store state. The Swift port of js-bao's
/// `record-log-client/vectorIndex.ts`, names, text and defaults and all, so a
/// store file reads the same on either client.
///
/// - The SQL function `record_log_vec_f32` (``RecordLogVectorFunction``),
///   which every connection the provider opens has: a field's stored base64
///   as vec1's binary32 bytes, or NULL for anything else.
/// - The tables: a vec1 `flat` table per `(db3, model, field)`
///   (``tableName(documentId:model:field:)``), kept by three triggers on the
///   view (``triggersDDL(_:_:)``); in `ann` mode a second table beside it
///   (``annTable(_:)``) that the same triggers write too.
/// - The defaults a `$near` and a training run use.
enum RecordLogVectorIndex {

    /// The most rows a `$near` answers from, and its default.
    static let nearDefaultK = 10
    static let nearMaxK = 10_000

    /// The share of an `ann` index's buckets a `$near` probes, as the statement writes it: a tenth.
    static let nearDefaultNprobe = "0.1"

    /// How many candidates an `ann` answer reranks on the full vectors for `k` rows: `max(20·k, 200)`.
    static func nearCandidates(_ k: Int) -> Int { max(20 * k, 200) }

    /// The sample a training run reads, per bucket of its model.
    static let samplePerBucket = 100

    /// The bucket count a training run takes when the registration gives none: `clamp(round(√rows), 16, 4096)`.
    static func defaultNbucket(rows: Int) -> Int {
        min(4096, max(16, Int((Double(max(0, rows))).squareRoot().rounded(.toNearestOrAwayFromZero))))
    }

    /// The fewest live rows an `ann` index is trained over: `max(4·nbucket, 1000)`.
    static func minRows(nbucket: Int) -> Int { max(4 * nbucket, 1000) }

    /// The codebook count a training run takes when the registration gives none: 32, or the field's dims when fewer.
    static let defaultCodesize = 32

    /// The quantizer a training run takes when the registration gives none.
    static let defaultQuantizer = "opq"

    /// The most rows one slice of an ANN table's fill copies.
    static let fillSliceRows = 256

    /// The most bytes a model may be: 64 MiB, the upload route's cap.
    static let modelMaxBytes = 64 * 1024 * 1024

    /// How long a model's upload claim holds unless renewed (the room's 15 minutes), and how often a trainer renews it.
    static let claimSeconds: TimeInterval = 900
    static let renewSeconds: TimeInterval = 300

    /// Why a vector entry is not built while its room's list does not say how
    /// (#5230, js-bao's `RECORD_LOG_VECTOR_UNBUILT`): a room from before device
    /// vector indexes, or a field whose encoding the room does not know, lists
    /// no `vector` options; and a store converted from version 8 caches its
    /// entries so until the next list.
    static let unbuilt = "the room's index list does not give this vector index's options and field encoding yet"

    /// The canonical name of the vec1 table a db3's vector index on
    /// `model.field` is kept in:
    /// `idx_record_log_vec_<len>_<doc id>_<len>_<model>_<len>_<field>`,
    /// lowercased. js-bao's `recordLogVectorTableName`.
    static func tableName(documentId: String, model: String, field: String) -> String {
        let part = { (name: String) in "\(name.utf16.count)_\(name.lowercased())" }
        return ["idx_record_log_vec", part(documentId), part(model), part(field)].joined(separator: "_")
    }

    /// The ANN table an `ann` index keeps beside its flat table.
    static func annTable(_ flat: String) -> String { "\(flat)_ann" }

    /// The suffixes of a vector index's three triggers on the view: insert, update of `_data`, delete.
    static let triggerSuffixes = ["__i", "__u", "__d"]

    static func quoted(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// `CREATE VIRTUAL TABLE` for a vec1 table named `table`.
    static func tableDDL(_ table: String) -> String { "CREATE VIRTUAL TABLE \(quoted(table)) USING vec1" }

    /// The `rebuild` argument that makes a vec1 table a flat index measuring `distance`.
    static func flatRebuildArg(_ distance: String) -> String { #"{index:"flat",distance:"\#(distance)"}"# }

    /// What a vector index's triggers keep: its db3, model, field and the field's encoding.
    struct Target: Equatable, Sendable {
        var documentId: String
        var model: String
        var field: String
        var element: String
        var dims: Int
    }

    /// The statements that create a vector index's triggers on the view, each
    /// scoped to its db3 and model: an insertion adds the row's vector (when
    /// it holds one) to `tables`, an update that changes the field's value
    /// removes the old row's and adds the new, a deletion removes it. `tables`
    /// is the flat table, and in `ann` mode its ANN table too. The conversion
    /// runs once per statement (`LIMIT -1` keeps SQLite from flattening it
    /// into the filter), and a value the conversion refuses holds no row.
    /// js-bao's `vectorTriggersDDL`, text for text.
    static func triggersDDL(_ tables: [String], _ target: Target) -> [String] {
        let flat = tables[0]
        let scope = { (row: String) in
            "\(row).doc_id = \(RecordLogSchema.quoteLiteral(target.documentId)) AND \(row)._type = \(RecordLogSchema.quoteLiteral(target.model))"
        }
        let path = RecordLogSchema.quoteLiteral("$.\(target.field)")
        let value = "\(RecordLogVectorFunction.name)(json_extract(NEW._data, \(path)), \(RecordLogSchema.quoteLiteral(target.element)), \(target.dims))"
        let insertNew = { (table: String) in
            "INSERT INTO \(quoted(table)) (rowid, vector) SELECT NEW.rowid, v FROM (SELECT \(value) AS v LIMIT -1) WHERE v IS NOT NULL"
        }
        let deleteOld = { (table: String) in "DELETE FROM \(quoted(table)) WHERE rowid = OLD.rowid" }
        let each = { (statement: (String) -> String) in tables.map { "  \(statement($0));" }.joined(separator: "\n") }
        let changed = "json_extract(OLD._data, \(path)) IS NOT json_extract(NEW._data, \(path))"
        return [
            "CREATE TRIGGER \(quoted("\(flat)__i")) AFTER INSERT ON record_log_view WHEN \(scope("NEW"))\nBEGIN\n\(each(insertNew))\nEND",
            "CREATE TRIGGER \(quoted("\(flat)__u")) AFTER UPDATE OF _data ON record_log_view WHEN \(scope("OLD")) AND \(changed)\nBEGIN\n"
                + tables.map { "  \(deleteOld($0));\n  \(insertNew($0));" }.joined(separator: "\n") + "\nEND",
            "CREATE TRIGGER \(quoted("\(flat)__d")) AFTER DELETE ON record_log_view WHEN \(scope("OLD"))\nBEGIN\n\(each(deleteOld))\nEND",
        ]
    }

    /// The SELECT that fills a vector index's table from the view: each row of
    /// the db3's model holding a vector, by rowid; binds the db3 and the model.
    /// js-bao's `vectorFillSql`.
    static func fillSQL(_ target: Target) -> String {
        "SELECT rowid, v FROM (SELECT rowid, \(RecordLogVectorFunction.name)(json_extract(_data, \(RecordLogSchema.quoteLiteral("$.\(target.field)"))), "
            + "\(RecordLogSchema.quoteLiteral(target.element)), \(target.dims)) AS v FROM record_log_view WHERE doc_id = ? AND _type = ? LIMIT -1) WHERE v IS NOT NULL"
    }

    /// vec1's version as `vec1_info()` names it (`version 0.8 (NEON, multi-threaded)` is `0.8`).
    static func vec1Version(of info: String) -> String {
        guard let match = info.range(of: #"version\s+[0-9][0-9.]*"#, options: .regularExpression) else { return info }
        return String(info[match]).replacingOccurrences(of: #"version\s+"#, with: "", options: .regularExpression)
    }

    private static let versionLock = NSLock()
    nonisolated(unsafe) private static var heldVersion: String?

    /// vec1's version on the bundled build (`0.8`), read once: every
    /// connection of the build runs the same vec1.
    static func engineVec1Version(_ sql: RecordLogSql) throws -> String {
        if let version = versionLock.withLock({ heldVersion }) { return version }
        let info = try sql.first("SELECT vec1_info() AS info")?["info"].stringValue ?? ""
        let version = vec1Version(of: info)
        versionLock.withLock { heldVersion = version }
        return version
    }

    /// A JSON number as an integer, when it is one.
    static func integer(_ value: JSONValue?) -> Int? {
        guard let number = value?.numberValue, number.rounded() == number, abs(number) < 9_007_199_254_740_992 else { return nil }
        return Int(number)
    }
}

/// A vector index's options as a device builds it (#5230): the
/// registration's `distance` and `index`, and the field's encoding. js-bao's
/// `RecordLogVectorOptions`.
struct RecordLogVectorOptions: Equatable, Sendable {
    /// How the index searches: every vector, or an approximate index over a shared model.
    enum Index: Equatable, Sendable {
        case exact
        case ann(nbucket: Int?, codesize: Int?, quantizer: String?)
    }

    /// `cos` or `l2`.
    var distance: String
    var index: Index
    var dims: Int
    var element: VectorElement

    var isAnn: Bool { if case .ann = index { return true }; return false }

    /// The registration's ann options, or none for an exact index.
    var ann: (nbucket: Int?, codesize: Int?, quantizer: String?)? {
        if case .ann(let nbucket, let codesize, let quantizer) = index { return (nbucket, codesize, quantizer) }
        return nil
    }

    /// An entry's options as the room lists them (or a local-only
    /// registration gives them), checked: `nil` when the list does not say
    /// how to build it (a room or a cache from before device vector indexes,
    /// or a field whose encoding is unknown). js-bao's `vectorOptionsOf`.
    init?(cached raw: JSONValue?) {
        guard let raw = raw?.objectValue, let dims = RecordLogVectorIndex.integer(raw["dims"]), (1...4096).contains(dims),
              let element = raw["element"]?.stringValue.flatMap(VectorElement.init(rawValue:))
        else { return nil }
        self.dims = dims
        self.element = element
        distance = raw["distance"]?.stringValue == "l2" ? "l2" : "cos"
        if let index = raw["index"]?.objectValue, index["mode"]?.stringValue == "ann" {
            // A count this device cannot hold or multiply (the room admits any positive integer, 1e20 too) builds nothing.
            guard Self.annProblem(index) == nil else { return nil }
            let count = { (key: String) in index[key]?.numberValue.flatMap { RecordLogVectorIndex.integer(.number($0)) } }
            self.index = .ann(nbucket: count("nbucket"), codesize: count("codesize"), quantizer: index["quantizer"]?.stringValue)
        } else {
            index = .exact
        }
    }

    /// The largest `nbucket` or `codesize` a device holds: JavaScript's
    /// largest safe integer, so a want's `4·nbucket` and a sample's
    /// `100·nbucket` never overflow.
    static let maxCount = 9_007_199_254_740_991

    /// Why an entry's `ann` options are not ones this device can train with
    /// (an `nbucket` or `codesize` that is not an integer from 1 to
    /// ``maxCount``), or `nil` when they are; an entry so listed is not built.
    static func annProblem(_ index: [String: JSONValue]) -> String? {
        for key in ["nbucket", "codesize"] {
            guard let number = index[key]?.numberValue else { continue }
            if let count = RecordLogVectorIndex.integer(.number(number)), (1...maxCount).contains(count) { continue }
            return "\(annProblemPrefix)\(key) \(RecordLogVectorModelCheck.jsString(.number(number))) is not an integer from 1 to \(maxCount); "
                + "this device builds no vector index with it"
        }
        return nil
    }

    /// How an ``annProblem(_:)`` reason begins, so a build reports the
    /// reconcile's reason for it and js-bao's for any other entry with no options.
    static let annProblemPrefix = "vector.index."

    /// Why a cached entry with no options it can build is not built: the
    /// reason the reconcile cached when that is an ``annProblem(_:)``, else
    /// js-bao's `RECORD_LOG_VECTOR_UNBUILT`.
    static func unbuiltReason(cached reason: String?) -> String {
        reason.flatMap { $0.hasPrefix(annProblemPrefix) ? $0 : nil } ?? RecordLogVectorIndex.unbuilt
    }

    /// Why a listed vector entry's options build nothing here: its `ann`
    /// options' problem (``annProblem(_:)``), else js-bao's
    /// `RECORD_LOG_VECTOR_UNBUILT`. Asked only of options that do not parse.
    static func unbuiltReason(_ raw: JSONValue?) -> String {
        if let index = raw?.objectValue?["index"]?.objectValue, index["mode"]?.stringValue == "ann", let problem = annProblem(index) { return problem }
        return RecordLogVectorIndex.unbuilt
    }

    init(distance: String, index: Index, dims: Int, element: VectorElement) {
        self.distance = distance
        self.index = index
        self.dims = dims
        self.element = element
    }

    /// The options as a cache row and a listing hold them.
    var json: JSONValue {
        let index: JSONValue
        switch self.index {
        case .exact: index = "exact"
        case .ann(let nbucket, let codesize, let quantizer):
            var object: [String: JSONValue] = ["mode": "ann"]
            if let nbucket { object["nbucket"] = .number(Double(nbucket)) }
            if let codesize { object["codesize"] = .number(Double(codesize)) }
            if let quantizer { object["quantizer"] = .string(quantizer) }
            index = .object(object)
        }
        return ["distance": .string(distance), "index": index, "dims": .number(Double(dims)), "element": .string(element.rawValue)]
    }
}

// MARK: - Training

/// What a training run uses: its buckets, codebooks and quantizer (#5230).
struct RecordLogVectorTrainingParams: Equatable, Sendable {
    var nbucket: Int
    var codesize: Int
    /// `none`, `pq`, `opq` or `bq`.
    var quantizer: String
}

extension RecordLogVectorIndex {

    /// What a device trains an `ann` index with: the registration's options
    /// where it gives them, else ``defaultNbucket(rows:)`` of the rows it
    /// holds, ``defaultCodesize`` (the dims when fewer, 0 with no quantizer,
    /// the registration's as vec1 resolves it for `bq`) and
    /// ``defaultQuantizer``. js-bao's `vectorTrainingParams`.
    static func trainingParams(_ index: RecordLogVectorOptions.Index, dims: Int, rows: Int) -> RecordLogVectorTrainingParams {
        let registered: (nbucket: Int?, codesize: Int?, quantizer: String?)
        if case .ann(let nbucket, let codesize, let quantizer) = index { registered = (nbucket, codesize, quantizer) } else { registered = (nil, nil, nil) }
        let quantizer = registered.quantizer ?? defaultQuantizer
        let codesize: Int
        switch quantizer {
        case "none": codesize = 0
        case "bq": codesize = RecordLogVectorModelCheck.bqCodesize(dims: dims, codesize: registered.codesize)
        default: codesize = registered.codesize ?? min(defaultCodesize, dims)
        }
        return RecordLogVectorTrainingParams(nbucket: registered.nbucket ?? defaultNbucket(rows: rows), codesize: codesize, quantizer: quantizer)
    }

    /// The bucket count a device's want is judged by: the registration's, or the default for the rows it holds.
    static func wantedNbucket(_ index: RecordLogVectorOptions.Index, rows: Int) -> Int {
        if case .ann(let nbucket?, _, _) = index { return nbucket }
        return defaultNbucket(rows: rows)
    }

    /// vec1_train's configuration for `params` measuring `distance`.
    static func trainConfig(distance: String, _ params: RecordLogVectorTrainingParams) -> String {
        params.quantizer == "none"
            ? #"{distance:"\#(distance)", nbucket:\#(params.nbucket), quantizer:"none"}"#
            : #"{distance:"\#(distance)", nbucket:\#(params.nbucket), codesize:\#(params.codesize), quantizer:"\#(params.quantizer)"}"#
    }
}
