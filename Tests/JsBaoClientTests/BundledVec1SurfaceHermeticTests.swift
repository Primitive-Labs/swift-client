import JsBaoSQLite
import XCTest
@testable import JsBaoClient

/// #5230 step 0 (a pin, plan behavior 1) — vec1 0.8's SQL surface on the
/// bundled SQLite, as #5227 bundled it, before any device vector work: on an
/// in-memory connection of the test's own, through the C API,
///
/// - `vec1_train` over 2,000 clustered 16-d vectors answers a model;
/// - a second vec1 table `rebuild`s from that model blob, takes the rows, and
///   answers a `{K, nprobe}` query and a `{K, nprobe, streaming:1}` query
///   under a join to a filter;
/// - `vec1_cos_distance` and `vec1_l2_distance` compute the distances the
///   brute-force reference does;
/// - the ANN table's `vector` column reads back the inserted bytes;
/// - `rebuild` refuses a truncated model, a wrong-length model, flipped
///   header flags and random bytes with an SQLite error inside a
///   transaction that rolls back, and the process stays alive.
///
/// A failure here disproves the intent's assumption that vec1 0.8 keeps its
/// SQL surface, or its decision that vec1 rejects malformed bodies safely,
/// and stops for the sponsor.
final class BundledVec1SurfaceHermeticTests: XCTestCase {

    private typealias Support = Db3VectorTestSupport

    private func seeded(_ db: Vec1Connection, _ table: String, _ vectors: [[Float]]) throws {
        try db.exec("BEGIN")
        for (offset, vector) in vectors.enumerated() {
            try db.run("INSERT INTO \(table) (rowid, vector) VALUES (?, ?)", [.integer(Int64(offset + 1)), .blob(Support.bytes(vector))])
        }
        try db.exec("COMMIT")
    }

