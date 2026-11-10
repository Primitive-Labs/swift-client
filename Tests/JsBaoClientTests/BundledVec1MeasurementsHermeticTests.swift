import JsBaoSQLite
import XCTest

/// #5227 behavior 15 (measurement) — vec1's exact search through the bundled
/// SQLite, logged (it informs, never gates) beside spike 1's native figure
/// (44.8 ms for k = 10 over 100,000 × 768 at `-O3`): 100,000 random unit
/// vectors of 768 dimensions inserted into a file-backed `flat` cosine table,
/// then the median of 20 k = 10 queries. Each figure is printed as one
/// `[5227 measurement]` line; the asserts only check that the queries answered.
final class BundledVec1MeasurementsHermeticTests: XCTestCase {

    private static let rows = 100_000
    private static let dims = 768
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func log(_ name: String, _ value: Double, digits: Int = 1) {
        let line = "[5227 measurement] \(name): \(String(format: "%.\(digits)f", value))\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private static func ms(_ since: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1_000_000
    }

    /// Deterministic unit vectors: an LCG's uniform draws centred on zero, normalized.
    private struct Vectors {
        var state: UInt32

        mutating func next(into vector: inout [Float]) {
            var norm: Float = 0
            for i in 0..<vector.count {
                state = state &* 1_664_525 &+ 1_013_904_223
                let x = Float(state) / 4_294_967_296 - 0.5
                vector[i] = x
                norm += x * x
            }
            let scale = 1 / norm.squareRoot()
            for i in 0..<vector.count { vector[i] *= scale }
        }
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            XCTFail("\(sql): \(String(cString: sqlite3_errmsg(db)))")
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func prepare(_ db: OpaquePointer?, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            XCTFail("\(sql): \(String(cString: sqlite3_errmsg(db)))")
            throw CocoaError(.fileReadUnknown)
        }
        return statement
    }

    func testExactSearchOverAHundredThousandVectors() throws {
        let directory = NSTemporaryDirectory() + "bundled-vec1-measure-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(directory + "/vectors.sqlite", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        try exec(db, "PRAGMA journal_mode=WAL")
        try exec(db, "CREATE VIRTUAL TABLE v USING vec1")
        try exec(db, #"INSERT INTO v(cmd, arg) VALUES ('rebuild', '{index:"flat",distance:"cos"}')"#)

        var vectors = Vectors(state: 5227)
        var vector = [Float](repeating: 0, count: Self.dims)
        let insert = try prepare(db, "INSERT INTO v(rowid, vector) VALUES (?, ?)")
        defer { sqlite3_finalize(insert) }
        // Only SQLite's work is timed: generating the vectors in a debug
        // build takes longer than inserting them.
        var inserted = 0.0
        var started = DispatchTime.now()
        try exec(db, "BEGIN")
        inserted += Self.ms(started)
        for rowid in 1...Self.rows {
            vectors.next(into: &vector)
            started = DispatchTime.now()
            sqlite3_bind_int64(insert, 1, Int64(rowid))
            vector.withUnsafeBytes { _ = sqlite3_bind_blob(insert, 2, $0.baseAddress, Int32($0.count), Self.transient) }
            guard sqlite3_step(insert) == SQLITE_DONE else {
                return XCTFail("insert \(rowid): \(String(cString: sqlite3_errmsg(db)))")
            }
            sqlite3_reset(insert)
            inserted += Self.ms(started)
        }
        started = DispatchTime.now()
        try exec(db, "COMMIT")
        inserted += Self.ms(started)

        let query = try prepare(db, "SELECT rowid FROM v(?, '{K:10}')")
        defer { sqlite3_finalize(query) }
        var samples: [Double] = []
        for _ in 0..<20 {
            vectors.next(into: &vector)
            vector.withUnsafeBytes { _ = sqlite3_bind_blob(query, 1, $0.baseAddress, Int32($0.count), Self.transient) }
            var answered = 0
            let asked = DispatchTime.now()
            while sqlite3_step(query) == SQLITE_ROW { answered += 1 }
            samples.append(Self.ms(asked))
            sqlite3_reset(query)
            XCTAssertEqual(answered, 10, String(cString: sqlite3_errmsg(db)))
        }
        let median = samples.sorted()[samples.count / 2]
        Self.log("vec1 insert \(Self.rows) x \(Self.dims) f32 (file, WAL, one transaction) ms", inserted, digits: 0)
        Self.log("vec1 exact (flat, cos) k=10 over \(Self.rows) x \(Self.dims), median of 20, ms", median)
    }
}
