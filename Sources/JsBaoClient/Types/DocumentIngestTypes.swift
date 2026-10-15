import Foundation

// MARK: - Options

/// Whether a bulk load merges its rows (the default) or refreshes its models.
public enum DocumentIngestMode: String, Codable, Sendable {
    /// Upsert each row and leave every other record as it is.
    case merge
    /// Replace the models the load covers: a record of a covered model that
    /// no row names is removed.
    case refresh
}

/// When a bulk load is ordered among the document's writes.
public enum DocumentIngestReserveEpoch: String, Codable, Sendable {
    /// At create (the default): every write made while the load uploads and
    /// applies comes after it and wins.
    case open
    /// At commit: a write made while the chunks were uploading loses to the
    /// load, and only writes after the commit win.
    case commit
}

/// The options of a bulk load into a record-log (format 3) document.
///
/// Every field is optional and a `nil` one takes the server's default; with
/// none set the request carries no body. A document of another format takes
/// only the defaults, and the server refuses anything else with
/// `400 INGEST_OPTION_INVALID`.
public struct DocumentIngestCreateOptions: Encodable, Sendable, Equatable {
    /// `.merge` (the default) or `.refresh`.
    public var mode: DocumentIngestMode?
    /// Models a refresh empties beside the ones its rows mention. Needed only
    /// for a model the rows do not mention; takes `mode: .refresh`.
    public var models: [String]?
    /// `.open` (the default) or `.commit`.
    public var reserveEpoch: DocumentIngestReserveEpoch?

    public init(
        mode: DocumentIngestMode? = nil,
        models: [String]? = nil,
        reserveEpoch: DocumentIngestReserveEpoch? = nil
    ) {
        self.mode = mode
        self.models = models
        self.reserveEpoch = reserveEpoch
    }

    /// No option is set, so the request carries no body.
    var isEmpty: Bool { mode == nil && models == nil && reserveEpoch == nil }
}

// MARK: - Session

/// One bulk-load session, as the server describes it.
///
/// Decoded leniently: a field an older server leaves out reads `nil` (or `0`
/// for a count), and `timings` and `throughput` are carried as `JSONValue` so a
/// field the server adds never stops a session from decoding.
public struct DocumentIngestSession: Decodable, Sendable {
    /// Where the load's records stand.
    public struct Progress: Decodable, Sendable, Equatable {
        public let rowsCopied: Int
        public let chunksApplied: Int
        public let rowsApplied: Int
        public let recordsReconciled: Int
        public let oldRowsRemoved: Int

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rowsCopied = try c.decodeIfPresent(Int.self, forKey: .rowsCopied) ?? 0
            chunksApplied = try c.decodeIfPresent(Int.self, forKey: .chunksApplied) ?? 0
            rowsApplied = try c.decodeIfPresent(Int.self, forKey: .rowsApplied) ?? 0
            recordsReconciled = try c.decodeIfPresent(Int.self, forKey: .recordsReconciled) ?? 0
            oldRowsRemoved = try c.decodeIfPresent(Int.self, forKey: .oldRowsRemoved) ?? 0
        }

        /// Nothing done yet, for a session that reports no progress.
        init() {
            rowsCopied = 0
            chunksApplied = 0
            rowsApplied = 0
            recordsReconciled = 0
            oldRowsRemoved = 0
        }

        private enum CodingKeys: String, CodingKey {
            case rowsCopied, chunksApplied, rowsApplied, recordsReconciled, oldRowsRemoved
        }
    }

    /// A record a failure or a refusal names.
    public struct RowRef: Decodable, Sendable, Equatable {
        public let model: String
        public let id: String
    }

    /// Why a `failed` session failed.
    public struct Failure: Decodable, Sendable, Equatable {
        public let code: String
        public let reason: String
        /// The records the failure names.
        public let rows: [RowRef]?
    }

    /// A row the load refused, with the code it was refused for.
    public struct RefusedRow: Decodable, Sendable, Equatable {
        public let model: String
        public let id: String
        public let code: String
    }

    /// Where the load sits in the document's log once it has started.
    public struct Load: Decodable, Sendable, Equatable {
        /// The epoch the load's rows are stamped with.
        public let epoch: Int
        /// The log number at the load's reservation.
        public let k: Int
        public let firstLsn: Int?
        public let lastLsn: Int?
    }

    public let sessionId: String
    public let documentId: String
    /// `uploading`, `committed`, a working state (`validating`, `staging`,
    /// `applying`, `finalizing`, `registering`), or a terminal one:
    /// `complete`, `failed`, `aborted`.
    public let state: String
    public let createdBy: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let completedAt: String?
    /// How many chunks the session holds.
    public let chunks: Int
    public let rows: Int
    /// Stored (gzipped) bytes across the chunks.
    public let bytes: Int
    /// Decompressed bytes across the chunks, when known.
    public let rawBytes: Int?
    public let progress: Progress
    public let failure: Failure?
    public let expiresAt: String?
    /// When the load is ordered among the document's writes; `nil` on a
    /// session of a format other than 3.
    public let reserveEpoch: DocumentIngestReserveEpoch?
    /// Merge or refresh; `nil` on a session of a format other than 3.
    public let mode: DocumentIngestMode?
    /// Rows the load refused, one at a time. A refused row is left out; the
    /// rest of the load lands.
    public let refusedRows: Int?
    /// The first refused rows.
    public let refusedSample: [RefusedRow]?
    /// `nil` until the load is committed with its epoch reserved.
    public let load: Load?
    /// Where the session's time went, as the server reports it.
    public let timings: JSONValue?
    /// Rates over the load's apply, once it is complete.
    public let throughput: JSONValue?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        documentId = try c.decodeIfPresent(String.self, forKey: .documentId) ?? ""
        state = try c.decode(String.self, forKey: .state)
        createdBy = try? c.decodeIfPresent(String.self, forKey: .createdBy)
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
        completedAt = try? c.decodeIfPresent(String.self, forKey: .completedAt)
        chunks = (try? c.decodeIfPresent(Int.self, forKey: .chunks)) ?? 0
        rows = (try? c.decodeIfPresent(Int.self, forKey: .rows)) ?? 0
        bytes = (try? c.decodeIfPresent(Int.self, forKey: .bytes)) ?? 0
        rawBytes = try? c.decodeIfPresent(Int.self, forKey: .rawBytes)
        progress = try c.decodeIfPresent(Progress.self, forKey: .progress)
            ?? Progress()
        failure = try? c.decodeIfPresent(Failure.self, forKey: .failure)
        expiresAt = try? c.decodeIfPresent(String.self, forKey: .expiresAt)
        // A value this client does not know reads `nil` rather than failing
        // the whole session.
        reserveEpoch = try? c.decodeIfPresent(DocumentIngestReserveEpoch.self, forKey: .reserveEpoch)
        mode = try? c.decodeIfPresent(DocumentIngestMode.self, forKey: .mode)
        refusedRows = try? c.decodeIfPresent(Int.self, forKey: .refusedRows)
        refusedSample = try? c.decodeIfPresent([RefusedRow].self, forKey: .refusedSample)
        load = try? c.decodeIfPresent(Load.self, forKey: .load)
        timings = try? c.decodeIfPresent(JSONValue.self, forKey: .timings)
        throughput = try? c.decodeIfPresent(JSONValue.self, forKey: .throughput)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, documentId, state, createdBy, createdAt, updatedAt, completedAt
        case chunks, rows, bytes, rawBytes, progress, failure, expiresAt
        case reserveEpoch, mode, refusedRows, refusedSample, load, timings, throughput
    }
}

