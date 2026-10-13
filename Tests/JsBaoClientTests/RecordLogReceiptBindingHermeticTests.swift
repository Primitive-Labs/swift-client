import XCTest
import YSwift
@testable import JsBaoClient

/// What a load's chunk does to a bound document's models, and the field names
/// a format-3 save may not carry, through the binding and the `DynamicModel`
/// facade over a real `SQLiteStorageProvider`.
///
/// - A chunk reply's `models` notify those models' listeners once per chunk;
///   its `changed` records notify theirs as before; reads see the loaded rows.
/// - A field named `type` or beginning with `_` is refused locally with
///   `.documentEntryInvalid`, reported with the one write and thrown before
///   any entry is minted; `id` is allowed.
final class RecordLogReceiptBindingHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let note = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string),
            "_hidden": FieldDescriptor(type: .string),
            "n": FieldDescriptor(type: .number, indexed: true),
        ]
    )
    private static let task = PrimitiveSchema(
        name: "Task",
        fields: ["id": FieldDescriptor(type: .id), "label": FieldDescriptor(type: .string)]
    )

    private func makeBinding() async throws -> (RecordLogDocumentBinding, DynamicModel, DynamicModel) {
        let directory = NSTemporaryDirectory() + "/record-log-receipt-binding-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let documentId = "rl-\(UUID().uuidString.prefix(8))"
        let binding = try RecordLogDocumentBinding(
            host: provider, documentId: documentId, clientId: "client-1",
            engine: BaoModelQueryEngine(host: provider), logger: Logger(level: .none)
        )
        let doc = YDocument()
        let note = MultiDocModel(schema: Self.note).connect(docId: documentId, doc: doc)
        try note.bindRecordLog(binding)
        let task = MultiDocModel(schema: Self.task).connect(docId: documentId, doc: doc)
        try task.bindRecordLog(binding)
        return (binding, note, task)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func hit(_ model: String) { lock.withLock { counts[model, default: 0] += 1 } }
        func count(_ model: String) -> Int { lock.withLock { counts[model] ?? 0 } }
    }

    func testAChunksModelsNotifyTheirListenersOncePerChunkAndItsChangedRecordsAsBefore() async throws {
        let (binding, note, _) = try await makeBinding()
        let heard = Counter()
        binding.onModelChanged("Note") { heard.hit("Note") }
        binding.onModelChanged("Task") { heard.hit("Task") }
        let writer = binding.writer
        let attempt = try binding.store.beginReceipt(writer: writer, kind: .load, id: "S1").attempt
        let lines = (1...50).map { RecordLogLoadLine(id: "n\($0)", patch: ["title": .string("t\($0)"), "n": .number(Double($0))]) }
        let reply = try binding.withOperation {
            try binding.store.applyLoadChunk(
                writer: writer, sessionId: "S1", attempt: attempt, model: "Note", lines: lines, project: binding.projectionSpecs
            )
        }
        XCTAssertEqual(reply.models, ["Note"])
        XCTAssertTrue(reply.changed.isEmpty)
        binding.notify(reply)
        XCTAssertEqual(heard.count("Note"), 1, "once for the chunk, not once per row")
        XCTAssertEqual(heard.count("Task"), 0)
        XCTAssertEqual(note.find(id: "n7")?["title"], .string("t7"))
        XCTAssertEqual(try note.query(["n": 7]).count, 1)

        // A record an unjudged entry touches is refreshed and named in `changed`.
        try note.update(id: "n7", values: ["title": .string("mine")])
        let refreshed = try binding.withOperation {
            try binding.store.applyLoadChunk(
                writer: writer, sessionId: "S1", attempt: attempt, model: "Note",
                lines: [RecordLogLoadLine(id: "n7", patch: ["title": "loaded", "n": 70])], project: binding.projectionSpecs
            )
        }
        XCTAssertEqual(refreshed.changed.map(\.id), ["n7"])
        let before = heard.count("Note")
        binding.notify(refreshed)
        XCTAssertEqual(heard.count("Note"), before + 1)
        XCTAssertEqual(note.find(id: "n7")?["title"], .string("mine"), "the pending patch's guess on top")
        XCTAssertEqual(note.find(id: "n7")?["n"], .number(70))
        XCTAssertEqual(try note.query(["n": 70]).count, 1)
    }

    func testASaveWithAReservedFieldIsRefusedBeforeAnyEntryIsMinted() async throws {
        let (binding, note, _) = try await makeBinding()
        let reported = LockedBox<[DocumentWriteRefusedEvent]>([])
        binding.setRefusalReporter { event in reported.withValue { $0.append(event) } }
        XCTAssertThrowsError(try note.create(id: "n1", values: ["title": .string("x"), "_hidden": .string("secret")])) { error in
            let refused = error as? JsBaoError
            XCTAssertEqual(refused?.code, .documentEntryInvalid)
            XCTAssertTrue(refused?.message.contains("Field '_hidden' is reserved") == true, refused?.message ?? "")
            XCTAssertTrue(refused?.message.hasSuffix("Rename the field.") == true)
        }
        XCTAssertEqual(try binding.store.pendingOf(binding.writer).count, 0, "no entry was minted")
        XCTAssertNil(note.find(id: "n1"))
        XCTAssertEqual(reported.value.count, 1)
        XCTAssertEqual(reported.value.first?.writes?.map(\.recordId), ["n1"])
        _ = try note.create(id: "n2", values: ["title": .string("fine")])
        XCTAssertEqual(try binding.store.pendingOf(binding.writer).count, 1)
    }
}
