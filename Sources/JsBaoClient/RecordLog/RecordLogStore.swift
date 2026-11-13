import Foundation

// A format-3 document's local store over the storage provider's SQLite
// connection: confirmed rows, the view reads answer from, the unjudged entries
// per writer, the cursor and the epochs. A db3's rows live in its view only
// (#4700): reads answer from it (`RecordLogViewReader`). A port of js-bao's
// `record-log-client/store.ts`.
//
// Synchronous: every call runs on the provider's serial queue. A save joins
// the connection's group of saves (``RecordLogGroupCommit``); every other
// command is one transaction of its own. A save's pending entry and its view
// row commit together or not at all.

/// Which documents' sessions are open (#5221), per host: a device read's
/// drift is `live` while its document's is. A binding's session marks it.
/// The client also says, per host, whether its room can reach it now: offline
/// mode can leave the socket, and so the session, open, and a read then is
/// not live, as `Db3State` is not.
enum RecordLogLiveness {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var live: Set<String> = []
    nonisolated(unsafe) private static var reachable: [ObjectIdentifier: Reachable] = [:]

    /// A host's predicate, held with the host weakly: a later host at the
    /// same address is not taken for it.
    private struct Reachable {
        weak var host: AnyObject?
        let now: @Sendable () -> Bool
    }

    private static func key(_ host: AnyObject, _ documentId: String) -> String {
        "\(ObjectIdentifier(host).hashValue)\n\(documentId)"
    }

    static func set(_ host: AnyObject, _ documentId: String, _ isLive: Bool) {
        let key = key(host, documentId)
        lock.withLock {
            if isLive { live.insert(key) } else { live.remove(key) }
        }
    }

    /// Whether the room can keep `host`'s documents current now: the socket
    /// is up and networking is allowed. A host no client connected always can.
    static func connect(_ host: AnyObject, reachable isReachable: @escaping @Sendable () -> Bool) {
        lock.withLock { reachable[ObjectIdentifier(host)] = Reachable(host: host, now: isReachable) }
    }

    static func isLive(_ host: AnyObject, _ documentId: String) -> Bool {
        let key = key(host, documentId)
        let (open, entry) = lock.withLock { (live.contains(key), reachable[ObjectIdentifier(host)]) }
        guard open else { return false }
        guard let entry, entry.host === host else { return true }
        return entry.now()
    }
}

/// What a store holds of a document, asked before the document is bound.
struct RecordLogStoredState: Equatable, Sendable {
    /// The cursor: 0 for a document the store never caught up.
    var cursor: Int
    /// How many records the view holds.
    var rows: Int
    /// Every writer with unjudged entries, with its lowest one.
    var writers: [Writer]
    /// A full replacement of the confirmed rows was interrupted.
    var replacing: Bool
    /// When a load or catch-up last completed on this device (ms), or `nil`.
    var lastCatchUpAt: Int64? = nil
    /// The replacement in progress is staged: the view keeps the previous
    /// completed generation until it commits.
    var staged = false
    /// The db3 lives only on this device (#5155): its store judges and
    /// confirms its own writes, and nothing of it is ever sent.
    var localOnly = false
    /// The room's head as this device last heard it (#5221), or `nil` before one is heard.
    var knownHead: Int? = nil
    /// When ``knownHead`` was heard (epoch ms), or `nil`.
    var knownHeadAt: Int64? = nil

    struct Writer: Equatable, Sendable {
        var writer: String
        var clientId: String
        var nextSeq: Int
        var lowestPending: Int
        var pending: Int
    }
}

/// What a binding mirrors, in one read.
struct RecordLogMarks: Equatable, Sendable {
    var cursor: Int
    var open: Int
    var grant: Int
    var entries: Int
    var constraints: [RecordLogConstraint]
    var permission: String?
    var replacing: Bool
    /// The generation of the full replacement in progress, or `nil`.
    var replacement: Int?
    var lastCatchUpAt: Int64?
    /// This client's writer, or `nil` before one is minted.
    var writer: String?
    /// The writer's next sequence number.
    var nextSeq: Int
    /// The `nextSeq` the writer last resumed at after a writer-scoped refusal
    /// (0 when it never did): every number a hand-back removed is below it.
    var resumedAt: Int
    /// The writer's lowest unjudged sequence number.
    var lowestPending: Int?
    /// How many unjudged entries the writer has.
    var pending: Int
    /// The writer's entries the room has not acknowledged, with the records each touches.
    var unacked: [(seq: Int, records: [RecordLogRecordKey])]
    /// The latest receipt of a load's or a segment's chunks begun and not completed, or `nil`.
    var receipt: RecordLogReceipt?
    /// The segment the confirmed rows were last replaced from, or `nil`.
    var segment: RecordLogHeldSegment? = nil
    /// The full replacement in progress is staged (see ``RecordLogStoredState/staged``).
    var staged = false
    /// What the room last said of the db3's type (#5020): `unknown` before any
    /// `record.opened` answered on this device.
    var typed: RecordLogTyped = .unknown
    /// A typed db3's type: its name, and the revision hash whose declarations are held (`nil` when none are).
    var db3Type: RecordLogDb3Type? = nil
    /// A typed db3's declarations as the room sent them, per model each declared field's kind.
    var declarations: [String: [String: String]]? = nil
    /// A typed db3's vector encodings as the room sent them with its
    /// declarations (#5225), per model declaring one; `nil` when none are held.
    var vectors: RecordLogVectorDeclarations? = nil
    /// Whether the held type entry records the vector encodings (#5225): `false`
    /// for one an older client wrote, whose next open asks the room for the
    /// declarations again.
    var vectorsKnown = true
    /// A typed db3's enforced enums as the room sent them with its
    /// declarations (#5897), per model enforcing one; `nil` when none are held.
    var enums: RecordLogEnumDeclarations? = nil
    /// Whether the held type entry records the enforced enums (#5897): `false`
    /// for one an older client wrote, whose next open asks the room for the
    /// declarations again.
    var enumsKnown = true
    /// The db3 lives only on this device (#5155): see ``RecordLogStoredState/localOnly``.
    var localOnly = false
    /// A local-only db3's index registrations made on this device, by name.
    var localIndexes: [RecordLogLocalIndex] = []
    /// The models the copy holds, sorted and distinct: those with a view or a
    /// confirmed row, and those an unjudged entry of any writer touches. An
    /// untyped open declares these (#5160).
    var models: [String] = []
    /// The room's head as this device last heard it (#5221), or `nil` before one is heard.
    var knownHead: Int? = nil
    /// When ``knownHead`` was heard (epoch ms), or `nil`.
    var knownHeadAt: Int64? = nil

    static func == (a: RecordLogMarks, b: RecordLogMarks) -> Bool {
        a.typed == b.typed && a.models == b.models && a.knownHead == b.knownHead && a.knownHeadAt == b.knownHeadAt && a.db3Type == b.db3Type && a.declarations == b.declarations
            && a.vectors == b.vectors && a.vectorsKnown == b.vectorsKnown
            && a.enums == b.enums && a.enumsKnown == b.enumsKnown
            && a.localOnly == b.localOnly && a.localIndexes == b.localIndexes
            && a.cursor == b.cursor && a.open == b.open && a.grant == b.grant && a.entries == b.entries
            && a.constraints == b.constraints && a.permission == b.permission && a.replacing == b.replacing
            && a.replacement == b.replacement && a.receipt == b.receipt && a.segment == b.segment && a.staged == b.staged
            && a.lastCatchUpAt == b.lastCatchUpAt && a.writer == b.writer && a.nextSeq == b.nextSeq
            && a.resumedAt == b.resumedAt
            && a.lowestPending == b.lowestPending && a.pending == b.pending
            && a.unacked.map(\.seq) == b.unacked.map(\.seq) && a.unacked.map(\.records) == b.unacked.map(\.records)
    }
}

/// Whether a db3 is typed, as its store last heard: `unknown` until a room answered (js-bao's `RecordLogTyped`).
enum RecordLogTyped: String, Sendable, Equatable {
    case unknown
    case no
    case yes
}

/// A typed db3's type as its store holds it: the name, and the revision hash
/// whose declarations are held (`nil` when none are).
struct RecordLogDb3Type: Equatable, Sendable {
    var name: String
    var hash: String?
}

/// What a store is told of a db3's type: untyped, or typed with a name, a
/// hash and, when the room sent them, the declarations and, per model
/// declaring one, each vector field's encoding (#5225) and, per model
/// enforcing one, each enforced field's enum values (#5897).
enum RecordLogTypeUpdate: Sendable, Equatable {
    case untyped
    case typed(
        name: String, hash: String?, models: [String: [String: String]]?,
        vectors: [String: [String: VectorEncoding]]? = nil,
        enums: RecordLogEnumDeclarations? = nil
    )
}

/// A typed db3's enforced enums, per model each enforced field's values (#5897).
typealias RecordLogEnumDeclarations = [String: [String: [String]]]

/// Per model, each enforced field's values; `nil` when `json` is not an
/// object of objects of non-empty string arrays.
func recordLogEnumDeclarations(_ json: JSONValue) -> RecordLogEnumDeclarations? {
    guard let models = json.objectValue else { return nil }
    var out: RecordLogEnumDeclarations = [:]
    for (model, fields) in models {
        guard let fields = fields.objectValue else { return nil }
        var enforced: [String: [String]] = [:]
        for (field, values) in fields {
            guard let list = values.arrayValue, !list.isEmpty else { return nil }
            let strings = list.compactMap(\.stringValue)
            guard strings.count == list.count else { return nil }
            enforced[field] = strings
        }
        out[model] = enforced
    }
    return out
}

func recordLogEnumDeclarationsJSON(_ enums: RecordLogEnumDeclarations) -> JSONValue {
    .object(enums.mapValues { .object($0.mapValues { .array($0.map { .string($0) }) }) })
}

/// A typed db3's vector encodings, per model each vector field's (#5225).
typealias RecordLogVectorDeclarations = [String: [String: VectorEncoding]]

extension VectorEncoding {
    /// The encoding as the room sends it and the store keeps it: `{ dims, element }`.
    var json: JSONValue { .object(["dims": .number(Double(dims)), "element": .string(element.rawValue)]) }

    /// `{ dims, element }` read back, or `nil` when it is not a well-formed encoding.
    init?(json: JSONValue?) {
        guard let object = json?.objectValue, let dims = object["dims"]?.numberValue, dims >= 1, dims == dims.rounded(),
              dims <= Double(Int32.max), let element = object["element"]?.stringValue.flatMap(VectorElement.init(rawValue:))
        else { return nil }
        self.init(dims: Int(dims), element: element)
    }
}

/// Per model, each vector field's encoding as JSON; `nil` when `json` is not
/// an object of objects of well-formed encodings.
func recordLogVectorDeclarations(_ json: JSONValue) -> RecordLogVectorDeclarations? {
    guard let models = json.objectValue else { return nil }
    var out: RecordLogVectorDeclarations = [:]
    for (model, fields) in models {
        guard let fields = fields.objectValue else { return nil }
        var encodings: [String: VectorEncoding] = [:]
        for (field, encoding) in fields {
            guard let encoding = VectorEncoding(json: encoding) else { return nil }
            encodings[field] = encoding
        }
        out[model] = encodings
    }
    return out
}

func recordLogVectorDeclarationsJSON(_ vectors: RecordLogVectorDeclarations) -> JSONValue {
    .object(vectors.mapValues { .object($0.mapValues(\.json)) })
}

/// One write of a commit: an entry's mutations, `m` first.
struct RecordLogWrite: Sendable {
    var mutations: [RecordLogMutation]
    /// `m` is an upsert on this field.
    var upsertOn: String?
}

/// A record and its view row (`nil` once it shows none).
struct RecordLogRowChange: Equatable, Sendable {
    var model: String
    var id: String
    var row: RecordLogRow?
}

/// What a command that changed view rows answers.
struct RecordLogChangeReply: Sendable {
    var changed: [RecordLogRowChange] = []
    var cursor: Int = 0
    /// A catch-up's page or completion was not applied: the store's cursor is
    /// past the log number it was read at, or another client of the store
    /// began a replacement of its own. The open starts over from the cursor.
    var stale = false
    /// Models whose view rows changed in bulk (a load's or a segment's chunk):
    /// `changed` then names only the records an unjudged entry touches, and a
    /// listener re-reads what it holds of these models.
    var models: [String] = []
    var acknowledged: [RecordLogEntryRef] = []
    var settled: [RecordLogEntryRef] = []
    /// The settled entries' records with their confirmed rows as each settled.
    var settlements: [RecordLogEntryRef: RecordLogSettlement] = [:]
    var handedBack: [RecordLogPendingEntry] = []
    var frames: [RecordLogUpFrame] = []
    /// A compact acknowledgement the store could not derive; the session opens again from the cursor.
    var underivable: RecordLogUnderivableAck?
}

/// The ids a bulk change of one model fell within, first and last included.
struct RecordLogIdRange: Equatable, Sendable {
    var model: String
    var firstId: String
    var lastId: String
}

/// What a chunk of a load or a segment answers.
struct RecordLogChunkReply: Sendable {
    /// Records the chunk put.
    var applied = 0
    /// Records it removed.
    var removed = 0
    /// The records an unjudged entry touches whose view row changed.
    var changed: [RecordLogRowChange] = []
    /// The models whose view rows changed in bulk.
    var models: [String] = []
    /// For a bulk change, the id range each of `models` changed within; a
    /// model with no range here changed anywhere.
    var ranges: [RecordLogIdRange] = []
    var cursor = 0
    /// The receipt attempt is no longer in progress in the store, or another
    /// replacement overtook its generation: nothing changed.
    var stale = false
    /// A held chunk could not be kept: nothing changed, and it is read instead.
    var mismatch = false
}

/// What `commitEntries` answers.
struct RecordLogCommitReply: Sendable {
    /// One entry per write, in order.
    var entries: [RecordLogPendingEntry]
    var changed: [RecordLogRowChange]
    var cursor: Int
    /// A local-only store's (#5155) entries it confirmed in the commit itself,
    /// as a `receive` would have answered them: the acknowledged entries,
    /// those that left the pending log, and their records' confirmed rows.
    /// `nil` in a synced store's reply, whose entries wait for the room.
    var acknowledged: [RecordLogEntryRef]? = nil
    /// See ``acknowledged``.
    var settled: [RecordLogEntryRef]? = nil
    /// See ``acknowledged``.
    var settlements: [RecordLogEntryRef: RecordLogSettlement]? = nil
    /// The upserts a local-only store applied to another record, as the room's aliases name them.
    var aliases: [RecordLogAlias] = []
}

/// An index registration made on a local-only db3 (#5155), as the store
/// keeps it: the room's registry, kept on the device. Stored as js-bao's
/// `RecordLogLocalIndex`, field for field.
struct RecordLogLocalIndex: Equatable, Sendable {
    /// The index's name, as the room would name it.
    var name: String
    var model: String
    var fields: [String]
    /// Whether the registration asks for uniqueness: its key is then a constraint the store enforces.
    var unique: Bool
    /// The `name` the registration gave, when it gave one.
    var named: String?
    /// A member index on the one field (#5156): its members kept in a table of their own on the device.
    var members: Bool
    /// What the index is (#5223): `.text` for a text index; stored as `kind`
    /// only then, a member index keeping `members: true`.
    var kind: Db3IndexKind
    /// A text index's options, filled in (#5223); stored as `text`.
    var text: RecordLogTextIndexOptions?
    /// A vector index's options with its field's encoding, filled in (#5230); stored as `vector`.
    var vector: RecordLogVectorOptions?

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name), "model": .string(model), "fields": .array(fields.map { .string($0) }), "unique": .bool(unique),
        ]
        if let named { object["named"] = .string(named) }
        if members { object["members"] = .bool(true) }
        if kind == .text || kind == .vector { object["kind"] = .string(kind.rawValue) }
        if let vector { object["vector"] = vector.json }
        if let text {
            object["text"] = .object([
                "tokenizer": .string(text.tokenizer.rawValue), "prefix": .array(text.prefix.map { .number(Double($0)) }),
                "weights": .object(text.weights.mapValues { .number($0) }),
            ])
        }
        return .object(object)
    }

    init(
        name: String, model: String, fields: [String], unique: Bool, named: String? = nil, members: Bool = false,
        kind: Db3IndexKind? = nil, text: RecordLogTextIndexOptions? = nil, vector: RecordLogVectorOptions? = nil
    ) {
        self.name = name
        self.model = model
        self.fields = fields
        self.unique = unique
        self.named = named
        self.members = members
        self.kind = kind ?? (members ? .members : .scalar)
        self.text = text
        self.vector = vector
    }

    init?(json: JSONValue?) {
        guard let name = json?["name"]?.stringValue, let model = json?["model"]?.stringValue else { return nil }
        let fields = json?["fields"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let kind = json?["kind"]?.stringValue.flatMap(Db3IndexKind.init(rawValue:))
        self.init(
            name: name, model: model, fields: fields,
            unique: json?["unique"]?.boolValue == true, named: json?["named"]?.stringValue,
            members: json?["members"]?.boolValue == true, kind: kind,
            text: kind == .text ? (try? RecordLogTextIndexOptions.parse(fields: fields, raw: json?["text"])) : nil,
            vector: kind == .vector ? RecordLogVectorOptions(cached: json?["vector"]) : nil
        )
    }

    /// Registrations as one text, in name order: what a change is judged against.
    static func text(_ indexes: [RecordLogLocalIndex]) -> String {
        RecordLogJSON.text(.array(indexes.sorted { $0.name < $1.name }.map(\.json)))
    }
}

/// What a change of a local-only db3's registrations did (`changeLocalIndexes`), and the marks after it.
enum RecordLogLocalIndexChange: Sendable {
    /// Written.
    case changed(RecordLogMarks)
    /// Another change came first: nothing was written.
    case moved(RecordLogMarks)
    /// Records share the unique key: nothing was written.
    case duplicates([(values: [JSONValue], count: Int)], RecordLogMarks)
}

/// What `purge` answers.
struct RecordLogPurgeReply: Sendable {
    /// Whether the document's local data is gone.
    var purged: Bool
    /// The store held writes the room has not judged, and the purge was not forced.
    var refusedForPending = false
    /// The store held nothing of the document.
    var nothingStored = false
    /// How many unjudged writes it held.
    var pendingOps: Int
    /// The unjudged writes a forced purge dropped, in the order they were written.
    var handedBack: [RecordLogPendingEntry]
}

/// SQL on the one connection, bound per call.
struct RecordLogSql {
    let connection: any Format2SqlConnection

    func exec(_ sql: String, _ bindings: [Format2SqlValue] = []) throws {
        try connection.execute(sql, bindings)
    }

    func rows(_ sql: String, _ bindings: [Format2SqlValue] = []) throws -> [Format2SqlRow] {
        try connection.query(sql, bindings)
    }

    func first(_ sql: String, _ bindings: [Format2SqlValue] = []) throws -> Format2SqlRow? {
        try connection.query(sql, bindings).first
    }
}

extension Format2SqlValue {
    /// A parameter `QueryTranslator` or `CursorManager` built, as a binding:
    /// a boolean as 1/0, an integer as an integer, a `Double` as a real, text
    /// as text and anything else (`NSNull`) as NULL.
    init(bindable value: Any) {
        switch value {
        // A statement's own value, a `$near`'s query vector among them (#5230).
        case let bound as Format2SqlValue: self = bound
        case let flag as Bool: self = .integer(flag ? 1 : 0)
        case let number as Int64: self = .integer(number)
        case let number as Int: self = .integer(Int64(number))
        case let number as Double: self = .real(number)
        case let text as String: self = .text(text)
        default: self = .null
        }
    }

