import CryptoKit
import Foundation

/// Reading one chunk of a base snapshot back, verified against the manifest
/// entry that describes it (#3436, behavior 22).
///
/// A port of `readSnapshotChunk` in `packages/js-bao/src/utils/snapshotChunks.ts`.
/// A chunk goes STRAIGHT into this client's authoritative table, so a truncated
/// or swapped one would write records the server never had — and on a format-2
/// document there is no whole-document comparison left to notice. The digest is
/// therefore checked before anything is decompressed: cheaper than inflating
/// bytes that are already wrong, and it is the check that makes a bad chunk a
/// typed refusal the loader can re-fetch on.
///
/// ## The line format
///
/// One `⟨id⟩\t⟨_data JSON verbatim⟩` line per record, `\n`-separated. Verbatim
/// matters: the data comes out of the server's `json_patch` and goes straight
/// into this client's `records` table, so re-serializing it here would be a
/// chance to round a number the server stored exactly.
/// A chunk that is not the one its manifest entry describes.
///
/// `key` names the object for the process that fetched it; `reason` is what a
/// record of the failure may carry to a reader who is never shown a storage
/// address, and `{model, ordinal}` is what the log line names — never the key
/// and never a grant path (the spec's Observability section).
///
/// Its own type rather than a `JsBaoError` code, as on the JS side: it is not
/// a refusal an application handles, it is the signal the LOADER acts on by
/// re-fetching the chunk. What reaches an application is the typed refusal the
/// loader raises when a re-fetch does not help.
public struct SnapshotChunkIntegrityError: Error, Equatable, CustomStringConvertible {
    public let key: String
    public let model: String
    public let ordinal: Int?
    public let reason: String

    public var description: String {
        "Snapshot chunk \(key) does not match its manifest entry: \(reason)"
    }

    /// What may be logged: the chunk's place, never its address.
    public var loggableChunk: String {
        "{model: \(model), ordinal: \(ordinal.map(String.init) ?? "?")}"
    }
}

public enum SnapshotChunkReader {

    /// One row of the authoritative `records` table, as a chunk carries it.
    public struct Row: Sendable, Equatable {
        public let type: String
        public let id: String
        /// The record's `_data` JSON, exactly as the chunk spelled it.
        public let data: String
    }

