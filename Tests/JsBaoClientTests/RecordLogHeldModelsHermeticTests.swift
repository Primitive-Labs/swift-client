import XCTest
@testable import JsBaoClient

/// The models a db3's copy holds, as the store's marks name them (#5160): what
/// an untyped open declares into the room before anything is bound. Real
/// SQLite on a temp file; the room's answers are built here.
final class RecordLogHeldModelsHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-held-models-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func makeStore(_ provider: SQLiteStorageProvider, documentId: String = "doc-1", clientId: String = "client-1") throws -> (RecordLogStore, String) {
        let store = RecordLogStore(host: provider, documentId: documentId, clientId: clientId)
        try store.initialize()
        return (store, try store.mintWriter())
    }

    @discardableResult
    private func write(_ store: RecordLogStore, _ writer: String, _ model: String, _ id: String,
                       _ kind: RecordLogWriteKind = .create, also: [RecordLogMutation] = []) throws -> RecordLogPendingEntry {
        let fields: [String: JSONValue]? = kind == .delete ? nil : ["title": .string(id)]
        let main = RecordLogMutation(model: model, id: id, kind: kind, fields: fields)
        return try store.commitEntries(writer: writer, writes: [RecordLogWrite(mutations: [main] + also)]).entries[0]
    }

    private func confirmed(_ l: Int, _ model: String, _ id: String) -> RecordLogResultItem {
        .result(RecordLogResult(l: l, e: 1, changes: [
            RecordLogChange(model: model, id: id, row: ["id": .string(id), "title": .string(id)]),
        ]))
    }

    // MARK: - Behavior 1

    func testAFreshStoreHoldsNoModels() async throws {
        let (store, _) = try makeStore(try await makeProvider())
        XCTAssertEqual(try store.marks().models, [])
    }

    func testTheModelsAreThoseOfTheViewTheConfirmedRowsAndTheUnjudgedEntriesOfAnyWriter() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)

        // A confirmed row another writer wrote, through the room.
        _ = try store.receive(writer: writer, items: [confirmed(1, "Task", "t1")])
        XCTAssertEqual(try store.marks().models, ["Task"])

        // This writer's unjudged write, in a transaction naming a second model.
        try write(store, writer, "Note", "n1", also: [RecordLogMutation(model: "Label", id: "l1", kind: .create, fields: ["title": "l"])])
        XCTAssertEqual(try store.marks().models, ["Label", "Note", "Task"], "sorted and distinct")

        // An earlier writer's unjudged delete of a record no row holds: only the entry names its model.
        let (earlierStore, earlier) = try makeStore(provider, clientId: "earlier")
        try write(earlierStore, earlier, "Ghost", "g1", .delete)
        XCTAssertEqual(try store.marks().models, ["Ghost", "Label", "Note", "Task"], "an unjudged entry of any writer counts")

        // Acknowledged: the delete's model no longer counts, though the entry is still pending.
        _ = try earlierStore.receive(writer: earlier, items: [
            .result(RecordLogResult(l: 5, e: 1, changes: [], w: earlier, seq: 1)),
        ])
        XCTAssertNotNil(try earlierStore.pendingOf(earlier).first { $0.seq == 1 }?.acked, "acknowledged, not settled")
        XCTAssertEqual(try store.marks().models, ["Label", "Note", "Task"], "an acknowledged entry's model does not count")

        // The same store opened again names the same models.
        let (reopened, _) = try makeStore(provider)
        XCTAssertEqual(try reopened.marks().models, ["Label", "Note", "Task"])
    }

    func testAVoidEntrysModelDoesNotCount() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)
        try write(store, writer, "Ghost", "g1", .delete)
        XCTAssertEqual(try store.marks().models, ["Ghost"])
        _ = try store.refused(writer: writer, refusal: RecordLogRefusal(
            seq: 1, code: "DOCUMENT_CONSTRAINT_VIOLATED", scope: .record, from: 1,
            records: [RecordLogRefusedRecord(model: "Ghost", id: "g1", from: 1)]
        ))
        XCTAssertEqual(try store.pendingOf(writer).filter(\.isVoid).map(\.seq), [1], "withdrawn: a void marker stays")
        XCTAssertEqual(try store.marks().models, [], "a void entry's model does not count")
    }

    func testOnlyThisDocumentsModelsAreNamedWhenAnotherSharesTheFile() async throws {
        let provider = try await makeProvider()
        let (x, xWriter) = try makeStore(provider, documentId: "doc-x")
        let (y, yWriter) = try makeStore(provider, documentId: "doc-y")
        try write(x, xWriter, "Note", "n1")
        try write(y, yWriter, "Task", "t1")
        _ = try y.receive(writer: yWriter, items: [confirmed(1, "Label", "l1")])
        XCTAssertEqual(try x.marks().models, ["Note"])
        XCTAssertEqual(try y.marks().models, ["Label", "Task"])
    }

    // MARK: - Behavior 22 (the store half): the cost of the read

    /// Prints the p50 of the marks read on a 5,000-row, 5-model copy. No bound:
    /// the figure is compared by hand at the base commit and at the head.
    func testTheMarksReadOnAFiveThousandRowFiveModelCopyIsMeasured() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)
        let models = ["A", "B", "C", "D", "E"]
        var l = 0
        for batch in 0..<50 {
            l += 1
            let changes = (0..<100).map { index -> RecordLogChange in
                let id = "r\(batch)-\(index)"
                return RecordLogChange(model: models[index % models.count], id: id, row: ["id": .string(id), "title": .string(id)])
            }
            _ = try store.receive(writer: writer, items: [.result(RecordLogResult(l: l, e: 1, changes: changes))])
        }
        XCTAssertEqual(try store.marks().models, models)
        var samples: [Double] = []
        for _ in 0..<200 {
            let started = DispatchTime.now().uptimeNanoseconds
            _ = try store.marks()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        samples.sort()
        print("[5160] marks read on 5,000 rows / 5 models: p50", String(format: "%.3f", samples[samples.count / 2]), "ms over 200 reads")
    }
}
