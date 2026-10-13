import Foundation

// The vocabulary of a receipt of chunks: a bulk load's or a checkpoint
// segment's rows, read from the room's artifacts rather than paged as rows.
// A port of the receipt types of js-bao's `record-log-client/types.ts`; every
// stored and wire shape is the JS one, field for field.

/// What a receipt of chunks is: a bulk load's, or a segment's.
enum RecordLogReceiptKind: String, Sendable, Equatable {
    case load
    case segment
}

/// How a bulk load applies: a merge sets what its lines name; a refresh also
/// removes every record of its models no line named.
enum RecordLogLoadMode: String, Sendable, Equatable {
    case merge
    case refresh
}

/// A receipt of chunks that began and has not completed: committed chunks may
/// hold rows the room does not have, so the next catch-up must be a pointer
/// receipt or a full replacement.
struct RecordLogReceipt: Equatable, Sendable {
    var kind: RecordLogReceiptKind
    /// The load's session id, or the segment's id.
    var id: String
}

/// One receipt of chunks begun in a store and not completed, with the store's
/// count at its last change.
struct RecordLogReceiptAttempt: Equatable, Sendable {
    var kind: RecordLogReceiptKind
    var id: String
    /// The id the store gave it; its commands carry it.
    var attempt: String
    /// The store's change count when the attempt last changed a row.
    var last: Int
}

/// The receipts of chunks a store has begun and not completed, persisted with
/// the document. Each attempt's changes are made right by its own completion,
/// a later completion of the same load or segment, or a full replacement that
/// began after its last change; until then the confirmed rows may hold what
/// the room does not.
struct RecordLogReceiptState: Equatable, Sendable {
    /// Counts the changes receipts made; each attempt keeps the count at its last.
    var n: Int
    /// The count when the full replacement in progress began, or `nil`.
    var since: Int?
    var attempts: [RecordLogReceiptAttempt]

    /// The JSON the JS store keeps in `record_log_state.receipt`.
    var json: JSONValue {
        .object([
            "n": .number(Double(n)),
            "since": since.map { .number(Double($0)) } ?? .null,
            "attempts": .array(attempts.map { attempt in
                .object([
                    "kind": .string(attempt.kind.rawValue), "id": .string(attempt.id),
                    "attempt": .string(attempt.attempt), "last": .number(Double(attempt.last)),
                ])
            }),
        ])
    }

    init(n: Int = 0, since: Int? = nil, attempts: [RecordLogReceiptAttempt] = []) {
        self.n = n
        self.since = since
        self.attempts = attempts
    }

    /// The stored state; a bare `{kind, id}` an earlier build wrote is one
    /// attempt nothing completes but a full replacement.
    init?(json: JSONValue?) {
        guard let json, case .object = json else { return nil }
        if let attempts = json["attempts"]?.arrayValue {
            self.init(
                n: json["n"]?.wholeNumber ?? 0,
                since: json["since"]?.wholeNumber,
                attempts: attempts.compactMap { item in
                    guard let kind = item["kind"]?.stringValue.flatMap(RecordLogReceiptKind.init(rawValue:)),
                          let id = item["id"]?.stringValue
                    else { return nil }
                    return RecordLogReceiptAttempt(
                        kind: kind, id: id, attempt: item["attempt"]?.stringValue ?? "", last: item["last"]?.wholeNumber ?? 0
                    )
                }
            )
            return
        }
        guard let kind = json["kind"]?.stringValue.flatMap(RecordLogReceiptKind.init(rawValue:)),
              let id = json["id"]?.stringValue, !id.isEmpty
        else { return nil }
        self.init(attempts: [RecordLogReceiptAttempt(kind: kind, id: id, attempt: "", last: 0)])
    }

    /// The latest attempt begun and not completed, as the marks show it.
    var latest: RecordLogReceipt? {
        attempts.last.map { RecordLogReceipt(kind: $0.kind, id: $0.id) }
    }
}

/// One line of a bulk load's chunk: a record id and the merge patch it applies.
struct RecordLogLoadLine: Equatable, Sendable {
    var id: String
    /// The fields it sets (`null` included); `_deleted: true` deletes the record.
    var patch: [String: JSONValue]
}

