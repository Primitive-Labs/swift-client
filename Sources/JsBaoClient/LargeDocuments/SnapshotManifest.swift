import Foundation

/// The manifest of a large document's base snapshot, and the checks every
/// reader of one runs before acting on it (#3436, phase B).
///
/// A port of `packages/js-bao/src/utils/snapshotChunks.ts`. That module is
/// shared by both ends of the JS implementation — the Durable Object writes
/// these manifests and the JS client reads them — and Swift is the third
/// reader. A manifest that meant something slightly different here would put
/// records into this client's authoritative table that the server never wrote,
/// silently: on a format-2 document there is no whole-document comparison left
/// to catch it.
///
/// The things a reader keys on — an entry's ordinal, its path, its id range —
/// are exactly the things a wrong manifest gets wrong QUIETLY. Two entries
/// sharing a resolved ordinal make an interrupted load skip a chunk and report
/// success. So the refusals are enumerated, they carry the JS validator's own
/// sentences, and the parity suite compares them verdict for verdict.

// MARK: - The chunk entry

/// What the manifest says about one chunk: enough to verify it standalone.
public struct SnapshotChunkEntry: Sendable, Equatable {

    /// R2 key, inside the document's own prefix. Never used to address a read
    /// — the client is not told the storage layout — but it names the chunk in
    /// a refusal.
    public let key: String

    /// Where this chunk is read from within the grant for its build (#3432):
    /// `{model}/{n}` for a chunk this build wrote, `{epoch}-{buildId}/{model}/{n}`
    /// for one carried forward from an earlier build of the SAME document.
    ///
    /// Optional because a manifest written before the field existed carries
    /// none; a reader then derives `{model}/{n}` from the key.
    public let path: String?

    /// This chunk's place in the manifest, unique within it (#3432). Resume is
    /// keyed on it rather than on `{model}/{n}`, because with reuse two chunks
    /// of one manifest can come from different builds and share that pair.
    public let ordinal: Int?

    public let model: String
    /// Stored (compressed) length.
    public let bytes: Int
    /// Uncompressed ndjson length, when the build recorded one.
    public let rawBytes: Int?
    public let rows: Int
    public let firstId: String
    public let lastId: String
    /// Hex SHA-256 of the STORED bytes — checkable before decompressing.
    public let sha256: String

    public init(
        key: String,
        path: String? = nil,
        ordinal: Int? = nil,
        model: String,
        bytes: Int,
        rawBytes: Int? = nil,
        rows: Int,
        firstId: String,
        lastId: String,
        sha256: String
    ) {
        self.key = key
        self.path = path
        self.ordinal = ordinal
        self.model = model
        self.bytes = bytes
        self.rawBytes = rawBytes
        self.rows = rows
        self.firstId = firstId
        self.lastId = lastId
        self.sha256 = sha256
    }
}

// MARK: - The ingest block

/// One id range a bulk load's artifact carried (#3435).
public struct SnapshotIngestRange: Sendable, Equatable {
    public let model: String
    public let firstId: String
    public let lastId: String
    public let rows: Int
}

/// The bulk-load session a base came from, and what it touched (#3435).
///
/// Read by a CONVERGING client, which is #3437's work; this client validates
/// it — a malformed block would leave ranges of the old document in a merged
/// view with nothing to notice — and otherwise carries it.
public struct SnapshotIngestInfo: Sendable, Equatable {
    public let sessionId: String
    public let epoch: Int
    public let ranges: [SnapshotIngestRange]
}

/// The partition rule a build ran under, recorded in its manifest.
public struct SnapshotPartitionDescriptor: Sendable, Equatable {
    public let scheme: String
    public let minBytes: Int
    public let maxBytes: Int
    public let anchorModulus: Int
}

// MARK: - The manifest

/// What one build wrote: the chunks, and everything a loader needs before the
/// first of them lands.
public struct SnapshotManifest: Sendable, Equatable {

    /// The newest manifest shape this client reads (`FORMAT2_MANIFEST_VERSION`).
    public static let currentVersion = 3
    /// The oldest still readable (`FORMAT2_MIN_MANIFEST_VERSION`).
    public static let minimumVersion = 2

