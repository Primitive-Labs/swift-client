import XCTest
@testable import JsBaoClient

/// A cold store loading a segment chunk holds an array-valued field as a
/// string set, whether or not the room had a declaration: the array stays in
/// the view row, and a query over the view reads its members. The Swift twin
/// of js-bao's `record-log-client-cold-set-4622.test.ts`. (Until #4700 a spec
/// for the model wrote the members into its query tables' junction too.)
final class RecordLogColdSetHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }


    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-cold-set-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    /// A cold store in a segment's full replacement: its writer and generation.
    private func cold(_ provider: SQLiteStorageProvider) throws -> (RecordLogStore, String, Int) {
        let store = RecordLogStore(host: provider, documentId: "doc-1", clientId: "client-a")
        try store.initialize()
        let writer = try store.mintWriter()
        _ = try store.beginReceipt(writer: writer, kind: .segment, id: "S1")
        let generation = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        return (store, writer, generation)
    }

    private let chunkRow = RecordLogCatchUpRow(
        model: "Note", id: "n1", row: ["id": "n1", "title": "a note", "tags": ["b", "a"]]
    )

    func testASegmentChunksArrayIsReadAsAStringSetByAQueryOverTheView() async throws {
        let provider = try await makeProvider()
        let (store, writer, generation) = try cold(provider)
        _ = try store.applySegmentChunk(writer: writer, generation: generation, rows: [chunkRow])
        XCTAssertEqual(try store.queryView("Note", ["tags": ["$contains": "a"]]).data.compactMap { $0["id"]?.stringValue }, ["n1"])
        XCTAssertEqual(try store.queryView("Note", ["tags": ["$all": ["a", "b"]]]).data.count, 1)
        let row = try XCTUnwrap(try store.read(model: "Note", id: "n1"))
        XCTAssertEqual(row["tags"], ["b", "a"])
        XCTAssertEqual(row["title"], "a note")
    }

    func testASegmentChunkWithNoSpecKeepsTheArrayInTheViewRow() async throws {
        let provider = try await makeProvider()
        let (store, writer, generation) = try cold(provider)
        _ = try store.applySegmentChunk(writer: writer, generation: generation, rows: [chunkRow])
        let row = try XCTUnwrap(try store.read(model: "Note", id: "n1"))
        XCTAssertEqual(row["tags"], ["b", "a"])
        let view = try provider.withConnection { connection in
            try connection.query("SELECT _data FROM record_log_view WHERE _id = ?", [.text("n1")])
        }.first?["_data"].stringValue
        XCTAssertNotNil(view)
        XCTAssertTrue(view?.contains("\"tags\":[\"b\",\"a\"]") ?? false, "the view row holds the array: \(view ?? "nil")")
    }
}
