import CryptoKit
import XCTest
@testable import JsBaoClient

/// Reading one chunk of a base snapshot (#3436, behavior 22, edges E7 and E8).
///
/// The bytes under test are the bytes the REAL platform encoder wrote: the
/// harness runs `encodeSnapshotChunk` — the Durable Object's own builder half
/// — and hands back the body and the manifest entry that describes it. A Swift
/// reader that agreed with a transcription of the format but not with the
/// writer would put records into this client's authoritative table that the
/// server never wrote, and on a format-2 document there is no whole-document
/// comparison left to notice.
final class Format2SnapshotChunkHermeticTests: XCTestCase {

    private struct EncodedChunk {
        let entry: SnapshotChunkEntry
        let body: Data
    }

    /// Encode chunks through js-bao's own builder.
    private func encode(
        _ chunks: [(model: String, ordinal: Int, rows: [(id: String, data: String)])]
    ) throws -> [EncodedChunk] {
        let response = try Format2Harness.run([
            "command": "encode-chunk",
            "chunks": chunks.map { chunk in
                [
                    "key": "app/doc/7-b1/\(chunk.model)/\(chunk.ordinal).ndjson.gz",
                    "path": "\(chunk.model)/\(chunk.ordinal)",
                    "ordinal": chunk.ordinal,
                    "model": chunk.model,
                    "rows": chunk.rows.map { ["id": $0.id, "data": $0.data] },
                ] as [String: Any]
            },
        ])
        let encoded = try XCTUnwrap(response["chunks"] as? [[String: Any]])
        return try encoded.map { each in
            let entry = try XCTUnwrap(each["entry"] as? [String: Any])
            let body = try XCTUnwrap(
                Data(base64Encoded: try XCTUnwrap(each["body"] as? String))
            )
            return EncodedChunk(
                entry: SnapshotChunkEntry(
                    key: try XCTUnwrap(entry["key"] as? String),
                    path: entry["path"] as? String,
                    ordinal: entry["ordinal"] as? Int,
                    model: try XCTUnwrap(entry["model"] as? String),
                    bytes: try XCTUnwrap(entry["bytes"] as? Int),
                    rawBytes: entry["rawBytes"] as? Int,
                    rows: try XCTUnwrap(entry["rows"] as? Int),
                    firstId: try XCTUnwrap(entry["firstId"] as? String),
                    lastId: try XCTUnwrap(entry["lastId"] as? String),
                    sha256: try XCTUnwrap(entry["sha256"] as? String)
                ),
                body: body
            )
        }
    }

    private func entry(
        _ base: SnapshotChunkEntry,
        bytes: Int? = nil,
        rows: Int? = nil,
        firstId: String? = nil,
        lastId: String? = nil,
        sha256: String? = nil
    ) -> SnapshotChunkEntry {
        SnapshotChunkEntry(
            key: base.key, path: base.path, ordinal: base.ordinal, model: base.model,
            bytes: bytes ?? base.bytes, rawBytes: base.rawBytes, rows: rows ?? base.rows,
            firstId: firstId ?? base.firstId, lastId: lastId ?? base.lastId,
            sha256: sha256 ?? base.sha256
        )
    }

    // MARK: - Behavior 22 — the happy path