    func testVec1sSurfaceOnTheBundledBuild() throws {
        let db = try Vec1Connection()
        let vectors = Support.clusteredVectors(2000, 16, clusters: 16)

        try db.exec("CREATE VIRTUAL TABLE flat USING vec1")
        try db.exec(#"INSERT INTO flat (cmd, arg) VALUES ('rebuild', '{index:"flat",distance:"cos"}')"#)
        try seeded(db, "flat", vectors)

        // Training over the flat table's vectors.
        let trained = try db.rows(
            #"SELECT vec1_train(vector, '{distance:"cos", nbucket:16, codesize:8, quantizer:"opq"}') AS m FROM flat"#
        ).first?["m"]?.data
        let model = try XCTUnwrap(trained, "vec1_train answered no model")
        XCTAssertGreaterThan(model.count, 24)

        // A second table rebuilt from the model blob, then filled.
        try db.exec("CREATE VIRTUAL TABLE ann USING vec1")
        try db.run("INSERT INTO ann (cmd, arg) VALUES ('rebuild', ?)", [.blob(model)])
        try seeded(db, "ann", vectors)

        // The ANN table's vectors read back as inserted.
        let held = try db.rows("SELECT rowid, vector FROM ann ORDER BY rowid")
        XCTAssertEqual(held.count, vectors.count)
        for row in held.prefix(50) {
            let rowid = try XCTUnwrap(row["rowid"]?.int)
            XCTAssertEqual(row["vector"]?.data, Support.bytes(vectors[rowid - 1]), "rowid \(rowid)")
        }

        // A `{K, nprobe}` query: the K nearest of the probed bucket, the query's own row first.
        // nprobe 0.1 of 16 buckets probes one, and vec1 seeds its training at random:
        // now and then a bucket holds fewer than 40 rows (1 run in 20).
        let query = vectors[7]
        let bucket = Set(try db.rows("SELECT rowid FROM ann(?, '{K:2000, nprobe:0.1}')", [.blob(Support.bytes(query))]).compactMap { $0["rowid"]?.int })
        let near = try db.rows("SELECT rowid, distance FROM ann(?, '{K:40, nprobe:0.1}')", [.blob(Support.bytes(query))])
        XCTAssertEqual(near.count, min(40, bucket.count))
        XCTAssertEqual(near.first?["rowid"]?.int, 8)
        let nearDistances = near.compactMap { $0["distance"]?.double }
        XCTAssertEqual(nearDistances, nearDistances.sorted())

        // Streaming under a join to a filter: the probed bucket's rows that pass it in
        // distance order, then the next buckets', until 40 pass it.
        try db.exec("CREATE TABLE tag (id INTEGER PRIMARY KEY, even INTEGER)")
        try db.exec("BEGIN")
        for rowid in 1...vectors.count { try db.run("INSERT INTO tag (id, even) VALUES (?, ?)", [.integer(Int64(rowid)), .integer(Int64(rowid % 2 == 0 ? 1 : 0))]) }
        try db.exec("COMMIT")
        let streamed = try db.rows(
            "SELECT a.rowid AS rowid, a.distance AS distance FROM ann(?, '{K:40, nprobe:0.1, streaming:1}') AS a CROSS JOIN tag ON tag.id = a.rowid WHERE tag.even = 1 LIMIT 40",
            [.blob(Support.bytes(query))]
        )
        XCTAssertEqual(streamed.count, 40)
        XCTAssertTrue(streamed.allSatisfy { ($0["rowid"]?.int ?? 1) % 2 == 0 })
        let fromBucket = streamed.prefix { bucket.contains($0["rowid"]?.int ?? 0) }
        XCTAssertEqual(fromBucket.count, min(40, bucket.filter { $0 % 2 == 0 }.count))
        let streamedDistances = fromBucket.compactMap { $0["distance"]?.double }
        XCTAssertEqual(streamedDistances, streamedDistances.sorted())

        // The exact flat table's answer for the same query, and the distance functions.
        let exact = try db.rows("SELECT rowid, distance FROM flat(?, '{K:10}')", [.blob(Support.bytes(query))])
        let reference = Support.bruteForce(vectors.enumerated().map { (String(format: "%05d", $0.offset + 1), $0.element) }, query, k: 10)
        XCTAssertEqual(exact.compactMap { $0["rowid"]?.int }, reference.map { Int($0.id)! })
        for (index, row) in exact.enumerated() { XCTAssertEqual(row["distance"]?.double ?? -1, reference[index].distance, accuracy: 1e-6) }
        let other = vectors[100]
        let measured = try XCTUnwrap(db.rows(
            "SELECT vec1_cos_distance(?, ?) AS c, vec1_l2_distance(?, ?) AS l",
            [.blob(Support.bytes(query)), .blob(Support.bytes(other)), .blob(Support.bytes(query)), .blob(Support.bytes(other))]
        ).first)
        XCTAssertEqual(measured["c"]?.double ?? -1, Support.cosDistance(query, other), accuracy: 1e-6)
        XCTAssertEqual(measured["l"]?.double ?? -1, Support.l2Distance(query, other), accuracy: 1e-4)

        // Malformed models: refused with an SQLite error inside a transaction that rolls back.
        var flipped = model
        flipped[flipped.startIndex + 7] ^= 0x02 // ROTATE cleared on an opq model's flags (big-endian u32 at byte 4)
        var wrongLength = model
        wrongLength.append(contentsOf: [0, 0, 0, 0])
        let random = Data((0..<model.count).map { UInt8(truncatingIfNeeded: $0 &* 7919 &+ 13) })
        let malformed: [(String, Data)] = [
            ("a truncated model", model.prefix(model.count - 4)),
            ("a wrong-length model", wrongLength),
            ("flipped header flags", flipped),
            ("random bytes", random),
            ("a header alone", model.prefix(24)),
        ]
        for (name, body) in malformed {
            try db.exec("BEGIN")
            try db.exec("CREATE VIRTUAL TABLE bad USING vec1")
            XCTAssertThrowsError(try db.run("INSERT INTO bad (cmd, arg) VALUES ('rebuild', ?)", [.blob(body)]), name) { error in
                XCTAssertFalse(String(describing: error).isEmpty, name)
            }
            try db.exec("ROLLBACK")
            XCTAssertTrue(try db.rows("SELECT name FROM sqlite_master WHERE name = 'bad'").isEmpty, "\(name): rolled back")
        }
        // The process is alive, and the tables built before still serve.
        XCTAssertEqual(try db.rows("SELECT rowid FROM ann(?, '{K:5, nprobe:0.1}')", [.blob(Support.bytes(query))]).count, 5)
        XCTAssertEqual(try db.rows("SELECT rowid FROM flat(?, '{K:5}')", [.blob(Support.bytes(query))]).count, 5)
    }
}
