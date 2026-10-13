import CryptoKit
import Foundation

// The readers of a receipt's chunks: a bulk load's ingest chunk, a segment's
// row chunk and its corrections chunk. Ports of js-bao's `readIngestChunk`,
// `readSnapshotChunk` and `readCorrectionsChunk` (`utils/snapshotChunks.ts`).
//
// The bytes came from the room's artifacts through a grant, so every chunk is
// checked against what its manifest or pointer says of it before anything is
// applied: the stored length and sha256 before a byte is inflated, inflation
// stopped the moment it passes `rawBytes` and equal to it at the end, the
// line count equal to `rows`, and the ids against the chunk's range.

/// A chunk that is not the one its manifest entry or pointer describes.
///
/// It names the chunk by its place (`Note/3`, `corrections`), never by the
/// grant path it was read through.
struct RecordLogChunkError: Error, Equatable, CustomStringConvertible {
    enum Code: String, Sendable {
        /// The bytes are not what the descriptor said.
        case integrity = "INGEST_CHUNK_INTEGRITY"
        /// A line is not `⟨id⟩\t⟨JSON object⟩`.
        case lineInvalid = "INGEST_LINE_INVALID"
        /// The lines are not in id order, or one id repeats.
        case unordered = "INGEST_LINES_UNORDERED"
    }

    let code: Code
    /// Which chunk: its model and index, or `corrections`.
    let place: String
    /// What was wrong.
    let reason: String

    var description: String { "The chunk \(place) does not match its descriptor (\(code.rawValue)): \(reason)" }
}

/// What a chunk's manifest entry (a load's) or pointer (a segment's) says of it.
struct RecordLogChunkDescriptor: Equatable, Sendable {
    var model: String
    var index: Int
    /// Where it is read, relative to the grant's path.
    var path: String
    var rows: Int
    var bytes: Int
    var rawBytes: Int
    var sha256: String
    var firstId: String
    var lastId: String

    /// The chunk's place in a refusal or a log line.
    var place: String { "\(model)/\(index)" }
}

/// What a segment's pointer says of its corrections chunk.
struct RecordLogCorrectionsDescriptor: Equatable, Sendable {
    var rows: Int
    var bytes: Int
    var rawBytes: Int
    var sha256: String
    var path: String
}

enum RecordLogChunkReader {

    /// Read one chunk of a bulk load: `⟨id⟩\t⟨patch JSON⟩` lines in strictly
    /// ascending id order (SQLite's order), the first and last the
    /// descriptor's.
    static func readLoadChunk(_ body: Data, _ descriptor: RecordLogChunkDescriptor) throws -> [RecordLogLoadLine] {
        let place = descriptor.place
        let text = try inflate(
            body, place: place, bytes: descriptor.bytes, rawBytes: descriptor.rawBytes, sha256: descriptor.sha256
        )
        var lines: [(id: String, json: Substring)] = []
        var previous: String?
        for line in splitLines(text) {
            if lines.count >= descriptor.rows {
                throw RecordLogChunkError(
                    code: .integrity, place: place, reason: "the chunk carries more than the \(descriptor.rows) rows it declares"
                )
            }
            guard let tab = line.firstIndex(of: "\t") else {
                throw RecordLogChunkError(code: .lineInvalid, place: place, reason: "a line carries no id/patch separator")
            }
            let id = String(line[..<tab])
            guard !id.isEmpty else {
                throw RecordLogChunkError(code: .lineInvalid, place: place, reason: "a line carries no id")
            }
            if let previous, compareIds(id, previous) <= 0 {
                throw RecordLogChunkError(code: .unordered, place: place, reason: "id \(id) does not come after \(previous)")
            }
            previous = id
            lines.append((id, line[line.index(after: tab)...]))
        }
        let patches = try objects(lines, place: place, what: "patch")
        try checkCount(lines.count, descriptor.rows, place: place)
        try checkRange(lines.first?.id, lines.last?.id, descriptor)
        return zip(lines, patches).map { RecordLogLoadLine(id: $0.id, patch: $1) }
    }

    /// Read one row chunk of a segment: `⟨id⟩\t⟨row JSON⟩` lines of the
    /// descriptor's model, no id twice, the first and last the descriptor's.
    static func readSegmentChunk(_ body: Data, _ descriptor: RecordLogChunkDescriptor) throws -> [RecordLogCatchUpRow] {
        let place = descriptor.place
        let text = try inflate(
            body, place: place, bytes: descriptor.bytes, rawBytes: descriptor.rawBytes, sha256: descriptor.sha256
        )
        var lines: [(id: String, json: Substring)] = []
        var seen = Set<String>()
        for line in splitLines(text) {
            guard let tab = line.firstIndex(of: "\t") else {
                throw RecordLogChunkError(code: .integrity, place: place, reason: "a line carries no id/data separator")
            }
            let id = String(line[..<tab])
            guard seen.insert(id).inserted else {
                throw RecordLogChunkError(code: .integrity, place: place, reason: "duplicate id \(id)")
            }
            lines.append((id, line[line.index(after: tab)...]))
        }
        try checkCount(lines.count, descriptor.rows, place: place)
        try checkRange(lines.first?.id, lines.last?.id, descriptor)
        let rows = try objects(lines, place: place, what: "row")
        return zip(lines, rows).map { RecordLogCatchUpRow(model: descriptor.model, id: $0.id, row: $1) }
    }

