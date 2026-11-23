import CryptoKit
import XCTest
@testable import JsBaoClient

/// #4475 — the Swift bulk-load chunk builder, with no server.
///
/// - Behavior 11 and E7: for the rows the JS suite builds too
///   (`Fixtures/DocumentIngestChunks`), each chunk's `rows`, `rawBytes`,
///   `firstId`, `lastId` and the SHA-256 of its decompressed body are the
///   fixture's — the same chunk text the JS builder wrote — and its
///   descriptor describes its own gzip body. `Gzip.gzip` writes the fixed
///   header and round-trips through `Gzip.gunzip`.
/// - Behavior 12, E4, E5: the JS builder's canonical rules (key order, number
///   text, escapes, model and id order, cuts) and its refusals and limits.
final class DocumentIngestChunksHermeticTests: XCTestCase {

    private static let MiB = 1024 * 1024

    private static var fixtureDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)
        // .../Tests/JsBaoClientTests/<this file>
        url.deleteLastPathComponent()
        return url.appendingPathComponent("Fixtures/DocumentIngestChunks")
    }

    private struct FixtureRows: Decodable {
        struct Options: Decodable { let cutRows: Int }
        struct Row: Decodable {
            let model: String
            let id: String
            let patch: [String: JSONValue]
        }
        let options: Options
        let rows: [Row]
    }

    private struct FixtureChunks: Decodable {
        struct Chunk: Decodable, Equatable {
            let model: String
            let index: Int
            let rows: Int
            let rawBytes: Int
            let firstId: String
            let lastId: String
            let rawSha256: String
        }
        let chunks: [Chunk]
    }

    private func build(
        _ rows: [DocumentIngestRow], _ options: DocumentIngestBuildOptions = DocumentIngestBuildOptions()
    ) throws -> [DocumentIngestChunk] {
        try DocumentIngestChunkBuilder.build(rows, options: options)
    }

    private func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func text(_ chunk: DocumentIngestChunk) throws -> String {
        String(decoding: try XCTUnwrap(Gzip.gunzip(chunk.body)), as: UTF8.self)
    }

    private func lines(_ chunk: DocumentIngestChunk) throws -> [String] {
        Array(try text(chunk).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init))
    }

    /// The one line a single row renders to.
    private func line(_ patch: [String: JSONValue]) throws -> String {
        let chunks = try build([DocumentIngestRow(model: "Note", id: "r", patch: patch)])
        return try lines(chunks[0])[0]
    }

    /// The builder's refusal, which must be `.invalidArgument`.
    private func refusal(_ body: () throws -> Any, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try body()
            XCTFail("the builder did not refuse", file: file, line: line)
            return ""
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument, file: file, line: line)
            return error.message
        } catch {
            XCTFail("refused with \(error)", file: file, line: line)
            return ""
        }
    }

    /// Printable ASCII that JSON leaves unescaped, from a seeded generator:
    /// text gzip cannot shrink much. The same generator as the JS suite's.
    private func incompressible(_ length: Int, seed: UInt32) -> String {
        let alphabet = (32..<127).map { UInt8($0) }.filter { $0 != 0x22 && $0 != 0x5C }
        var state = seed
        var out = [UInt8](repeating: 0, count: length)
        for i in 0..<length {
            state = state &* 1_664_525 &+ 1_013_904_223
            out[i] = alphabet[Int(state % UInt32(alphabet.count))]
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Behavior 11

    func testTheSharedFixtureRowsBuildTheChunkTextTheJSBuilderWrote() throws {
        let rows = try JSONDecoder().decode(
            FixtureRows.self, from: Data(contentsOf: Self.fixtureDirectory.appendingPathComponent("rows.json"))
        )
        let expected = try JSONDecoder().decode(
            FixtureChunks.self, from: Data(contentsOf: Self.fixtureDirectory.appendingPathComponent("chunks.json"))
        ).chunks
        let chunks = try build(
            rows.rows.map { DocumentIngestRow(model: $0.model, id: $0.id, patch: $0.patch) },
            DocumentIngestBuildOptions(cutRows: rows.options.cutRows)
        )
        let described = try chunks.map { chunk in
            FixtureChunks.Chunk(
                model: chunk.model, index: chunk.index, rows: chunk.rows, rawBytes: chunk.rawBytes,
                firstId: chunk.firstId, lastId: chunk.lastId,
                rawSha256: hex(try XCTUnwrap(Gzip.gunzip(chunk.body)))
            )
        }
        let decompressed = try chunks.map(text)
        XCTAssertEqual(described, expected, "decompressed text: \(decompressed)")
        for chunk in chunks {
            XCTAssertEqual(chunk.bytes, chunk.body.count)
            XCTAssertEqual(chunk.sha256, hex(chunk.body))
            XCTAssertEqual(try XCTUnwrap(Gzip.gunzip(chunk.body)).count, chunk.rawBytes)
        }
    }

    func testGzipWritesTheFixedHeaderAndRoundTrips() throws {
        let raw = Data("n1\t{\"title\":\"one\"}\n".utf8)
        let body = Gzip.gzip(raw)
        XCTAssertEqual(Array(body.prefix(10)), [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])
        XCTAssertEqual(Gzip.gunzip(body), raw)
        XCTAssertEqual(Gzip.gzip(raw), body, "the same bytes in give the same member out")
        XCTAssertEqual(Gzip.gunzip(Gzip.gzip(Data())), Data())
        XCTAssertEqual(Gzip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        let large = Data(incompressible(3 * Self.MiB, seed: 3).utf8)
        XCTAssertEqual(Gzip.gunzip(Gzip.gzip(large)), large)
    }

    // MARK: - Behavior 12

    func testIdsAscendInUTF8OrderAndModelsAreEmittedInUTF8NameOrder() throws {
        let chunks = try build([
            DocumentIngestRow(model: "alpha", id: "\u{1F600}", patch: [:]),
            DocumentIngestRow(model: "beta", id: "e", patch: [:]),
            DocumentIngestRow(model: "alpha", id: "b", patch: [:]),
            DocumentIngestRow(model: "Zed", id: "z", patch: [:]),
            DocumentIngestRow(model: "alpha", id: "\u{FF21}", patch: [:]),
            DocumentIngestRow(model: "alpha", id: "a", patch: [:]),
        ])
        XCTAssertEqual(chunks.map(\.model), ["Zed", "alpha", "beta"])
        XCTAssertEqual(chunks.map(\.index), [0, 0, 0])
        XCTAssertEqual(try lines(chunks[1]).map { String($0.split(separator: "\t")[0]) }, ["a", "b", "\u{FF21}", "\u{1F600}"])
        XCTAssertEqual(chunks[1].firstId, "a")
        XCTAssertEqual(chunks[1].lastId, "\u{1F600}")
    }

    func testAPatchIsWrittenAsCanonicalJSON() throws {
        XCTAssertEqual(try line(["b": 1, "a": 2, "10": 3, "9": 4]), "r\t{\"10\":3,\"9\":4,\"a\":2,\"b\":1}")
        XCTAssertEqual(
            try line(["n": ["z": [["y": 1, "x": 2]], "é": 1, "e": 2, "Z": 3]]),
            "r\t{\"n\":{\"Z\":3,\"e\":2,\"z\":[{\"x\":2,\"y\":1}],\"é\":1}}"
        )
        let numbers: [(Double, String)] = [
            (3.0, "3"),
            (0.5, "0.5"),
            (-0.0, "0"),
            (1e21, "1e+21"),
            (1e20, "100000000000000000000"),
            (1e16, "10000000000000000"),
            (1.5e-7, "1.5e-7"),
            (1e-7, "1e-7"),
            (0.000001, "0.000001"),
            (5e-324, "5e-324"),
            (1.2345678901234568e20, "123456789012345680000"),
            (-1.7976931348623157e308, "-1.7976931348623157e+308"),
            (0.1 + 0.2, "0.30000000000000004"),
            (Double("9007199254740993")!, "9007199254740992"),
            (-123.456, "-123.456"),
            (2.5e-12, "2.5e-12"),
            (1.2345e25, "1.2345e+25"),
        ]
        for (value, written) in numbers {
            XCTAssertEqual(try line(["v": .number(value)]), "r\t{\"v\":\(written)}", "\(value)")
        }
        let awkward = "q \" b \\ s / n \n t \t r \r \u{08} \u{0C} \u{01} \u{1F} \u{7F} é 日本 😀 \u{2028}"
        XCTAssertEqual(
            try line(["s": .string(awkward)]),
            "r\t{\"s\":\"q \\\" b \\\\ s / n \\n t \\t r \\r \\b \\f \\u0001 \\u001f \u{7F} é 日本 😀 \u{2028}\"}"
        )
        XCTAssertEqual(try line(["t": true, "f": false, "z": .null]), "r\t{\"f\":false,\"t\":true,\"z\":null}")
    }

    func testEmptyValuesStayOneIdInTwoModelsIsTwoRecordsAndDeletedPassesThrough() throws {
        XCTAssertEqual(try line(["b": .object([:]), "c": .array([])]), "r\t{\"b\":{},\"c\":[]}")
        let twice = try build([
            DocumentIngestRow(model: "Note", id: "same", patch: ["n": 1]),
            DocumentIngestRow(model: "Tag", id: "same", patch: ["n": 2]),
        ])
        XCTAssertEqual(twice.map(\.model), ["Note", "Tag"])
        XCTAssertEqual(twice.map(\.firstId), ["same", "same"])
        XCTAssertEqual(try line(["_deleted": true, "title": "kept"]), "r\t{\"_deleted\":true,\"title\":\"kept\"}")
        XCTAssertEqual(try build([]), [])
    }

    func testChunksAreCutAtCutRowsAndBeforeARowThatWouldPassCutRawBytes() throws {
        // Every line is `rN\t{}\n`: 6 bytes.
        let rows = (0..<7).map { DocumentIngestRow(model: "Note", id: "r\($0)", patch: [:]) }
        let byRows = try build(rows, DocumentIngestBuildOptions(cutRows: 3))
        XCTAssertEqual(byRows.map(\.rows), [3, 3, 1])
        XCTAssertEqual(byRows.map(\.index), [0, 1, 2])
        XCTAssertEqual(byRows.map(\.firstId), ["r0", "r3", "r6"])
        XCTAssertEqual(byRows.map(\.lastId), ["r2", "r5", "r6"])
        XCTAssertEqual(try build(rows, DocumentIngestBuildOptions(cutRawBytes: 12)).map(\.rawBytes), [12, 12, 12, 6])
        XCTAssertEqual(try build(rows, DocumentIngestBuildOptions(cutRawBytes: 17)).map(\.rows), [2, 2, 2, 1])
        XCTAssertEqual(try build(rows, DocumentIngestBuildOptions(cutRawBytes: 5)).map(\.rows), [1, 1, 1, 1, 1, 1, 1])
    }

    func testARowTheArtifactCannotCarryIsRefusedNamingItsModelAndId() {
        let cases: [([DocumentIngestRow], String)] = [
            ([
                DocumentIngestRow(model: "Note", id: "a", patch: [:]),
                DocumentIngestRow(model: "Tag", id: "a", patch: [:]),
                DocumentIngestRow(model: "Note", id: "a", patch: ["x": 1]),
            ], "Note a"),
            ([DocumentIngestRow(model: "Note", id: "a\tb", patch: [:])], "Note \"a\\tb\""),
            ([DocumentIngestRow(model: "Note", id: "a\nb", patch: [:])], "Note \"a\\nb\""),
            ([DocumentIngestRow(model: "Note", id: "a\rb", patch: [:])], "Note \"a\\rb\""),
            ([DocumentIngestRow(model: "Note", id: "a\r\nb", patch: [:])], "Note \"a\\r\\nb\""),
            ([DocumentIngestRow(model: "Note", id: "", patch: [:])], "Note"),
            ([DocumentIngestRow(model: "Note", id: "\u{FEFF}id", patch: [:])], "Note"),
            ([DocumentIngestRow(model: "", id: "a", patch: [:])], "\"\""),
            ([DocumentIngestRow(model: "_Note", id: "a", patch: [:])], "\"_Note\""),
            ([DocumentIngestRow(model: "9Note", id: "a", patch: [:])], "\"9Note\""),
            ([DocumentIngestRow(model: "Émile", id: "a", patch: [:])], "\"Émile\""),
            ([DocumentIngestRow(model: "Note-2", id: "a", patch: [:])], "\"Note-2\""),
            ([DocumentIngestRow(model: "Note", id: "nan", patch: ["n": .number(.nan)])], "Note nan"),
            ([DocumentIngestRow(model: "Note", id: "inf", patch: ["deep": [["n": .number(.infinity)]]])], "Note inf"),
        ]
        for (rows, named) in cases {
            XCTAssertTrue(refusal { try self.build(rows) }.contains(named), named)
        }
    }

    func testACutOutsideTheServersLimitsIsRefusedBeforeAnyRowIsRead() throws {
        let bad = [DocumentIngestRow(model: "Note", id: "a\tb", patch: [:])]
        let options: [(DocumentIngestBuildOptions, String)] = [
            (DocumentIngestBuildOptions(cutRows: 0), "cutRows"),
            (DocumentIngestBuildOptions(cutRows: 50_001), "cutRows"),
            (DocumentIngestBuildOptions(cutRawBytes: 0), "cutRawBytes"),
            (DocumentIngestBuildOptions(cutRawBytes: 16 * Self.MiB + 1), "cutRawBytes"),
        ]
        for (option, named) in options {
            XCTAssertTrue(refusal { try self.build(bad, option) }.contains(named), named)
        }
        let one = try build(
            [DocumentIngestRow(model: "Note", id: "a", patch: [:])],
            DocumentIngestBuildOptions(cutRows: 50_000, cutRawBytes: 16 * Self.MiB)
        )
        XCTAssertEqual(one.count, 1)
    }

    func testTheServersRowCapAppliesBesideTheCuts() throws {
        let rows = (0..<50_001).map {
            DocumentIngestRow(model: "Note", id: "r" + String(repeating: "0", count: 6 - String($0).count) + String($0), patch: ["n": 1])
        }
        XCTAssertEqual(try build(rows, DocumentIngestBuildOptions(cutRows: 50_000)).map(\.rows), [50_000, 1])
        let defaults = try build(rows)
        XCTAssertEqual(defaults.map(\.rows), [40_000, 10_001])
        for chunk in defaults { XCTAssertLessThanOrEqual(chunk.rawBytes, 16 * Self.MiB) }
    }

    func testTheServersRawCapAppliesBesideTheCutsAndARowOverItIsRefused() throws {
        let big = String(repeating: "x", count: Self.MiB)
        let rows = (0..<20).map { DocumentIngestRow(model: "Note", id: String(format: "r%02d", $0), patch: ["s": .string(big)]) }
        let chunks = try build(rows, DocumentIngestBuildOptions(cutRawBytes: 16 * Self.MiB))
        XCTAssertEqual(chunks.map(\.rows), [15, 5])
        for chunk in chunks { XCTAssertLessThanOrEqual(chunk.rawBytes, 16 * Self.MiB) }
        let huge = refusal {
            try self.build([DocumentIngestRow(model: "Note", id: "big", patch: ["s": .string(String(repeating: "x", count: 16 * Self.MiB))])])
        }
        XCTAssertTrue(huge.contains("Note big"), huge)
    }

    func testAChunkPast8MiBStoredIsSplitInHalfByRowsAndARowThatCannotFitIsRefused() throws {
        let rows = (0..<12).map {
            DocumentIngestRow(
                model: "Note", id: String(format: "r%02d", $0),
                patch: ["s": .string(incompressible(Self.MiB - 32, seed: UInt32($0 + 1)))]
            )
        }
        let chunks = try build(rows)
        XCTAssertEqual(chunks.map(\.rows), [6, 6])
        XCTAssertEqual(chunks.map(\.index), [0, 1])
        XCTAssertEqual(chunks.map(\.firstId), ["r00", "r06"])
        XCTAssertEqual(chunks.map(\.lastId), ["r05", "r11"])
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.bytes, 8 * Self.MiB)
            XCTAssertEqual(chunk.bytes, chunk.body.count)
        }
        let single = refusal {
            try self.build([DocumentIngestRow(model: "Note", id: "dense", patch: ["s": .string(self.incompressible(12 * Self.MiB, seed: 7))])])
        }
        XCTAssertTrue(single.contains("Note dense"), single)
    }

    func testAnArtifactOfMoreChunksThanALoadMayHoldIsRefusedBeforeAnyIsReturned() throws {
        let rows = (0..<4097).map { DocumentIngestRow(model: "Note", id: String(format: "r%05d", $0), patch: [:]) }
        XCTAssertTrue(refusal { try self.build(rows, DocumentIngestBuildOptions(cutRows: 1)) }.contains("4096"))
        XCTAssertEqual(try build(Array(rows.prefix(4096)), DocumentIngestBuildOptions(cutRows: 1)).count, 4096)
    }
}
