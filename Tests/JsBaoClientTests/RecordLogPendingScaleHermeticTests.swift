import XCTest
@testable import JsBaoClient

/// The record-log store's cost per acknowledgement and per write does not grow
/// with the number of entries pending, over a real `SQLiteStorageProvider` on a
/// temp file: the bounds js-bao's store meets in
/// `record-log-client-pending-scale-4471.test.ts`.
///
/// - With 10,000 creates pending, a 125-item acknowledgement frame takes under
///   150 ms, and acknowledging all 10,000 under 10 s.
/// - Committing 10,000 creates in batches of 500 takes under 6 s.
/// - A store whose tables an earlier version created gains the pending log's
///   order and epoch indexes when it is opened, and keeps its entries.
final class RecordLogPendingScaleHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }


    private static let rows = 10_000
    private static let batch = 500
    private static let frame = 125
    private static let added = ["record_log_pending_by_ord", "record_log_pending_by_epoch"]

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-pending-scale-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func makeStore(_ provider: SQLiteStorageProvider) throws -> (RecordLogStore, String) {
        let store = RecordLogStore(host: provider, documentId: "doc-4471", clientId: "client-1")
        try store.initialize()
        return (store, try store.mintWriter())
    }

    private func id(_ i: Int) -> String { "n" + String(format: "%05d", i) }
    private func fields(_ i: Int) -> [String: JSONValue] { ["title": .string("t\(i)"), "n": .number(Double(i))] }
    private func create(_ i: Int) -> RecordLogMutation {
        RecordLogMutation(model: "Note", id: id(i), kind: .create, fields: fields(i))
    }

    private func elapsedMs(_ body: () throws -> Void) rethrows -> Double {
        let started = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    }

    /// Commit every create in batches; answers the time taken.
    private func commitAll(_ store: RecordLogStore, _ writer: String) throws -> Double {
        try elapsedMs {
            for at in stride(from: 1, through: Self.rows, by: Self.batch) {
                let writes = (at..<(at + Self.batch)).map { RecordLogWrite(mutations: [create($0)]) }
                _ = try store.commitEntries(writer: writer, writes: writes)
            }
            try store.flush()
        }
    }

    private func indexes(_ provider: SQLiteStorageProvider) throws -> [String] {
        try provider.withConnection { connection in
            try connection.query("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'record_log_pending'", [])
                .compactMap { $0["name"].stringValue }
        }
    }

    func testAcknowledgesA125ItemFrameInUnder150MsWith10000PendingAndAllInUnder10Seconds() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)
        _ = try commitAll(store, writer)
        XCTAssertEqual(try store.marks().pending, Self.rows)

        var perFrame: [Double] = []
        var total = 0.0
        for at in stride(from: 1, through: Self.rows, by: Self.frame) {
            let items: [RecordLogResultItem] = (at..<(at + Self.frame)).map { seq in
                var row = fields(seq)
                row["id"] = .string(id(seq))
                return .result(RecordLogResult(
                    l: seq, e: 1, changes: [RecordLogChange(model: "Note", id: id(seq), row: row)], w: writer, seq: seq
                ))
            }
            let took = try elapsedMs { _ = try store.receive(writer: writer, items: items) }
            perFrame.append(took)
            total += took
            // Past the bound already: the rest of the frames cannot bring it back.
            if total >= 10_000 { break }
        }
        // The first third of the frames run with 6,700 to 10,000 entries pending.
        let firstThird = perFrame.prefix(max(1, perFrame.count / 3)).sorted()
        let median = firstThird[firstThird.count / 2]
        print("[#4471] swift receive \(perFrame.count) frames in \(Int(total)) ms, first-third median \(Int(median)) ms per frame")
        XCTAssertLessThan(median, 150)
        XCTAssertLessThan(total, 10_000)
        XCTAssertEqual(perFrame.count, Self.rows / Self.frame)
        guard perFrame.count == Self.rows / Self.frame else { return }
        let marks = try store.marks()
        XCTAssertEqual(marks.pending, 0)
        XCTAssertEqual(marks.cursor, Self.rows)
        XCTAssertTrue(marks.unacked.isEmpty)
    }

    func testCommits10000CreatesInBatchesOf500InUnder6Seconds() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)
        let took = try commitAll(store, writer)
        print("[#4471] swift commit \(Int(took)) ms")
        XCTAssertLessThan(took, 6_000)
        let marks = try store.marks()
        XCTAssertEqual(marks.pending, Self.rows)
        XCTAssertEqual(marks.nextSeq, Self.rows + 1)
    }

    func testAStoreAnEarlierVersionCreatedGainsThePendingIndexesOnOpenAndKeepsItsEntries() async throws {
        let provider = try await makeProvider()
        // The tables as the previous version wrote them: every statement but the new indexes.
        try provider.withConnection { connection in
            for statement in RecordLogSchema.ddl where !Self.added.contains(where: { statement.contains($0) }) {
                try connection.executeScript(statement)
            }
        }
        let earlier = RecordLogStore(host: provider, documentId: "doc-4471", clientId: "client-1")
        let writer = try earlier.mintWriter()
        _ = try earlier.commitEntries(writer: writer, writes: [RecordLogWrite(mutations: [create(1)])])
        try earlier.flush()
        XCTAssertFalse(try indexes(provider).contains(Self.added[0]))

        let (store, sameWriter) = try makeStore(provider)
        XCTAssertEqual(sameWriter, writer)
        XCTAssertTrue(Set(try indexes(provider)).isSuperset(of: Self.added))
        _ = try store.commitEntries(writer: writer, writes: [RecordLogWrite(mutations: [create(2)])])
        try store.flush()
        XCTAssertEqual(try store.pendingOf(writer).map(\.seq), [1, 2])
        let ords = try provider.withConnection { connection in
            try connection.query("SELECT ord FROM record_log_pending WHERE doc_id = 'doc-4471' ORDER BY seq", [])
                .compactMap { $0["ord"].intValue }
        }
        XCTAssertEqual(ords, [1, 2])
    }
}