    /// A written value as `record_log_pending_values` keeps it: a boolean as
    /// 1/0, an object or array as its JSON.
    static func recordLogWritten(_ value: JSONValue) -> Format2SqlValue {
        switch value {
        case .bool(let flag): return .integer(flag ? 1 : 0)
        case .number, .string: return Format2SqlValue(json: value)
        case .null: return .null
        case .object, .array: return .text(RecordLogJSON.text(value))
        }
    }

    /// A value as the JS store binds it into a `json_extract` lookup: a boolean
    /// as 1/0, a number or a string as itself, and anything else as JavaScript's
    /// `String()` of it (which matches no stored value).
    static func recordLogLookup(_ value: JSONValue) -> Format2SqlValue {
        switch value {
        case .null: return .null
        case .bool(let flag): return .integer(flag ? 1 : 0)
        case .number, .string: return Format2SqlValue(json: value)
        case .object: return .text("[object Object]")
        case .array(let items):
            return .text(items.map { item -> String in
                switch item {
                case .string(let text): return text
                case .null: return ""
                default: return Format2SqlValue.recordLogLookup(item).stringValue ?? ""
                }
            }.joined(separator: ","))
        }
    }

    /// The same value whatever SQLite stored it as: a whole real as an integer.
    var recordLogNormalized: Format2SqlValue {
        if case .real(let value) = self, value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
            return .integer(Int64(value))
        }
        return self
    }
}

/// How many ids holding U+0000 one statement binds, well under the oldest
/// SQLite builds' 999 variables.
private let recordLogBoundIds = 400

/// `ids`, each once (byte for byte, as SQLite compares them), as subqueries
/// of one column `value` (the right side of `_id IN …`, or a `FROM`), with
/// their bindings: one JSON array through `json_each`, a single binding
/// however many ids it holds, and the ids holding U+0000, which a binding
/// cuts short there and JSON would not, bound one by one,
/// ``recordLogBoundIds`` a list.
func recordLogIdLists(_ ids: [String]) -> [(list: String, bindings: [Format2SqlValue])] {
    var seen = Set<RecordLogExactText>()
    var listed: [String] = []
    var bound: [Format2SqlValue] = []
    for id in ids where seen.insert(RecordLogExactText(id)).inserted {
        if recordLogJsonUnsafeId(id) { bound.append(.text(id)) } else { listed.append(id) }
    }
    var lists: [(list: String, bindings: [Format2SqlValue])] = []
    if !listed.isEmpty { lists.append(("(SELECT value FROM json_each(?))", [.text(recordLogJSONArray(listed))])) }
    for start in stride(from: 0, to: bound.count, by: recordLogBoundIds) {
        let slice = Array(bound[start..<min(start + recordLogBoundIds, bound.count)])
        let values = slice.map { _ in "(?)" }.joined(separator: ", ")
        lists.append(("(SELECT column1 AS value FROM (VALUES \(values)))", slice))
    }
    return lists
}

/// `values` as a JSON array of strings (or of arrays of strings): a payload
/// `json_each` reads back as it was.
func recordLogJSONArray<T: Encodable>(_ values: [T]) -> String {
    guard let data = try? recordLogPayloadEncoder.encode(values), let text = String(data: data, encoding: .utf8) else { return "[]" }
    return text
}

private let recordLogPayloadEncoder = JSONEncoder()

/// Whether `id` holds U+0000: bound, it is cut short there, so it does not
/// travel in a JSON payload, and SQL answers it as another id (two ids can
/// name one stored row); a chunk holding one goes row by row.
func recordLogJsonUnsafeId(_ id: String) -> Bool { id.utf8.contains(0) }

/// The ids of `keys` by model, the models in order of first mention.
private func recordLogIdsByModel(_ keys: [RecordLogRecordKey]) -> [(model: String, ids: [String])] {
    var models: [String] = []
    var byModel: [String: [String]] = [:]
    for key in keys {
        if byModel[key.model] == nil { models.append(key.model) }
        byModel[key.model, default: []].append(key.id)
    }
    return models.map { ($0, byModel[$0] ?? []) }
}

/// An ordered map: entries keep the order they were first put in.
struct RecordLogOrderedMap<Key: Hashable, Value> {
    private(set) var keys: [Key] = []
    private var values: [Key: Value] = [:]

    subscript(key: Key) -> Value? {
        get { values[key] }
        set {
            guard let newValue else {
                if values.removeValue(forKey: key) != nil { keys.removeAll { $0 == key } }
                return
            }
            if values.updateValue(newValue, forKey: key) == nil { keys.append(key) }
        }
    }

    func contains(_ key: Key) -> Bool { values[key] != nil }

    var entries: [(key: Key, value: Value)] { keys.map { ($0, values[$0]!) } }
}

/// The client's state for one document, kept in the store's tables.
///
/// Every method runs on the provider's queue inside one of the store's calls,
/// on the connection that call bound (`sql`).
final class SqlRecordLogTables: RecordLogReceiptTables, RecordLogBatchRowTables {
    /// How many results held ahead of the cursor make the store say so, once.
    static let heldWarn = 10_000

    private let docId: String
    private let logger: Logger?
    var sql: RecordLogSql!
    /// Results ahead of the cursor; held in memory, refetched by catch-up if lost.
    private var held: [Int: RecordLogResult] = [:]
    /// Whether the held results passed ``heldWarn`` since they last fell below it.
    private var heldWarned = false
    /// Records of entries changed or removed since the last `takeDirty`.
    private var dirty: [RecordLogRecordKey] = []
    /// Inside ``countingEpochs(_:)``, each epoch's unwithdrawn pending entries
    /// once counted, kept as entries are added; `nil` outside it.
    private var epochPending: [Int: Int]?

    init(docId: String, logger: Logger? = nil) {
        self.docId = docId
        self.logger = logger
    }

    private var doc: Format2SqlValue { .text(docId) }

    private func state() throws -> Format2SqlRow? {
        try sql.first("SELECT * FROM record_log_state WHERE doc_id = ?", [doc])
    }

    func ensureState() throws {
        try sql.exec("INSERT OR IGNORE INTO record_log_state (doc_id) VALUES (?)", [doc])
    }

    func cursor() throws -> Int { try state()?["cursor"].intValue ?? 0 }

    func setCursor(_ cursor: Int) throws {
        try ensureState()
        try sql.exec("UPDATE record_log_state SET cursor = ? WHERE doc_id = ?", [.integer(Int64(cursor)), doc])
    }

    func knownHead() throws -> RecordLogKnownHead? {
        guard let state = try state(), let head = state["known_head"].intValue else { return nil }
        return RecordLogKnownHead(head: head, at: Int64(state["known_head_at"].intValue ?? 0))
    }

    func setKnownHead(_ head: Int, at: Int64) throws {
        try ensureState()
        try sql.exec(
            "UPDATE record_log_state SET known_head = ?, known_head_at = ? WHERE doc_id = ?",
            [.integer(Int64(head)), .integer(at), doc]
        )
    }

    func epochs() throws -> RecordLogEpochs {
        let state = try state()
        return RecordLogEpochs(
            open: state?["open_epoch"].intValue ?? RecordLogTransport.firstEpoch,
            grant: state?["grant_epoch"].intValue ?? RecordLogTransport.firstEpoch + 1,
            entries: state?["epoch_entries"].intValue ?? RecordLogTransport.defaultEpochEntries
        )
    }

    func setEpochs(_ epochs: RecordLogEpochs) throws {
        try ensureState()
        try sql.exec(
            "UPDATE record_log_state SET open_epoch = ?, grant_epoch = ?, epoch_entries = ? WHERE doc_id = ?",
            [.integer(Int64(epochs.open)), .integer(Int64(epochs.grant)), .integer(Int64(epochs.entries)), doc]
        )
    }

    func constraints() throws -> [RecordLogConstraint] {
        guard let text = try state()?["constraints"].stringValue else { return [] }
        return RecordLogJSON.parse(text)?.arrayValue?.compactMap { RecordLogConstraint(json: $0) } ?? []
    }

    func setConstraints(_ constraints: [RecordLogConstraint]) throws {
        try ensureState()
        try sql.exec(
            "UPDATE record_log_state SET constraints = ? WHERE doc_id = ?",
            [.text(RecordLogJSON.text(.array(constraints.map(\.json)))), doc]
        )
    }

    func setPermission(_ permission: String?) throws {
        try ensureState()
        try sql.exec(
            "UPDATE record_log_state SET permission = ? WHERE doc_id = ?",
            [permission.map { .text($0) } ?? .null, doc]
        )
    }

    /// The `record_log_meta` key a document's type mark is kept under (#5020):
    /// a JSON `{ typed, name?, hash?, models?, vectors?, enums? }`, absent
    /// before any room answered. `vectors` (#5225) is the vector encodings or
    /// `null`, `enums` (#5897) the enforced enums or `null`; an entry an older
    /// client wrote has no such key.
    private var typeKey: Format2SqlValue { .text("db3_type:\(docId)") }

    /// The typed mark, the type, its held declarations, vector encodings and
    /// enforced enums, and whether the entry records the encodings (#5225)
    /// and the enums (#5897).
    func typeState() throws -> (
        typed: RecordLogTyped, db3Type: RecordLogDb3Type?, declarations: [String: [String: String]]?,
        vectors: RecordLogVectorDeclarations?, vectorsKnown: Bool,
        enums: RecordLogEnumDeclarations?, enumsKnown: Bool
    ) {
        let text = try sql.first("SELECT value FROM record_log_meta WHERE key = ?", [typeKey])?["value"].stringValue
        guard let held = text.flatMap({ JSONValue(jsonText: $0) })?.objectValue else { return (.unknown, nil, nil, nil, true, nil, true) }
        let typed = RecordLogTyped(rawValue: held["typed"]?.stringValue ?? "") ?? .unknown
        guard typed == .yes, let name = held["name"]?.stringValue else { return (typed, nil, nil, nil, true, nil, true) }
        let declarations = held["models"]?.objectValue?.mapValues { ($0.objectValue ?? [:]).compactMapValues(\.stringValue) }
        let vectors = held["vectors"].flatMap(recordLogVectorDeclarations)
        let enums = held["enums"].flatMap(recordLogEnumDeclarations)
        // An entry with declarations and no `enums` key was written before enforced enums (#5897).
        let enumsKnown = declarations == nil || held["enums"] != nil
        return (
            typed, RecordLogDb3Type(name: name, hash: held["hash"]?.stringValue), declarations, vectors, held["vectors"] != nil,
            enums, enumsKnown
        )
    }

    /// Record what the room said of the type: untyped clears it; typed keeps
    /// the held declarations when the hash is theirs and none were sent.
    func setType(_ update: RecordLogTypeUpdate) throws {
        var object: [String: JSONValue]
        switch update {
        case .untyped:
            object = ["typed": "no"]
        case .typed(let name, let hash, let models, let vectors, let enums):
            let held = try typeState()
            let keepsHeld = models == nil && hash != nil && held.db3Type?.hash == hash
            let kept = models ?? (keepsHeld ? held.declarations : nil)
            object = ["typed": "yes", "name": .string(name), "hash": kept != nil ? hash.map { .string($0) } ?? .null : .null]
            object["models"] = kept.map { .object($0.mapValues { .object($0.mapValues { .string($0) }) }) } ?? .null
            // The encodings travel with the declarations (#5225). Held ones
            // kept from an entry that never recorded them stay unrecorded, so
            // the next open still asks for them.
            if keepsHeld {
                if held.vectorsKnown { object["vectors"] = held.vectors.map(recordLogVectorDeclarationsJSON) ?? .null }
            } else {
                object["vectors"] = vectors.map(recordLogVectorDeclarationsJSON) ?? .null
            }
            // So do the enforced enums (#5897).
            if keepsHeld {
                if held.enumsKnown { object["enums"] = held.enums.map(recordLogEnumDeclarationsJSON) ?? .null }
            } else {
                object["enums"] = enums.map(recordLogEnumDeclarationsJSON) ?? .null
            }
        }
        try sql.exec(
            "INSERT INTO record_log_meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
            [typeKey, .text(RecordLogJSON.text(.object(object)))]
        )
    }

    /// Forget the type mark and the local-only owner: the document's local data is removed.
    func forgetType() throws {
        try sql.exec("DELETE FROM record_log_meta WHERE key IN (?, ?)", [typeKey, .text(RecordLogStore.localOwnerKey(docId))])
    }

    func setLastCatchUpAt(_ at: Int64) throws {
        try ensureState()
        try sql.exec("UPDATE record_log_state SET last_catch_up_at = ? WHERE doc_id = ?", [.integer(at), doc])
    }

    /// Whether the db3 lives only on this device (#5155).
    func localOnly() throws -> Bool { try state()?["local_only"].intValue == 1 }

    func setLocalOnly(_ localOnly: Bool) throws {
        try ensureState()
        try sql.exec("UPDATE record_log_state SET local_only = ? WHERE doc_id = ?", [.integer(localOnly ? 1 : 0), doc])
    }

    /// A local-only db3's index registrations, by name.
    func localIndexes() throws -> [RecordLogLocalIndex] {
        guard let text = try state()?["local_indexes"].stringValue else { return [] }
        return RecordLogJSON.parse(text)?.arrayValue?.compactMap { RecordLogLocalIndex(json: $0) } ?? []
    }

    func setLocalIndexes(_ indexes: [RecordLogLocalIndex]) throws {
        try ensureState()
        try sql.exec(
            "UPDATE record_log_state SET local_indexes = ? WHERE doc_id = ?", [.text(RecordLogLocalIndex.text(indexes)), doc]
        )
    }

    func generation() throws -> Int {
        let state = try state()
        if let replacing = state?["replacing"], !replacing.isNull { return replacing.intValue ?? 0 }
        return state?["rows_gen"].intValue ?? 0
    }

    func isReplacing() throws -> Bool {
        guard let replacing = try state()?["replacing"] else { return false }
        return !replacing.isNull
    }

    func replacing() throws -> Int? {
        guard let replacing = try state()?["replacing"], !replacing.isNull else { return nil }
        return replacing.intValue
    }

    func receipts() throws -> RecordLogReceiptState? {
        guard let text = try state()?["receipt"].stringValue, !text.isEmpty else { return nil }
        return RecordLogReceiptState(json: RecordLogJSON.parse(text))
    }

    func setReceipts(_ state: RecordLogReceiptState?) throws {
        try ensureState()
        try sql.exec(
            "UPDATE record_log_state SET receipt = ? WHERE doc_id = ?",
            [state.map { .text(RecordLogJSON.text($0.json)) } ?? .null, doc]
        )
    }

    func heldSegment() throws -> RecordLogHeldSegment? {
        guard let text = try state()?["segment"].stringValue, !text.isEmpty else { return nil }
        return RecordLogHeldSegment(json: RecordLogJSON.parse(text))
    }

    func setHeldSegment(_ segment: RecordLogHeldSegment?) throws {
        try ensureState()
        try sql.exec(
            "UPDATE record_log_state SET segment = ? WHERE doc_id = ?",
            [segment.map { .text(RecordLogJSON.text($0.json)) } ?? .null, doc]
        )
    }

    func keepConfirmedRange(model: String, firstId: String, lastId: String, rows: Int) throws -> Bool {
        let state = try state()
        guard let replacing = state?["replacing"], !replacing.isNull, let generation = replacing.intValue else { return false }
        // The confirmed generation's rows only: one an interrupted replacement
        // put carries that replacement's generation. `_id` compares BINARY, the
        // order the room cut the chunk in.
        let predicate = "WHERE doc_id = ? AND _type = ? AND _id >= ? AND _id <= ? AND _gen = ?"
        let bindings: [Format2SqlValue] = [
            doc, .text(model), .text(firstId), .text(lastId), .integer(Int64(state?["rows_gen"].intValue ?? 0)),
        ]
        let count = try sql.first("SELECT COUNT(*) AS n FROM record_log_rows \(predicate)", bindings)?["n"].intValue ?? 0
        guard count == rows else { return false }
        try sql.exec("UPDATE record_log_rows SET _gen = ? \(predicate)", [.integer(Int64(generation))] + bindings)
        return true
    }

    func noteLoadKeys(_ attempt: String, _ keys: [RecordLogRecordKey]) throws {
        for (model, ids) in recordLogIdsByModel(keys) {
            for (list, bindings) in recordLogIdLists(ids) {
                try sql.exec(
                    "INSERT OR IGNORE INTO record_log_load_keys (doc_id, attempt, _type, _id) SELECT ?, ?, ?, value FROM \(list)",
                    [doc, .text(attempt), .text(model)] + bindings
                )
            }
        }
    }

    func removeUnnamed(_ attempt: String, models: [String]) throws -> [RecordLogRecordKey] {
        var removed: [RecordLogRecordKey] = []
        let unnamed = """
            FROM record_log_rows r WHERE r.doc_id = ? AND r._type = ? AND NOT EXISTS (
              SELECT 1 FROM record_log_load_keys k
               WHERE k.doc_id = r.doc_id AND k.attempt = ? AND k._type = r._type AND k._id = r._id)
            """
        for model in models {
            let bindings: [Format2SqlValue] = [doc, .text(model), .text(attempt)]
            for row in try sql.rows("SELECT r._id AS _id \(unnamed)", bindings) {
                if let id = row["_id"].stringValue { removed.append(RecordLogRecordKey(model: model, id: id)) }
            }
            try sql.exec(
                "DELETE FROM record_log_rows WHERE doc_id = ? AND _type = ? AND _id IN (SELECT r._id \(unnamed))",
                [doc, .text(model)] + bindings
            )
        }
        return removed
    }

    func forgetLoad(_ attempt: String) throws {
        try sql.exec("DELETE FROM record_log_load_keys WHERE doc_id = ? AND attempt = ?", [doc, .text(attempt)])
    }

    func renameLoad(_ from: String, to: String) throws {
        try sql.exec(
            "UPDATE record_log_load_keys SET attempt = ? WHERE doc_id = ? AND attempt = ?", [.text(to), doc, .text(from)]
        )
    }

    func keepLoads(_ attempts: [String]) throws {
        let marks = attempts.map { _ in "?" }.joined(separator: ", ")
        try sql.exec(
            "DELETE FROM record_log_load_keys WHERE doc_id = ?\(attempts.isEmpty ? "" : " AND attempt NOT IN (\(marks))")",
            [doc] + attempts.map { .text($0) }
        )
    }

    func confirmed() throws -> RecordLogRowTable { ConfirmedTable(tables: self) }

    func readConfirmed(_ keys: [RecordLogRecordKey]) throws -> [RecordLogExactKey: RecordLogRow] {
        var found: [RecordLogExactKey: RecordLogRow] = [:]
        let confirmed = try self.confirmed()
        for (model, ids) in recordLogIdsByModel(keys) {
            var listed: [String] = []
            for id in ids {
                guard recordLogJsonUnsafeId(id) else {
                    listed.append(id)
                    continue
                }
                // SQL would answer it as another id: read as `row` reads it, under the id asked for.
                let key = RecordLogRecordKey(model: model, id: id)
                if let row = try confirmed.row(key) { found[RecordLogExactKey(key)] = row }
            }
            guard !listed.isEmpty else { continue }
            for row in try sql.rows(
                "SELECT _id, json(_data) AS _data FROM record_log_rows WHERE doc_id = ? AND _type = ? AND _id IN (SELECT value FROM json_each(?))",
                [doc, .text(model), .text(recordLogJSONArray(listed))]
            ) {
                guard let id = row["_id"].stringValue else { continue }
                found[RecordLogExactKey(RecordLogRecordKey(model: model, id: id))] = RecordLogJSON.row(row["_data"].stringValue, id: id)
            }
        }
        return found
    }

