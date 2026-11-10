import Foundation
import JsBaoSQLite
@testable import JsBaoClient

/// #5230 — what the Swift device vector suites share, the port of
/// `tests/helpers/db3-device-vectors-5229.ts`: seeded vectors (mulberry32,
/// so a suite's vectors are the JS suite's), a brute-force nearest-neighbour
/// reference, a vector index entry as the room lists one, and a connection of
/// the test's own on the bundled SQLite (with vec1) through the C API, which
/// trains a model with vec1 itself.
enum Db3VectorTestSupport {

    /// A seeded generator of numbers in [0, 1) (mulberry32), js's `seeded`.
    struct Seeded {
        private var a: UInt32

        init(_ seed: UInt32) { a = seed }

        mutating func next() -> Double {
            a = a &+ 0x6d2b_79f5
            var t = a
            t = (t ^ (t >> 15)) &* (t | 1)
            t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
            return Double(t ^ (t >> 14)) / 4_294_967_296
        }
    }

    /// `count` vectors of `dims` numbers in [-1, 1), seeded.
    static func randomVectors(_ count: Int, _ dims: Int, seed: UInt32 = 5229) -> [[Float]] {
        var next = Seeded(seed)
        return (0..<count).map { _ in (0..<dims).map { _ in Float(next.next() * 2 - 1) } }
    }

    /// `count` vectors around `clusters` seeded centres, as embeddings group (js's `clusteredVectors`).
    static func clusteredVectors(_ count: Int, _ dims: Int, clusters: Int, seed: UInt32 = 5229) -> [[Float]] {
        var next = Seeded(seed)
        let centres = (0..<clusters).map { _ in (0..<dims).map { _ in Float(next.next() * 2 - 1) } }
        return (0..<count).map { i in centres[i % clusters].map { Float(Double($0) + (next.next() * 2 - 1) * 0.15) } }
    }

    /// vec1's cosine distance, `1 - a·b / (|a| |b|)`, in double precision; 1 when either is all zeros.
    static func cosDistance(_ a: [Float], _ b: [Float]) -> Double {
        var (dot, na, nb) = (0.0, 0.0, 0.0)
        for i in a.indices {
            dot += Double(a[i]) * Double(b[i])
            na += Double(a[i]) * Double(a[i])
            nb += Double(b[i]) * Double(b[i])
        }
        if na == 0 || nb == 0 { return 1 }
        return 1 - dot / (na * nb).squareRoot()
    }

    /// vec1's l2 distance: the squared Euclidean distance.
    static func l2Distance(_ a: [Float], _ b: [Float]) -> Double {
        var sum = 0.0
        for i in a.indices { sum += (Double(a[i]) - Double(b[i])) * (Double(a[i]) - Double(b[i])) }
        return sum
    }

    /// The `k` nearest of `rows` to `query` by brute force, nearest first, then by id.
    static func bruteForce(_ rows: [(id: String, vector: [Float])], _ query: [Float], k: Int, distance: String = "cos") -> [(id: String, distance: Double)] {
        let measure = distance == "cos" ? cosDistance : l2Distance
        return rows.map { (id: $0.id, distance: measure($0.vector, query)) }
            .sorted { $0.distance != $1.distance ? $0.distance < $1.distance : Array($0.id.utf8).lexicographicallyPrecedes(Array($1.id.utf8)) }
            .prefix(k).map { $0 }
    }

    /// What a device holds for `values` stored in `encoding`: its numbers after the encoding's rounding.
    static func heldAs(_ values: [Float], _ encoding: VectorEncoding) throws -> [Float] {
        try VectorCodec.decode(VectorCodec.encode(values, encoding: encoding), encoding: encoding)
    }

    /// A vector index entry as `GET db3/:id/indexes` lists one (#5229).
    static func vectorEntry(
        _ model: String, _ field: String, _ encoding: VectorEncoding, distance: String = "cos", index: JSONValue = "exact",
        generation: Int? = 1, revision: Int? = 1, annModel: JSONValue? = nil, name: String? = nil
    ) -> RecordLogIndexEntry {
        var json: [String: JSONValue] = [
            "name": .string(name ?? "idx_vec_\(model)_\(field)".lowercased()), "model": .string(model), "fields": [.string(field)],
            "unique": false, "kind": "vector", "on": "device",
            "vector": ["distance": .string(distance), "index": index, "dims": .number(Double(encoding.dims)), "element": .string(encoding.element.rawValue)],
        ]
        if let generation { json["generation"] = .number(Double(generation)) }
        if let revision { json["revision"] = .number(Double(revision)) }
        if let annModel { json["annModel"] = annModel }
        return RecordLogIndexEntry(json: .object(json))!
    }