    public let version: Int
    public let epoch: Int
    public let buildId: String
    public let createdAt: Int
    /// What each model declares — its stringset fields above all, which decide
    /// how a row becomes an overlay entry. Travels with the manifest so a cold
    /// client can materialize a model it has never seen a document describe.
    public let schema: [String: JSONValue]
    public let chunks: [SnapshotChunkEntry]
    public let totalRows: Int
    public let totalBytes: Int
    public let partition: SnapshotPartitionDescriptor?
    public let ingest: SnapshotIngestInfo?
    /// What this manifest says it IS. `nil` on every manifest written before
    /// the field existed, and they are all snapshots.
    public let kind: String?

    public init(
        version: Int,
        epoch: Int,
        buildId: String,
        createdAt: Int = 0,
        schema: [String: JSONValue] = [:],
        chunks: [SnapshotChunkEntry],
        totalRows: Int,
        totalBytes: Int,
        partition: SnapshotPartitionDescriptor? = nil,
        ingest: SnapshotIngestInfo? = nil,
        kind: String? = nil
    ) {
        self.version = version
        self.epoch = epoch
        self.buildId = buildId
        self.createdAt = createdAt
        self.schema = schema
        self.chunks = chunks
        self.totalRows = totalRows
        self.totalBytes = totalBytes
        self.partition = partition
        self.ingest = ingest
        self.kind = kind
    }

    /// Fields `model` declares as stringsets, out of the manifest's schema.
    ///
    /// The manifest carries the schema so a chunk can be materialized before
    /// any document has been discovered from — which is what lets a cold
    /// client create a model's rows without replaying anything.
    public func stringSetFields(for model: String) -> Set<String> {
        guard case .object(let declared)? = schema[model],
              case .array(let fields)? = declared["stringSetFields"]
        else { return [] }
        return Set(fields.compactMap { value -> String? in
            if case .string(let name) = value { return name }
            return nil
        })
    }
}

// MARK: - Refusals

/// A manifest that is not internally consistent, or one written by a newer
/// platform than this reader.
///
/// Two codes rather than one because the answer is different: nothing is wrong
/// with an unsupported manifest, the reader is too old, and the caller's move
/// is to upgrade rather than to re-fetch or refuse the base.
public enum SnapshotManifestError {

    public static func invalid(_ reason: String) -> JsBaoError {
        JsBaoError(
            code: .snapshotManifestInvalid,
            message: "Snapshot manifest is not valid: \(reason)",
            details: ["reason": .string(reason)]
        )
    }

    public static func unsupported(
        version: Int, supported: Int = SnapshotManifest.currentVersion
    ) -> JsBaoError {
        JsBaoError(
            code: .snapshotManifestUnsupported,
            message: "Snapshot manifest is version \(version); this client reads up "
                + "to version \(supported). Upgrade the client library.",
            details: [
                "manifestVersion": .number(Double(version)),
                "supportedVersion": .number(Double(supported)),
            ]
        )
    }
}

// MARK: - Id order

/// Compare two record ids the way the table they came from orders them
/// (#3432's `compareRecordIds`).
///
/// Every id in a snapshot arrives in SQLite's order — the builder walks
/// `ORDER BY _type, _id` — and SQLite's BINARY collation is `memcmp` over
/// UTF-8. Swift's `String` comparison is neither: it normalizes and collates,
/// so `"\u{E000}" < "🙂"` comes out the other way round from the table. The
/// partitioner would never see a boundary go past; the validator would call a
/// correctly ordered manifest backwards and refuse every build of the
/// document, forever.
///
/// So id ordering has exactly one implementation, here, over the UTF-8 bytes
/// themselves — which is what the JS side's surrogate-rank arithmetic exists
/// to reproduce from UTF-16 units.
/// There is deliberately no `left == right` short-circuit at the top: Swift's
/// `String` equality NORMALIZES, so it calls `"a\u{0301}"` and `"\u{00E1}"`
/// the same string, and a fast path built on it would report two distinct
/// records as one id. The loop below answers `0` for genuinely equal bytes.
public func compareRecordIds(_ left: String, _ right: String) -> Int {
    var a = left.utf8.makeIterator()
    var b = right.utf8.makeIterator()
    while true {
        switch (a.next(), b.next()) {
        case (nil, nil): return 0
        // A prefix sorts before what extends it, in both collations.
        case (nil, _): return -1
        case (_, nil): return 1
        case (let x?, let y?):
            if x != y { return x < y ? -1 : 1 }
        }
    }
}