/// One line of a segment's corrections: a record's row after the segment
/// began, or `nil` when it was deleted.
struct RecordLogCorrection: Equatable, Sendable {
    var model: String
    var id: String
    var row: RecordLogRow?
}

/// A command of a receipt whose attempt is no longer the store's: a full
/// replacement or its own completion already made its changes right, so a
/// later change of it would go uncorrected.
struct RecordLogStaleReceiptError: Error, Equatable, CustomStringConvertible {
    /// The attempt the command carried.
    let attempt: String

    var description: String { "The receipt attempt \(attempt) is no longer in progress in the store." }
}

/// A command of a full replacement arrived under a generation the store no
/// longer replaces under: another session of the store began one of its own.
/// Nothing of the command was applied.
struct RecordLogStaleReplacementError: Error, Equatable, CustomStringConvertible {
    /// The generation the command carried.
    let generation: Int
    /// The one the store replaces under now, or `nil`.
    let current: Int?

    var description: String {
        "The replacement under generation \(generation) was overtaken (the store is now at \(current.map(String.init) ?? "none"))."
    }
}

// MARK: - Pointers

/// Where a pointer's objects are read: an origin-relative grant path (the
/// grant inside it, no other credential) and when it stops working.
struct RecordLogDownload: Equatable, Sendable {
    var path: String
    var expiresAt: Double?

    init(path: String, expiresAt: Double? = nil) {
        self.path = path
        self.expiresAt = expiresAt
    }

    init?(json: JSONValue?) {
        guard let path = json?["path"]?.stringValue, !path.isEmpty else { return nil }
        self.init(path: path, expiresAt: json?["expiresAt"]?.numberValue)
    }
}

/// A completed bulk load as the room points a client at it (the `record.load`
/// `complete` frame, or the `load` catch-up form): its log range and counts,
/// and the grant its manifest and chunks are read through. The manifest is at
/// `download.path`; each chunk at `download.path + "/" + chunk.path`.
struct RecordLogLoadPointer: Equatable, Sendable {
    var sessionId: String
    var mode: RecordLogLoadMode
    var models: [String]
    var epoch: Int
    var k: Int
    /// The first and last log numbers it wrote; `nil` for a load that wrote no row.
    var firstLsn: Int?
    var lastLsn: Int?
    var rows: Int
    var refusedRows: Int
    var download: RecordLogDownload?
    /// How many chunks the manifest lists.
    var chunkCount: Int

    init?(json: JSONValue?) {
        guard let json, let sessionId = json["sessionId"]?.stringValue, !sessionId.isEmpty else { return nil }
        self.sessionId = sessionId
        mode = RecordLogLoadMode(rawValue: json["mode"]?.stringValue ?? "") ?? .merge
        models = (json["models"]?.arrayValue ?? []).compactMap(\.stringValue)
        epoch = json["epoch"]?.wholeNumber ?? RecordLogTransport.firstEpoch
        k = json["k"]?.wholeNumber ?? 0
        firstLsn = json["firstLsn"]?.wholeNumber
        lastLsn = json["lastLsn"]?.wholeNumber
        rows = json["rows"]?.wholeNumber ?? 0
        refusedRows = json["refusedRows"]?.wholeNumber ?? 0
        download = RecordLogDownload(json: json["download"])
        chunkCount = json["chunkCount"]?.wholeNumber ?? 0
    }
}

/// The room's checkpoint segment as it points a far-behind client at it: the
/// rows at its start `lsn` (B), the corrections through `completedLsn` (C),
/// and the grant its chunks are read through.
struct RecordLogSegmentPointer: Equatable, Sendable {
    var segmentId: String
    var lsn: Int
    var completedLsn: Int
    var rows: Int
    var download: RecordLogDownload?
    var chunks: [RecordLogChunkDescriptor]
    var corrections: RecordLogCorrectionsDescriptor