    /// Read a segment's corrections chunk: every row and tombstone written
    /// after the segment began, each line `⟨id⟩\t⟨JSON object⟩` naming its model
    /// in `_type` (`_deleted: true` for a tombstone). A record is `(model, id)`,
    /// so one bare id may appear under two models; one record twice is refused.
    static func readCorrectionsChunk(_ body: Data, _ descriptor: RecordLogCorrectionsDescriptor) throws -> [RecordLogCorrection] {
        let place = "corrections"
        func refuse(_ reason: String) -> RecordLogChunkError {
            RecordLogChunkError(code: .integrity, place: place, reason: reason)
        }
        let text = try inflate(
            body, place: place, bytes: descriptor.bytes, rawBytes: descriptor.rawBytes, sha256: descriptor.sha256
        )
        var out: [RecordLogCorrection] = []
        var seen = Set<RecordLogRecordKey>()
        for line in splitLines(text) {
            if out.count >= descriptor.rows {
                throw refuse("the chunk carries more than the \(descriptor.rows) rows it declares")
            }
            guard let tab = line.firstIndex(of: "\t") else { throw refuse("a line carries no id/data separator") }
            let id = String(line[..<tab])
            guard let parsed = RecordLogJSON.parse(String(line[line.index(after: tab)...])) else {
                throw refuse("the line for \(id) is not JSON")
            }
            guard var fields = parsed.objectValue else { throw refuse("the line for \(id) is not a JSON object") }
            guard case .string(let model)? = fields.removeValue(forKey: "_type"), !model.isEmpty else {
                throw refuse("the line for \(id) names no model in _type")
            }
            let deleted = fields.removeValue(forKey: "_deleted") == .bool(true)
            let key = RecordLogRecordKey(model: model, id: id)
            guard seen.insert(key).inserted else { throw refuse("duplicate record \(model)/\(id)") }
            fields["id"] = .string(id)
            out.append(RecordLogCorrection(model: model, id: id, row: deleted ? nil : fields))
        }
        try checkCount(out.count, descriptor.rows, place: place)
        return out
    }

    /// The text's non-empty lines, split at every LF as the JS readers split
    /// them. A `Character` split would not: Swift reads CR LF as one
    /// character, so a CRLF chunk would stay one line. The CR stays at the end
    /// of the line's JSON, whose whitespace it is.
    private static func splitLines(_ text: String) -> [Substring] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: true).map(Substring.init)
    }

    // MARK: - Checks

    /// The chunk's text: its stored length and digest checked first, then
    /// inflated no further than `rawBytes`, which it must equal.
    private static func inflate(_ body: Data, place: String, bytes: Int, rawBytes: Int, sha256: String) throws -> String {
        func refuse(_ reason: String) -> RecordLogChunkError {
            RecordLogChunkError(code: .integrity, place: place, reason: reason)
        }
        guard body.count == bytes else { throw refuse("expected \(bytes) stored bytes, got \(body.count)") }
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256.lowercased() else { throw refuse("expected sha256 \(sha256), got \(digest)") }
        switch Gzip.gunzipBounded(body, limit: rawBytes) {
        case .pastLimit:
            throw refuse("the chunk decompresses past the \(rawBytes) bytes it declares")
        case .unreadable:
            throw refuse("the chunk is not readable gzip")
        case .inflated(let inflated):
            guard inflated.count == rawBytes else {
                throw refuse("expected \(rawBytes) decompressed bytes, got \(inflated.count)")
            }
            return String(decoding: inflated, as: UTF8.self)
        }
    }

    private static func checkCount(_ count: Int, _ rows: Int, place: String) throws {
        guard count == rows else {
            throw RecordLogChunkError(code: .integrity, place: place, reason: "expected \(rows) rows, got \(count)")
        }
    }

    private static func checkRange(_ first: String?, _ last: String?, _ descriptor: RecordLogChunkDescriptor) throws {
        guard let first, let last else { return }
        if first != descriptor.firstId {
            throw RecordLogChunkError(
                code: .integrity, place: descriptor.place, reason: "expected it to begin at \(descriptor.firstId), got \(first)"
            )
        }
        if last != descriptor.lastId {
            throw RecordLogChunkError(
                code: .integrity, place: descriptor.place, reason: "expected it to end at \(descriptor.lastId), got \(last)"
            )
        }
    }

    /// Each line's JSON as an object, decoded in one pass; on a failure the
    /// lines are decoded one by one to name the one at fault.
    private static func objects(
        _ lines: [(id: String, json: Substring)], place: String, what: String
    ) throws -> [[String: JSONValue]] {
        if lines.isEmpty { return [] }
        let joined = "[" + lines.map(\.json).joined(separator: ",") + "]"
        if let decoded = RecordLogJSON.parse(joined)?.arrayValue, decoded.count == lines.count {
            let objects = decoded.compactMap(\.objectValue)
            if objects.count == lines.count { return objects }
        }
        return try lines.map { line in
            guard let parsed = RecordLogJSON.parse(String(line.json)) else {
                throw RecordLogChunkError(code: .lineInvalid, place: place, reason: "the \(what) for \(line.id) is not JSON")
            }
            guard let object = parsed.objectValue else {
                throw RecordLogChunkError(code: .lineInvalid, place: place, reason: "the \(what) for \(line.id) is not a JSON object")
            }
            return object
        }
    }

    /// Compare two record ids the way the room's table orders them: SQLite's
    /// `BINARY` collation, which is UTF-8 byte order.
    static func compareIds(_ left: String, _ right: String) -> Int {
        if left.utf8.elementsEqual(right.utf8) { return 0 }
        return left.utf8.lexicographicallyPrecedes(right.utf8) ? -1 : 1
    }
}