    /// `values` as vec1 reads them: binary32, little-endian.
    static func bytes(_ values: [Float]) -> Data {
        values.withUnsafeBytes { Data($0) }
    }

    /// Binary32 little-endian bytes as numbers.
    static func floats(_ data: Data) -> [Float] {
        stride(from: 0, to: data.count - data.count % 4, by: 4).map { offset in
            Float(bitPattern: data[data.startIndex + offset..<data.startIndex + offset + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) })
        }
    }

    /// A model vec1 trains over `vectors`, as its `vec1_train` answers it, on a connection of the test's own.
    static func trainModel(_ vectors: [[Float]], distance: String, nbucket: Int, codesize: Int, quantizer: String) throws -> Data {
        let db = try Vec1Connection()
        try db.exec("CREATE TEMP TABLE sample (vector BLOB)")
        try db.exec("BEGIN")
        for vector in vectors { try db.run("INSERT INTO sample (vector) VALUES (?)", [.blob(bytes(vector))]) }
        try db.exec("COMMIT")
        let config = quantizer == "none"
            ? #"{distance:"\#(distance)", nbucket:\#(nbucket), quantizer:"none"}"#
            : #"{distance:"\#(distance)", nbucket:\#(nbucket), codesize:\#(codesize), quantizer:"\#(quantizer)"}"#
        guard case .blob(let model)? = try db.rows("SELECT vec1_train(vector, ?) AS m FROM sample", [.text(config)]).first?["m"] else {
            throw Vec1Connection.Failure(message: "vec1_train answered no model")
        }
        return model
    }

    /// vec1's version on this build, as `vec1_info()` names it (`0.8`).
    static func vec1Version() throws -> String {
        let info = try Vec1Connection().rows("SELECT vec1_info() AS i").first?["i"]
        guard case .text(let text)? = info else { return "" }
        guard let match = text.range(of: #"version\s+([0-9.]+)"#, options: .regularExpression) else { return text }
        return String(text[match]).replacingOccurrences(of: #"version\s+"#, with: "", options: .regularExpression)
    }
}

/// A connection of the test's own on the bundled SQLite, through its C API:
/// an in-memory database (or a file) with vec1, statements bound per call,
/// blobs bound and read as `Data`. Closed when released.
final class Vec1Connection {

    struct Failure: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    enum Value: Equatable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)

        var data: Data? { if case .blob(let data) = self { return data }; return nil }
        var int: Int? { if case .integer(let n) = self { return Int(n) }; return nil }
        var double: Double? {
            switch self {
            case .real(let n): return n
            case .integer(let n): return Double(n)
            default: return nil
            }
        }
    }

    let db: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String = ":memory:") throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let handle else {
            throw Failure(message: "open \(path) failed")
        }
        db = handle
    }

    deinit { sqlite3_close_v2(db) }

    var lastError: String { String(cString: sqlite3_errmsg(db)) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(message: "\(lastError) — \(sql)") }
    }

    func run(_ sql: String, _ bindings: [Value] = []) throws {
        _ = try rows(sql, bindings)
    }

    func rows(_ sql: String, _ bindings: [Value] = []) throws -> [[String: Value]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw Failure(message: "\(lastError) — \(sql)")
        }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let n): sqlite3_bind_int64(statement, index, n)
            case .real(let n): sqlite3_bind_double(statement, index, n)
            case .text(let text): _ = text.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
            case .blob(let data):
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
            }
        }
        var out: [[String: Value]] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw Failure(message: "\(lastError) — \(sql)") }
            var row: [String: Value] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_NULL: row[name] = .null
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, column))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    row[name] = .blob(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, column), count: count))
                default: row[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                }
            }
            out.append(row)
        }
        return out
    }
}