// MARK: - Chunks

/// One chunk of a bulk-load artifact: the descriptor the server checks, and
/// the stored (gzipped) bytes.
public struct DocumentIngestChunk: Sendable, Equatable {
    public let model: String
    /// The chunk's index within its model, ascending from 0.
    public let index: Int
    public let rows: Int
    /// The stored (gzipped) byte length, which the server re-measures.
    public let bytes: Int
    /// The decompressed byte length.
    public let rawBytes: Int
    /// SHA-256 of the stored bytes, lowercase hex, which the server re-computes.
    public let sha256: String
    public let firstId: String
    public let lastId: String
    /// The stored bytes themselves.
    public let body: Data

    public init(
        model: String, index: Int, rows: Int, bytes: Int, rawBytes: Int,
        sha256: String, firstId: String, lastId: String, body: Data
    ) {
        self.model = model
        self.index = index
        self.rows = rows
        self.bytes = bytes
        self.rawBytes = rawBytes
        self.sha256 = sha256
        self.firstId = firstId
        self.lastId = lastId
        self.body = body
    }
}

/// What the server answers a chunk upload with: the chunk alone, not the
/// session. Poll `DocumentIngestsAPI.get` for the session.
public struct DocumentIngestChunkUploadResult: Decodable, Sendable, Equatable {
    public let ok: Bool
    /// The stored byte length the server measured and accepted.
    public let bytes: Int
    /// The chunk's position among the session's stored chunks.
    public let ordinal: Int
}

/// One page of a document's bulk-load sessions, newest first.
public struct DocumentIngestPage: Decodable, Sendable {
    public let items: [DocumentIngestSession]
    public let hasMore: Bool
    public let nextCursor: String?
}

/// One record of a bulk load: its model, its id, and the fields to write.
///
/// A merge writes `patch` over the record's fields; a patch of exactly
/// `["_deleted": true]` deletes the record. The builder does not read the
/// document's schema: the room refuses a row that breaks a declared type or
/// constraint, one row at a time, and reports it as a refused row.
public struct DocumentIngestRow: Sendable, Equatable {
    /// The model's name: ASCII letters, digits and `_`, starting with a letter.
    public var model: String
    /// The record's id; not empty, carrying no tab, newline or carriage
    /// return, and not starting with U+FEFF.
    public var id: String
    public var patch: [String: JSONValue]

    public init(model: String, id: String, patch: [String: JSONValue]) {
        self.model = model
        self.id = id
        self.patch = patch
    }
}

/// Where a bulk-load artifact is cut into chunks.
public struct DocumentIngestBuildOptions: Sendable, Equatable {
    /// The default row cut: 80% of the 50,000 rows one chunk may carry.
    public static let defaultCutRows = 40_000
    /// The default size cut: 12 MiB decompressed, 75% of what one chunk may carry.
    public static let defaultCutRawBytes = 12 * 1024 * 1024

    /// Close a chunk once it holds this many rows: 1 to 50,000.
    public var cutRows: Int
    /// Close a chunk before a row that would take its decompressed size past
    /// this many bytes: 1 to 16 MiB.
    public var cutRawBytes: Int

    public init(
        cutRows: Int = DocumentIngestBuildOptions.defaultCutRows,
        cutRawBytes: Int = DocumentIngestBuildOptions.defaultCutRawBytes
    ) {
        self.cutRows = cutRows
        self.cutRawBytes = cutRawBytes
    }
}