    func writeConfirmed(_ changes: [(key: RecordLogRecordKey, row: RecordLogRow?)]) throws {
        guard !changes.isEmpty else { return }
        let replacing = try isReplacing()
        let generation = Format2SqlValue.integer(Int64(try generation()))
        var models: [String] = []
        var byModel: [String: (removed: [String], puts: [(id: String, data: String)])] = [:]
        for change in changes {
            if byModel[change.key.model] == nil { models.append(change.key.model) }
            if let row = change.row {
                byModel[change.key.model, default: ([], [])].puts.append((change.key.id, RecordLogJSON.stored(row)))
            } else {
                byModel[change.key.model, default: ([], [])].removed.append(change.key.id)
            }
        }
        for model in models {
            guard let entry = byModel[model] else { continue }
            // While replacing, each put takes a new rowid, as `set` deletes first.
            let deleted = replacing ? entry.removed + entry.puts.map(\.id) : entry.removed
            for (list, bindings) in recordLogIdLists(deleted) {
                try sql.exec("DELETE FROM record_log_rows WHERE doc_id = ? AND _type = ? AND _id IN \(list)", [doc, .text(model)] + bindings)
            }
            guard !entry.puts.isEmpty else { continue }
            if entry.puts.contains(where: { recordLogJsonUnsafeId($0.id) }) {
                for put in entry.puts {
                    try sql.exec(
                        """
                        INSERT INTO record_log_rows (doc_id, _type, _id, _data, _gen) VALUES (?, ?, ?, jsonb(?), ?)
                          ON CONFLICT (doc_id, _type, _id) DO UPDATE SET _data = excluded._data, _gen = excluded._gen
                        """,
                        [doc, .text(model), .text(put.id), .text(put.data), generation]
                    )
                }
                continue
            }
            // Each put is `[id, its stored JSON text]`: `jsonb()` parses the text
            // `set` binds, and the array's order is the order fresh rows take
            // their rowids in. `WHERE true` lets the upsert follow a `FROM`.
            let payload = recordLogJSONArray(entry.puts.map { [$0.id, $0.data] })
            try sql.exec(
                """
                INSERT INTO record_log_rows (doc_id, _type, _id, _data, _gen)
                  SELECT ?, ?, j.value ->> 0, jsonb(j.value ->> 1), ? FROM json_each(?) AS j WHERE true
                  ON CONFLICT (doc_id, _type, _id) DO UPDATE SET _data = excluded._data, _gen = excluded._gen
                """,
                [doc, .text(model), generation, .text(payload)]
            )
        }
    }

    /// The confirmed rows, in the order they arrived: a full replacement puts
    /// its rows in the order it carries them.
    ///
    /// One table serves one rule call, inside which no replacement begins or
    /// ends: whether one is under way, and its generation, are read once.
    private final class ConfirmedTable: RecordLogRowTable {
        let tables: SqlRecordLogTables
        private var writing: (replacing: Bool, generation: Int)?
        init(tables: SqlRecordLogTables) { self.tables = tables }

        private func write() throws -> (replacing: Bool, generation: Int) {
            if let writing { return writing }
            let read = (try tables.isReplacing(), try tables.generation())
            writing = read
            return read
        }

        func row(_ key: RecordLogRecordKey) throws -> RecordLogRow? {
            try tables.confirmedRow(key)
        }

        func set(_ key: RecordLogRecordKey, _ row: RecordLogRow) throws {
            let sql = tables.sql!
            let bindings: [Format2SqlValue] = [tables.doc, .text(key.model), .text(key.id)]
            let (replacing, generation) = try write()
            if replacing {
                try sql.exec("DELETE FROM record_log_rows WHERE doc_id = ? AND _type = ? AND _id = ?", bindings)
            }
            try sql.exec(
                """
                INSERT INTO record_log_rows (doc_id, _type, _id, _data, _gen) VALUES (?, ?, ?, jsonb(?), ?)
                  ON CONFLICT (doc_id, _type, _id) DO UPDATE SET _data = excluded._data, _gen = excluded._gen
                """,
                bindings + [.text(RecordLogJSON.stored(row)), .integer(Int64(generation))]
            )
        }

        func delete(_ key: RecordLogRecordKey) throws {
            try tables.sql.exec(
                "DELETE FROM record_log_rows WHERE doc_id = ? AND _type = ? AND _id = ?",
                [tables.doc, .text(key.model), .text(key.id)]
            )
        }

        func holder(model: String, fields: [String], values: [JSONValue], excluding: [String]) throws -> String? {
            try RecordLogStore.findHolders(
                tables.sql, table: "record_log_rows", docId: tables.docId, model: model,
                fields: fields, values: values, excluding: excluding, limitToFirst: true
            ).first
        }
    }

    func confirmedRow(_ key: RecordLogRecordKey) throws -> RecordLogRow? {
        try sql.first(
            "SELECT json(_data) AS _data FROM record_log_rows WHERE doc_id = ? AND _type = ? AND _id = ?",
            [doc, .text(key.model), .text(key.id)]
        ).map { RecordLogJSON.row($0["_data"].stringValue, id: key.id) }
    }

    func beginReplace() throws {
        try ensureState()
        // The view holds a completed generation when a catch-up completed here
        // and no replacement is in progress, or the one in progress is staged:
        // the new one is staged too, and the view keeps those rows until it
        // completes. Over a cold load's rows it is written as rows arrive.
        let before = try state()
        let wasReplacing = before.map { !$0["replacing"].isNull } ?? false
        let caughtUp = before.map { !$0["last_catch_up_at"].isNull } == true
        let completeView = try caughtUp && (!wasReplacing || staged())
        // Every attempt takes a generation of its own: a row an interrupted
        // attempt put is gone unless this one puts it again.
        try sql.exec(
            "UPDATE record_log_state SET replacing = MAX(rows_gen, COALESCE(replacing, rows_gen)) + 1 WHERE doc_id = ?",
            [doc]
        )
        try sql.exec("UPDATE record_log_state SET staged = \(completeView ? "replacing" : "NULL") WHERE doc_id = ?", [doc])
        // A staged attempt after an interrupted staged one keeps the base the
        // first took: the view still holds that completed generation.
        if !completeView || !wasReplacing { try clearStagedBase() }
    }

    /// Whether the replacement in progress is staged: the view still holds
    /// the previous completed generation's rows.
    func staged() throws -> Bool {
        guard let state = try state(), !state["replacing"].isNull, !state["staged"].isNull else { return false }
        return state["staged"].intValue == state["replacing"].intValue
    }

    /// Keep, once per record, the previous completed generation's confirmed
    /// row of each of `keys` (none when it had none) before a staged
    /// replacement rewrites it.
    func stageBase(_ keys: [RecordLogRecordKey]) throws {
        for key in keys {
            try sql.exec(
                """
                INSERT OR IGNORE INTO record_log_staged_base (doc_id, _type, _id, _data)
                  VALUES (?, ?, ?, (SELECT _data FROM record_log_rows WHERE doc_id = ? AND _type = ? AND _id = ?))
                """,
                [doc, .text(key.model), .text(key.id), doc, .text(key.model), .text(key.id)]
            )
        }
    }

    /// What a view refresh guesses over: the confirmed rows, except, while a
    /// staged replacement is in progress, the previous completed generation's
    /// row of each record the replacement has rewritten.
    func viewBase() throws -> (RecordLogRecordKey) throws -> RecordLogRow? {
        guard try staged() else { return { [unowned self] key in try self.confirmedRow(key) } }
        return { [unowned self] key in
            guard let kept = try self.sql.first(
                "SELECT json(_data) AS _data FROM record_log_staged_base WHERE doc_id = ? AND _type = ? AND _id = ?",
                [self.doc, .text(key.model), .text(key.id)]
            ) else { return try self.confirmedRow(key) }
            return kept["_data"].isNull ? nil : RecordLogJSON.row(kept["_data"].stringValue, id: key.id)
        }
    }

    private func clearStagedBase() throws {
        try sql.exec("DELETE FROM record_log_staged_base WHERE doc_id = ?", [doc])
    }

    func completeReplace() throws -> [RecordLogRecordKey] {
        guard let replacing = try state()?["replacing"], !replacing.isNull, let gen = replacing.intValue else {
            return []
        }
        let removed = try sql.rows(
            "SELECT _type, _id FROM record_log_rows WHERE doc_id = ? AND _gen <> ?", [doc, .integer(Int64(gen))]
        ).compactMap { row -> RecordLogRecordKey? in
            guard let model = row["_type"].stringValue, let id = row["_id"].stringValue else { return nil }
            return RecordLogRecordKey(model: model, id: id)
        }
        try sql.exec("DELETE FROM record_log_rows WHERE doc_id = ? AND _gen <> ?", [doc, .integer(Int64(gen))])
        try sql.exec(
            "UPDATE record_log_state SET rows_gen = ?, replacing = NULL, staged = NULL WHERE doc_id = ?",
            [.integer(Int64(gen)), doc]
        )
        try clearStagedBase()
        return removed
    }

    func buffered(_ l: Int) -> RecordLogResult? { held[l] }

    func buffer(_ item: RecordLogResult) {
        held[item.l] = item
        if held.count > Self.heldWarn && !heldWarned {
            heldWarned = true
            logger?.warn(
                "[record-log] \(docId): \(held.count) results held ahead of the cursor \((try? cursor()) ?? 0) "
                    + "(a load applying, or a result lost); they apply once the store catches up past the gap"
            )
        }
    }

    func dropBufferedThrough(_ l: Int) {
        held = held.filter { $0.key > l }
        if held.count <= Self.heldWarn { heldWarned = false }
    }

    func forgetBuffered() {
        held = [:]
        heldWarned = false
    }

    /// The records of every entry changed or removed since the last call.
    func takeDirty() -> [RecordLogRecordKey] {
        defer { dirty = [] }
        return dirty
    }

    private func markDirty(_ writer: String, _ seq: Int) throws {
        for row in try sql.rows(
            "SELECT _type, _id FROM record_log_pending_keys WHERE doc_id = ? AND writer = ? AND seq = ?",
            [doc, .text(writer), .integer(Int64(seq))]
        ) {
            if let model = row["_type"].stringValue, let id = row["_id"].stringValue {
                dirty.append(RecordLogRecordKey(model: model, id: id))
            }
        }
    }

    func isWriter(_ writer: String) throws -> Bool {
        try sql.first("SELECT 1 AS present FROM record_log_writers WHERE doc_id = ? AND writer = ?", [doc, .text(writer)]) != nil
    }

    func writerState(_ writer: String) throws -> RecordLogWriterState {
        let row = try sql.first(
            "SELECT next_seq, resumed_at FROM record_log_writers WHERE doc_id = ? AND writer = ?", [doc, .text(writer)]
        )
        return RecordLogWriterState(nextSeq: row?["next_seq"].intValue ?? 1, resumedAt: row?["resumed_at"].intValue ?? 0)
    }

    func setWriterState(_ writer: String, _ state: RecordLogWriterState) throws {
        try sql.exec(
            "UPDATE record_log_writers SET next_seq = ?, resumed_at = ? WHERE doc_id = ? AND writer = ?",
            [.integer(Int64(state.nextSeq)), .integer(Int64(state.resumedAt)), doc, .text(writer)]
        )
    }

    func pending(_ writer: String) throws -> [RecordLogPendingEntry] {
        try sql.rows(
            "SELECT entry, acked FROM record_log_pending WHERE doc_id = ? AND writer = ? ORDER BY seq",
            [doc, .text(writer)]
        ).compactMap(Self.pendingEntry(row:))
    }

    func pendingEntry(_ writer: String, _ seq: Int) throws -> RecordLogPendingEntry? {
        try sql.first(
            "SELECT entry, acked FROM record_log_pending WHERE doc_id = ? AND writer = ? AND seq = ?",
            [doc, .text(writer), .integer(Int64(seq))]
        ).flatMap(Self.pendingEntry(row:))
    }

    func pendingThrough(_ writer: String, _ seq: Int) throws -> [RecordLogPendingEntry] {
        try sql.rows(
            "SELECT entry, acked FROM record_log_pending WHERE doc_id = ? AND writer = ? AND seq <= ? ORDER BY seq",
            [doc, .text(writer), .integer(Int64(seq))]
        ).compactMap(Self.pendingEntry(row:))
    }

    /// A `record_log_pending` row's entry, its acknowledgement with it.
    private static func pendingEntry(row: Format2SqlRow) -> RecordLogPendingEntry? {
        guard var entry = RecordLogPendingEntry(stored: row["entry"].stringValue.flatMap(RecordLogJSON.parse)) else {
            return nil
        }
        entry.acked = row["acked"].intValue
        return entry
    }

    func putPending(_ writer: String, _ entry: RecordLogPendingEntry) throws {
        let w: Format2SqlValue = .text(writer)
        let seq: Format2SqlValue = .integer(Int64(entry.seq))
        let stored = RecordLogJSON.text(entry.storedJSON)
        let acked: Format2SqlValue = entry.acked.map { .integer(Int64($0)) } ?? .null
        let exists = try sql.first(
            "SELECT 1 AS present FROM record_log_pending WHERE doc_id = ? AND writer = ? AND seq = ?", [doc, w, seq]
        ) != nil
        if exists {
            if epochPending != nil { epochPending = [:] }
            try markDirty(writer, entry.seq)
            try sql.exec(
                "UPDATE record_log_pending SET entry = ?, void = ?, acked = ?, e = ? WHERE doc_id = ? AND writer = ? AND seq = ?",
                [.text(stored), .integer(entry.isVoid ? 1 : 0), acked, .integer(Int64(entry.e)), doc, w, seq]
            )
            try sql.exec(
                "DELETE FROM record_log_pending_keys WHERE doc_id = ? AND writer = ? AND seq = ? AND resolved = 0",
                [doc, w, seq]
            )
        } else {
            let top = try sql.first("SELECT MAX(ord) AS ord FROM record_log_pending WHERE doc_id = ?", [doc])
            try sql.exec(
                "INSERT INTO record_log_pending (doc_id, writer, seq, ord, e, entry, ts, void, acked) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [
                    doc, w, seq, .integer(Int64((top?["ord"].intValue ?? 0) + 1)), .integer(Int64(entry.e)),
                    .text(stored), entry.ts.map { .integer($0) } ?? .null, .integer(entry.isVoid ? 1 : 0), acked,
                ]
            )
            if !entry.isVoid, let n = epochPending?[entry.e] { epochPending?[entry.e] = n + 1 }
        }
        try putValues(writer, entry)
        for key in entry.keys {
            try sql.exec(
                "INSERT OR IGNORE INTO record_log_pending_keys (doc_id, writer, seq, _type, _id, resolved) VALUES (?, ?, ?, ?, ?, 0)",
                [doc, w, seq, .text(key.model), .text(key.id)]
            )
        }
    }

    /// Keep the values an entry's mutations write, each by model and field, its
    /// upsert's own marked; a string-set change is kept without a value, since
    /// the members it leaves depend on the row.
    private func putValues(_ writer: String, _ entry: RecordLogPendingEntry) throws {
        let w: Format2SqlValue = .text(writer)
        let seq: Format2SqlValue = .integer(Int64(entry.seq))
        try sql.exec("DELETE FROM record_log_pending_values WHERE doc_id = ? AND writer = ? AND seq = ?", [doc, w, seq])
        func put(_ model: String, _ field: String, _ value: Format2SqlValue, _ upsert: Bool) throws {
            try sql.exec(
                """
                INSERT INTO record_log_pending_values (doc_id, writer, seq, _type, field, value, upsert) VALUES (?, ?, ?, ?, ?, ?, ?)
                  ON CONFLICT (doc_id, writer, seq, _type, field, value) DO UPDATE SET upsert = MAX(upsert, excluded.upsert)
                """,
                [doc, w, seq, .text(model), .text(field), value, .integer(upsert ? 1 : 0)]
            )
        }
        for (index, mutation) in entry.mutations.enumerated() {
            for (field, value) in (mutation.fields ?? [:]).sorted(by: { $0.key < $1.key }) where value != .null {
                try put(mutation.model, field, .recordLogWritten(value), index == 0 && field == entry.upsertOn)
            }
            for field in (mutation.stringSetDeltas ?? [:]).keys.sorted() {
                try put(mutation.model, field, .null, false)
            }
        }
    }

    func deletePending(_ writer: String, _ seq: Int) throws {
        if epochPending != nil { epochPending = [:] }
        try markDirty(writer, seq)
        let bindings: [Format2SqlValue] = [doc, .text(writer), .integer(Int64(seq))]
        try sql.exec("DELETE FROM record_log_pending WHERE doc_id = ? AND writer = ? AND seq = ?", bindings)
        try sql.exec("DELETE FROM record_log_pending_keys WHERE doc_id = ? AND writer = ? AND seq = ?", bindings)
        try sql.exec("DELETE FROM record_log_pending_values WHERE doc_id = ? AND writer = ? AND seq = ?", bindings)
    }

    func acknowledgedThrough(_ l: Int) throws -> [RecordLogEntryRef] {
        try sql.rows(
            "SELECT writer, seq FROM record_log_pending WHERE doc_id = ? AND acked IS NOT NULL AND acked <= ? ORDER BY writer, seq",
            [doc, .integer(Int64(l))]
        ).compactMap { row in
            guard let writer = row["writer"].stringValue, let seq = row["seq"].intValue else { return nil }
            return RecordLogEntryRef(writer: writer, seq: seq)
        }
    }

    func handled(_ writer: String, _ key: RecordLogRecordKey) throws -> [Int: Int] {
        var out: [Int: Int] = [:]
        for row in try sql.rows(
            "SELECT from_seq, until_seq FROM record_log_handled WHERE doc_id = ? AND writer = ? AND _type = ? AND _id = ?",
            [doc, .text(writer), .text(key.model), .text(key.id)]
        ) {
            if let from = row["from_seq"].intValue, let until = row["until_seq"].intValue { out[from] = until }
        }
        return out
    }

    func setHandled(_ writer: String, _ key: RecordLogRecordKey, from: Int, until: Int) throws {
        try sql.exec(
            "INSERT OR REPLACE INTO record_log_handled (doc_id, writer, _type, _id, from_seq, until_seq) VALUES (?, ?, ?, ?, ?, ?)",
            [doc, .text(writer), .text(key.model), .text(key.id), .integer(Int64(from)), .integer(Int64(until))]
        )
    }

    func epochCount(_ e: Int) throws -> Int {
        try sql.first(
            "SELECT count FROM record_log_epoch_counts WHERE doc_id = ? AND epoch = ?", [doc, .integer(Int64(e))]
        )?["count"].intValue ?? 0
    }

    func countEpoch(_ e: Int) throws {
        try sql.exec(
            """
            INSERT INTO record_log_epoch_counts (doc_id, epoch, count) VALUES (?, ?, 1)
              ON CONFLICT (doc_id, epoch) DO UPDATE SET count = count + 1
            """,
            [doc, .integer(Int64(e))]
        )
    }

    func pendingInEpoch(_ e: Int) throws -> Int {
        if let n = epochPending?[e] { return n }
        let n = try sql.first(
            "SELECT COUNT(*) AS n FROM record_log_pending WHERE doc_id = ? AND void = 0 AND e = ?", [doc, .integer(Int64(e))]
        )?["n"].intValue ?? 0
        if epochPending != nil { epochPending?[e] = n }
        return n
    }

    /// Run `body` counting each epoch's pending entries once: a commit's
    /// writes each check the budget, and inside one transaction only they
    /// change the count. Any other change to the pending log counts again.
    func countingEpochs<T>(_ body: () throws -> T) rethrows -> T {
        epochPending = [:]
        defer { epochPending = nil }
        return try body()
    }
}

/// Whether a purge keeps the device's index policy for the document (#5322):
/// an evict keeps it, the document's deletion clears it.
enum RecordLogPurgePolicy: Sendable, Equatable {
    case keep
    case clear
}

