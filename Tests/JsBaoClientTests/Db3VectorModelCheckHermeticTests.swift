import XCTest
@testable import JsBaoClient

/// #5230 behavior 17 — the `pvm1` envelope check in Swift answers every case
/// of the shared fixture `Fixtures/Db3Vectors/vector-model-check.json` as
/// js-bao does: genuine opq, pq, none and bq models trained by vec1 in Node,
/// and each malformed body (over 64 MiB, short, a bad magic, another envelope
/// version, params past the body or not JSON, a model length mismatch,
/// another vec1, dims or distance, nbucket 0 and 65,537, an unknown
/// quantizer, the codesize rules, a registration option the params do not
/// match, rows, trainedAt, vec1's header and layout, a coefficient that is not
/// finite) with the same `ok`, params and reason; `vec1Codebooks` and
/// `vec1BqCodesize` as js-bao resolves them.
final class Db3VectorModelCheckHermeticTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Patch: Decodable {
            let at: Int
            let hex: String
        }
        struct Expectation: Decodable {
            let vec1: String
            let dims: Int
            let distance: String
            let index: JSONValue
        }
        struct Case: Decodable {
            let name: String
            let base: String
            let length: Int
            let patches: [Patch]
            let expectation: Expectation
        }
        struct Codebooks: Decodable {
            let dims: Int
            let codesize: Int
            let codebooks: Int
        }
        struct Bq: Decodable {
            let dims: Int
            let codesize: Int?
            let resolved: Int
        }
        let vec1: String
        let bases: [String: String]
        let cases: [Case]
        let answers: [String: JSONValue]
        let codebooks: [Codebooks]
        let bqCodesize: [Bq]
    }

    private static func bytes(_ hex: String) -> Data {
        var out = Data(capacity: hex.utf8.count / 2)
        var high: UInt8?
        for character in hex.utf8 {
            let nibble = character >= 97 ? character - 87 : character - 48
            if let first = high {
                out.append(first << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return out
    }

    private static func fixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Db3VectorFixture.fixtureDirectory.appendingPathComponent("vector-model-check.json")))
    }

    private static func index(_ raw: JSONValue) -> RecordLogVectorOptions.Index {
        guard let object = raw.objectValue, object["mode"] == "ann" else { return .exact }
        return .ann(
            nbucket: object["nbucket"]?.numberValue.map { Int($0) }, codesize: object["codesize"]?.numberValue.map { Int($0) },
            quantizer: object["quantizer"]?.stringValue
        )
    }

    func testEveryFixtureCaseIsAnsweredAsJsBaoAnswersIt() throws {
        let fixture = try Self.fixture()
        XCTAssertGreaterThan(fixture.cases.count, 40)
        let bases = fixture.bases.mapValues(Self.bytes)
        for item in fixture.cases {
            let base = try XCTUnwrap(bases[item.base], item.name)
            var body = Data(count: item.length)
            body.replaceSubrange(0..<min(base.count, item.length), with: base.prefix(item.length))
            for patch in item.patches {
                let bytes = Self.bytes(patch.hex)
                body.replaceSubrange(patch.at..<(patch.at + bytes.count), with: bytes)
            }
            let expectation = RecordLogVectorModelCheck.Expectation(
                vec1: item.expectation.vec1, dims: item.expectation.dims, distance: item.expectation.distance, index: Self.index(item.expectation.index)
            )
            let answer = try XCTUnwrap(fixture.answers[item.name], item.name)
            switch RecordLogVectorModelCheck.check(body, expectation) {
            case .ok(let params, let model):
                XCTAssertEqual(answer["ok"], true, "\(item.name): js-bao refused it: \(answer["reason"]?.stringValue ?? "")")
                XCTAssertEqual(answer["modelLength"]?.numberValue.map(Int.init), model.count, item.name)
                let expected = try XCTUnwrap(answer["params"], item.name)
                XCTAssertEqual(expected["vec1"]?.stringValue, params.vec1, item.name)
                XCTAssertEqual(expected["dims"]?.numberValue.map(Int.init), params.dims, item.name)
                XCTAssertEqual(expected["distance"]?.stringValue, params.distance, item.name)
                XCTAssertEqual(expected["nbucket"]?.numberValue.map(Int.init), params.nbucket, item.name)
                XCTAssertEqual(expected["codesize"]?.numberValue.map(Int.init), params.codesize, item.name)
                XCTAssertEqual(expected["quantizer"]?.stringValue, params.quantizer, item.name)
                XCTAssertEqual(expected["rows"]?.numberValue.map(Int.init), params.rows, item.name)
                XCTAssertEqual(expected["trainedAt"]?.stringValue, params.trainedAt, item.name)
            case .refused(let reason):
                XCTAssertEqual(answer["ok"], false, "\(item.name): js-bao admitted it; Swift refused: \(reason)")
                XCTAssertEqual(answer["reason"]?.stringValue, reason, item.name)
            }
        }
    }

    func testCodebooksAndBqCodesizeAreJsBaos() throws {
        let fixture = try Self.fixture()
        for row in fixture.codebooks {
            XCTAssertEqual(RecordLogVectorModelCheck.codebooks(dims: row.dims, codesize: row.codesize), row.codebooks, "\(row.dims)/\(row.codesize)")
        }
        XCTAssertEqual(RecordLogVectorModelCheck.codebooks(dims: 100, codesize: 32), 25)
        for row in fixture.bqCodesize {
            XCTAssertEqual(RecordLogVectorModelCheck.bqCodesize(dims: row.dims, codesize: row.codesize), row.resolved, "\(row.dims)/\(String(describing: row.codesize))")
        }
        // The engine's vec1 is the fixture's: a genuine body is not refused for its version.
        XCTAssertEqual(try Db3VectorTestSupport.vec1Version(), fixture.vec1)
    }

    /// A body's params as anyone wrote them, framed as a `pvm1` envelope.
    private static func envelope(params json: String, model: [UInt8] = [0, 0, 0, 0]) -> Data {
        let text = Array(json.utf8)
        var out = Data([0x50, 0x56, 0x4d, 0x31, 1, 0, UInt8(text.count & 0xff), UInt8(text.count >> 8)])
        out.append(contentsOf: text)
        out.append(contentsOf: [UInt8(model.count), 0, 0, 0])
        out.append(contentsOf: model)
        return out
    }

    /// F-5230-CODE-001: a framed body whose params hold numbers past Int64
    /// is refused with the number as JavaScript writes it, never a trap.
    func testParamsPastInt64AreRefusedWithTheirNumbersAsJavaScriptWritesThem() {
        let expectation = RecordLogVectorModelCheck.Expectation(vec1: "0.8", dims: 8, distance: "cos", index: .ann(nbucket: nil, codesize: nil, quantizer: nil))
        let params = { (dims: String, nbucket: String, codesize: String, rows: String) in
            #"{"vec1":"0.8","dims":\#(dims),"distance":"cos","nbucket":\#(nbucket),"codesize":\#(codesize),"quantizer":"opq","rows":\#(rows),"trainedAt":"2026-11-05T00:00:00.000Z"}"#
        }
        let cases: [(String, String)] = [
            (params("1e20", "20", "4", "1200"), "the model is for dims 100000000000000000000, the field holds 8"),
            (params("-1e20", "20", "4", "1200"), "the model is for dims -100000000000000000000, the field holds 8"),
            (params("1e300", "20", "4", "1200"), "the model is for dims 1e+300, the field holds 8"),
            (params("8", "1e20", "4", "1200"), "the model's nbucket 100000000000000000000 is outside 1 to 65536"),
            (params("8", "-9.3e18", "4", "1200"), "the model's nbucket -9300000000000000000 is outside 1 to 65536"),
            (params("8", "20", "1e20", "1200"), "the model's codesize 100000000000000000000 is outside 1 to 8"),
            (params("8", "20", "4", "-1e20"), "the model's rows -100000000000000000000 is not a positive integer"),
        ]
        for (json, reason) in cases {
            XCTAssertEqual(RecordLogVectorModelCheck.check(Self.envelope(params: json), expectation), .refused(reason), json)
        }
    }

    func testTheEnvelopeIsJsBaosLayout() throws {
        let params = RecordLogVectorModelParams(
            vec1: "0.8", dims: 8, distance: "cos", nbucket: 20, codesize: 4, quantizer: "opq", rows: 1200, trainedAt: "2026-11-05T00:00:00.000Z"
        )
        let envelope = RecordLogVectorModelCheck.encode(params, model: Data([1, 2, 3]))
        let json = #"{"vec1":"0.8","dims":8,"distance":"cos","nbucket":20,"codesize":4,"quantizer":"opq","rows":1200,"trainedAt":"2026-11-05T00:00:00.000Z"}"#
        XCTAssertEqual(Array(envelope.prefix(8)), [0x50, 0x56, 0x4d, 0x31, 1, 0, UInt8(json.utf8.count), 0])
        XCTAssertEqual(String(data: envelope.subdata(in: 8..<(8 + json.utf8.count)), encoding: .utf8), json)
        XCTAssertEqual(Array(envelope.suffix(7)), [3, 0, 0, 0, 1, 2, 3])
    }
}