    /// Read a chunk back, verified against its manifest entry.
    ///
    /// - Parameter ordinal: the chunk's place in the manifest, carried into
    ///   the refusal so a log line can name `{model, ordinal}` without naming
    ///   the object.
    public static func read(
        body: Data,
        entry: SnapshotChunkEntry,
        ordinal: Int? = nil
    ) throws -> [Row] {
        func refuse(_ reason: String) -> SnapshotChunkIntegrityError {
            SnapshotChunkIntegrityError(
                key: entry.key,
                model: entry.model,
                ordinal: ordinal ?? entry.ordinal,
                reason: reason
            )
        }

        // Length and digest BEFORE any decompression work: a chunk that is
        // already the wrong bytes must not cost this device an inflate of
        // however many megabytes it carries.
        guard body.count == entry.bytes else {
            throw refuse("expected \(entry.bytes) bytes, got \(body.count)")
        }
        let digest = SHA256.hash(data: body)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == entry.sha256 else {
            throw refuse("expected sha256 \(entry.sha256), got \(digest)")
        }

        guard let inflated = Gzip.gunzip(body) else {
            throw refuse("its bytes are not a well-formed gzip member")
        }

        // Split on BYTES, not on Swift `Character`s. A `\r\n` is ONE grapheme
        // cluster to Swift, so `String.split(separator: "\n")` does not break
        // a CRLF-terminated line at all — the whole chunk comes back as a
        // single row and the refusal below could never fire. The ndjson format
        // is defined in bytes; so is reading it.
        let newline = UInt8(ascii: "\n")
        let carriageReturn = UInt8(ascii: "\r")
        let tab = UInt8(ascii: "\t")
        var rows: [Row] = []
        for line in inflated.split(separator: newline, omittingEmptySubsequences: true) {
            // Edge E8. The encoder refuses a record whose id or data holds
            // `\r`, so a chunk whose lines end `\r\n` was not written by this
            // platform. Keeping the carriage return would put it inside the
            // record's `_data` — valid JSON, a different document — so it is a
            // refusal rather than a repair.
            guard !line.contains(carriageReturn) else {
                throw refuse("a line carries a carriage return, which the line format reserves")
            }
            guard let separator = line.firstIndex(of: tab) else {
                throw refuse("a line carries no id/data separator")
            }
            guard let id = String(data: line[line.startIndex..<separator], encoding: .utf8),
                  let data = String(
                      data: line[line.index(after: separator)...], encoding: .utf8
                  )
            else {
                throw refuse("a line is not UTF-8")
            }
            rows.append(Row(type: entry.model, id: id, data: data))
        }

        guard rows.count == entry.rows else {
            throw refuse("expected \(entry.rows) rows, got \(rows.count)")
        }

        // The counts above do not establish the IDS (#3432, decision 3432-03).
        // `[a, a, b]` declaring three rows passes the length, the digest and
        // the row count, and even an id-SET comparison against the table —
        // while applying it overwrites one record with another. A `rows: 0`
        // chunk carries no ids and skips all of it (edge E7).
        // Identity here is the BYTES, as it is everywhere else a record id is
        // compared (`compareRecordIds`). A `Set<String>` would call two
        // canonically equivalent ids one id and refuse a chunk that carries
        // both — a valid base, rejected, and the load failing for a reason that
        // is not true of it.
        guard !rows.isEmpty else { return rows }
        var seen = Set<ByteKey>()
        for row in rows where !seen.insert(ByteKey(row.id)).inserted {
            throw refuse("duplicate id \(row.id)")
        }
        guard compareRecordIds(rows[0].id, entry.firstId) == 0 else {
            throw refuse("expected it to begin at \(entry.firstId), got \(rows[0].id)")
        }
        guard compareRecordIds(rows[rows.count - 1].id, entry.lastId) == 0 else {
            throw refuse(
                "expected it to end at \(entry.lastId), got \(rows[rows.count - 1].id)"
            )
        }
        return rows
    }

    /// One snapshot row as an overlay entry that REPLACES whatever is there.
    ///
    /// A snapshot row is the whole record, not a patch, so it carries
    /// `replace` — which is also what clears any stringset members a
    /// half-loaded earlier attempt left behind. The same conversion the server
    /// uses to install an imported chain, because a row must not come to mean
    /// two things.
    public static func overlayEntry(
        id: String,
        data: [String: JSONValue],
        stringSetFields: Set<String>
    ) -> OverlayRecordEntry {
        var fields: [String: JSONValue] = [:]
        var stringSets: [String: [String: Bool]] = [:]
        for (field, value) in data {
            if field == "id" { continue }
            if stringSetFields.contains(field), case .array(let members) = value {
                var set: [String: Bool] = [:]
                for member in members { set[memberName(member)] = true }
                stringSets[field] = set
                continue
            }
            fields[field] = value
        }
        return OverlayRecordEntry(
            id: id, fields: fields, stringSets: stringSets,
            replace: true, deleted: false
        )
    }

    /// How `String(member)` renders a stringset member on the JS side, so a
    /// set written by either client reads the same on the other.
    private static func memberName(_ value: JSONValue) -> String {
        switch value {
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .number(let value):
            if value.rounded() == value, value.magnitude < 1e15 {
                return String(Int(value))
            }
            return String(value)
        case .array, .object: return "[object Object]"
        }
    }

    /// Decode one chunk line's `_data` into the fields a fold applies.
    public static func decodeData(
        _ data: String, entry: SnapshotChunkEntry, ordinal: Int?, id: String
    ) throws -> [String: JSONValue] {
        guard let bytes = data.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: bytes),
              case .object(let fields) = value
        else {
            throw SnapshotChunkIntegrityError(
                key: entry.key,
                model: entry.model,
                ordinal: ordinal ?? entry.ordinal,
                reason: "record \(id) does not carry a JSON object"
            )
        }
        return fields
    }
}