/// One format-3 document's store, for one client of the database.
///
/// `@unchecked Sendable`: its one mutable member, `tables` (the bound
/// connection and the results held ahead of the cursor), is touched only
/// inside a call on the provider's serial queue (``RecordLogGroupCommitHost/withRecordLogConnection(_:)``
/// or ``Format2SqlHost/withConnection(_:)``), which is the lock.
final class RecordLogStore: @unchecked Sendable {
    let host: any Format2SqlHost
    let documentId: String
    let clientId: String
    /// The client's default for the device indexes it has not built yet (#5322).
    let deviceIndexes: Db3DeviceIndexes
    let logger: Logger?
    private let group: RecordLogGroupCommit
    private let tables: SqlRecordLogTables

    /// Where the view's order puts the records only a guess holds, and after them those a guess creates.
    private static let guessHeld = 1 << 50
    private static let guessCreated = 1 << 51

    init(host: any Format2SqlHost, documentId: String, clientId: String, logger: Logger? = nil, deviceIndexes: Db3DeviceIndexes = .all) {
        self.host = host
        self.logger = logger
        self.documentId = documentId
        self.clientId = clientId
        self.deviceIndexes = deviceIndexes
        self.group = (host as? any RecordLogGroupCommitHost)?.recordLogGroupCommit ?? RecordLogGroupCommit()
        self.tables = SqlRecordLogTables(docId: documentId, logger: logger)
    }

    private var doc: Format2SqlValue { .text(documentId) }

    // MARK: - Running on the connection

    /// Run `body` on the connection, joining an open group without closing it.
    private func onConnection<T>(_ body: (RecordLogSql) throws -> T) throws -> T {
        let run = { (connection: any Format2SqlConnection) throws -> T in
            let sql = RecordLogSql(connection: connection)
            let outer = self.tables.sql
            self.tables.sql = sql
            defer { self.tables.sql = outer }
            return try body(sql)
        }
        if let groupHost = host as? any RecordLogGroupCommitHost {
            return try groupHost.withRecordLogConnection(run)
        }
        return try host.withConnection(run)
    }

    /// A read: no transaction; it sees what the open group has written.
    func reading<T>(_ body: (RecordLogSql) throws -> T) throws -> T {
        try onConnection { sql in try group.read { try body(sql) } }
    }

    /// Run a read of the view (``RecordLogViewReader``) on this store's
    /// connection, in one read transaction (#5221): a deferred `BEGIN` …
    /// `COMMIT` of its own when nothing is open on the connection, else the
    /// open group's or transaction's, whose writes it sees. A nested call
    /// joins the outer one, so a page's rows, include legs and sync state are
    /// one snapshot.
    func readView<T>(_ body: (RecordLogSql) throws -> T) throws -> T {
        try onConnection { sql in try group.readTransaction(sql.connection) { try body(sql) } }
    }

    /// The connection's group commit, for a test that holds a group open.
    var groupCommitForTest: RecordLogGroupCommit { group }

    /// A test's turn between a vector command's read of an entry and its use
    /// (#5230): an install's check, a fill slice's read and a `$near`'s
    /// judgement of its index run before it, the install's and the slice's
    /// writes and the `$near`'s statement after, so an index list the test
    /// applies here lands where one applied by another task may.
    var vectorEntryReadForTest: (() throws -> Void)?

    // MARK: - Live

    /// Whether this client's session of the document is open now (#5221):
    /// a device read's drift is `live` only then. Kept per host and document,
    /// so a read over several documents of one host asks each.
    var isLive: Bool { RecordLogLiveness.isLive(host, documentId) }

    /// Mark the document's session open (`true`) or not.
    func setLive(_ live: Bool) { RecordLogLiveness.set(host, documentId, live) }

    // MARK: - Sync state

    /// Each of `documents`' sync state (#5221), in one statement: its cursor,
    /// the room's head as last heard and when, its unjudged writes (every
    /// writer's, as ``storedState()`` counts them) and whether it lives only
    /// on this device; a document with no state reads as one with nothing
    /// heard. Run inside a reader's ``readView(_:)`` it is that read's.
    static func documentSync(_ sql: RecordLogSql, _ documents: [String]) throws -> [String: RecordLogDocumentSync] {
        var out: [String: RecordLogDocumentSync] = [:]
        for documentId in documents {
            out[documentId] = RecordLogDocumentSync(cursor: 0, knownHead: nil, knownHeadAt: nil, pendingWrites: 0, localOnly: false)
        }
        guard !documents.isEmpty else { return out }
        let list = RecordLogJSON.text(.array(documents.map { .string($0) }))
        for row in try sql.rows(
            """
            SELECT s.doc_id AS doc_id, s.cursor AS cursor, s.known_head AS known_head, s.known_head_at AS known_head_at,
                   s.local_only AS local_only,
                   (SELECT COUNT(p.seq) FROM record_log_writers w
                      JOIN record_log_pending p ON p.doc_id = w.doc_id AND p.writer = w.writer
                     WHERE w.doc_id = s.doc_id) AS pending
              FROM record_log_state s
             WHERE s.doc_id IN (SELECT value FROM json_each(?))
            """,
            [.text(list)]
        ) {
            guard let documentId = row["doc_id"].stringValue else { continue }
            let head = row["known_head"].intValue
            out[documentId] = RecordLogDocumentSync(
                cursor: row["cursor"].intValue ?? 0, knownHead: head,
                knownHeadAt: head == nil ? nil : row["known_head_at"].intValue.map { Int64($0) },
                pendingWrites: row["pending"].intValue ?? 0, localOnly: row["local_only"].intValue == 1
            )
        }
        return out
    }

    /// A command that is not a save: the open group commits first.
    func command<T>(_ body: (RecordLogSql) throws -> T) throws -> T {
        try onConnection { sql in try group.command(sql.connection) { try body(sql) } }
    }

    /// A save: it joins the connection's group of saves.
    func save<T>(listener: RecordLogGroupCommit.Listener? = nil, _ body: (RecordLogSql) throws -> T) throws -> T {
        try onConnection { sql in try group.save(sql.connection, listener: listener) { try body(sql) } }
    }

    /// Commit the open group of saves now.
    func flush() throws {
        try onConnection { sql in group.flush(on: sql.connection) }
    }

    // MARK: - Tables and identity

    /// Create the record-log tables and bring the store to
    /// ``RecordLogSchema/storageVersion``, holding the provider's queue once
    /// for the whole open. Idempotent.
    ///
    /// A store at or above the version is answered by one read of its version
    /// and one `sqlite_master` probe for the projection rule table an older
    /// build creates on every open and the staged replacement's base table
    /// (#4701, added with no version change): when neither says otherwise,
    /// nothing else runs; when one does, one transaction creates the tables
    /// and retires the layout, and the version is left as it is (a newer
    /// build's is never lowered).
    ///
    /// A store below the version takes one transaction to create the tables
    /// and retire the projection layout an older build kept
    /// (``retireProjection(_:)``), with every record kept; then each document
    /// that still holds a row as JSON text is converted in a transaction of
    /// its own, in `doc_id` order (``convertDocument(_:_:)``), and the version
    /// is written last, in one more. A row's own SQLite type is its marker
    /// (text is unconverted, a blob is done), so nothing else is written and
    /// the store does not grow; a conversion interrupted between two documents
    /// resumes at the next open with the documents still holding text. An
    /// older build opening a store at the version is not refused: its layout
    /// is retired again at the next open, and a row it wrote as text reads as
    /// any other and is stored as JSONB when it is next written. A store at
    /// version 3 has nothing to convert: the first transaction adds the
    /// local-only columns (#5155) and the version is written after it, every
    /// db3 it holds reading synced.
    func initialize() throws {
        try onConnection { sql in
            guard let opened = try group.command(sql.connection, { try openTables(sql) }) else { return }
            var parts: [String] = []
            if let pending = opened.pending {
                for documentId in pending {
                    try group.command(sql.connection) { try convertDocument(sql, documentId) }
                }
                let rows = try group.command(sql.connection) { () -> Int in
                    let changes = try sql.first("SELECT total_changes() AS n")?["n"].intValue ?? 0
                    try sql.exec(
                        """
                        INSERT INTO record_log_meta (key, value) VALUES ('storage_version', ?)
                          ON CONFLICT (key) DO UPDATE SET value = excluded.value
                        """,
                        [.text(String(RecordLogSchema.storageVersion))]
                    )
                    // Every change since the documents were listed: each one a row re-encoded.
                    return changes - opened.changes
                }
                if !pending.isEmpty || opened.resumed > 0 {
                    parts.append(
                        "\(pending.count) document(s), \(rows) row(s) re-encoded as JSONB without id"
                            + (opened.resumed > 0 ? " (resumed; \(opened.resumed) already converted)" : "")
                    )
                }
            }
            if !opened.dropped.isEmpty {
                parts.append("dropped \(opened.dropped.joined(separator: ", ")); a db3's rows live in its view")
            }
            if !parts.isEmpty {
                let version = max(opened.version ?? 0, RecordLogSchema.storageVersion)
                logger?.log("[record-log] the local store was migrated to storage version \(version):", parts.joined(separator: "; "))
            }
        }
    }

    /// What the first transaction of an open did to a store not answered by
    /// the fast path.
    private struct OpenedTables {
        /// The version the store was at, or `nil` for one without it.
        var version: Int?
        /// What ``retireProjection(_:)`` dropped.
        var dropped: [String]
        /// The documents still to convert, in `doc_id` order; `nil` when the
        /// store is at or above the version.
        var pending: [String]?
        /// The documents an interrupted conversion already converted.
        var resumed: Int
        /// The connection's `total_changes()` once the documents were listed.
        var changes: Int
    }

    /// The first transaction of an open: `nil` on the fast path, else the
    /// tables created, the projection layout retired, and the documents a
    /// store below the version has still to convert.
    private func openTables(_ sql: RecordLogSql) throws -> OpenedTables? {
        let version = (try? sql.first(
            "SELECT value FROM record_log_meta WHERE key = 'storage_version'"
        ))??["value"].intValue
        // One probe: an older build's projection rule, and the staged
        // replacement's base table a store from before #4701 lacks (its
        // `staged` column is added with it).
        let probed = Set(try sql.rows(
            """
            SELECT name FROM sqlite_master WHERE type = 'table'
               AND name IN ('record_log_projection_rule', 'record_log_staged_base')
            """
        ).compactMap { $0["name"].stringValue })
        let olderBuildWasHere = probed.contains("record_log_projection_rule")
        let current = (version ?? 0) >= RecordLogSchema.storageVersion
        if current && !olderBuildWasHere && probed.contains("record_log_staged_base") { return nil }
        for statement in RecordLogSchema.ddl { try sql.connection.executeScript(statement) }
        for added in RecordLogSchema.addedColumns {
            let has = try sql.first(
                "SELECT 1 AS present FROM pragma_table_info(?) WHERE name = ?", [.text(added.table), .text(added.column)]
            ) != nil
            if !has { try sql.connection.executeScript(added.add) }
        }
        try RecordLogSchema.rebuildIndexCache(sql.connection)
        let dropped = try retireProjection(sql)
        guard !current else { return OpenedTables(version: version, dropped: dropped, pending: nil, resumed: 0, changes: 0) }
        // From version 3 every row is JSONB already: the steps to 4 through
        // 9 are the local-only columns (#5155), the member table's name
        // (#5156), the index cache keyed by kind (#5223), the head as last
        // heard (#5221), the index policy (#5322) and the vector entry's flat
        // table (#5230) the statements above made.
        if (version ?? 0) >= RecordLogSchema.jsonbVersion {
            return OpenedTables(version: version, dropped: dropped, pending: [], resumed: 0, changes: 0)
        }
        // A document holding a text row is still to convert; one holding
        // only blobs was converted by an earlier open that was interrupted.
        var pending: [String] = []
        var resumed = 0
        for row in try sql.rows(
            """
            SELECT doc_id, MAX(encoding = 'text') AS text FROM (
              SELECT doc_id, typeof(_data) AS encoding FROM record_log_rows
              UNION ALL SELECT doc_id, typeof(_data) FROM record_log_view
              UNION ALL SELECT doc_id, typeof(_data) FROM record_log_staged_base
            ) WHERE encoding IN ('text', 'blob') GROUP BY doc_id ORDER BY doc_id
            """
        ) {
            guard let documentId = row["doc_id"].stringValue else { continue }
            if row["text"].intValue == 1 { pending.append(documentId) } else { resumed += 1 }
        }
        let changes = try sql.first("SELECT total_changes() AS n")?["n"].intValue ?? 0
        return OpenedTables(version: version, dropped: dropped, pending: pending, resumed: resumed, changes: changes)
    }

    /// Bring one document's rows to the storage version, in the caller's
    /// transaction: every `_data` an older build wrote as JSON text with `id`
    /// (confirmed, view and staged base rows) becomes JSONB without it. A row
    /// whose `id` the key does not hold whole (``RecordLogJSON/stored(_:)``)
    /// keeps it. A row already JSONB, and a staged base's NULL, are left as
    /// they are.
    private func convertDocument(_ sql: RecordLogSql, _ documentId: String) throws {
        let doc = Format2SqlValue.text(documentId)
        for table in ["record_log_rows", "record_log_view", "record_log_staged_base"] {
            try sql.exec(
                """
                UPDATE \(table) SET _data = jsonb(CASE WHEN json_extract(_data, '$.id') IS _id
                  THEN json_remove(_data, '$.id') ELSE _data END) WHERE doc_id = ? AND typeof(_data) = 'text'
                """,
                [doc]
            )
        }
    }

