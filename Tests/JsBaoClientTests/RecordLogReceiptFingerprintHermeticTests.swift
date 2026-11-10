import XCTest
@testable import JsBaoClient

/// #5267 behavior 14 (Swift): the fingerprint of a receipt's chunk list
/// answers, for every input of the shared fixture
/// (`tests/perf/overlay-layouts/fixtures/receipt-fingerprints.json`), the hex
/// the fixture states, as js-bao's `record-log-receipt-fingerprint-5267.test.ts`
/// does; a change to any one descriptor field, the order or the corrections
/// changes it.
final class RecordLogReceiptFingerprintHermeticTests: XCTestCase {

    private struct Case {
        let name: String
        let differsFrom: String?
        let input: RecordLogFingerprintInput
        let sha256: String
    }

    private func cases() throws -> [Case] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // JsBaoClientTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // swift-client
            .deletingLastPathComponent()  // the repository
        let data = try Data(contentsOf: root.appendingPathComponent("tests/perf/overlay-layouts/fixtures/receipt-fingerprints.json"))
        let fixture = try JSONDecoder().decode(JSONValue.self, from: data)
        return try (fixture["cases"]?.arrayValue ?? []).map { item in
            let input = try XCTUnwrap(item["input"])
            let chunks = try (input["chunks"]?.arrayValue ?? []).enumerated().map { position, chunk in
                try XCTUnwrap(RecordLogChunkDescriptor(json: chunk, position: position))
            }
            let parsed: RecordLogFingerprintInput
            if input["kind"]?.stringValue == "load" {
                parsed = .load(chunks)
            } else {
                let k = try XCTUnwrap(input["corrections"])
                parsed = .segment(
                    segmentId: try XCTUnwrap(input["segmentId"]?.stringValue),
                    chunks: chunks,
                    corrections: RecordLogCorrectionsDescriptor(
                        rows: try XCTUnwrap(k["rows"]?.wholeNumber), bytes: try XCTUnwrap(k["bytes"]?.wholeNumber),
                        rawBytes: try XCTUnwrap(k["rawBytes"]?.wholeNumber), sha256: try XCTUnwrap(k["sha256"]?.stringValue),
                        path: try XCTUnwrap(k["path"]?.stringValue)
                    )
                )
            }
            return Case(
                name: item["name"]?.stringValue ?? "",
                differsFrom: item["differsFrom"]?.stringValue,
                input: parsed,
                sha256: try XCTUnwrap(item["sha256"]?.stringValue)
            )
        }
    }

    func testTheFingerprintIsTheFixturesForEveryLoadAndSegmentInput() throws {
        let all = try cases()
        XCTAssertGreaterThan(all.count, 20)
        for c in all {
            XCTAssertEqual(recordLogReceiptFingerprint(c.input), c.sha256, c.name)
        }
    }

    func testTheFingerprintChangesWithAnyOneFieldTheOrderOrTheCorrections() throws {
        let all = try cases()
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        let names = Set(all.map(\.name))
        for field in ["sha256", "firstId", "lastId", "bytes", "rawBytes", "rows", "path", "model"] {
            XCTAssertTrue(names.contains("load, a chunk's \(field) changed"), field)
            XCTAssertTrue(names.contains("segment, a chunk's \(field) changed"), field)
        }
        for name in ["load, the list reordered", "segment, the list reordered", "segment, a chunk's index changed", "segment, the corrections' sha256 changed"] {
            XCTAssertTrue(names.contains(name), name)
        }
        for c in all {
            guard let base = c.differsFrom.flatMap({ byName[$0] }) else { continue }
            XCTAssertNotEqual(recordLogReceiptFingerprint(c.input), recordLogReceiptFingerprint(base.input), c.name)
        }
    }
}