    /// The pointer, or `nil` when it lacks an id, a log number, or a chunk or
    /// the corrections lack a field their reader checks.
    init?(json: JSONValue?) {
        guard let json, let segmentId = json["segmentId"]?.stringValue, !segmentId.isEmpty,
              let lsn = json["lsn"]?.wholeNumber, let completedLsn = json["completedLsn"]?.wholeNumber,
              let list = json["chunks"]?.arrayValue, let corrections = json["corrections"]
        else { return nil }
        let chunks = list.enumerated().compactMap { RecordLogChunkDescriptor(json: $1, position: $0) }
        guard chunks.count == list.count,
              let rows = corrections["rows"]?.wholeNumber, let bytes = corrections["bytes"]?.wholeNumber,
              let rawBytes = corrections["rawBytes"]?.wholeNumber, let sha256 = corrections["sha256"]?.stringValue,
              let path = corrections["path"]?.stringValue
        else { return nil }
        self.segmentId = segmentId
        self.lsn = lsn
        self.completedLsn = completedLsn
        self.rows = json["rows"]?.wholeNumber ?? chunks.reduce(0) { $0 + $1.rows }
        self.download = RecordLogDownload(json: json["download"])
        self.chunks = chunks
        self.corrections = RecordLogCorrectionsDescriptor(rows: rows, bytes: bytes, rawBytes: rawBytes, sha256: sha256, path: path)
    }
}

extension RecordLogChunkDescriptor {
    /// A manifest's or a segment pointer's chunk entry, or `nil` when it lacks
    /// a field the reader checks. `index` defaults to the entry's position.
    init?(json: JSONValue, position: Int) {
        guard let model = json["model"]?.stringValue, let path = json["path"]?.stringValue,
              let rows = json["rows"]?.wholeNumber, rows >= 0, let bytes = json["bytes"]?.wholeNumber, bytes >= 0,
              let rawBytes = json["rawBytes"]?.wholeNumber, rawBytes >= 0, let sha256 = json["sha256"]?.stringValue,
              let firstId = json["firstId"]?.stringValue, let lastId = json["lastId"]?.stringValue
        else { return nil }
        self.init(
            model: model, index: json["index"]?.wholeNumber ?? position, path: path, rows: rows, bytes: bytes,
            rawBytes: rawBytes, sha256: sha256, firstId: firstId, lastId: lastId
        )
    }

    /// Whether the path stays under the grant it is joined to: never absolute,
    /// never a `..` segment, never empty.
    var pathIsRelative: Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}

/// Why a receipt of chunks cannot go on: the session opens again from the cursor.
struct RecordLogReceiptFailure: Error, CustomStringConvertible {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var description: String { reason }
}

/// A load's manifest as a receipt reads it: its chunks in manifest order,
/// checked against the pointer (an ingest manifest of the same session listing
/// `chunkCount` chunks, every descriptor complete, every path under the grant).
func recordLogLoadManifest(_ data: Data, pointer: RecordLogLoadPointer) throws -> [RecordLogChunkDescriptor] {
    guard let manifest = RecordLogJSON.parse(String(decoding: data, as: UTF8.self)), case .object = manifest else {
        throw RecordLogReceiptFailure("the manifest is not JSON")
    }
    guard manifest["kind"]?.stringValue == "ingest" else { throw RecordLogReceiptFailure("the manifest is not a load's") }
    let sessionId = manifest["sessionId"]?.stringValue ?? "no"
    guard sessionId == pointer.sessionId else {
        throw RecordLogReceiptFailure("the manifest is session \(sessionId)'s")
    }
    guard let list = manifest["chunks"]?.arrayValue, list.count == pointer.chunkCount else {
        let listed = manifest["chunks"]?.arrayValue.map { String($0.count) } ?? "no"
        throw RecordLogReceiptFailure("the manifest lists \(listed) chunks, the pointer \(pointer.chunkCount)")
    }
    return try list.enumerated().map { position, item in
        guard let chunk = RecordLogChunkDescriptor(json: item, position: position) else {
            throw RecordLogReceiptFailure("a manifest chunk lacks its descriptor")
        }
        guard chunk.pathIsRelative else {
            throw RecordLogReceiptFailure("a manifest chunk's path leaves the grant")
        }
        return chunk
    }
}