    /// Drop what the query projection kept beside the view (#4700): every
    /// table with a `_meta_doc_id` column (in this database each is a db3's
    /// query table or its string-set junction, since format-1 documents query
    /// an in-memory mirror), the projection marks and rule, and the view
    /// indexes the store built from declarations (`idx_record_log_view_f…`,
    /// `idx_record_log_view_u…`; the store builds its indexes from the room's
    /// list now). Never touches a record. Answers what it dropped.
    private func retireProjection(_ sql: RecordLogSql) throws -> [String] {
        var dropped: [String] = []
        let derived = try sql.rows(
            """
            SELECT m.name AS name FROM sqlite_master m WHERE m.type = 'table'
              AND EXISTS (SELECT 1 FROM pragma_table_info(m.name) WHERE name = '_meta_doc_id')
            """
        ).compactMap { $0["name"].stringValue }
        for table in derived {
            try sql.connection.executeScript("DROP TABLE IF EXISTS \"\(table.replacingOccurrences(of: "\"", with: "\"\""))\"")
            dropped.append(table)
        }
        for table in ["record_log_projection", "record_log_projection_rule"] where try sql.first(
            "SELECT 1 AS present FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)]
        ) != nil {
            try sql.connection.executeScript("DROP TABLE \(table)")
            dropped.append(table)
        }
        let declared = try sql.rows(
            #"SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'record_log_view' "#
                + #"AND (name LIKE 'idx\_record\_log\_view\_f%' ESCAPE '\' OR name LIKE 'idx\_record\_log\_view\_u%' ESCAPE '\')"#
        ).compactMap { $0["name"].stringValue }
        for index in declared {
            try sql.connection.executeScript("DROP INDEX IF EXISTS \"\(index.replacingOccurrences(of: "\"", with: "\"\""))\"")
            dropped.append(index)
        }
        return dropped
    }

    private func tablesExist(_ sql: RecordLogSql) throws -> Bool {
        try sql.first(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text("record_log_state")]
        ) != nil
    }

    /// What the store holds of this document, without creating anything: its
    /// cursor, its view's row count, every writer with unjudged entries, and
    /// the marks residency is read from (``isResident(_:createdLocally:)``).
    func storedState() throws -> RecordLogStoredState {
        try reading { sql in
            guard try tablesExist(sql) else { return RecordLogStoredState(cursor: 0, rows: 0, writers: [], replacing: false) }
            let state = try sql.first("SELECT * FROM record_log_state WHERE doc_id = ?", [doc])
            let count = try sql.first("SELECT COUNT(*) AS n FROM record_log_view WHERE doc_id = ?", [doc])?["n"].intValue ?? 0
            let writers = try sql.rows(
                """
                SELECT w.writer AS writer, w.client_id AS client_id, w.next_seq AS next_seq,
                       MIN(p.seq) AS lowest, COUNT(p.seq) AS pending
                  FROM record_log_writers w JOIN record_log_pending p ON p.doc_id = w.doc_id AND p.writer = w.writer
                 WHERE w.doc_id = ?
                 GROUP BY w.writer, w.client_id, w.next_seq
                 ORDER BY w.writer
                """,
                [doc]
            ).compactMap { row -> RecordLogStoredState.Writer? in
                guard let writer = row["writer"].stringValue, let clientId = row["client_id"].stringValue else { return nil }
                return RecordLogStoredState.Writer(
                    writer: writer, clientId: clientId, nextSeq: row["next_seq"].intValue ?? 1,
                    lowestPending: row["lowest"].intValue ?? 1, pending: row["pending"].intValue ?? 0
                )
            }
            return RecordLogStoredState(
                cursor: try tables.cursor(), rows: count, writers: writers, replacing: try tables.isReplacing(),
                lastCatchUpAt: state?["last_catch_up_at"].intValue.map { Int64($0) }, staged: try tables.staged(),
                localOnly: state?["local_only"].intValue == 1,
                knownHead: state?["known_head"].intValue,
                knownHeadAt: state?["known_head"].intValue == nil ? nil : state?["known_head_at"].intValue.map { Int64($0) }
            )
        }
    }

    private func writerOf(_ sql: RecordLogSql) throws -> String? {
        try sql.first(
            "SELECT writer FROM record_log_writers WHERE doc_id = ? AND client_id = ?", [doc, .text(clientId)]
        )?["writer"].stringValue
    }

    /// This client's writer, or `nil` before one is minted.
    func writer() throws -> String? {
        try reading { sql in try tablesExist(sql) ? try writerOf(sql) : nil }
    }

    /// This client's writer, minted when it has none: a 26-character ULID.
    func mintWriter() throws -> String {
        try command { sql in
            try tables.ensureState()
            if let known = try writerOf(sql) { return known }
            let writer = ULID.generate()
            try sql.exec(
                "INSERT INTO record_log_writers (doc_id, client_id, writer, next_seq, resumed_at) VALUES (?, ?, ?, 1, 0)",
                [doc, .text(clientId), .text(writer)]
            )
            return writer
        }
    }

    /// Replace a writer the room no longer knows: a new writer id takes the old
    /// one's client, its unacknowledged entries are renumbered from 1 in `seq`
    /// order (their epochs, cursors and order kept), and its void markers and
    /// the refusals it acted on are dropped, since the room never saw the new id.
    func remintWriter(_ old: String) throws -> (writer: String, renumbered: [(from: Int, to: Int)]) {
        try command { sql in
            let fresh = ULID.generate()
            var renumbered: [(from: Int, to: Int)] = []
            let pending = try tables.pending(old)
            for entry in pending where entry.isVoid { try tables.deletePending(old, entry.seq) }
            _ = tables.takeDirty()
            var next = 1
            for entry in pending {
                // An acknowledged entry is the room's already; it settles when the
                // cursor passes its result, under the id it was acknowledged for.
                if entry.isVoid || entry.acked != nil { continue }
                var moved = entry
                moved.seq = next
                moved.acked = nil
                moved.alias = nil
                try sql.exec(
                    "UPDATE record_log_pending SET writer = ?, seq = ?, entry = ?, acked = NULL WHERE doc_id = ? AND writer = ? AND seq = ?",
                    [.text(fresh), .integer(Int64(next)), .text(RecordLogJSON.text(moved.storedJSON)), doc, .text(old), .integer(Int64(entry.seq))]
                )
                for table in ["record_log_pending_keys", "record_log_pending_values"] {
                    try sql.exec(
                        "UPDATE \(table) SET writer = ?, seq = ? WHERE doc_id = ? AND writer = ? AND seq = ?",
                        [.text(fresh), .integer(Int64(next)), doc, .text(old), .integer(Int64(entry.seq))]
                    )
                }
                renumbered.append((entry.seq, next))
                next += 1
            }
            try sql.exec("DELETE FROM record_log_handled WHERE doc_id = ? AND writer = ?", [doc, .text(old)])
            try sql.exec(
                "UPDATE record_log_writers SET writer = ?, next_seq = ?, resumed_at = 0 WHERE doc_id = ? AND writer = ?",
                [.text(fresh), .integer(Int64(next)), doc, .text(old)]
            )
            return (fresh, renumbered)
        }
    }

    /// Remove everything the store keeps of this document: its rows, view,
    /// unjudged entries, writers, epoch counts and cached index list. Refused
    /// while it holds unjudged writes, unless `force`; a forced purge answers
    /// what it dropped. The device's index policy for the document is kept
    /// (#5322), so an evict keeps a decline; `policy: .clear` removes it too,
    /// as the document's deletion does.
    func purge(force: Bool, policy: RecordLogPurgePolicy = .keep) throws -> RecordLogPurgeReply {
        // A store an older build wrote lacks tables the purge clears.
        if try reading({ try tablesExist($0) }) { try initialize() }
        return try command { sql in
            guard try tablesExist(sql) else {
                return RecordLogPurgeReply(purged: true, nothingStored: true, pendingOps: 0, handedBack: [])
            }
            let live = try sql.rows(
                "SELECT entry FROM record_log_pending WHERE doc_id = ? AND void = 0 AND acked IS NULL ORDER BY ord", [doc]
            ).compactMap { RecordLogPendingEntry(stored: $0["entry"].stringValue.flatMap(RecordLogJSON.parse)) }
            if !force && !live.isEmpty {
                return RecordLogPurgeReply(purged: false, refusedForPending: true, pendingOps: live.count, handedBack: [])
            }
            let held = try sql.first("SELECT COUNT(*) AS n FROM record_log_state WHERE doc_id = ?", [doc])?["n"].intValue ?? 0
            // Its device tables go first, so deleting its view rows fires no trigger of theirs (#5156, #5223).
            try RecordLogIndexes.dropDeviceTables(sql, documentId: documentId)
            for table in RecordLogSchema.clientTables {
                try sql.exec("DELETE FROM \(table) WHERE doc_id = ?", [doc])
            }
            if policy == .clear, try sql.first("SELECT 1 AS present FROM sqlite_master WHERE type = 'table' AND name = 'record_log_index_policy'") != nil {
                try sql.exec("DELETE FROM record_log_index_policy WHERE doc_id = ?", [doc])
            }
            try tables.forgetType()
            tables.forgetBuffered()
            return RecordLogPurgeReply(
                purged: true, nothingStored: held == 0 && live.isEmpty, pendingOps: live.count, handedBack: live
            )
        }
    }

    /// Everything a binding mirrors, in one read.
    func marks() throws -> RecordLogMarks {
        try reading { sql in try marksOn(sql) }
    }

    private func marksOn(_ sql: RecordLogSql) throws -> RecordLogMarks {
        let epochs = try tables.epochs()
        let state = try sql.first("SELECT * FROM record_log_state WHERE doc_id = ?", [doc])
        let writer = try writerOf(sql)
        let writerState = try writer.map { try tables.writerState($0) }
        let pending = try writer.flatMap { writer in
            try sql.first(
                "SELECT MIN(seq) AS lowest, COUNT(*) AS n FROM record_log_pending WHERE doc_id = ? AND writer = ?",
                [doc, .text(writer)]
            )
        }
        let type = try tables.typeState()
        return RecordLogMarks(
            cursor: try tables.cursor(), open: epochs.open, grant: epochs.grant, entries: epochs.entries,
            constraints: try tables.constraints(),
            permission: state?["permission"].stringValue,
            replacing: try tables.isReplacing(),
            replacement: try tables.replacing(),
            lastCatchUpAt: state?["last_catch_up_at"].intValue.map { Int64($0) },
            writer: writer,
            nextSeq: writerState?.nextSeq ?? 1,
            resumedAt: writerState?.resumedAt ?? 0,
            lowestPending: pending?["lowest"].intValue,
            pending: pending?["n"].intValue ?? 0,
            unacked: try writer.map { try unackedOf(sql, $0) } ?? [],
            receipt: try tables.receipts()?.latestMark,
            segment: try tables.heldSegment(),
            staged: try tables.staged(),
            typed: type.typed,
            db3Type: type.db3Type,
            declarations: type.declarations,
            vectors: type.vectors,
            vectorsKnown: type.vectorsKnown,
            enums: type.enums,
            enumsKnown: type.enumsKnown,
            localOnly: state?["local_only"].intValue == 1,
            localIndexes: try tables.localIndexes(),
            models: try modelsHeld(sql),
            knownHead: state?["known_head"].intValue,
            knownHeadAt: state?["known_head"].intValue == nil ? nil : state?["known_head_at"].intValue.map { Int64($0) }
        )
    }

    /// The models this copy holds, sorted and distinct: those with a view or
    /// confirmed row, and those an unjudged entry of any writer touches. The
    /// view and rows tables are walked model by model on their primary key
    /// (one seek per model), not row by row: the open reads this.
    private func modelsHeld(_ sql: RecordLogSql) throws -> [String] {
        var held = Set<String>()
        for table in ["record_log_view", "record_log_rows"] {
            for row in try sql.rows(
                """
                WITH RECURSIVE t(m) AS (
                  SELECT MIN(_type) FROM \(table) WHERE doc_id = ?
                  UNION ALL SELECT (SELECT MIN(_type) FROM \(table) WHERE doc_id = ? AND _type > t.m) FROM t WHERE t.m IS NOT NULL)
                SELECT m AS _type FROM t WHERE m IS NOT NULL
                """,
                [doc, doc]
            ) {
                if let model = row["_type"].stringValue { held.insert(model) }
            }
        }
        for row in try sql.rows(
            """
            SELECT DISTINCT k._type AS _type FROM record_log_pending p JOIN record_log_pending_keys k
                ON k.doc_id = p.doc_id AND k.writer = p.writer AND k.seq = p.seq
             WHERE p.doc_id = ? AND p.void = 0 AND p.acked IS NULL
            """,
            [doc]
        ) {
            if let model = row["_type"].stringValue { held.insert(model) }
        }
        return held.sorted()
    }

    /// A writer's unacknowledged, unwithdrawn entries and the records each touches.
    private func unackedOf(_ sql: RecordLogSql, _ writer: String) throws -> [(seq: Int, records: [RecordLogRecordKey])] {
        var bySeq = RecordLogOrderedMap<Int, [RecordLogRecordKey]>()
        for row in try sql.rows(
            """
            SELECT p.seq AS seq, k._type AS _type, k._id AS _id
              FROM record_log_pending p JOIN record_log_pending_keys k
                ON k.doc_id = p.doc_id AND k.writer = p.writer AND k.seq = p.seq
             WHERE p.doc_id = ? AND p.writer = ? AND p.void = 0 AND p.acked IS NULL AND k.resolved = 0
             ORDER BY p.seq
            """,
            [doc, .text(writer)]
        ) {
            guard let seq = row["seq"].intValue, let model = row["_type"].stringValue, let id = row["_id"].stringValue else {
                continue
            }
            bySeq[seq] = (bySeq[seq] ?? []) + [RecordLogRecordKey(model: model, id: id)]
        }
        return bySeq.entries.map { ($0.key, $0.value) }
    }

    /// A writer's unjudged entries, in `seq` order: what a resubmission sends.
    func pendingOf(_ writer: String) throws -> [RecordLogPendingEntry] {
        try reading { _ in try tables.pending(writer) }
    }

    /// The confirmed rows of the document, in the order they arrived.
    func confirmedRows() throws -> [RecordLogRow] {
        try reading { sql in
            try sql.rows("SELECT json(_data) AS _data, _id FROM record_log_rows WHERE doc_id = ? ORDER BY rowid", [doc])
                .map { RecordLogJSON.row($0["_data"].stringValue, id: $0["_id"].stringValue) }
        }
    }

    // MARK: - Reads (the view)

    /// A record's view row, or `nil`.
    func read(model: String, id: String) throws -> RecordLogRow? {
        try reading { sql in try viewRow(sql, RecordLogRecordKey(model: model, id: id)) }
    }

    private func viewRow(_ sql: RecordLogSql, _ key: RecordLogRecordKey) throws -> RecordLogRow? {
        try sql.first(
            "SELECT json(_data) AS _data FROM record_log_view WHERE doc_id = ? AND _type = ? AND _id = ?",
            [doc, .text(key.model), .text(key.id)]
        ).map { RecordLogJSON.row($0["_data"].stringValue, id: key.id) }
    }

    /// Several records' view rows, in the order asked for; a missing one is `nil`.
    func readMany(model: String, ids: [String]) throws -> [RecordLogRow?] {
        guard !ids.isEmpty else { return [] }
        return try reading { sql in
            var found: [String: RecordLogRow] = [:]
            let unique = Array(Set(ids))
            for start in stride(from: 0, to: unique.count, by: 500) {
                let slice = Array(unique[start..<min(start + 500, unique.count)])
                let placeholders = slice.map { _ in "?" }.joined(separator: ", ")
                for row in try sql.rows(
                    "SELECT _id, json(_data) AS _data FROM record_log_view WHERE doc_id = ? AND _type = ? AND _id IN (\(placeholders))",
                    [doc, .text(model)] + slice.map { .text($0) }
                ) {
                    if let id = row["_id"].stringValue { found[id] = RecordLogJSON.row(row["_data"].stringValue, id: id) }
                }
            }
            return ids.map { found[$0] }
        }
    }

    /// One page of a model's view rows in id order, after `after`.
    func readRowsAfter(model: String, after: String?, limit: Int) throws -> [RecordLogRow] {
        try reading { sql in
            let rows: [Format2SqlRow]
            if let after {
                rows = try sql.rows(
                    "SELECT json(_data) AS _data, _id FROM record_log_view WHERE doc_id = ? AND _type = ? AND _id > ? ORDER BY _id LIMIT ?",
                    [doc, .text(model), .text(after), .integer(Int64(limit))]
                )
            } else {
                rows = try sql.rows(
                    "SELECT json(_data) AS _data, _id FROM record_log_view WHERE doc_id = ? AND _type = ? ORDER BY _id LIMIT ?",
                    [doc, .text(model), .integer(Int64(limit))]
                )
            }
            return rows.map { RecordLogJSON.row($0["_data"].stringValue, id: $0["_id"].stringValue) }
        }
    }

    /// One page of a model's record ids in id order, after `after`.
    func recordIdsAfter(model: String, after: String?, limit: Int) throws -> [String] {
        try reading { sql in
            let rows: [Format2SqlRow]
            if let after {
                rows = try sql.rows(
                    "SELECT _id FROM record_log_view WHERE doc_id = ? AND _type = ? AND _id > ? ORDER BY _id LIMIT ?",
                    [doc, .text(model), .text(after), .integer(Int64(limit))]
                )
            } else {
                rows = try sql.rows(
                    "SELECT _id FROM record_log_view WHERE doc_id = ? AND _type = ? ORDER BY _id LIMIT ?",
                    [doc, .text(model), .integer(Int64(limit))]
                )
            }
            return rows.compactMap { $0["_id"].stringValue }
        }
    }

    /// The id of the first live record of `model` in the view whose `fields` hold `values`.
    func findIdByFields(model: String, fields: [String], values: [JSONValue]) throws -> String? {
        try reading { sql in
            try Self.findHolders(
                sql, table: "record_log_view", docId: documentId, model: model, fields: fields,
                values: values, excluding: [], limitToFirst: true
            ).first
        }
    }

    /// The live records of `model` in `table` (by id) whose `fields` hold
    /// `values`, not one of `excluding`. A field named `id` is the record's
    /// key (`_id`): `_data` does not hold it.
    static func findHolders(
        _ sql: RecordLogSql, table: String, docId: String, model: String, fields: [String],
        values: [JSONValue], excluding: [String], limitToFirst: Bool
    ) throws -> [String] {
        guard !fields.isEmpty, !values.contains(.null) else { return [] }
        let literal = RecordLogSchema.isValidIdentifier(model) && fields.allSatisfy(RecordLogSchema.isValidIdentifier)
        var bindings: [Format2SqlValue] = [.text(docId)]
        var predicates: [String]
        if literal {
            predicates = ["_type = \(RecordLogSchema.quoteLiteral(model))"]
            for (field, value) in zip(fields, values) {
                predicates.append(field == "id" ? "_id IS ?" : "json_extract(_data, '$.\(field)') IS ?")
                bindings.append(.recordLogLookup(value))
            }
        } else {
            predicates = ["_type = ?"]
            bindings.append(.text(model))
            for (field, value) in zip(fields, values) {
                if field == "id" {
                    predicates.append("_id IS ?")
                } else {
                    predicates.append("json_extract(_data, '$.' || ?) IS ?")
                    bindings.append(.text(field))
                }
                bindings.append(.recordLogLookup(value))
            }
        }
        var query = "SELECT _id FROM \(table) WHERE doc_id = ? AND \(predicates.joined(separator: " AND ")) ORDER BY _id"
        if limitToFirst {
            query += " LIMIT ?"
            bindings.append(.integer(Int64(Set(excluding).count + 1)))
        }
        return try sql.rows(query, bindings).compactMap { $0["_id"].stringValue }.filter { !excluding.contains($0) }
    }

    /// The records of `model` in the view matching `filter`, one page of
    /// them, as stored: the model API's filter grammar on any field, declared
    /// or not, answered by the statement the room runs for the same filter
    /// (``RecordLogViewReader``). `options` sorts (`sortOrder`, else `sort`;
    /// `id`, then the document, break ties), pages (`limit` from 1 to 10,000,
    /// 100 when none is sent, a page ending before the record that would take
    /// it past 8 MiB; `hasMore` exact; `cursor` and `direction`, a backward page
    /// answered in sort order), keeps or drops row keys (`projection`, `id`
    /// always kept) and scopes (`documents`: `nil` or a list naming this
    /// document; any other answers no rows). A `limit` outside its range, or a
    /// model or field name that is not an identifier, throws
    /// `JsBaoError(.invalidArgument)` before any SQL runs; a cursor minted under
    /// another sort throws `InvalidCursorError`.
    func queryView(_ model: String, _ filter: DocumentFilter = [:], options: QueryOptions? = nil) throws
        -> PagedQueryResult<RecordLogRow>
    {
        let page = try RecordLogViewReader(store: self, documents: scope(options?.documentScope()))
            .page(model, filter, options: options, shape: .stored)
        return PagedQueryResult(
            data: page.rows, nextCursor: page.nextCursor, prevCursor: page.prevCursor, hasMore: page.hasMore, drift: page.drift
        )
    }

    /// How many records of `model` in the view match `filter`, as
    /// ``queryView(_:_:options:)`` matches them, in the `documents` scope;
    /// with `maxDrift`, refused `DB3_DRIFT_EXCEEDED` as a page is (#5221).
    func countView(_ model: String, _ filter: DocumentFilter = [:], documents: [String]? = nil, maxDrift: Db3MaxDrift? = nil) throws -> Int {
        try RecordLogViewReader(store: self, documents: scope(documents)).count(model, filter, maxDrift: maxDrift)
    }

    /// Explain a read of `model` over this document's copy (#5241): the read
    /// `request` describes, run for real and forced as `request.index` asks,
    /// with SQLite's plan of each statement and the registry indexes it used,
    /// in the server explain's shape (``RecordLogExplain``). The root model's
    /// set fields are `request.setFields` when given, else the ones the
    /// room-sent declarations of a typed db3 give it. Nothing is written.
    func explainView(_ model: String, _ request: Db3ExplainRequest) throws -> Db3Explain {
        let setFields: Set<String>
        if let given = request.setFields {
            setFields = Set(given)
        } else {
            let declared = try reading { _ in try tables.typeState().declarations?[model] } ?? [:]
            setFields = Set(declared.filter { $0.value == "stringset" }.keys)
        }
        return try RecordLogExplain.explain(store: self, model: model, request: request, setFields: setFields)
    }

    /// This document, when a read's `documents` scope admits it.
    private func scope(_ documents: [String]?) -> [String] {
        documents.map { $0.contains(documentId) ? [documentId] : [] } ?? [documentId]
    }

    // MARK: - Indexes from the room's list

    /// Cache `entries` as this document's index list and reconcile the store's
    /// view indexes and member tables over every document's cached list
    /// (``RecordLogIndexes``); `nil` reconciles from the cache. The cache and
    /// the drops are one command; each build is a command of its own, so a
    /// build that fails (a full disk) loses only itself (#5322). When it built
    /// a member table, the store gathers statistics in another, once it has
    /// committed (#5156).
    @discardableResult
    func syncIndexes(_ entries: [RecordLogIndexEntry]?) throws -> RecordLogIndexSync {
        let (sync, built) = try RecordLogIndexes.sync(
            documentId: documentId, entries, deviceIndexes: deviceIndexes, logger: logger,
            transaction: { body in try command { sql in try body(sql) } }
        )
        if built {
            do {
                if try reading({ try RecordLogIndexes.populated($0) }) {
                    _ = try command { sql in RecordLogIndexes.gatherStatistics(sql, logger: logger) }
                }
            } catch {
                logger?.warn("[record-log] statistics for the member indexes were not gathered: \(error.localizedDescription)")
            }
        }
        return sync
    }

    /// Each index the document's room places on this device, with how it
    /// stands here (#5322): `built`, `unbuilt` (with why) or `declined` (with why).
    func localIndexes() throws -> [Db3LocalIndex] {
        try readView { sql in try RecordLogIndexes.statuses(sql, documentId: documentId, deviceIndexes: deviceIndexes) }
    }

    /// Each entry of the document's room's list this copy skipped when it
    /// last applied it, with why (#5241): what ``localIndexes()`` does not list.
    func localIndexSkips() throws -> [Db3SkippedIndex] {
        try readView { sql in try RecordLogIndexes.skips(sql, documentId: documentId) }
    }

    /// Decline the index the room names `name` on this device (#5322): its
    /// verdict is kept by its identity `(model, fields, kind)` and its table
    /// or index dropped; it is not built again until accepted. Declining it
    /// again changes nothing. The room's registry is not told.
    ///
    /// - Throws: `.db3IndexNotFound` for a name placed on no device here; `.db3LocalOnly` on a db3 that lives only here.
    func declineIndex(_ name: String) throws -> Db3LocalIndex {
        if try readView({ try RecordLogIndexes.verdict($0, documentId: documentId, name: name) }) == "declined" {
            return try readView { try RecordLogIndexes.status($0, documentId: documentId, name: name, deviceIndexes: deviceIndexes) }
        }
        try command { sql in try RecordLogIndexes.writeVerdict(sql, documentId: documentId, name: name, verdict: "declined") }
        try syncIndexes(nil)
        logger?.log("[record-log] \(documentId): index \(name) declined on this device")
        return try readView { try RecordLogIndexes.status($0, documentId: documentId, name: name, deviceIndexes: deviceIndexes) }
    }

    /// Accept the index the room names `name` on this device (#5322): its
    /// verdict becomes `accepted`, whatever left it unbuilt, and it is built
    /// when it is not. A build that fails answers `unbuilt` with why; an index
    /// already built answers `built` and nothing is rebuilt.
    ///
    /// - Throws: As ``declineIndex(_:)``.
    func acceptIndex(_ name: String) throws -> Db3LocalIndex {
        let was = try readView { try RecordLogIndexes.verdict($0, documentId: documentId, name: name) }
        try command { sql in try RecordLogIndexes.writeVerdict(sql, documentId: documentId, name: name, verdict: "accepted") }
        let status = try readView { try RecordLogIndexes.status($0, documentId: documentId, name: name, deviceIndexes: deviceIndexes) }
        if status.status != .built { try syncIndexes(nil) }
        if was != "accepted" { logger?.log("[record-log] \(documentId): index \(name) accepted on this device") }
        return try readView { try RecordLogIndexes.status($0, documentId: documentId, name: name, deviceIndexes: deviceIndexes) }
    }

    /// `reply`, once statistics were gathered if the view has grown past its
    /// mark (``gatherStatisticsIfGrown()``): the catch-up, load and segment
    /// commands grow a synced db3's view as a local commit grows a local-only
    /// one's (#5223, js-bao's `statisticsAfter`). Called after the command's
    /// transaction, never inside it.
    private func statisticsAfter<T>(_ reply: T) -> T {
        gatherStatisticsIfGrown()
        return reply
    }

    /// Gather statistics once the view has grown past its mark, in a store
    /// holding a member index (#5156): one cheap read, and a command of its
    /// own (the open group of saves commits first) only when they are due.
    /// Never throws.
    private func gatherStatisticsIfGrown() {
        do {
            guard try reading({ try RecordLogIndexes.statisticsDue($0) }) else { return }
            _ = try command { sql in RecordLogIndexes.gatherStatistics(sql, logger: logger) }
        } catch {
            logger?.warn("[record-log] the member indexes' statistics were not gathered: \(error.localizedDescription)")
        }
    }

    /// The store's view indexes as the room lists its own, sorted by model, then fields.
    func indexTuples() throws -> [RecordLogIndexTuple] {
        try reading { sql in try RecordLogIndexes.tuples(sql) }
    }

    // MARK: - The view

    /// Rewrite the view rows of `keys` and of every record an unjudged entry
    /// touching them also touches: the confirmed row (or, while a staged
    /// replacement is in progress, the previous generation's row of a record
    /// it rewrote: ``SqlRecordLogTables/viewBase()``), then every such
    /// unwithdrawn entry's guess in the order they were written. Answers the
    /// records whose view row changed.
    ///
    /// An upsert's guess lands on whichever record holds its value first in
    /// the view's order, so it depends on every record that holds its value or
    /// is written it. A refresh takes in each unjudged upsert whose value a
    /// refreshed record's confirmed or view row holds or a refreshed entry
    /// writes, and with it every record holding that value and every entry
    /// writing it; a guess that resolves outside the records refreshed starts
    /// the refresh again with that record in it.
    private func refreshView(_ sql: RecordLogSql, _ keys: [RecordLogRecordKey]) throws -> [RecordLogRecordKey] {
        guard !keys.isEmpty else { return [] }
        let base = try tables.viewBase()
        var seeds = keys
        while true {
            var closure = RecordLogOrderedMap<RecordLogRecordKey, Bool>()
            var entries = RecordLogOrderedMap<RecordLogEntryRef, Bool>()
            var probed = Set<ProbeKey>()
            var queue: [RecordLogEntryRef] = []

            func queueRows(_ rows: [Format2SqlRow]) {
                for row in rows {
                    if let writer = row["writer"].stringValue, let seq = row["seq"].intValue {
                        queue.append(RecordLogEntryRef(writer: writer, seq: seq))
                    }
                }
            }
            // The unjudged upserts of `model` on `field` whose value is `value`
            // (as kept); every one on `field` when the value is not known.
            func probe(_ model: String, _ field: String, _ value: Format2SqlValue) throws {
                guard probed.insert(ProbeKey(kind: "upsert", model: model, field: field, value: value)).inserted else { return }
                if value.isNull {
                    queueRows(try sql.rows(
                        "SELECT writer, seq FROM record_log_pending_values WHERE doc_id = ? AND _type = ? AND field = ? AND upsert = 1",
                        [doc, .text(model), .text(field)]
                    ))
                } else {
                    queueRows(try sql.rows(
                        "SELECT writer, seq FROM record_log_pending_values WHERE doc_id = ? AND _type = ? AND field = ? AND upsert = 1 AND value = ?",
                        [doc, .text(model), .text(field), value]
                    ))
                }
            }
            // Every record that may hold `value` in `field` when an upsert on it
            // is guessed: one whose confirmed or view row holds it, and one an
            // unjudged entry writes it (or a string-set change) to.
            func holders(_ model: String, _ field: String, _ value: Format2SqlValue) throws {
                guard probed.insert(ProbeKey(kind: "held", model: model, field: field, value: value)).inserted else { return }
                let json = Self.jsonOf(value)
                for table in ["record_log_rows", "record_log_view"] {
                    for id in try Self.findHolders(
                        sql, table: table, docId: documentId, model: model, fields: [field], values: [json],
                        excluding: [], limitToFirst: false
                    ) {
                        try add(RecordLogRecordKey(model: model, id: id))
                    }
                }
                queueRows(try sql.rows(
                    """
                    SELECT writer, seq FROM record_log_pending_values
                     WHERE doc_id = ? AND _type = ? AND field = ? AND upsert IN (0, 1) AND (value = ? OR value IS NULL)
                    """,
                    [doc, .text(model), .text(field), value]
                ))
            }
            func add(_ key: RecordLogRecordKey) throws {
                guard !closure.contains(key) else { return }
                closure[key] = true
                queueRows(try sql.rows(
                    "SELECT writer, seq FROM record_log_pending_keys WHERE doc_id = ? AND _type = ? AND _id = ?",
                    [doc, .text(key.model), .text(key.id)]
                ))
                for row in [try base(key), try viewRow(sql, key)] {
                    for (field, value) in (row ?? [:]).sorted(by: { $0.key < $1.key }) where value != .null {
                        try probe(key.model, field, Format2SqlValue.recordLogWritten(value).recordLogNormalized)
                    }
                }
            }

            for key in seeds { try add(key) }
            while let ref = queue.popLast() {
                guard !entries.contains(ref) else { continue }
                entries[ref] = true
                for written in try sql.rows(
                    "SELECT _type, field, value, upsert FROM record_log_pending_values WHERE doc_id = ? AND writer = ? AND seq = ?",
                    [doc, .text(ref.writer), .integer(Int64(ref.seq))]
                ) {
                    guard let model = written["_type"].stringValue, let field = written["field"].stringValue else { continue }
                    let value = written["value"].recordLogNormalized
                    try probe(model, field, value)
                    if written["upsert"].intValue == 1 && !value.isNull { try holders(model, field, value) }
                }
                for other in try sql.rows(
                    "SELECT _type, _id FROM record_log_pending_keys WHERE doc_id = ? AND writer = ? AND seq = ?",
                    [doc, .text(ref.writer), .integer(Int64(ref.seq))]
                ) {
                    if let model = other["_type"].stringValue, let id = other["_id"].stringValue {
                        try add(RecordLogRecordKey(model: model, id: id))
                    }
                }
            }

            let working = try guessView(sql, closure: closure.keys, entries: entries.keys, base: base)
            let outside = working.resolved.filter { !closure.contains($0) }
            if outside.isEmpty { return try writeView(sql, working.rows) }
            seeds.append(contentsOf: outside)
        }
    }

    /// What a probe was asked for, so each is asked once per refresh.
    private struct ProbeKey: Hashable {
        var kind: String
        var model: String
        var field: String
        var value: String

        init(kind: String, model: String, field: String, value: Format2SqlValue) {
            self.kind = kind
            self.model = model
            self.field = field
            switch value {
            case .null: self.value = "n"
            case .text(let text): self.value = "t" + text
            case .integer(let number): self.value = "i\(number)"
            case .real(let number): self.value = "r\(number)"
            case .blob(let bytes): self.value = "b" + bytes.map { String(format: "%02x", $0) }.joined()
            }
        }
    }

    private static func jsonOf(_ value: Format2SqlValue) -> JSONValue {
        switch value {
        case .null: return .null
        case .text(let text): return .string(text)
        case .integer(let number): return .number(Double(number))
        case .real(let number): return .number(number)
        // A record's values are JSON: no pending value is bytes.
        case .blob: return .null
        }
    }

    /// A record's place in the view's order: its confirmed row's, or, for a
    /// record only a guess holds, after every confirmed row in the order its
    /// entries were written.
    private func viewOrder(_ sql: RecordLogSql, _ key: RecordLogRecordKey) throws -> Int {
        if let row = try sql.first(
            "SELECT rowid AS at FROM record_log_rows WHERE doc_id = ? AND _type = ? AND _id = ?",
            [doc, .text(key.model), .text(key.id)]
        ), let at = row["at"].intValue {
            return at
        }
        let pending = try sql.first(
            """
            SELECT MIN(p.ord) AS ord FROM record_log_pending p JOIN record_log_pending_keys k
                ON k.doc_id = p.doc_id AND k.writer = p.writer AND k.seq = p.seq
             WHERE p.doc_id = ? AND k._type = ? AND k._id = ?
            """,
            [doc, .text(key.model), .text(key.id)]
        )
        return Self.guessHeld + (pending?["ord"].intValue ?? 0)
    }

    /// The table a refresh guesses over: the closure's confirmed rows, and view
    /// rows of anything else a guess reaches.
    private final class WorkingTable: RecordLogRowTable {
        let store: RecordLogStore
        let sql: RecordLogSql
        var rows = RecordLogOrderedMap<RecordLogRecordKey, RecordLogRow?>()
        var placed: [RecordLogRecordKey: Int] = [:]
        var appended = 0

        init(store: RecordLogStore, sql: RecordLogSql) {
            self.store = store
            self.sql = sql
        }

        func place(_ key: RecordLogRecordKey) throws -> Int {
            if let at = placed[key] { return at }
            let at = try store.viewOrder(sql, key)
            placed[key] = at
            return at
        }

        func row(_ key: RecordLogRecordKey) throws -> RecordLogRow? {
            if let held = rows[key] { return held }
            let read = try store.viewRow(sql, key)
            rows[key] = .some(read)
            return read
        }

        func set(_ key: RecordLogRecordKey, _ row: RecordLogRow) throws {
            if try self.row(key) == nil {
                placed[key] = RecordLogStore.guessCreated + appended
                appended += 1
            }
            rows[key] = .some(row)
        }

        func delete(_ key: RecordLogRecordKey) throws {
            rows[key] = .some(nil)
        }

        func holder(model: String, fields: [String], values: [JSONValue], excluding: [String]) throws -> String? {
            var found: [RecordLogRecordKey] = []
            for (key, row) in rows.entries {
                guard let row, key.model == model, !excluding.contains(key.id) else { continue }
                if recordLogHolds(row, fields: fields, values: values) { found.append(key) }
            }
            let skip = excluding + rows.keys.filter { $0.model == model }.map(\.id)
            for id in try RecordLogStore.findHolders(
                sql, table: "record_log_view", docId: store.documentId, model: model, fields: fields,
                values: values, excluding: skip, limitToFirst: false
            ) {
                found.append(RecordLogRecordKey(model: model, id: id))
            }
            guard var first = found.first else { return nil }
            for key in found.dropFirst() where try place(key) < place(first) { first = key }
            return first.id
        }
    }

    /// The rows of `closure` as `base` answers them (the confirmed rows, or a
    /// staged replacement's previous generation) with `entries`' guesses
    /// applied in the order they were written, and every record a guess
    /// resolved to (recorded against its entry, so a later refresh of either
    /// reaches the other).
    private func guessView(
        _ sql: RecordLogSql, closure: [RecordLogRecordKey], entries: [RecordLogEntryRef],
        base: (RecordLogRecordKey) throws -> RecordLogRow?
    ) throws -> (rows: RecordLogOrderedMap<RecordLogRecordKey, RecordLogRow?>, resolved: [RecordLogRecordKey]) {
        let table = WorkingTable(store: self, sql: sql)
        for key in closure { table.rows[key] = .some(try base(key)) }

        var ordered: [(ref: RecordLogEntryRef, ord: Int, entry: RecordLogPendingEntry)] = []
        for ref in entries {
            guard let row = try sql.first(
                "SELECT ord, entry, void, acked FROM record_log_pending WHERE doc_id = ? AND writer = ? AND seq = ?",
                [doc, .text(ref.writer), .integer(Int64(ref.seq))]
            ), row["void"].intValue != 1,
                var entry = RecordLogPendingEntry(stored: row["entry"].stringValue.flatMap(RecordLogJSON.parse))
            else { continue }
            // A guarded entry the room has not acknowledged stays out of the view;
            // its keys stay in the closure, so its acknowledgement's refresh reaches it.
            entry.acked = row["acked"].intValue
            if recordLogGuessHeld(entry) { continue }
            ordered.append((ref, row["ord"].intValue ?? 0, entry))
        }
        ordered.sort { $0.ord < $1.ord }

        var resolved = RecordLogOrderedMap<RecordLogRecordKey, Bool>()
        for (ref, _, entry) in ordered {
            for key in try recordLogApplyGuess(table, entry) {
                resolved[key] = true
                // An upsert resolved to a record its entry does not name: kept, so
                // the next refresh of either reaches the other.
                try sql.exec(
                    "INSERT OR IGNORE INTO record_log_pending_keys (doc_id, writer, seq, _type, _id, resolved) VALUES (?, ?, ?, ?, ?, 1)",
                    [doc, .text(ref.writer), .integer(Int64(ref.seq)), .text(key.model), .text(key.id)]
                )
            }
        }
        return (table.rows, resolved.keys)
    }

    /// Write the working rows into the view; answers the records whose view row changed.
    private func writeView(
        _ sql: RecordLogSql, _ working: RecordLogOrderedMap<RecordLogRecordKey, RecordLogRow?>
    ) throws -> [RecordLogRecordKey] {
        var changed: [RecordLogRecordKey] = []
        for (key, row) in working.entries {
            let before = try viewRow(sql, key)
            if recordLogSameRow(before, row) { continue }
            if let row {
                try sql.exec(
                    """
                    INSERT INTO record_log_view (doc_id, _type, _id, _data) VALUES (?, ?, ?, jsonb(?))
                      ON CONFLICT (doc_id, _type, _id) DO UPDATE SET _data = excluded._data
                    """,
                    [doc, .text(key.model), .text(key.id), .text(RecordLogJSON.stored(row))]
                )
            } else {
                try sql.exec(
                    "DELETE FROM record_log_view WHERE doc_id = ? AND _type = ? AND _id = ?",
                    [doc, .text(key.model), .text(key.id)]
                )
            }
            changed.append(key)
        }
        return changed
    }

    /// Refresh and describe the view rows a command touched, with any already refreshed.
    private func settleView(
        _ sql: RecordLogSql, _ touched: [RecordLogRecordKey], refreshed: [RecordLogRecordKey] = []
    ) throws -> [RecordLogRowChange] {
        var unique = RecordLogOrderedMap<RecordLogRecordKey, Bool>()
        for key in touched + tables.takeDirty() { unique[key] = true }
        var changed = RecordLogOrderedMap<RecordLogRecordKey, Bool>()
        for key in refreshed + (try refreshView(sql, unique.keys)) { changed[key] = true }
        let keys = changed.keys
        return try keys.map { RecordLogRowChange(model: $0.model, id: $0.id, row: try viewRow(sql, $0)) }
    }

    private func rules(_ writer: String) -> RecordLogRules {
        RecordLogRules(tables: tables, writer: writer)
    }

    // MARK: - Writes

    /// Commit local writes, one entry each, as one save in the connection's
    /// group: the budget check, the pending entry and the guess on the view.
    /// `listener` hears the group's outcome after it commits:
    /// `nil`, or — when the group's `COMMIT` failed and everything in it was
    /// rolled back, these entries included — a `JsBaoError(.unavailable)`
    /// naming the document, with `details.reason` `"commit-failed"`.
    ///
    /// - Throws: `JsBaoError(.documentEpochBudget)` when both epochs this client
    ///   may write into are full; nothing of the save lands. A db3 that lives
    ///   only on this device commits through ``commitLocally(_:writer:writes:ts:)``
    ///   and throws what it throws; in a store holding a member index it then
    ///   gathers statistics once the view has grown past its mark (#5156),
    ///   outside the save.
    func commitEntries(
        writer: String, writes: [RecordLogWrite],
        ts: Int64? = nil, listener: RecordLogGroupCommit.Listener? = nil
    ) throws -> RecordLogCommitReply {
        let documentId = documentId
        let heard: RecordLogGroupCommit.Listener? = listener.map { listener in
            { error in
                listener(error.map { error in
                    JsBaoError(
                        code: .unavailable,
                        message: "Saves to the format-3 document \(documentId) could not be committed and were "
                            + "rolled back: \(error.localizedDescription)",
                        details: ["documentId": .string(documentId), "reason": "commit-failed",
                                  "error": .string(error.localizedDescription)]
                    )
                })
            }
        }
        var local = false
        let reply = try save(listener: heard) { sql -> RecordLogCommitReply in
            if try tables.localOnly() {
                local = true
                return try commitLocally(sql, writer: writer, writes: writes, ts: ts)
            }
            return try tables.countingEpochs {
                let rules = rules(writer)
                var entries: [RecordLogPendingEntry] = []
                var refreshed: [RecordLogRecordKey] = []
                for write in writes {
                    guard let m = write.mutations.first else { continue }
                    try rules.budgetCheck(documentId: documentId)
                    let entry = try rules.write(
                        m, also: Array(write.mutations.dropFirst()), upsertOn: write.upsertOn,
                        ts: ts ?? Int64(Date().timeIntervalSince1970 * 1000)
                    )
                    // Each write lands on the view before the next is applied over it.
                    refreshed.append(contentsOf: try refreshView(sql, entry.keys + tables.takeDirty()))
                    entries.append(entry)
                }
                let changed = try settleView(sql, [], refreshed: refreshed)
                return RecordLogCommitReply(entries: entries, changed: changed, cursor: try tables.cursor())
            }
        }
        if local { gatherStatisticsIfGrown() }
        return reply
    }

    /// Commit the writes of a db3 that lives only on this device (#5155), in
    /// the save's transaction. No room will judge them, so the store does, as
    /// the room would (``judgeLocally(_:_:)``). An accepted write is written
    /// and confirmed at once by a result of the store's own making (the next
    /// log number, the open epoch, its changes), so it leaves the pending log
    /// as it lands and the cursor advances by one. The reply carries what such
    /// a `receive` answers. No write budget applies: nothing else writes to
    /// the db3.
    ///
    /// - Throws: `JsBaoError` `.documentConstraintViolated`,
    ///   `.db3ConditionNotMet`, `.db3RecordNotFound` or `.documentEntryInvalid`
    ///   (`details.scope` `local`, with the room's `constraint`, `conflicting`
    ///   and `current`); nothing of the save lands.
    private func commitLocally(
        _ sql: RecordLogSql, writer: String, writes: [RecordLogWrite], ts: Int64?
    ) throws -> RecordLogCommitReply {
        let rules = rules(writer)
        var reply = RecordLogCommitReply(entries: [], changed: [], cursor: 0, acknowledged: [], settled: [], settlements: [:])
        var touched: [RecordLogRecordKey] = []
        for write in writes {
            guard let m = write.mutations.first else { continue }
            let judged = try judgeLocally(sql, write)
            let entry = try rules.write(
                m, also: Array(write.mutations.dropFirst()), upsertOn: write.upsertOn,
                ts: ts ?? Int64(Date().timeIntervalSince1970 * 1000)
            )
            let out = try rules.receive(.result(RecordLogResult(
                l: try tables.cursor() + 1, e: try tables.epochs().open, changes: judged.changes, alias: judged.alias,
                w: writer, seq: entry.seq
            )))
            touched.append(contentsOf: out.touched)
            reply.acknowledged?.append(contentsOf: out.acknowledged)
            reply.settled?.append(contentsOf: out.settled)
            reply.settlements?.merge(out.settlements) { _, new in new }
            if let alias = judged.alias { reply.aliases.append(alias) }
            reply.entries.append(entry)
        }
        reply.changed = try settleView(sql, touched)
        reply.cursor = try tables.cursor()
        return reply
    }

    /// Judge one write of a local-only db3 against the confirmed rows, as the
    /// room judges an entry (#5155): an upsert lands on the live record
    /// holding its value; `ifNotExists` fails on a live record, a `condition`
    /// on no live record or one it does not match, an increment on a record
    /// neither live nor created by the entry; the rows the entry leaves are
    /// checked against the store's unique constraints. Answers its changes,
    /// whole rows, and the upsert's alias when it landed on another record.
    ///
    /// - Throws: the room's refusal, as ``commitLocally(_:writer:writes:ts:)`` says.
    private func judgeLocally(
        _ sql: RecordLogSql, _ write: RecordLogWrite
    ) throws -> (changes: [RecordLogChange], alias: RecordLogAlias?) {
        let documentId = documentId
        func refused(_ code: JsBaoErrorCode, _ message: String, _ extra: [String: JSONValue] = [:]) -> JsBaoError {
            var details: [String: JSONValue] = ["documentId": .string(documentId), "scope": "local"]
            details.merge(extra) { _, new in new }
            return JsBaoError(code: code, message: "Cannot save to the db3 '\(documentId)': \(message).", details: details)
        }
        let confirmed = try tables.confirmed()
        let constraints = try tables.constraints()
        let m = write.mutations[0]
        if let field = write.upsertOn, !constraints.contains(where: { $0.model == m.model && $0.fields == [field] }) {
            throw refused(.documentEntryInvalid, "upsertOn names \(field), which no single-field unique constraint of \(m.model) covers")
        }
        let resolved = try recordLogResolveEntry(confirmed, RecordLogPendingEntry(
            seq: 0, e: 0, k: 0, m: m, also: write.mutations.count > 1 ? Array(write.mutations.dropFirst()) : nil,
            upsertOn: write.upsertOn
        ))
        // The guards and an increment's record, on the records the entry
        // resolves to, as they stand before it.
        var created = Set<RecordLogRecordKey>()
        for (at, sent) in write.mutations.enumerated() {
            let target = resolved.mutations[at]
            if target.kind == .create { created.insert(target.key) }
            guard sent.kind == .increment || sent.carriesGuard else { continue }
            let place = at == 0 ? "" : "write \(at + 1) of the transaction: "
            let record = "\(target.model) id=\(target.id)"
            let row = try confirmed.row(target.key)
            let current: [String: JSONValue] = ["current": RecordLogCurrentRecord(model: target.model, id: target.id, row: row).json]
            if sent.kind == .increment, !created.contains(target.key), row == nil {
                throw refused(.db3RecordNotFound, "\(place)\(record) has no live record to increment", current)
            }
            if sent.ifNotExists, row != nil {
                throw refused(.db3ConditionNotMet, "\(place)ifNotExists failed: \(record) already exists", current)
            }
            if let condition = sent.condition {
                guard let row, try conditionHolds(sql, target.key, row, condition) else {
                    let none = row == nil ? " (a record with no live row meets none)" : ""
                    throw refused(.db3ConditionNotMet, "\(place)the condition on \(record) is not met\(none)", current)
                }
            }
        }
        // The rows the entry leaves, its guards dropped.
        var order: [RecordLogRecordKey] = []
        var before: [RecordLogRecordKey: RecordLogRow] = [:]
        var after: [RecordLogRecordKey: RecordLogRow] = [:]
        for (at, resolvedMutation) in resolved.mutations.enumerated() {
            let mutation = resolvedMutation.withoutGuards
            let key = mutation.key
            if !order.contains(key) {
                order.append(key)
                before[key] = try confirmed.row(key)
                after[key] = before[key]
            }
            let row = recordLogPlainRowAfter(after[key], mutation)
            if mutation.kind == .increment, let row,
               let field = (mutation.fields ?? [:]).keys.sorted().first(where: { !recordLogNumeric(row[$0]).isFinite }) {
                let place = at == 0 ? "" : "write \(at + 1) of the transaction: "
                throw refused(.documentEntryInvalid, "\(place)increment of `\(field)` overflows", [
                    "current": RecordLogCurrentRecord(model: key.model, id: key.id, row: after[key]).json,
                ])
            }
            after[key] = row
        }
        // Every touched live record against every constraint of its model whose
        // key it holds in full: another touched record holding the key, or an
        // untouched live one, refuses the entry (js-bao's `checkConstraints`).
        for constraint in constraints {
            let mine = order.filter { $0.model == constraint.model }
            guard !mine.isEmpty else { continue }
            var held: [String: RecordLogRecordKey] = [:]
            for key in mine {
                guard let row = after[key] else { continue }
                let values = constraint.fields.map { row[$0] ?? .null }
                guard !values.contains(.null) else { continue }
                let text = RecordLogJSON.text(.array(values))
                let holder: String?
                if let other = held[text] {
                    holder = other.id
                } else {
                    held[text] = key
                    holder = try confirmed.holder(model: constraint.model, fields: constraint.fields, values: values, excluding: mine.map(\.id))
                }
                if let holder {
                    throw refused(
                        .documentConstraintViolated,
                        "unique constraint \"\(constraint.name)\" of \(constraint.model): \(holder) already holds the key",
                        ["constraint": .string(constraint.name), "conflicting": RecordLogRecordKey(model: constraint.model, id: holder).json]
                    )
                }
            }
        }
        let changes = order.compactMap { key -> RecordLogChange? in
            if let row = after[key] { return RecordLogChange(model: key.model, id: key.id, row: row) }
            return before[key] == nil ? nil : RecordLogChange(model: key.model, id: key.id, gone: true)
        }
        return (changes, resolved.alias)
    }

    /// Whether `row`, as record `key`, matches `condition` (the query filter
    /// grammar): the view's own translation, run over a one-row table holding
    /// the row, so a condition means what the same filter means to a query.
    private func conditionHolds(
        _ sql: RecordLogSql, _ key: RecordLogRecordKey, _ row: RecordLogRow, _ condition: JSONValue
    ) throws -> Bool {
        guard let filter = condition.objectValue else { return false }
        let (clause, params) = try QueryTranslator.translateView(filter, table: "condition_row", model: key.model)
        return try sql.first(
            "WITH condition_row(doc_id, _type, _id, _data) AS (SELECT ?, ?, ?, jsonb(?)) "
                + "SELECT 1 AS hit FROM condition_row WHERE (\(clause))",
            [doc, .text(key.model), .text(key.id), .text(RecordLogJSON.stored(row))] + params.map(Format2SqlValue.init(bindable:))
        ) != nil
    }

    /// Apply what the room relayed, item by item.
    func receive(writer: String, items: [RecordLogResultItem], heard: RecordLogHeard = RecordLogHeard()) throws -> RecordLogChangeReply {
        try command { sql in
            let rules = rules(writer)
            var reply = RecordLogChangeReply()
            var touched: [RecordLogRecordKey] = []
            for item in items {
                let out = try rules.receive(item)
                touched.append(contentsOf: out.touched)
                reply.acknowledged.append(contentsOf: out.acknowledged)
                reply.settled.append(contentsOf: out.settled)
                reply.settlements.merge(out.settlements) { _, new in new }
                if reply.underivable == nil { reply.underivable = out.underivable }
            }
            // The frame's head, in the transaction that applied it (#5221).
            try rules.noteHead(heard)
            reply.changed = try settleView(sql, touched)
            reply.cursor = try tables.cursor()
            return reply
        }
    }

    /// Act on a refusal: hand back what it reaches and answer the frames that move the room past it.
    func refused(writer: String, refusal: RecordLogRefusal) throws -> RecordLogChangeReply {
        try command { sql in
            let out = try rules(writer).refused(refusal)
            var reply = RecordLogChangeReply()
            reply.handedBack = out.handedBack
            reply.frames = out.frames
            reply.changed = try settleView(sql, out.touched)
            reply.cursor = try tables.cursor()
            return reply
        }
    }

    /// The room has moved past a withdrawn entry's number.
    func settled(writer: String, seq: Int) throws {
        try command { _ in try rules(writer).settled(seq) }
    }

    /// Begin a catch-up; a full one replaces the confirmed rows as its pages arrive.
    func beginCatchUp(writer: String, full: Bool) throws {
        _ = try beginFencedCatchUp(writer: writer, full: full)
    }

    /// Begin a catch-up as ``beginCatchUp(writer:full:)`` does, answering a full
    /// one's generation: every later command of it carries it, and another
    /// client of the store beginning a replacement makes it stale. A full one
    /// begun for a segment's receipt `attempt` records the generation on it.
    func beginFencedCatchUp(writer: String, full: Bool, attempt: String? = nil) throws -> Int? {
        try command { _ in try rules(writer).beginFencedCatchUp(full: full, attempt: attempt) }
    }

    /// Begin a segment's full replacement for receipt `attempt`: its generation
    /// (recorded on the attempt), and the segment the store's rows were last
    /// replaced from, read in the same transaction (a mirror's may be older).
    /// The receipt tries to keep only those chunks.
    func beginSegmentReplacement(writer: String, attempt: String? = nil) throws -> (generation: Int?, held: RecordLogHeldSegment?) {
        try command { _ in
            let generation = try rules(writer).beginFencedCatchUp(full: true, attempt: attempt)
            return (generation, try tables.heldSegment())
        }
    }

    /// Whether `receipt` names an attempt another attempt of the store took over.
    private func displaced(_ writer: String, _ receipt: String?) throws -> Bool {
        guard let receipt else { return false }
        return try rules(writer).displacedReceipt(receipt)
    }

    /// Whether `generation` is not the replacement the store is in.
    private func staleGeneration(_ generation: Int?) throws -> Bool {
        guard let generation else { return false }
        return try tables.replacing() != generation
    }

    /// Apply one page of a catch-up, read by the room at log number `lsn`. One
    /// older than the cursor, under a replacement generation another began
    /// after, or of the remainder of receipt `receipt` once another attempt
    /// took it over, is answered `stale` and changes nothing. A staged
    /// replacement's page keeps the previous row of each record it rewrites
    /// and leaves the view as it was.
    func applyCatchUpPage(
        writer: String, rows: [RecordLogCatchUpRow], gone: [RecordLogRecordKey] = [], lsn: Int? = nil,
        generation: Int? = nil, receipt: String? = nil, heard: RecordLogHeard = RecordLogHeard()
    ) throws -> RecordLogChangeReply {
        statisticsAfter(try command { sql in
            let cursor = try tables.cursor()
            let rules = rules(writer)
            // The page's head is the room's whether or not its rows apply (#5221).
            if let lsn, cursor > lsn {
                try rules.noteHead(heard)
                return RecordLogChangeReply(cursor: cursor, stale: true)
            }
            if try staleGeneration(generation) {
                try rules.noteHead(heard)
                return RecordLogChangeReply(cursor: cursor, stale: true)
            }
            if try displaced(writer, receipt) {
                try rules.noteHead(heard)
                return RecordLogChangeReply(cursor: cursor, stale: true)
            }
            let staged = try generation != nil && tables.staged()
            if staged { try tables.stageBase(rows.map { RecordLogRecordKey(model: $0.model, id: $0.id) } + gone) }
            let touched = try rules.applyCatchUpPage(RecordLogCatchUpInput(rows: rows, gone: gone), generation: generation, receipt: receipt)
            try rules.noteHead(heard)
            // A staged replacement's pages reach the view at its completion.
            return RecordLogChangeReply(changed: staged ? [] : try settleView(sql, touched), cursor: try tables.cursor())
        })
    }

    /// Complete a catch-up at the room's log number, seeing the highest epoch
    /// its rows carry. One below the cursor, or a replacement's under a
    /// generation another began after, is answered `stale`: the cursor never
    /// moves back, and a full replacement removes nothing. A completion that
    /// ends receipt attempt `receipt` ends it in the store, and a full
    /// replacement every attempt whose last change came before it began; one
    /// of an attempt another took over is answered `stale`. A
    /// staged replacement's completion rebuilds the view
    /// (``settleReplacement(_:_:)``) and names exactly the records whose view
    /// row changed, appeared or left.
    func completeCatchUp(
        writer: String, lsn: Int, high: Int? = nil, full: Bool = false, generation: Int? = nil,
        receipt: String? = nil, segment: RecordLogHeldSegment? = nil, at: Int64? = nil, heard: RecordLogHeard = RecordLogHeard()
    ) throws -> RecordLogChangeReply {
        statisticsAfter(try command { sql in
            let cursor = try tables.cursor()
            let rules = rules(writer)
            let superseded = try staleGeneration(generation)
            let takenOver = try displaced(writer, receipt)
            if cursor > lsn || superseded || takenOver {
                try rules.noteHead(heard)
                return RecordLogChangeReply(cursor: cursor, stale: true)
            }
            let staged = try full && tables.staged()
            // The view as the staged replacement left it, to tell what its completion changes.
            if staged { try snapshotView(sql) }
            let out = try rules.completeCatchUp(
                lsn: lsn, high: high, full: full, generation: generation, receipt: receipt, segment: segment
            )
            try tables.setLastCatchUpAt(at ?? Int64(Date().timeIntervalSince1970 * 1000))
            try rules.noteHead(heard)
            var reply = RecordLogChangeReply()
            reply.acknowledged = out.acknowledged
            reply.settled = out.settled
            reply.settlements = out.settlements
            reply.underivable = out.underivable
            reply.changed = staged ? try settleReplacement(sql, out.touched) : try settleView(sql, out.touched)
            reply.cursor = try tables.cursor()
            return reply
        })
    }

    // MARK: - Receipts of chunks

    /// A receipt of a load's or a segment's chunks begins: it is kept from now
    /// until its completion, or a full replacement begun after its last
    /// change, ends it, so a store reopened after an interrupted receipt knows
    /// its rows may hold what the room does not. Answers the cursor and the
    /// attempt's id, which each of its commands carries.
    ///
    /// With the `fingerprint` of its chunk list, an unfinished attempt of the
    /// same load or segment and list whose rows the store still holds is taken
    /// over instead (``RecordLogRules/resumeReceipt(_:fingerprint:chunks:)``):
    /// the answer says how many chunks it has done and whether it completed
    /// them, and for a segment the replacement generation it continues under
    /// and the held segment, so no replacement is begun. Otherwise a fresh
    /// attempt begins at `done: 0`.
    func beginReceipt(
        writer: String, kind: RecordLogReceiptKind, id: String, fingerprint: String? = nil, chunks: Int? = nil
    ) throws -> RecordLogReceiptStart {
        try command { _ in
            let client = rules(writer)
            let receipt = RecordLogReceipt(kind: kind, id: id)
            if let fingerprint, let resumed = try client.resumeReceipt(receipt, fingerprint: fingerprint, chunks: chunks) {
                var start = RecordLogReceiptStart(
                    cursor: try tables.cursor(), attempt: resumed.attempt, done: resumed.done, completed: resumed.completed
                )
                if kind == .segment {
                    start.generation = resumed.generation
                    start.held = try tables.heldSegment()
                }
                return start
            }
            let attempt = try client.beginReceipt(receipt, fingerprint: fingerprint)
            return RecordLogReceiptStart(cursor: try tables.cursor(), attempt: attempt)
        }
    }

    /// The answer to a chunk command of a receipt attempt the store no longer has in progress: nothing changed.
    private func staleReceipt(_ writer: String, _ attempt: String?) throws -> RecordLogChunkReply? {
        guard let attempt, try !rules(writer).receiptInProgress(attempt) else { return nil }
        return RecordLogChunkReply(cursor: try tables.cursor(), stale: true)
    }

    /// Apply one chunk of bulk load `sessionId` as receipt `attempt`, in one
    /// transaction: its lines merged into the confirmed rows by key, and the
    /// view rows of the chunk's records. The reply names the
    /// model, and in `changed` only the records an unjudged entry touches. An
    /// attempt the store no longer has in progress (a full replacement or its
    /// own completion ended it) is answered `stale` and changes nothing.
    func applyLoadChunk(
        writer: String, sessionId: String, attempt: String, model: String, lines: [RecordLogLoadLine]
    ) throws -> RecordLogChunkReply {
        statisticsAfter(try command { sql in
            if let stale = try staleReceipt(writer, attempt) { return stale }
            let touched = try rules(writer).applyLoadLines(attempt: attempt, model: model, lines: lines)
            // A delete is touched only when it removed a record.
            let touchedIds = Set(touched.map(\.id))
            let removed = lines.filter { $0.patch["_deleted"] == .bool(true) && touchedIds.contains($0.id) }.count
            var reply = RecordLogChunkReply()
            reply.applied = touched.count - removed
            reply.removed = removed
            reply.changed = try settleBulk(sql, touched)
            reply.models = [model]
            if let first = lines.first, let last = lines.last {
                reply.ranges = [RecordLogIdRange(model: model, firstId: first.id, lastId: last.id)]
            }
            reply.cursor = try tables.cursor()
            return reply
        })
    }

    /// Receipt `attempt` applied every chunk of bulk load `sessionId`. A
    /// refresh removes the confirmed rows of `models` no line the attempt
    /// applied named, from the view too (an unjudged
    /// entry's guess stays); a merge removes nothing. `stale` as
    /// ``applyLoadChunk(writer:sessionId:attempt:model:lines:)``.
    func completeLoad(
        writer: String, sessionId: String, attempt: String, mode: RecordLogLoadMode, models: [String]
    ) throws -> RecordLogChunkReply {
        statisticsAfter(try command { sql in
            if let stale = try staleReceipt(writer, attempt) { return stale }
            let touched = try rules(writer).completeLoad(attempt: attempt, mode: mode, models: models)
            var reply = RecordLogChunkReply()
            reply.removed = touched.count
            reply.changed = try settleBulk(sql, touched)
            reply.models = Self.modelsOf(touched)
            reply.cursor = try tables.cursor()
            return reply
        })
    }

    /// Put one row chunk of a segment under the replacement `generation`, its
    /// view rows with it (a staged replacement's reach the view at its
    /// completion). Under a generation another replacement superseded, or as
    /// an attempt no longer in progress, it is answered `stale` and changes
    /// nothing.
    func applySegmentChunk(
        writer: String, generation: Int, attempt: String? = nil, rows: [RecordLogCatchUpRow]
    ) throws -> RecordLogChunkReply {
        statisticsAfter(try command { sql in
            let cursor = try tables.cursor()
            if try staleGeneration(generation) { return RecordLogChunkReply(cursor: cursor, stale: true) }
            if let stale = try staleReceipt(writer, attempt) { return stale }
            let staged = try tables.staged()
            if staged { try tables.stageBase(rows.map { RecordLogRecordKey(model: $0.model, id: $0.id) }) }
            let touched = try rules(writer).applySegmentRows(generation: generation, attempt: attempt, rows: rows)
            var reply = RecordLogChunkReply()
            reply.applied = touched.count
            if staged { reply.cursor = cursor; return reply }
            reply.changed = try settleBulk(sql, touched)
            reply.models = Self.modelsOf(touched)
            if let first = rows.first, let last = rows.last, rows.allSatisfy({ $0.model == first.model }) {
                reply.ranges = [RecordLogIdRange(model: first.model, firstId: first.id, lastId: last.id)]
            }
            reply.cursor = cursor
            return reply
        })
    }

    /// Keep one chunk of segment `segmentId` from the confirmed rows instead of
    /// reading it, in one transaction, as
    /// ``RecordLogRules/keepSegmentChunk(generation:attempt:object:sha256:model:firstId:lastId:rows:)``
    /// decides: the reply's `applied` is the rows kept, or it answers
    /// `mismatch` and nothing changed. `stale` as
    /// ``applySegmentChunk(writer:generation:attempt:rows:)``, and for
    /// an attempt no longer in progress. The view rows are already the kept
    /// rows'.
    func keepSegmentChunk(
        writer: String, generation: Int, attempt: String, segmentId: String, object: String, sha256: String, model: String,
        firstId: String, lastId: String, rows: Int
    ) throws -> RecordLogChunkReply {
        try command { _ in
            let cursor = try tables.cursor()
            if try staleGeneration(generation) { return RecordLogChunkReply(cursor: cursor, stale: true) }
            if let stale = try staleReceipt(writer, attempt) { return stale }
            let out = try rules(writer).keepSegmentChunk(
                generation: generation, attempt: attempt, object: object, sha256: sha256, model: model,
                firstId: firstId, lastId: lastId, rows: rows
            )
            var reply = RecordLogChunkReply()
            reply.cursor = cursor
            switch out {
            case .mismatch:
                reply.mismatch = true
            case .kept(let kept, let ranges):
                reply.applied = kept
                reply.ranges = ranges
            }
            return reply
        }
    }

    /// Apply a segment's corrections under the replacement `generation`;
    /// `stale` as ``applySegmentChunk(writer:generation:attempt:rows:)``.
    func applySegmentCorrections(
        writer: String, generation: Int, attempt: String? = nil, lines: [RecordLogCorrection]
    ) throws -> RecordLogChunkReply {
        statisticsAfter(try command { sql in
            let cursor = try tables.cursor()
            if try staleGeneration(generation) { return RecordLogChunkReply(cursor: cursor, stale: true) }
            if let stale = try staleReceipt(writer, attempt) { return stale }
            let staged = try tables.staged()
            if staged { try tables.stageBase(lines.map { RecordLogRecordKey(model: $0.model, id: $0.id) }) }
            let touched = try rules(writer).applySegmentCorrections(generation: generation, attempt: attempt, lines: lines)
            let hit = Set(touched)
            let removed = lines.filter { $0.row == nil && hit.contains(RecordLogRecordKey(model: $0.model, id: $0.id)) }.count
            var reply = RecordLogChunkReply()
            reply.applied = touched.count - removed
            reply.removed = removed
            if staged { reply.cursor = cursor; return reply }
            reply.changed = try settleBulk(sql, touched)
            reply.models = Self.modelsOf(touched)
            reply.cursor = cursor
            return reply
        })
    }

    /// The distinct models of `keys`, in first-seen order.
    private static func modelsOf(_ keys: [RecordLogRecordKey]) -> [String] {
        var seen = Set<String>()
        return keys.compactMap { seen.insert($0.model).inserted ? $0.model : nil }
    }

    /// The view rows of records a chunk changed, written set-based:
    /// a record no unjudged entry touches and no unjudged upsert's value lands
    /// on shows its confirmed row, copied a model at a time; the rest are refreshed one
    /// closure at a time as any other change is. Answers the records the
    /// refresh changed.
    private func settleBulk(_ sql: RecordLogSql, _ keys: [RecordLogRecordKey]) throws -> [RecordLogRowChange] {
        var refresh = tables.takeDirty()
        for (model, ids) in recordLogIdsByModel(keys) {
            var guessed = RecordLogOrderedMap<String, Bool>()
            for (list, bindings) in recordLogIdLists(ids) {
                for row in try sql.rows(
                    "SELECT DISTINCT _id FROM record_log_pending_keys WHERE doc_id = ? AND _type = ? AND _id IN \(list)",
                    [doc, .text(model)] + bindings
                ) {
                    if let id = row["_id"].stringValue { guessed[id] = true }
                }
            }
            // An unjudged upsert lands on the first record holding its value: a
            // record of the chunk that now holds one is refreshed with it.
            let chunkIds = Set(ids)
            for upsert in try sql.rows(
                """
                SELECT DISTINCT field, value FROM record_log_pending_values
                 WHERE doc_id = ? AND _type = ? AND upsert = 1 AND value IS NOT NULL
                """,
                [doc, .text(model)]
            ) {
                guard let field = upsert["field"].stringValue else { continue }
                for id in try Self.findHolders(
                    sql, table: "record_log_rows", docId: documentId, model: model, fields: [field],
                    values: [Self.jsonOf(upsert["value"].recordLogNormalized)], excluding: [], limitToFirst: false
                ) where chunkIds.contains(id) {
                    guessed[id] = true
                }
            }
            let plain = ids.filter { !guessed.contains($0) }
            for (list, ids) in recordLogIdLists(plain) {
                let bindings: [Format2SqlValue] = [doc, .text(model)] + ids
                try sql.exec("DELETE FROM record_log_view WHERE doc_id = ? AND _type = ? AND _id IN \(list)", bindings)
                try sql.exec(
                    """
                    INSERT INTO record_log_view (doc_id, _type, _id, _data)
                      SELECT doc_id, _type, _id, _data FROM record_log_rows WHERE doc_id = ? AND _type = ? AND _id IN \(list)
                    """,
                    bindings
                )
            }
            refresh.append(contentsOf: guessed.keys.map { RecordLogRecordKey(model: model, id: $0) })
        }
        return try settleView(sql, refresh)
    }

    /// The view's rows of this document, copied aside before a staged
    /// replacement completes (``settleReplacement(_:_:)`` compares with it).
    private func snapshotView(_ sql: RecordLogSql) throws {
        try sql.connection.executeScript("""
            CREATE TEMP TABLE IF NOT EXISTS record_log_view_before (
              _type TEXT NOT NULL, _id TEXT NOT NULL, _data TEXT NOT NULL, PRIMARY KEY (_type, _id)
            )
            """)
        try sql.exec("DELETE FROM temp.record_log_view_before")
        try sql.exec(
            "INSERT INTO temp.record_log_view_before (_type, _id, _data) SELECT _type, _id, _data FROM record_log_view WHERE doc_id = ?",
            [doc]
        )
    }

    /// A staged replacement completed: the view becomes the completed
    /// generation's rows with this client's guesses over them, every record
    /// of the document rewritten as a chunk's are (``settleBulk(_:_:)``).
    /// Answers each record whose view row changed, appeared or left, with its
    /// row, by comparing with the view ``snapshotView(_:)`` kept: one pass
    /// over the document's rows, once per replacement.
    private func settleReplacement(_ sql: RecordLogSql, _ touched: [RecordLogRecordKey]) throws -> [RecordLogRowChange] {
        var keys = RecordLogOrderedMap<RecordLogRecordKey, Bool>()
        for key in touched { keys[key] = true }
        for found in try sql.rows(
            "SELECT _type, _id FROM record_log_rows WHERE doc_id = ? UNION SELECT _type, _id FROM record_log_view WHERE doc_id = ?",
            [doc, doc]
        ) {
            if let model = found["_type"].stringValue, let id = found["_id"].stringValue {
                keys[RecordLogRecordKey(model: model, id: id)] = true
            }
        }
        _ = try settleBulk(sql, keys.keys)
        var changed: [RecordLogRowChange] = []
        for found in try sql.rows(
            """
            SELECT v._type AS _type, v._id AS _id, json(v._data) AS _data FROM record_log_view v
              LEFT JOIN temp.record_log_view_before b ON b._type = v._type AND b._id = v._id
             WHERE v.doc_id = ? AND (b._id IS NULL OR b._data <> v._data)
            UNION ALL
            SELECT b._type AS _type, b._id AS _id, NULL AS _data FROM temp.record_log_view_before b
             WHERE NOT EXISTS (SELECT 1 FROM record_log_view v WHERE v.doc_id = ? AND v._type = b._type AND v._id = b._id)
            ORDER BY _type, _id
            """,
            [doc, doc]
        ) {
            guard let model = found["_type"].stringValue, let id = found["_id"].stringValue else { continue }
            changed.append(RecordLogRowChange(
                model: model, id: id, row: found["_data"].isNull ? nil : RecordLogJSON.row(found["_data"].stringValue, id: id)
            ))
        }
        try sql.exec("DELETE FROM temp.record_log_view_before")
        return changed
    }

    /// Record what the room said about epochs, constraints and the db3's type, and the permission the client holds.
    /// `localOnly` marks the db3 as living only on this device (#5155): from
    /// then on its writes are judged and confirmed here.
    @discardableResult
    func setState(
        writer: String, notice: (current: Int, next: Int?, entries: Int?)? = nil,
        constraints: [RecordLogConstraint]? = nil, permission: String?? = nil, type: RecordLogTypeUpdate? = nil,
        localOnly: Bool? = nil, heard: RecordLogHeard? = nil
    ) throws -> RecordLogMarks {
        try command { sql in
            if let notice { try rules(writer).notice(current: notice.current, next: notice.next, entries: notice.entries) }
            if let constraints { try tables.setConstraints(constraints) }
            if let permission { try tables.setPermission(permission) }
            if let type { try tables.setType(type) }
            if let localOnly { try tables.setLocalOnly(localOnly) }
            // A `record.opened`'s head (#5221); a command no frame carried records none.
            if let heard { try rules(writer).noteHead(heard) }
            return try marksOn(sql)
        }
    }

    /// Replace a local-only db3's index registrations and the constraints it
    /// enforces, in one transaction (#5155), only while its registrations are
    /// still `from` and, when `unique` names a key, no two records of the view
    /// share it: a registration is judged against the registrations and rows
    /// it changes, and no write lands between the check and the constraint.
    /// Answers `moved` (nothing written) when another change came first, and
    /// `duplicates` (nothing written) naming up to `unique.limit` shared keys.
    func changeLocalIndexes(
        from: [RecordLogLocalIndex], to: [RecordLogLocalIndex], constraints: [RecordLogConstraint],
        unique: (model: String, fields: [String], limit: Int)? = nil
    ) throws -> RecordLogLocalIndexChange {
        try command { sql in
            if RecordLogLocalIndex.text(try tables.localIndexes()) != RecordLogLocalIndex.text(from) {
                return .moved(try marksOn(sql))
            }
            if let unique {
                let shared = try duplicateKeys(sql, model: unique.model, fields: unique.fields, limit: unique.limit)
                if !shared.isEmpty { return .duplicates(shared, try marksOn(sql)) }
            }
            try tables.setLocalIndexes(to)
            try tables.setConstraints(constraints)
            return .changed(try marksOn(sql))
        }
    }

    /// Up to `limit` keys over `fields` that records of `model` in the view
    /// share, null-free keys only, in key order: what a unique registration on
    /// a local-only db3 is refused for (#5155), as the room reads its records.
    private func duplicateKeys(
        _ sql: RecordLogSql, model: String, fields: [String], limit: Int
    ) throws -> [(values: [JSONValue], count: Int)] {
        let columns = fields.map { "json_extract(_data, '$.\($0)')" }
        let selected = columns.enumerated().map { "json_quote(\($0.element)) AS k\($0.offset)" }.joined(separator: ", ")
        return try sql.rows(
            """
            SELECT \(selected), COUNT(*) AS n FROM record_log_view
             WHERE doc_id = ? AND _type = ? AND \(columns.map { "\($0) IS NOT NULL" }.joined(separator: " AND "))
             GROUP BY \(columns.joined(separator: ", ")) HAVING COUNT(*) > 1
             ORDER BY \(columns.joined(separator: ", ")) LIMIT \(max(1, limit))
            """,
            [doc, .text(model)]
        ).map { row in
            (fields.indices.map { RecordLogJSON.parse(row["k\($0)"].stringValue ?? "null") ?? .null }, row["n"].intValue ?? 0)
        }
    }

    /// Mark the copy of a db3 the server just created caught up (#4806): the
    /// room's log is empty at create, so this store holds all of it and the
    /// first open asks from its cursor (0). A store already marked keeps its
    /// mark.
    @discardableResult
    func markCaughtUpAtCreate(at: Int64) throws -> RecordLogMarks {
        try command { sql in
            if try marksOn(sql).lastCatchUpAt == nil { try tables.setLastCatchUpAt(at) }
            return try marksOn(sql)
        }
    }

    /// The client's copy of its open epoch is full: it moves to the next epoch
    /// the room has opened, the move a write's budget check makes on its own.
    @discardableResult
    func spill(writer: String) throws -> RecordLogMarks {
        try command { sql in
            try rules(writer).spill()
            return try marksOn(sql)
        }
    }

    /// The room said the epochs moved without a write: the client has seen `e`.
    func sawEpoch(writer: String, _ e: Int) throws {
        try command { _ in try rules(writer).sawEpoch(e) }
    }

    // MARK: - Residency

    /// Whether a db3's store holds a readable copy (js-bao's
    /// `isRecordLogResident`): it lives only on this device, or it was created
    /// here and not yet synced, or a
    /// load or catch-up completed on this device and no replacement is
    /// interrupted, or the one in progress is staged.
    static func isResident(_ marks: RecordLogMarks, createdLocally: Bool = false) -> Bool {
        // A db3 that lives only on this device (#5155) has no room to load from.
        isResident(
            lastCatchUpAt: marks.lastCatchUpAt, replacing: marks.replacing, staged: marks.staged,
            createdLocally: createdLocally || marks.localOnly
        )
    }

    /// ``isResident(_:createdLocally:)`` over what a store holds of a document before it is bound.
    static func isResident(_ state: RecordLogStoredState, createdLocally: Bool = false) -> Bool {
        isResident(
            lastCatchUpAt: state.lastCatchUpAt, replacing: state.replacing, staged: state.staged,
            createdLocally: createdLocally || state.localOnly
        )
    }

    private static func isResident(lastCatchUpAt: Int64?, replacing: Bool, staged: Bool, createdLocally: Bool) -> Bool {
        if createdLocally { return true }
        guard lastCatchUpAt != nil else { return false }
        return !replacing || staged
    }

    /// Every document the store holds a state row for, sorted by id; `[]`,
    /// creating nothing, on a database with no record-log tables. With
    /// `userId`, a db3 that lives only on this device is listed only for the
    /// user it belongs to (``localOnlyOwner(sql:documentId:)``).
    static func storedDocumentIds(host: any Format2SqlHost, userId: String? = nil) throws -> [String] {
        let store = try migrated(host: host, documentId: "")
        return try store.reading { sql in
            guard try store.tablesExist(sql) else { return [] }
            guard let userId else {
                return try sql.rows("SELECT doc_id FROM record_log_state ORDER BY doc_id").compactMap { $0["doc_id"].stringValue }
            }
            return try sql.rows(
                """
                SELECT s.doc_id AS doc_id FROM record_log_state s
                 WHERE s.local_only = 0 OR COALESCE(
                   (SELECT value FROM record_log_meta WHERE key = 'local_owner:' || s.doc_id),
                   (SELECT user_id FROM record_log_owner LIMIT 1)
                 ) IS ?
                 ORDER BY s.doc_id
                """,
                [.text(userId)]
            ).compactMap { $0["doc_id"].stringValue }
        }
    }

    /// The db3s living only on this device that belong to `userId` (its owner
    /// tag, else the store's owner, as ``isVisible(host:documentId:userId:)``
    /// reads it), sorted by id; `[]`, creating nothing, on a database with no
    /// record-log tables (#5155).
    static func localOnlyDocumentIds(host: any Format2SqlHost, userId: String) throws -> [String] {
        let store = try migrated(host: host, documentId: "")
        return try store.reading { sql in
            guard try store.tablesExist(sql) else { return [] }
            return try sql.rows(
                """
                SELECT s.doc_id AS doc_id FROM record_log_state s
                 WHERE s.local_only = 1 AND COALESCE(
                   (SELECT value FROM record_log_meta WHERE key = 'local_owner:' || s.doc_id),
                   (SELECT user_id FROM record_log_owner LIMIT 1)
                 ) IS ?
                 ORDER BY s.doc_id
                """,
                [.text(userId)]
            ).compactMap { $0["doc_id"].stringValue }
        }
    }

    /// A store for `documentId` whose tables, when an older build wrote them,
    /// are brought to ``RecordLogSchema/storageVersion`` first, so a read of
    /// the local-only columns (#5155) meets them; a database with no
    /// record-log table is left without one. A store at the version costs one
    /// version read and one probe.
    private static func migrated(host: any Format2SqlHost, documentId: String) throws -> RecordLogStore {
        let store = RecordLogStore(host: host, documentId: documentId, clientId: "")
        if try store.reading({ try store.tablesExist($0) }) { try store.initialize() }
        return store
    }

    /// The `record_log_meta` key a local-only db3's owner is kept under once
    /// another user signed in on this device (#5155).
    static func localOwnerKey(_ documentId: String) -> String { "local_owner:\(documentId)" }

    /// Whether `userId` may read `documentId` here: any db3 that syncs; one
    /// that lives only on this device only for the user it belongs to (its
    /// owner tag, else the store's owner).
    static func isVisible(host: any Format2SqlHost, documentId: String, userId: String) throws -> Bool {
        let store = try migrated(host: host, documentId: documentId)
        return try store.reading { sql in
            guard try store.tablesExist(sql) else { return true }
            guard try sql.first(
                "SELECT 1 AS hit FROM record_log_state WHERE doc_id = ? AND local_only = 1", [.text(documentId)]
            ) != nil else { return true }
            let tagged = try sql.first("SELECT value FROM record_log_meta WHERE key = ?", [.text(localOwnerKey(documentId))])?["value"].stringValue
            let owner = try sql.first("SELECT user_id FROM record_log_owner LIMIT 1")?["user_id"].stringValue
            return (tagged ?? owner) == userId
        }
    }

    // MARK: - The owner

    /// Whether the database holds the record-log tables at all — read only,
    /// so a client that never bound a format-3 document writes nothing.
    static func hasTables(host: any Format2SqlHost) throws -> Bool {
        try RecordLogStore(host: host, documentId: "", clientId: "").reading { sql in try sql.first(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text("record_log_state")]
        ) != nil }
    }

    /// The user the record-log tables belong to, or `nil` when none is written.
    static func owner(host: any Format2SqlHost) throws -> String? {
        try RecordLogStore(host: host, documentId: "", clientId: "").reading { sql in
            guard try sql.first(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(RecordLogSchema.ownerTable)]
            ) != nil else { return nil }
            return try sql.first("SELECT user_id FROM record_log_owner LIMIT 1")?["user_id"].stringValue
        }
    }

    /// Write down the user the record-log tables belong to.
    static func setOwner(host: any Format2SqlHost, userId: String) throws {
        let store = RecordLogStore(host: host, documentId: "", clientId: "")
        try store.initialize()
        try store.command { sql in
            try sql.exec("DELETE FROM record_log_owner")
            try sql.exec("INSERT INTO record_log_owner (user_id) VALUES (?)", [.text(userId)])
        }
    }

    /// Remove every document's rows from every record-log table: the store
    /// reset of a principal change. Answers how many unjudged entries were
    /// dropped. A store an older build wrote is brought to the version first,
    /// since it lacks tables the reset clears; a database with no record-log
    /// table is left without one.
    ///
    /// A db3 that lives only on this device has no copy anywhere else, so the
    /// reset keeps it (#5155): one with no owner tag is tagged `previousOwner`'s
    /// (the user the store belonged to), and it is listed and bound for that
    /// user alone (``storedDocumentIds(host:userId:)``,
    /// ``isVisible(host:documentId:userId:)``).
    @discardableResult
    static func purgeAll(host: any Format2SqlHost, previousOwner: String? = nil) throws -> Int {
        let store = try migrated(host: host, documentId: "")
        return try store.command { sql in
            guard try store.tablesExist(sql) else { return 0 }
            let kept = "(SELECT doc_id FROM record_log_state WHERE local_only = 1)"
            if let previousOwner {
                try sql.exec(
                    """
                    INSERT OR IGNORE INTO record_log_meta (key, value)
                      SELECT 'local_owner:' || doc_id, ? FROM record_log_state WHERE local_only = 1
                    """,
                    [.text(previousOwner)]
                )
            }
            let dropped = try sql.first(
                "SELECT COUNT(*) AS n FROM record_log_pending WHERE void = 0 AND acked IS NULL AND doc_id NOT IN \(kept)"
            )?["n"].intValue ?? 0
            for table in RecordLogSchema.clientTables where table != "record_log_state" {
                try sql.exec("DELETE FROM \(table) WHERE doc_id NOT IN \(kept)")
            }
            try sql.exec(
                "DELETE FROM record_log_meta WHERE key LIKE 'db3_type:%' AND substr(key, 10) NOT IN \(kept)"
            )
            try sql.exec("DELETE FROM record_log_state WHERE local_only = 0")
            return dropped
        }
    }
}