// MARK: - Chunk addressing

/// One chunk of a granted build, as a path names it (#3432).
public struct SnapshotChunkAddress: Sendable, Equatable {
    public let model: String
    public let index: Int
    /// The build the chunk was written by, when it is not the granted one.
    /// Always a build of the SAME document: the download route supplies the
    /// app and the document from the grant and only ever takes the build from
    /// here.
    public let source: (epoch: Int, buildId: String)?

    public static func == (lhs: SnapshotChunkAddress, rhs: SnapshotChunkAddress) -> Bool {
        lhs.model == rhs.model && lhs.index == rhs.index
            && lhs.source?.epoch == rhs.source?.epoch
            && lhs.source?.buildId == rhs.source?.buildId
    }
}

/// Read a chunk address out of a manifest entry's `path` (#3432).
///
/// The one grammar, shared by the validator, the loader and — on the server —
/// the download route, because those three disagreeing is precisely how a path
/// one of them normalizes becomes a read of an object the grant does not
/// cover. Anything outside it is `nil`: refused, never repaired.
public func parseSnapshotChunkPath(_ path: String?) -> SnapshotChunkAddress? {
    guard let path, !path.isEmpty else { return nil }
    let segments = path.split(separator: "/", omittingEmptySubsequences: false)
    func isModelName(_ segment: Substring) -> Bool {
        SnapshotManifest.isModelName(String(segment))
    }
    func isIndex(_ segment: Substring) -> Bool {
        !segment.isEmpty && segment.allSatisfy { $0.isASCII && $0.isNumber }
    }
    func isBuildId(_ segment: Substring) -> Bool {
        !segment.isEmpty && segment.count <= 64
            && segment.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
    if segments.count == 2, isModelName(segments[0]), isIndex(segments[1]) {
        return SnapshotChunkAddress(
            model: String(segments[0]), index: Int(segments[1]) ?? 0, source: nil
        )
    }
    guard segments.count == 3,
          isModelName(segments[1]),
          isIndex(segments[2])
    else { return nil }
    // `{epoch}-{buildId}` — the epoch is digits and the build id is what
    // follows the FIRST hyphen, which is how the server writes it.
    let build = segments[0]
    guard let hyphen = build.firstIndex(of: "-") else { return nil }
    let epoch = build[build.startIndex..<hyphen]
    let buildId = build[build.index(after: hyphen)...]
    guard isIndex(epoch), let epochValue = Int(epoch), isBuildId(buildId) else { return nil }
    return SnapshotChunkAddress(
        model: String(segments[1]),
        index: Int(segments[2]) ?? 0,
        source: (epoch: epochValue, buildId: String(buildId))
    )
}

/// Which chunk of a manifest this entry is — its `ordinal`, or its position.
///
/// The fallback is what keeps a manifest written before ordinals existed
/// loadable and resumable; the validator is what keeps the two from colliding.
public func resolveChunkOrdinal(_ entry: SnapshotChunkEntry, at index: Int) -> Int {
    entry.ordinal ?? index
}

/// Where one chunk is read from, WITHIN the grant for its build.
///
/// The manifest's own `path` wins over anything derivable from the key,
/// because the key of a REUSED entry names an object under a build the grant
/// is not for, while the path is the form the route resolves. The fallback is
/// what keeps a manifest written before the field existed loadable.
public func snapshotChunkPath(_ chunk: SnapshotChunkEntry) throws -> String {
    if let path = chunk.path {
        guard parseSnapshotChunkPath(path) != nil else {
            throw SnapshotManifestError.invalid(
                "chunk path is not addressable: \(path)"
            )
        }
        return path
    }
    // `…/{n}.ndjson.gz` is the key shape every build writes.
    guard let range = chunk.key.range(
        of: "/([0-9]+)\\.ndjson\\.gz$", options: .regularExpression
    ) else {
        throw SnapshotManifestError.invalid(
            "chunk key is not addressable: \(chunk.key)"
        )
    }
    let digits = chunk.key[range]
        .dropFirst()
        .prefix(while: { $0.isNumber })
    return "\(chunk.model)/\(digits)"
}

// MARK: - The validator

extension SnapshotManifest {

    /// Check a manifest before anything acts on it (#3432, principle 6).
    ///
    /// Run at every boundary a manifest crosses — this client's loader before
    /// its first fetch, and on the server the install and the verifier —
    /// because each of those is a place a manifest arrives from somewhere the
    /// process does not control, and the fields they key on fail silently
    /// rather than loudly.
    public func validate() throws {
        try SnapshotManifest.checkKind(kind)
        try SnapshotManifest.checkVersion(version)
        try SnapshotManifest.checkChunks(chunks)
        try SnapshotManifest.checkTotals(chunks, rows: totalRows, bytes: totalBytes)
        try SnapshotManifest.checkIngest(ingest)
    }

    /// A manifest that says what it is must say `snapshot` (#3434, behavior 13).
    ///
    /// A bulk-load session writes a manifest in this same layout marked
    /// `kind: "ingest"`, and its entries describe merge PATCHES rather than a
    /// base — a loader that took one for a snapshot would install patches as
    /// records.
    static func checkKind(_ kind: String?) throws {
        guard let kind, kind != "snapshot" else { return }
        throw SnapshotManifestError.invalid(
            "it is a \(kind) manifest, not a snapshot manifest"
        )
    }

    static func checkVersion(_ version: Int) throws {
        if version > currentVersion {
            throw SnapshotManifestError.unsupported(version: version)
        }
        if version < minimumVersion {
            throw SnapshotManifestError.invalid(
                "version \(version) is older than the large-document format "
                    + "(\(minimumVersion))"
            )
        }
    }

    static func checkChunks(_ chunks: [SnapshotChunkEntry]) throws {
        var seenOrdinals = Set<Int>()
        var lastEndPerModel: [String: String] = [:]
        for (index, entry) in chunks.enumerated() {
            let where_ = "chunk \(index) (\(entry.model))"
            let ordinal = resolveChunkOrdinal(entry, at: index)
            guard ordinal >= 0 else {
                throw SnapshotManifestError.invalid(
                    "\(where_) resolves to ordinal \(ordinal), which is not a "
                        + "non-negative integer"
                )
            }
            guard seenOrdinals.insert(ordinal).inserted else {
                // The resume key. Two entries sharing it is a chunk that never
                // lands, under a load that reports success.
                throw SnapshotManifestError.invalid(
                    "\(where_) shares ordinal \(ordinal) with an earlier chunk"
                )
            }
            if let path = entry.path, parseSnapshotChunkPath(path) == nil {
                throw SnapshotManifestError.invalid(
                    "\(where_) has a path that is not addressable: \(path)"
                )
            }
            // A `rows: 0` chunk carries no ids, so its bounds say nothing and
            // are not checked against each other or against its neighbours
            // (edge E7).
            guard entry.rows > 0 else { continue }
            guard compareRecordIds(entry.firstId, entry.lastId) <= 0 else {
                throw SnapshotManifestError.invalid(
                    "\(where_) spans \(entry.firstId)..\(entry.lastId), which runs backwards"
                )
            }
            if let previousEnd = lastEndPerModel[entry.model],
               compareRecordIds(entry.firstId, previousEnd) <= 0 {
                throw SnapshotManifestError.invalid(
                    "\(where_) starts at \(entry.firstId), at or before \(previousEnd) "
                        + "where the previous chunk of \(entry.model) ended"
                )
            }
            lastEndPerModel[entry.model] = entry.lastId
        }
    }

    /// `rows`/`bytes` are optional because a manifest may carry no `totals` at
    /// all, and the refusal says so the way the JS one does (`undefined`)
    /// rather than inventing a number for it.
    static func checkTotals(
        _ chunks: [SnapshotChunkEntry], rows: Int?, bytes: Int?
    ) throws {
        let actualRows = chunks.reduce(0) { $0 + $1.rows }
        let actualBytes = chunks.reduce(0) { $0 + $1.bytes }
        guard rows == actualRows, bytes == actualBytes else {
            let said = { (value: Int?) in value.map(String.init) ?? "undefined" }
            throw SnapshotManifestError.invalid(
                "its totals say \(said(rows))/\(said(bytes)) rows/bytes but its "
                    + "chunks add up to \(actualRows)/\(actualBytes)"
            )
        }
    }

    /// Check the bulk-load block a base's manifest may carry (#3435).
    ///
    /// It decides which chunks a converging client REPLACES and which it
    /// keeps, so a malformed one is a merged view with ranges of the old
    /// document left in it — and the client would have no way to notice,
    /// because a kept chunk is marked, not fetched.
    static func checkIngest(_ ingest: SnapshotIngestInfo?) throws {
        guard let ingest else { return }
        guard !ingest.sessionId.isEmpty else {
            throw SnapshotManifestError.invalid(
                "its ingest block names session \(ingest.sessionId)"
            )
        }
        guard ingest.epoch > 0 else {
            throw SnapshotManifestError.invalid(
                "its ingest block names epoch \(ingest.epoch), which is not an epoch"
            )
        }
        var lastPerModel: [String: String] = [:]
        for (index, range) in ingest.ranges.enumerated() {
            let where_ = "ingest range \(index) (\(range.model))"
            guard isModelName(range.model) else {
                throw SnapshotManifestError.invalid(
                    "\(where_) names \(range.model), which is not a model name"
                )
            }
            guard compareRecordIds(range.firstId, range.lastId) <= 0 else {
                throw SnapshotManifestError.invalid(
                    "\(where_) spans \(range.firstId)..\(range.lastId), which runs backwards"
                )
            }
            // Ascending and DISJOINT within a model: two ranges of one model
            // that overlap describe an artifact that carried one `(model, id)`
            // twice, which is what the server's ordering rule refuses.
            if let previous = lastPerModel[range.model],
               compareRecordIds(range.firstId, previous) <= 0 {
                throw SnapshotManifestError.invalid(
                    "\(where_) starts at \(range.firstId), at or before \(previous) "
                        + "where the previous range of \(range.model) ended"
                )
            }
            lastPerModel[range.model] = range.lastId
        }
    }

    /// Model names in a manifest are letter-led identifiers, as paths are.
    static func isModelName(_ value: String) -> Bool {
        guard let first = value.first, first.isASCII, first.isLetter else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}

// MARK: - Decoding

extension SnapshotManifest {

    /// Decode a manifest the server wrote, refusing exactly what the JS
    /// validator refuses, in the order it refuses it.
    ///
    /// The order is why this is one function rather than a `Decodable` plus a
    /// check: a manifest from a NEWER platform may carry a chunk list this
    /// reader cannot decode, and the honest answer to it is "upgrade the
    /// client", not "chunk 4 is malformed". So the version gate runs before
    /// anything below it is looked at.
    public static func decode(_ raw: JSONValue) throws -> SnapshotManifest {
        guard case .object(let root) = raw else {
            throw SnapshotManifestError.invalid("it is not an object")
        }
        let kind: String?
        switch root["kind"] {
        case .none, .some(.null): kind = nil
        case .some(.string(let value)): kind = value
        case .some(let other): kind = describe(other)
        }
        try checkKind(kind)

        guard let version = integer(root["version"]) else {
            throw SnapshotManifestError.invalid(
                "version \(describe(root["version"])) is not an integer"
            )
        }
        try checkVersion(version)

        guard case .array(let rawChunks)? = root["chunks"] else {
            throw SnapshotManifestError.invalid("its chunk list is not an array")
        }
        var chunks: [SnapshotChunkEntry] = []
        chunks.reserveCapacity(rawChunks.count)
        for (index, rawChunk) in rawChunks.enumerated() {
            guard case .object(let chunk) = rawChunk else {
                throw SnapshotManifestError.invalid(
                    "chunk \(index) (?) is not an object"
                )
            }
            let model = string(chunk["model"]) ?? "?"
            if let ordinal = chunk["ordinal"], ordinal != .null,
               integer(ordinal) == nil {
                throw SnapshotManifestError.invalid(
                    "chunk \(index) (\(model)) has ordinal \(describe(ordinal)), "
                        + "which is not an integer"
                )
            }
            chunks.append(SnapshotChunkEntry(
                key: string(chunk["key"]) ?? "",
                path: string(chunk["path"]),
                ordinal: integer(chunk["ordinal"]),
                model: model,
                bytes: integer(chunk["bytes"]) ?? 0,
                rawBytes: integer(chunk["rawBytes"]),
                rows: integer(chunk["rows"]) ?? 0,
                firstId: string(chunk["firstId"]) ?? "",
                lastId: string(chunk["lastId"]) ?? "",
                sha256: string(chunk["sha256"]) ?? ""
            ))
        }
        try checkChunks(chunks)

        let totals: [String: JSONValue]
        if case .object(let value)? = root["totals"] { totals = value } else { totals = [:] }
        let totalRows = integer(totals["rows"])
        let totalBytes = integer(totals["bytes"])
        try checkTotals(chunks, rows: totalRows, bytes: totalBytes)

        let ingest = try decodeIngest(root["ingest"])
        try checkIngest(ingest)

        var schema: [String: JSONValue] = [:]
        if case .object(let value)? = root["schema"] { schema = value }

        return SnapshotManifest(
            version: version,
            epoch: integer(root["epoch"]) ?? 0,
            buildId: string(root["buildId"]) ?? "",
            createdAt: integer(root["createdAt"]) ?? 0,
            schema: schema,
            chunks: chunks,
            totalRows: totalRows ?? 0,
            totalBytes: totalBytes ?? 0,
            partition: decodePartition(root["partition"]),
            ingest: ingest,
            kind: kind
        )
    }

    /// Decode a manifest from the bytes a download answered with.
    public static func decode(bytes: Data) throws -> SnapshotManifest {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: bytes)
        } catch {
            throw SnapshotManifestError.invalid("it is not an object")
        }
        return try decode(value)
    }

    private static func decodeIngest(_ raw: JSONValue?) throws -> SnapshotIngestInfo? {
        guard let raw, raw != .null else { return nil }
        guard case .object(let block) = raw else {
            throw SnapshotManifestError.invalid("its ingest block is not an object")
        }
        guard case .string(let sessionId)? = block["sessionId"] else {
            throw SnapshotManifestError.invalid(
                "its ingest block names session \(describe(block["sessionId"]))"
            )
        }
        guard let epoch = integer(block["epoch"]) else {
            throw SnapshotManifestError.invalid(
                "its ingest block names epoch \(describe(block["epoch"])), "
                    + "which is not an epoch"
            )
        }
        guard case .array(let rawRanges)? = block["ranges"] else {
            throw SnapshotManifestError.invalid(
                "its ingest block's range list is not an array"
            )
        }
        var ranges: [SnapshotIngestRange] = []
        for (index, rawRange) in rawRanges.enumerated() {
            guard case .object(let range) = rawRange else {
                throw SnapshotManifestError.invalid(
                    "ingest range \(index) (?) is not an object"
                )
            }
            let model = string(range["model"])
            guard let firstId = string(range["firstId"]),
                  let lastId = string(range["lastId"])
            else {
                throw SnapshotManifestError.invalid(
                    "ingest range \(index) (\(model ?? "?")) has no id bounds"
                )
            }
            ranges.append(SnapshotIngestRange(
                model: model ?? "?",
                firstId: firstId,
                lastId: lastId,
                rows: integer(range["rows"]) ?? 0
            ))
        }
        return SnapshotIngestInfo(sessionId: sessionId, epoch: epoch, ranges: ranges)
    }

    private static func decodePartition(_ raw: JSONValue?) -> SnapshotPartitionDescriptor? {
        guard case .object(let block)? = raw else { return nil }
        guard let scheme = string(block["scheme"]) else { return nil }
        return SnapshotPartitionDescriptor(
            scheme: scheme,
            minBytes: integer(block["minBytes"]) ?? 0,
            maxBytes: integer(block["maxBytes"]) ?? 0,
            anchorModulus: integer(block["anchorModulus"]) ?? 0
        )
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value else { return nil }
        guard number.rounded() == number, number.magnitude <= 9_007_199_254_740_991
        else { return nil }
        return Int(number)
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }

    /// How JavaScript's `String(value)` renders what was there, so a refusal
    /// this client produces reads the same as the one the JS client produces
    /// for the same manifest.
    private static func describe(_ value: JSONValue?) -> String {
        switch value {
        case .none: return "undefined"
        case .some(.null): return "null"
        case .some(.string(let value)): return value
        case .some(.bool(let value)): return value ? "true" : "false"
        case .some(.number(let value)):
            if value.rounded() == value, value.magnitude < 1e15 {
                return String(Int(value))
            }
            return String(value)
        case .some(.array): return "[object Array]"
        case .some(.object): return "[object Object]"
        }
    }
}