    func testAChunkTheRealEncoderWroteDecodesToTheRowsItCarried() throws {
        let rows = [
            (id: "n1", data: #"{"title":"first","n":1}"#),
            (id: "n2", data: #"{"title":"second","n":2.5}"#),
            (id: "n3", data: #"{"title":"third","tags":["a","b"]}"#),
        ]
        let chunk = try encode([(model: "Note", ordinal: 0, rows: rows)])[0]

        let decoded = try SnapshotChunkReader.read(body: chunk.body, entry: chunk.entry)
        XCTAssertEqual(decoded.map(\.id), ["n1", "n2", "n3"])
        XCTAssertEqual(decoded.map(\.type), ["Note", "Note", "Note"])
        // VERBATIM: the data came out of the server's `json_patch` and goes
        // straight back into this client's `records` table, so re-serializing
        // it here would be a chance to round a number the server stored
        // exactly.
        XCTAssertEqual(decoded.map(\.data), rows.map(\.data))
    }

    func testAnEmptyChunkDecodesToNoRowsAndIsNotAnIntegrityFailure() throws {
        let chunk = try encode([(model: "Note", ordinal: 4, rows: [])])[0]
        XCTAssertEqual(chunk.entry.rows, 0)
        XCTAssertEqual(try SnapshotChunkReader.read(body: chunk.body, entry: chunk.entry).count, 0)
    }

    /// Edge E7 — a `rows: 0` chunk carries no ids, so the id-range checks say
    /// nothing about it and are skipped. The entry the builder writes for one
    /// has EMPTY bounds, which a reader that insisted on matching them would
    /// refuse.
    func testARowsZeroChunkSkipsTheIdRangeChecks() throws {
        let chunk = try encode([(model: "Note", ordinal: 0, rows: [])])[0]
        XCTAssertEqual(chunk.entry.firstId, "")
        XCTAssertEqual(chunk.entry.lastId, "")
        XCTAssertNoThrow(
            try SnapshotChunkReader.read(
                // Bounds that would run backwards if they were checked.
                body: chunk.body,
                entry: entry(chunk.entry, firstId: "z", lastId: "a")
            )
        )
    }

    // MARK: - Behavior 22 — every integrity failure

    func testAShortBodyIsRefusedByLength() throws {
        let chunk = try encode([(model: "Note", ordinal: 2, rows: [(id: "n1", data: "{}")])])[0]
        XCTAssertThrowsError(
            try SnapshotChunkReader.read(
                body: chunk.body.dropLast(4), entry: chunk.entry
            )
        ) { error in
            let refusal = error as? SnapshotChunkIntegrityError
            XCTAssertEqual(refusal?.model, "Note")
            XCTAssertEqual(refusal?.ordinal, 2)
            XCTAssertEqual(
                refusal?.reason,
                "expected \(chunk.entry.bytes) bytes, got \(chunk.entry.bytes - 4)"
            )
        }
    }

    func testBytesThatAreNotTheEntrysDigestAreRefused() throws {
        let chunk = try encode([(model: "Note", ordinal: 1, rows: [(id: "n1", data: "{}")])])[0]
        let wrong = String(repeating: "f", count: 64)
        XCTAssertThrowsError(
            try SnapshotChunkReader.read(
                body: chunk.body, entry: entry(chunk.entry, sha256: wrong)
            )
        ) { error in
            let refusal = error as? SnapshotChunkIntegrityError
            XCTAssertEqual(refusal?.model, "Note")
            XCTAssertEqual(refusal?.ordinal, 1)
            XCTAssertTrue(
                refusal?.reason.hasPrefix("expected sha256 \(wrong), got ") == true,
                "reason was \(refusal?.reason ?? "<none>")"
            )
        }
    }

    /// The digest is checked BEFORE any decompression work: inflating bytes
    /// that are already wrong costs this device the whole chunk for nothing.
    /// Observable because bytes that are neither the right digest NOR valid
    /// gzip are refused as a DIGEST mismatch.
    func testTheDigestIsCheckedBeforeAnyGunzipWork() throws {
        let chunk = try encode([(model: "Note", ordinal: 0, rows: [(id: "n1", data: "{}")])])[0]
        let notGzipAtAll = Data(repeating: 0x41, count: chunk.entry.bytes)
        XCTAssertThrowsError(
            try SnapshotChunkReader.read(body: notGzipAtAll, entry: chunk.entry)
        ) { error in
            let reason = (error as? SnapshotChunkIntegrityError)?.reason ?? ""
            XCTAssertTrue(
                reason.hasPrefix("expected sha256 "),
                "a chunk that is not gzip at all was refused as \(reason), so the "
                    + "gunzip ran before the digest check"
            )
        }
    }

    func testARowCountThatDisagreesWithTheEntryIsRefused() throws {
        let chunk = try encode([(
            model: "Note", ordinal: 0,
            rows: [(id: "n1", data: "{}"), (id: "n2", data: "{}")]
        )])[0]
        XCTAssertThrowsError(
            try SnapshotChunkReader.read(body: chunk.body, entry: entry(chunk.entry, rows: 3))
        ) { error in
            XCTAssertEqual(
                (error as? SnapshotChunkIntegrityError)?.reason,
                "expected 3 rows, got 2"
            )
        }
    }

    /// The counts do not establish the IDS: `[a, a, b]` declaring three rows
    /// passes the length, the digest and the row count, and even an id-SET
    /// comparison against the table — while applying it overwrites one record
    /// with another (#3432, decision 3432-03).
    func testADuplicateIdInsideOneChunkIsRefused() throws {
        let chunk = try encode([(
            model: "Note", ordinal: 0,
            rows: [
                (id: "n1", data: #"{"v":1}"#),
                (id: "n1", data: #"{"v":2}"#),
                (id: "n2", data: #"{"v":3}"#),
            ]
        )])[0]
        XCTAssertThrowsError(
            try SnapshotChunkReader.read(body: chunk.body, entry: chunk.entry)
        ) { error in
            XCTAssertEqual(
                (error as? SnapshotChunkIntegrityError)?.reason, "duplicate id n1"
            )
        }
    }

    func testAChunkThatDoesNotBeginOrEndWhereItsEntrySaysIsRefused() throws {
        let chunk = try encode([(
            model: "Note", ordinal: 0,
            rows: [(id: "n1", data: "{}"), (id: "n2", data: "{}")]
        )])[0]
        XCTAssertThrowsError(
            try SnapshotChunkReader.read(body: chunk.body, entry: entry(chunk.entry, firstId: "n0"))
        ) { error in
            XCTAssertEqual(
                (error as? SnapshotChunkIntegrityError)?.reason,
                "expected it to begin at n0, got n1"
            )
        }
        XCTAssertThrowsError(
            try SnapshotChunkReader.read(body: chunk.body, entry: entry(chunk.entry, lastId: "n9"))
        ) { error in
            XCTAssertEqual(
                (error as? SnapshotChunkIntegrityError)?.reason,
                "expected it to end at n9, got n2"
            )
        }
    }

    /// A refusal may be recorded and logged, and what it may say is
    /// `{model, ordinal}` — never the key, and never a grant path.
    func testARefusalCanBeLoggedWithoutNamingTheObject() {
        let refusal = SnapshotChunkIntegrityError(
            key: "app/doc/7-b1/Note/3.ndjson.gz", model: "Note", ordinal: 3,
            reason: "expected 10 bytes, got 4"
        )
        XCTAssertEqual(refusal.loggableChunk, "{model: Note, ordinal: 3}")
        XCTAssertFalse(refusal.loggableChunk.contains("app/doc"))
    }

    // MARK: - Edge E8 — line endings

    /// The encoder refuses a record whose id or data holds a carriage return,
    /// so a chunk whose lines end `\r\n` was not written by this platform.
    /// Keeping it would put the `\r` inside the record's `_data` — still valid
    /// JSON, a different document — so it is a refusal rather than a repair.
    func testACarriageReturnLineEndingIsARefusal() throws {
        let body = try gzipped("n1\t{\"v\":1}\r\nn2\t{\"v\":2}\r\n")
        let described = SnapshotChunkEntry(
            key: "app/doc/7-b1/Note/0.ndjson.gz", path: "Note/0", ordinal: 0,
            model: "Note", bytes: body.count, rows: 2,
            firstId: "n1", lastId: "n2", sha256: sha256Hex(body)
        )
        XCTAssertThrowsError(
            try SnapshotChunkReader.read(body: body, entry: described)
        ) { error in
            XCTAssertEqual(
                (error as? SnapshotChunkIntegrityError)?.reason,
                "a line carries a carriage return, which the line format reserves"
            )
        }
    }

    func testTheSameLinesWithoutTheCarriageReturnsAreRead() throws {
        let body = try gzipped("n1\t{\"v\":1}\nn2\t{\"v\":2}\n")
        let described = SnapshotChunkEntry(
            key: "app/doc/7-b1/Note/0.ndjson.gz", path: "Note/0", ordinal: 0,
            model: "Note", bytes: body.count, rows: 2,
            firstId: "n1", lastId: "n2", sha256: sha256Hex(body)
        )
        XCTAssertEqual(
            try SnapshotChunkReader.read(body: body, entry: described).map(\.id),
            ["n1", "n2"]
        )
    }

    func testALineWithNoSeparatorIsARefusal() throws {
        let body = try gzipped("n1 no tab here\n")
        let described = SnapshotChunkEntry(
            key: "app/doc/7-b1/Note/0.ndjson.gz", path: "Note/0", ordinal: 7,
            model: "Note", bytes: body.count, rows: 1,
            firstId: "n1", lastId: "n1", sha256: sha256Hex(body)
        )
        XCTAssertThrowsError(
            try SnapshotChunkReader.read(body: body, entry: described)
        ) { error in
            let refusal = error as? SnapshotChunkIntegrityError
            XCTAssertEqual(refusal?.reason, "a line carries no id/data separator")
            XCTAssertEqual(refusal?.ordinal, 7)
        }
    }

    // MARK: - Identity is the bytes (finding 3436-REV-09)

    /// Two record ids that are canonically equivalent are ONE Swift `String`
    /// and two records to SQLite, to yrs and to the JS client — which is why
    /// `compareRecordIds` orders by bytes. A `Set<String>` here called them a
    /// duplicate and refused a chunk the builder had just written: a valid
    /// base, rejected, the load failing for something that is not true of it.
    func testAChunkCarryingTwoCanonicallyEquivalentIdsIsNotADuplicate() throws {
        let decomposed = "a\u{0301}"   // "a" + COMBINING ACUTE
        let precomposed = "\u{00E1}"   // LATIN SMALL LETTER A WITH ACUTE
        XCTAssertEqual(
            decomposed, precomposed,
            "precondition: Swift calls these one string — that is the whole hazard"
        )
        XCTAssertNotEqual(
            compareRecordIds(decomposed, precomposed), 0,
            "precondition: the platform calls them two records"
        )

        // In the byte order a chunk's rows are written in.
        let ids = [decomposed, precomposed].sorted { compareRecordIds($0, $1) < 0 }
        let chunk = try encode([(
            model: "Note", ordinal: 0,
            rows: ids.map { (id: $0, data: #"{"title":"x"}"#) }
        )])[0]

        let decoded = try SnapshotChunkReader.read(body: chunk.body, entry: chunk.entry)
        XCTAssertEqual(decoded.count, 2, "both rows survive the read")
        XCTAssertNotEqual(
            compareRecordIds(decoded[0].id, decoded[1].id), 0,
            "and they are still two records"
        )
    }

    // MARK: - Rows into overlay entries

    /// A snapshot row is the whole record, not a patch, so it carries
    /// `replace` — which is also what clears any members a half-loaded earlier
    /// attempt left behind. A declared stringset field becomes MEMBERS; an
    /// array on a field that is not declared one stays an array value.
    func testARowBecomesAReplacingOverlayEntryWithItsStringsetsSplitOut() throws {
        let fields: [String: JSONValue] = [
            "id": .string("n1"),
            "title": .string("first"),
            "tags": .array([.string("a"), .string("b")]),
            "scores": .array([.number(1), .number(2)]),
        ]
        let overlay = SnapshotChunkReader.overlayEntry(
            id: "n1", data: fields, stringSetFields: ["tags"]
        )
        XCTAssertTrue(overlay.replace)
        XCTAssertFalse(overlay.deleted)
        XCTAssertEqual(overlay.stringSets["tags"], ["a": true, "b": true])
        XCTAssertEqual(overlay.fields["title"], .string("first"))
        XCTAssertEqual(overlay.fields["scores"], .array([.number(1), .number(2)]))
        // `id` is the row's identity, never one of its fields.
        XCTAssertNil(overlay.fields["id"])
    }

    // MARK: - helpers

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Gzip bytes for a body the platform encoder would refuse to write, so
    /// edge E8 can be stated at all. Built by `node`'s own zlib rather than by
    /// hand: the reader's gunzip has to be fed a real member.
    private func gzipped(_ text: String) throws -> Data {
        let node = try Format2Harness.nodePath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [
            "-e",
            "const z=require('zlib');let c=[];process.stdin.on('data',d=>c.push(d))"
                + ".on('end',()=>process.stdout.write(z.gzipSync(Buffer.concat(c))));",
        ]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(text.utf8))
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}
