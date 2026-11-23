import XCTest
@testable import JsBaoClient

/// #5230 behavior 2 — `Format2SqlValue.blob(Data)` on the store's
/// connection: a bound blob reads back byte for byte, a `SQLITE_BLOB`
/// column reads as `.blob` (a zero-length one as empty `Data`), and `hex()`
/// of a bound blob is its bytes. vec1 needs both: the query vector and a
/// model are bound as blobs, a training sample is read as one.
final class Format2SqlBlobHermeticTests: XCTestCase {

    private var provider: SQLiteStorageProvider!

    override func setUp() async throws {
        provider = SQLiteStorageProvider(path: ":memory:")
        try await provider.initialize(namespace: "blob-5230")
    }

    override func tearDown() async throws {
        await provider.close()
    }

    func testABoundBlobReadsBackByteForByte() throws {
        let bytes = Data((0..<1031).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) } + [0, 0, 255])
        try provider.withConnection { connection in
            try connection.executeScript("CREATE TABLE blobs (id INTEGER PRIMARY KEY, b BLOB)")
            try connection.execute("INSERT INTO blobs (id, b) VALUES (?, ?)", [.integer(1), .blob(bytes)])
            try connection.execute("INSERT INTO blobs (id, b) VALUES (?, ?)", [.integer(2), .blob(Data())])
            let rows = try connection.query("SELECT id, b, typeof(b) AS t, length(b) AS n FROM blobs ORDER BY id", [])
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows[0]["b"], .blob(bytes))
            XCTAssertEqual(rows[0]["t"].stringValue, "blob")
            XCTAssertEqual(rows[0]["n"].intValue, bytes.count)
            // A zero-length blob is a blob of no bytes, not NULL.
            XCTAssertEqual(rows[1]["b"], .blob(Data()))
            XCTAssertEqual(rows[1]["t"].stringValue, "blob")
            XCTAssertEqual(rows[1]["b"].stringValue, nil)
            XCTAssertEqual(rows[1]["b"].intValue, nil)
            XCTAssertFalse(rows[1]["b"].isNull)
        }
    }

    func testHexOfABoundBlobIsItsBytes() throws {
        let bytes = Data([0x00, 0x01, 0x7f, 0x80, 0xfe, 0xff, 0x50, 0x56, 0x4d, 0x31])
        let hex = try provider.withConnection { connection in
            try connection.query("SELECT hex(?) AS h, typeof(?) AS t", [.blob(bytes), .blob(bytes)]).first
        }
        XCTAssertEqual(hex?["h"].stringValue, bytes.map { String(format: "%02X", $0) }.joined())
        XCTAssertEqual(hex?["t"].stringValue, "blob")
    }

    func testAStreamedRowReadsABlobToo() throws {
        let bytes = Data([1, 2, 3, 4, 5, 6, 7, 8])
        var seen: [Format2SqlValue] = []
        try provider.withConnection { connection in
            try connection.eachRow("SELECT ? AS b UNION ALL SELECT zeroblob(0)", [.blob(bytes)]) { row in
                seen.append(row["b"])
                return true
            }
        }
        XCTAssertEqual(seen, [.blob(bytes), .blob(Data())])
    }
}
