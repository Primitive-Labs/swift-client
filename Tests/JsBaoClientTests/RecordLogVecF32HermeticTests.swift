import XCTest
@testable import JsBaoClient

/// #5230 behavior 3 — `record_log_vec_f32(value, element, dims)`, the SQL
/// function a device vector index's triggers and fill convert a stored value
/// with, js-bao's `recordLogVecF32` rule for rule: on every connection a
/// `SQLiteStorageProvider` opens (a reopened one too), each `f32`, `f16` and
/// `i8` case of the #5225 codec fixture answers the codec's binary32
/// little-endian bytes; NULL for a null, a non-string, another length,
/// non-canonical base64, an unknown element, dims below 1 and a decoded
/// number that is not finite; and the same answer every time.
final class RecordLogVecF32HermeticTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Case: Decodable {
            let name: String
            let element: String
            let dims: Int
            let base64: String
            let decoded: [Double]
        }
        struct DecodeOnly: Decodable {
            struct Case: Decodable {
                let name: String
                let element: String
                let dims: Int
                let base64: String
            }
            let cases: [Case]
        }
        let cases: [Case]
        let decodeOnly: DecodeOnly
    }

    private static let fixture: Fixture = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url.appendingPathComponent("Fixtures/Db3Vectors/codec.json")))
    }()

    private var directory = ""

    override func setUp() {
        directory = NSTemporaryDirectory() + "vec-f32-5230-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func convert(_ provider: SQLiteStorageProvider, _ value: Format2SqlValue, _ element: Format2SqlValue, _ dims: Format2SqlValue) throws -> Format2SqlValue {
        try provider.withConnection { connection in
            try connection.query("SELECT record_log_vec_f32(?, ?, ?) AS v", [value, element, dims]).first?["v"] ?? .null
        }
    }

    private func binary32(_ numbers: [Double]) -> Data {
        Db3VectorTestSupport.bytes(numbers.map { Float($0) })
    }

    func testEachCodecCaseConvertsToItsBinary32Bytes() async throws {
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "vec")
        for item in Self.fixture.cases {
            let answer = try convert(provider, .text(item.base64), .text(item.element), .integer(Int64(item.dims)))
            XCTAssertEqual(answer, .blob(binary32(item.decoded)), item.name)
            // Deterministic: the same answer again.
            XCTAssertEqual(try convert(provider, .text(item.base64), .text(item.element), .integer(Int64(item.dims))), answer, item.name)
        }
        await provider.close()
        // A provider reopened over the same file registers it again.
        let reopened = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await reopened.initialize(namespace: "vec")
        let first = Self.fixture.cases[0]
        XCTAssertEqual(
            try convert(reopened, .text(first.base64), .text(first.element), .integer(Int64(first.dims))), .blob(binary32(first.decoded))
        )
        await reopened.close()
    }

    func testAValueThatIsNotAVectorConvertsToNull() async throws {
        let provider = SQLiteStorageProvider(path: ":memory:")
        try await provider.initialize(namespace: "vec")
        defer { Task { await provider.close() } }
        XCTAssertEqual(try convert(provider, .text("AACAPw=="), .text("f32"), .integer(1)), .blob(Db3VectorTestSupport.bytes([1])))
        let good = try VectorCodec.encode([1, -2, 0.5], encoding: VectorEncoding(dims: 3, element: .f32))
        XCTAssertNotEqual(try convert(provider, .text(good), .text("f32"), .integer(3)), .null)
        let cases: [(String, Format2SqlValue, Format2SqlValue, Format2SqlValue)] = [
            ("a null", .null, .text("f32"), .integer(3)),
            ("a number", .integer(5), .text("f32"), .integer(3)),
            ("a blob", .blob(Data([0, 0, 128, 63])), .text("f32"), .integer(1)),
            ("another length", .text(good), .text("f32"), .integer(4)),
            ("another element's length", .text(good), .text("f16"), .integer(3)),
            ("non-canonical base64 (unused bits set)", .text("AACAPx=="), .text("f32"), .integer(1)),
            ("base64 without padding", .text("AACAPw"), .text("f32"), .integer(1)),
            ("an unknown element", .text(good), .text("f64"), .integer(3)),
            ("an element that is not text", .text(good), .integer(32), .integer(3)),
            ("dims 0", .text(""), .text("f32"), .integer(0)),
            ("dims -1", .text(good), .text("f32"), .integer(-1)),
            ("dims as text", .text(good), .text("f32"), .text("3")),
            ("dims not whole", .text(good), .text("f32"), .real(3.5)),
        ]
        for (name, value, element, dims) in cases {
            XCTAssertEqual(try convert(provider, value, element, dims), .null, name)
        }
        // A decoded number that is not finite holds no vector.
        for item in Self.fixture.decodeOnly.cases {
            XCTAssertEqual(try convert(provider, .text(item.base64), .text(item.element), .integer(Int64(item.dims))), .null, item.name)
        }
    }

    func testTheFunctionIsDeterministicSoAnIndexMayUseIt() async throws {
        let provider = SQLiteStorageProvider(path: ":memory:")
        try await provider.initialize(namespace: "vec")
        defer { Task { await provider.close() } }
        // SQLite admits only a deterministic function in an index expression.
        try provider.withConnection { connection in
            try connection.executeScript("CREATE TABLE t (v TEXT)")
            try connection.executeScript("CREATE INDEX t_vec ON t (record_log_vec_f32(v, 'f32', 1))")
        }
    }

    /// The function reads a value's bytes directly (a trigger runs it once per row written): it answers exactly what the
    /// codec's decode does, for random vectors of each element (f16 subnormals, zeros and i8 extremes among them) and for
    /// each one with a character changed, cut short or lengthened.
    func testTheDirectReadingAnswersAsTheCodecDecodes() throws {
        func reference(_ text: String, _ encoding: VectorEncoding) -> Data? {
            guard let numbers = try? VectorCodec.decode(text, encoding: encoding), numbers.allSatisfy(\.isFinite) else { return nil }
            return Db3VectorTestSupport.bytes(numbers)
        }
        var state: UInt32 = 5230
        func next() -> UInt32 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return state
        }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        var compared = 0
        for element in VectorElement.allCases {
            for dims in [1, 2, 3, 7, 16, 100] {
                let encoding = VectorEncoding(dims: dims, element: element)
                for round in 0..<40 {
                    // Raw bytes, so every bit pattern turns up: NaNs, infinities, subnormals, a zero scale.
                    var bytes = (0..<VectorCodec.byteLength(encoding)).map { _ in UInt8(truncatingIfNeeded: next() >> 24) }
                    if round == 0 { bytes = bytes.map { _ in 0 } }
                    let text = Data(bytes).base64EncodedString()
                    var variants = [text, String(text.dropLast()), text + "A"]
                    var mangled = Array(text)
                    mangled[Int(next() % UInt32(mangled.count))] = alphabet[Int(next() % UInt32(alphabet.count))]
                    variants.append(String(mangled))
                    for variant in variants {
                        XCTAssertEqual(RecordLogVectorFunction.binary32(variant, element: element.rawValue, dims: dims), reference(variant, encoding),
                                       "\(element.rawValue) × \(dims): \(variant)")
                        compared += 1
                    }
                }
            }
        }
        XCTAssertEqual(compared, 3 * 6 * 40 * 4)
    }
}
