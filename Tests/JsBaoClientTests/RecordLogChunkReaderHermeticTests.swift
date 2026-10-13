import CryptoKit
import XCTest
@testable import JsBaoClient

/// The readers of a receipt's chunks, against gzip members built here as the
/// room writes them: the Swift twin of js-bao's `readIngestChunk`,
/// `readSnapshotChunk` and `readCorrectionsChunk` cases
/// (`record-log-client-rules-load-4311.test.ts` and the ingest reader's).
///
/// Every refusal is a `RecordLogChunkError` naming the chunk's place, never the
/// path it was read from.
final class RecordLogChunkReaderHermeticTests: XCTestCase {

    /// A chunk of `text`, gzipped, and the descriptor that describes it.
    static func chunk(
        _ text: String, model: String = "Note", index: Int = 0, path: String = "Note/0.ATTEMPTSECRET"
    ) -> (body: Data, descriptor: RecordLogChunkDescriptor) {
        let raw = Data(text.utf8)
        let body = GzipFixture.gzip(raw)
        let ids = text.split(separator: "\n").compactMap { $0.split(separator: "\t", maxSplits: 1).first.map(String.init) }
        return (body, RecordLogChunkDescriptor(
            model: model, index: index, path: path, rows: ids.count, bytes: body.count, rawBytes: raw.count,
            sha256: sha256(body), firstId: ids.first ?? "", lastId: ids.last ?? ""
        ))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func refusal(
        _ body: Data, _ descriptor: RecordLogChunkDescriptor, _ read: (Data, RecordLogChunkDescriptor) throws -> Any,
        file: StaticString = #filePath, line: UInt = #line
    ) -> RecordLogChunkError? {
        do {
            _ = try read(body, descriptor)
            XCTFail("the chunk was read", file: file, line: line)
            return nil
        } catch let error as RecordLogChunkError {
            XCTAssertFalse(error.description.contains(descriptor.path), "the refusal names no path", file: file, line: line)
            XCTAssertEqual(error.place, descriptor.place, file: file, line: line)
            return error
        } catch {
            XCTFail("not a RecordLogChunkError: \(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: - A load's chunk

    func testALoadChunksLinesAreReadWithDeletesAndNestedValuesIntact() throws {
        let (body, descriptor) = Self.chunk(
            "a1\t{\"title\":\"x\",\"n\":null,\"meta\":{\"deep\":[1,{\"z\":2}]}}\n"
                + "a2\t{\"_deleted\":true}\n"
                + "b1\t{\"tags\":[\"p\",\"q\"]}\n"
        )
        let lines = try RecordLogChunkReader.readLoadChunk(body, descriptor)
        XCTAssertEqual(lines, [
            RecordLogLoadLine(id: "a1", patch: ["title": "x", "n": .null, "meta": ["deep": [1, ["z": 2]]]]),
            RecordLogLoadLine(id: "a2", patch: ["_deleted": true]),
            RecordLogLoadLine(id: "b1", patch: ["tags": ["p", "q"]]),
        ])
    }

    func testALoadChunkIsRefusedOnItsLengthDigestRowCountAndDecompressedSize() throws {
        let (body, d) = Self.chunk("a1\t{\"t\":1}\na2\t{\"t\":2}\n")
        let read = { (body: Data, d: RecordLogChunkDescriptor) -> Any in try RecordLogChunkReader.readLoadChunk(body, d) }
        var wrong = d
        wrong.bytes += 1
        XCTAssertTrue(refusal(body, wrong, read)?.reason.contains("stored bytes") == true)
        wrong = d
        wrong.sha256 = String(repeating: "0", count: 64)
        XCTAssertTrue(refusal(body, wrong, read)?.reason.contains("sha256") == true)
        wrong = d
        wrong.rows = 3
        XCTAssertTrue(refusal(body, wrong, read)?.reason.contains("rows") == true)
        wrong = d
        wrong.rows = 1
        XCTAssertTrue(refusal(body, wrong, read)?.reason.contains("more than the 1 rows") == true)
        wrong = d
        wrong.rawBytes -= 1
        XCTAssertTrue(refusal(body, wrong, read)?.reason.contains("decompresses past") == true)
        wrong = d
        wrong.rawBytes += 1
        XCTAssertTrue(refusal(body, wrong, read)?.reason.contains("decompressed bytes") == true)
        XCTAssertEqual(refusal(body, wrong, read)?.code, .integrity)
        XCTAssertEqual(refusal(Data("not gzip at all, nor long enough".utf8), {
            var d = d
            d.bytes = 32
            d.sha256 = Self.sha256(Data("not gzip at all, nor long enough".utf8))
            return d
        }(), read)?.reason, "the chunk is not readable gzip")
    }

    func testALoadChunkIsRefusedOnItsOrderItsRangeAndEachMalformedLine() throws {
        let read = { (body: Data, d: RecordLogChunkDescriptor) -> Any in try RecordLogChunkReader.readLoadChunk(body, d) }
        for (text, code) in [
            ("a2\t{}\na1\t{}\n", RecordLogChunkError.Code.unordered),
            ("a1\t{}\na1\t{}\n", .unordered),
            ("a1 {}\n", .lineInvalid),
            ("\t{}\n", .lineInvalid),
            ("a1\t[1]\n", .lineInvalid),
            ("a1\t\"x\"\n", .lineInvalid),
            ("a1\tnot json\n", .lineInvalid),
        ] {
            let (body, d) = Self.chunk(text)
            XCTAssertEqual(refusal(body, d, read)?.code, code, text)
        }
        let (body, d) = Self.chunk("a1\t{}\na2\t{}\n")
        var range = d
        range.firstId = "a0"
        XCTAssertTrue(refusal(body, range, read)?.reason.contains("begin at a0") == true)
        range = d
        range.lastId = "a3"
        XCTAssertTrue(refusal(body, range, read)?.reason.contains("end at a3") == true)
    }

    func testIdsAreOrderedAsSQLiteOrdersThemByUTF8Bytes() throws {
        // U+E000 sorts below U+1F600 in UTF-8 (and SQLite), above it in UTF-16.
        let (body, d) = Self.chunk("a\u{E000}\t{}\na\u{1F600}\t{}\n")
        XCTAssertEqual(try RecordLogChunkReader.readLoadChunk(body, d).map(\.id), ["a\u{E000}", "a\u{1F600}"])
        XCTAssertEqual(RecordLogChunkReader.compareIds("a\u{1F600}", "a\u{E000}"), 1)
        XCTAssertEqual(RecordLogChunkReader.compareIds("ab", "abc"), -1)
    }

    // MARK: - A segment's row chunk

    func testASegmentRowChunkReadsAsRowsOfItsModelAndRefusesADuplicateOrARangeItDoesNotMatch() throws {
        let (body, d) = Self.chunk("r1\t{\"id\":\"r1\",\"title\":\"a\"}\nr2\t{\"id\":\"r2\",\"t\":[\"x\"]}\n", model: "Task", index: 4)
        XCTAssertEqual(try RecordLogChunkReader.readSegmentChunk(body, d), [
            RecordLogCatchUpRow(model: "Task", id: "r1", row: ["id": "r1", "title": "a"]),
            RecordLogCatchUpRow(model: "Task", id: "r2", row: ["id": "r2", "t": ["x"]]),
        ])
        let read = { (body: Data, d: RecordLogChunkDescriptor) -> Any in try RecordLogChunkReader.readSegmentChunk(body, d) }
        let (twice, td) = Self.chunk("r1\t{}\nr1\t{}\nr2\t{}\n", model: "Task", index: 4)
        XCTAssertTrue(refusal(twice, td, read)?.reason.contains("duplicate id r1") == true)
        var range = d
        range.lastId = "r9"
        XCTAssertEqual(refusal(body, range, read)?.place, "Task/4")
        let (noTab, nd) = Self.chunk("r1 {}\n", model: "Task", index: 4)
        XCTAssertNotNil(refusal(noTab, nd, read))
        var big = d
        big.rawBytes -= 5
        XCTAssertTrue(refusal(body, big, read)?.reason.contains("decompresses past") == true)
    }

    // MARK: - A segment's corrections chunk

    private static func corrections(_ text: String) -> (body: Data, descriptor: RecordLogCorrectionsDescriptor) {
        let raw = Data(text.utf8)
        let body = GzipFixture.gzip(raw)
        return (body, RecordLogCorrectionsDescriptor(
            rows: text.split(separator: "\n").count, bytes: body.count, rawBytes: raw.count, sha256: sha256(body),
            path: "corrections.SECRETPATH"
        ))
    }

    func testACorrectionsChunkReadsRowsAndTombstonesWithTheSameBareIdInTwoModels() throws {
        let (body, d) = Self.corrections(
            "a1\t{\"id\":\"a1\",\"title\":\"x\",\"_type\":\"Note\"}\n"
                + "a1\t{\"id\":\"a1\",\"title\":\"y\",\"_type\":\"Task\"}\n"
                + "b2\t{\"_type\":\"Note\",\"_deleted\":true}\n"
        )
        XCTAssertEqual(try RecordLogChunkReader.readCorrectionsChunk(body, d), [
            RecordLogCorrection(model: "Note", id: "a1", row: ["id": "a1", "title": "x"]),
            RecordLogCorrection(model: "Task", id: "a1", row: ["id": "a1", "title": "y"]),
            RecordLogCorrection(model: "Note", id: "b2", row: nil),
        ])
    }

    func testACorrectionsChunkIsRefusedOnEachCheck() throws {
        func refused(_ body: Data, _ d: RecordLogCorrectionsDescriptor) -> RecordLogChunkError? {
            do {
                _ = try RecordLogChunkReader.readCorrectionsChunk(body, d)
                return nil
            } catch {
                return error as? RecordLogChunkError
            }
        }
        let (body, d) = Self.corrections("a1\t{\"id\":\"a1\",\"_type\":\"Note\"}\n")
        func changed(_ change: (inout RecordLogCorrectionsDescriptor) -> Void) -> RecordLogCorrectionsDescriptor {
            var wrong = d
            change(&wrong)
            return wrong
        }
        let wrongs: [RecordLogCorrectionsDescriptor] = [
            changed { $0.bytes += 1 }, changed { $0.sha256 = String(repeating: "0", count: 64) }, changed { $0.rows = 2 },
            changed { $0.rawBytes -= 1 }, changed { $0.rawBytes += 1 },
        ]
        for wrong in wrongs {
            let error = refused(body, wrong)
            XCTAssertEqual(error?.place, "corrections")
            XCTAssertFalse(error?.description.contains("SECRETPATH") ?? true)
        }
        for text in [
            "a1 {\"_type\":\"Note\"}\n", "a1\t{\"title\":\"x\"}\n", "a1\t{\"_type\":7}\n", "a1\t{\"_type\":\"\"}\n",
            "a1\t[1]\n", "a1\tnot json\n", "a1\t{\"_type\":\"Note\"}\na1\t{\"_type\":\"Note\",\"_deleted\":true}\n",
        ] {
            let (body, d) = Self.corrections(text)
            XCTAssertNotNil(refused(body, d), text)
        }
    }

    // MARK: - CRLF line ends (4312-C2-02)

    /// The JS readers split at LF and leave a CR to the JSON as whitespace; a
    /// Swift `Character` split reads CR LF as one character and would see one
    /// line. The descriptors here are written out, not derived from the text.
    func testCRLFLinesReadAsTheJSReadersReadThem() throws {
        let loadRaw = Data("a1\t{\"t\":1}\r\na2\t{\"_deleted\":true}\r\n".utf8)
        let loadBody = GzipFixture.gzip(loadRaw)
        let load = RecordLogChunkDescriptor(
            model: "Note", index: 0, path: "Note/0.ATTEMPT", rows: 2, bytes: loadBody.count, rawBytes: loadRaw.count,
            sha256: Self.sha256(loadBody), firstId: "a1", lastId: "a2"
        )
        XCTAssertEqual(try RecordLogChunkReader.readLoadChunk(loadBody, load), [
            RecordLogLoadLine(id: "a1", patch: ["t": 1]),
            RecordLogLoadLine(id: "a2", patch: ["_deleted": true]),
        ])

        let rowsRaw = Data("r1\t{\"id\":\"r1\"}\r\nr2\t{\"id\":\"r2\"}\r\n".utf8)
        let rowsBody = GzipFixture.gzip(rowsRaw)
        let rows = RecordLogChunkDescriptor(
            model: "Task", index: 1, path: "Task/1", rows: 2, bytes: rowsBody.count, rawBytes: rowsRaw.count,
            sha256: Self.sha256(rowsBody), firstId: "r1", lastId: "r2"
        )
        XCTAssertEqual(try RecordLogChunkReader.readSegmentChunk(rowsBody, rows), [
            RecordLogCatchUpRow(model: "Task", id: "r1", row: ["id": "r1"]),
            RecordLogCatchUpRow(model: "Task", id: "r2", row: ["id": "r2"]),
        ])

        let correctionsRaw = Data("c1\t{\"_type\":\"Note\",\"title\":\"x\"}\r\nc2\t{\"_type\":\"Note\",\"_deleted\":true}\r\n".utf8)
        let correctionsBody = GzipFixture.gzip(correctionsRaw)
        let corrections = RecordLogCorrectionsDescriptor(
            rows: 2, bytes: correctionsBody.count, rawBytes: correctionsRaw.count, sha256: Self.sha256(correctionsBody),
            path: "corrections"
        )
        XCTAssertEqual(try RecordLogChunkReader.readCorrectionsChunk(correctionsBody, corrections), [
            RecordLogCorrection(model: "Note", id: "c1", row: ["id": "c1", "title": "x"]),
            RecordLogCorrection(model: "Note", id: "c2", row: nil),
        ])
    }

    // MARK: - The bounded gunzip

    func testGunzipWithALimitStopsPastItAndWithoutOneDecodesAsBefore() {
        let raw = Data(String(repeating: "abcdefgh", count: 50_000).utf8)
        let body = GzipFixture.gzip(raw)
        XCTAssertEqual(Gzip.gunzip(body), raw)
        XCTAssertEqual(Gzip.gunzip(body, limit: raw.count), raw)
        XCTAssertNil(Gzip.gunzip(body, limit: raw.count - 1))
        XCTAssertEqual(Gzip.gunzipBounded(body, limit: 1_000), .pastLimit)
        XCTAssertEqual(Gzip.gunzipBounded(Data([1, 2, 3])), .unreadable)
    }
}
