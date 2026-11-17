import Foundation
import XCTest
@testable import JsBaoClient

/// #6021 behavior 27 — a Swift device holding a db3 type's clearing revision
/// leaves its cleared and tombstoned fields out of what it reads, as js-bao's
/// store does.
///
/// - The store keeps `record.opened`'s `cleared` map with the declarations,
///   and an entry held from before this change (no `cleared` key) makes the
///   next open omit `db3TypeHash` once, so the room sends them again.
/// - Model-free reads (`get`, `query`, `count`) answer no cleared field, and a
///   filter or sort on one treats it as unset, a value the local copy kept
///   from before the clear included. A change notice carries none.
/// - A read over several db3s reads the field as unset only on the rows of
///   the db3s that clear it.
final class RecordLogClearedFieldsHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    private func provider(_ label: String) async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/db3-cleared-\(label)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private static let live: [String: [String: String]] = ["tasks": ["title": "string", "score": "number"]]

    func testModelFreeReadsLeaveOutAClearedFieldAndReadItAsUnset() async throws {
        let provider = try await provider("records")
        let documentId = "rl-cleared-\(UUID().uuidString.prefix(8))"
        let binding = try RecordLogDocumentBinding(host: provider, documentId: documentId, clientId: "client-1", logger: Logger(level: .none))
        try binding.setState(type: .typed(name: "workspace", hash: "h1", models: Self.live))
        let records = DocumentRecords(documentId: documentId) { binding }
        _ = try records.put("tasks", ["id": "r1", "title": "a", "score": 42])
        _ = try records.put("tasks", ["id": "r2", "title": "b", "score": 7])
        XCTAssertEqual(try records.get("tasks", id: "r1")?["score"], 42)
        XCTAssertEqual(try records.count("tasks", ["score": 42]), 1)
        XCTAssertNil(binding.heldCleared)

        try binding.setState(type: .typed(
            name: "workspace", hash: "h2", models: ["tasks": ["title": "string"]], cleared: ["tasks": ["score"]]
        ))
        XCTAssertEqual(binding.heldCleared, ["tasks": ["score"]])
        // The local copy still holds the values; no read answers them.
        let one = try XCTUnwrap(try records.get("tasks", id: "r1"))
        XCTAssertNil(one["score"])
        XCTAssertEqual(one["title"], "a")
        let all = try records.query("tasks")
        XCTAssertEqual(Set(all.data.map { $0["id"]?.stringValue ?? "" }), ["r1", "r2"])
        XCTAssertTrue(all.data.allSatisfy { $0["score"] == nil })
        XCTAssertEqual(try records.count("tasks", ["score": 42]), 0)
        XCTAssertEqual(try records.count("tasks", ["score": .null]), 2)
        XCTAssertEqual(try records.count("tasks", ["score": ["$exists": true]]), 0)
        XCTAssertEqual(try records.query("tasks", ["score": ["$gte": 1]]).data.count, 0)
        // A sort on the field orders as on records that never had it: by id.
        var sorted = QueryOptions()
        sorted.sort = ["score": -1]
        XCTAssertEqual(try records.query("tasks", options: sorted).data.map { $0["id"]?.stringValue ?? "" }, ["r1", "r2"])

        // A change notice carries no cleared value.
        let heard = LockedBox<[RecordLogChangeNotice]>([])
        let token = binding.onChange { notice in heard.withValue { $0.append(notice) } }
        _ = try records.put("tasks", ["id": "r3", "title": "c", "score": 9])
        binding.removeChangeListener(token)
        XCTAssertFalse(heard.value.isEmpty)
        for notice in heard.value {
            for change in notice.changes { XCTAssertNil(change.row?["score"], "\(change)") }
        }

        // Un-cleared, the values the local copy holds read again.
        try binding.setState(type: .typed(name: "workspace", hash: "h3", models: Self.live, cleared: nil))
        XCTAssertNil(binding.heldCleared)
        XCTAssertEqual(try records.get("tasks", id: "r1")?["score"], 42)
        XCTAssertEqual(try records.count("tasks", ["score": 42]), 1)
    }

    /// `explain` runs the read a query or count runs, so it reads a cleared
    /// field as unset too while the local copy still holds its value.
    func testAnExplainReadsAClearedFieldAsTheReadDoes() async throws {
        let provider = try await provider("explain")
        let documentId = "rl-cleared-exp-\(UUID().uuidString.prefix(8))"
        let binding = try RecordLogDocumentBinding(host: provider, documentId: documentId, clientId: "client-1", logger: Logger(level: .none))
        try binding.setState(type: .typed(name: "workspace", hash: "h1", models: Self.live))
        let records = DocumentRecords(documentId: documentId) { binding }
        _ = try records.put("tasks", ["id": "r1", "title": "a", "score": 42])
        _ = try records.put("tasks", ["id": "r2", "title": "b", "score": 7])
        XCTAssertEqual(try records.explain("tasks", Db3ExplainRequest(op: .count, filter: ["score": 42])).answered, 1)

        try binding.setState(type: .typed(
            name: "workspace", hash: "h2", models: ["tasks": ["title": "string"]], cleared: ["tasks": ["score"]]
        ))
        let count = try records.explain("tasks", Db3ExplainRequest(op: .count, filter: ["score": 42]))
        XCTAssertEqual(count.answered, try records.count("tasks", ["score": 42]))
        XCTAssertEqual(count.answered, 0)
        XCTAssertEqual(try records.explain("tasks", Db3ExplainRequest(op: .query, filter: ["score": ["$gte": 1]])).answered, 0)
        XCTAssertEqual(try records.explain("tasks", Db3ExplainRequest(op: .count, filter: ["score": .null])).answered, 2)
    }

    func testAReadOverSeveralDb3sHidesTheFieldOnlyWhereItsDb3ClearsIt() async throws {
        let provider = try await provider("scope")
        let a = "rl-cleared-a-\(UUID().uuidString.prefix(8))"
        let b = "rl-cleared-b-\(UUID().uuidString.prefix(8))"
        let bindingA = try RecordLogDocumentBinding(host: provider, documentId: a, clientId: "client-1", logger: Logger(level: .none))
        let bindingB = try RecordLogDocumentBinding(host: provider, documentId: b, clientId: "client-1", logger: Logger(level: .none))
        for binding in [bindingA, bindingB] { try binding.setState(type: .typed(name: "workspace", hash: "h1", models: Self.live)) }
        _ = try DocumentRecords(documentId: a) { bindingA }.put("tasks", ["id": "a1", "title": "a", "score": 42])
        _ = try DocumentRecords(documentId: b) { bindingB }.put("tasks", ["id": "b1", "title": "b", "score": 42])
        _ = try DocumentRecords(documentId: b) { bindingB }.put("tasks", ["id": "b2", "title": "c", "score": 7])
        try bindingA.setState(type: .typed(
            name: "workspace", hash: "h2", models: ["tasks": ["title": "string"]], cleared: ["tasks": ["score"]]
        ))

        var reader = RecordLogViewReader(store: bindingA.store, documents: [a, b])
        reader.cleared = [a: try XCTUnwrap(bindingA.heldCleared)]
        XCTAssertEqual(try reader.count("tasks", ["score": 42]), 1)
        XCTAssertEqual(try reader.count("tasks", ["score": .null]), 1)
        var sorted = QueryOptions()
        sorted.sort = ["score": -1]
        let page = try reader.page("tasks", [:], options: sorted, shape: .stored)
        XCTAssertEqual(page.rows.map { $0["id"]?.stringValue ?? "" }, ["b1", "b2", "a1"])
        XCTAssertEqual(page.rows.map { $0["score"] }, [42, 7, nil])
        let sum = try reader.aggregate("tasks", AggregateOptions(operations: [.init(type: .sum, field: "score")]), setFields: [])
        XCTAssertEqual(sum.first?.values.compactMap(\.numberValue).first, 49)

        // Over A alone the field is unset on every row.
        var alone = RecordLogViewReader(store: bindingA.store, documents: [a])
        alone.cleared = reader.cleared
        XCTAssertEqual(try alone.count("tasks", ["score": 42]), 0)
        // With nothing held cleared, the reader reads as it always did.
        XCTAssertEqual(try RecordLogViewReader(store: bindingA.store, documents: [a, b]).count("tasks", ["score": 42]), 2)
    }

    /// A model generated before the clear, with the field optional and a
    /// `default`, reads it through `holds`: once the device holds the clear,
    /// neither a record nor a query row answers the default for it.
    func testAClearedFieldReadsUnsetNotAsItsDefaultOnARecordAndAQueryRow() async throws {
        let provider = try await provider("defaults")
        let documentId = "rl-cleared-def-\(UUID().uuidString.prefix(8))"
        RecordLogDocumentIds.note(documentId)
        let binding = try RecordLogDocumentBinding(host: provider, documentId: documentId, clientId: "client-1", logger: Logger(level: .none))
        try binding.setState(type: .typed(name: "workspace", hash: "h1", models: Self.live))
        let schema = try XCTUnwrap(try TomlSchemaLoader.load(tomlString: """
            [models.tasks.fields.title]
            type = "string"

            [models.tasks.fields.score]
            type = "number"
            default = 7
            """).first)
        let delegate = try RecordLogModelDelegate(binding: binding, schema: schema)
        let records = DocumentRecords(documentId: documentId) { binding }
        _ = try records.put("tasks", ["id": "r1", "title": "a", "score": 42])
        _ = try records.put("tasks", ["id": "r2", "title": "b"])
        // What the generated `init?(record:)` and `init?(row:)` read for a field with a default.
        func fromRecord(_ id: String) throws -> Double? {
            try delegate.holds(id: id, field: "score") == false ? 7 : delegate.row(id: id)?["score"]?.numberValue
        }
        func fromRows() throws -> [String: Double?] {
            var out: [String: Double?] = [:]
            for row in try delegate.query(filter: nil, options: nil) {
                out[row["id"]?.stringValue ?? ""] = PrimitiveRecord.holds("score", in: row) == false ? 7 : row["score"]?.numberValue
            }
            return out
        }
        XCTAssertEqual(try fromRecord("r1"), 42)
        XCTAssertEqual(try fromRecord("r2"), 7)
        XCTAssertEqual(try fromRows(), ["r1": 42, "r2": 7])

        try binding.setState(type: .typed(
            name: "workspace", hash: "h2", models: ["tasks": ["title": "string"]], cleared: ["tasks": ["score"]]
        ))
        XCTAssertNil(try fromRecord("r1"))
        XCTAssertNil(try fromRecord("r2"))
        XCTAssertEqual(try fromRows(), ["r1": nil, "r2": nil])
        XCTAssertEqual(try delegate.holds(id: "r1", field: "title"), true)
        for row in try delegate.query(filter: nil, options: nil) { XCTAssertNil(row["score"]) }

        // Un-cleared, the default fills the record that never held the field again.
        try binding.setState(type: .typed(name: "workspace", hash: "h3", models: Self.live, cleared: nil))
        XCTAssertEqual(try fromRecord("r1"), 42)
        XCTAssertEqual(try fromRows(), ["r1": 42, "r2": 7])
    }

    typealias H = RecordLogReceiptHarness

    func testTheStoreKeepsClearedAndAnEntryHeldWithoutItOmitsTheHashOnce() async throws {
        let provider = try await provider("cache")
        let binding = try RecordLogDocumentBinding(host: provider, documentId: H.documentId, clientId: "client-a", logger: Logger(level: .none))
        try binding.registerModel(H.schema)
        let connection = H.Connection(fetches: false)
        let synced = LockedBox(0)
        let session = RecordLogSession(
            documentId: H.documentId, binding: binding,
            host: RecordLogSessionHost(
                connection: { connection }, declarations: { [:] }, synced: { _ in synced.withValue { $0 += 1 } },
                syncFailed: { _, _ in }, waitsForTypeBeforeDeclaring: true
            ),
            timings: H.timings, logger: Logger(level: .none)
        )
        await session.attach()
        func feed(_ frame: [String: JSONValue]) async {
            var frame = frame
            frame["documentId"] = .string(H.documentId)
            await session.receive(frame)
        }
        func until(_ what: String, _ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertTrue(condition(), "timed out waiting for \(what)")
        }
        func reopen() async -> [String: JSONValue]? {
            await session.disconnected()
            let at = connection.frames.count
            await session.start()
            await until("an open") { connection.frames.dropFirst(at).contains { $0["type"]?.stringValue == "record.open" } }
            return connection.frames.dropFirst(at).first { $0["type"]?.stringValue == "record.open" }
        }
        func held() throws -> [String: JSONValue]? {
            let text = try provider.withConnection {
                try $0.query("SELECT value FROM record_log_meta WHERE key = ?", [.text("db3_type:\(H.documentId)")]).first?["value"].stringValue
            }
            return text.flatMap { JSONValue(jsonText: $0) }?.objectValue
        }
        let models: JSONValue = ["Note": ["title": "string"]]
        let cleared: JSONValue = ["Note": ["score"]]
        var opened = H.opened(lsn: 0)
        opened["db3Type"] = ["name": "notes", "hash": "h1", "models": models, "cleared": cleared]
        await session.start()
        await feed(opened)
        await until("the open") { synced.value == 1 }
        XCTAssertEqual(binding.heldCleared, ["Note": ["score"]])
        XCTAssertEqual(try held()?["cleared"], cleared)
        let first = await reopen()
        XCTAssertEqual(first?["db3TypeHash"]?.stringValue, "h1")

        // The entry as a client from before cleared fields wrote it: no `cleared` key.
        try provider.withConnection { connection in
            try connection.execute(
                "UPDATE record_log_meta SET value = ? WHERE key = ?",
                [.text(#"{"typed":"yes","name":"notes","hash":"h1","models":{"Note":{"title":"string"}},"vectors":null,"enums":null}"#),
                 .text("db3_type:\(H.documentId)")]
            )
        }
        _ = try binding.refreshMarks()
        XCTAssertNil(binding.heldCleared)
        let omitted = await reopen()
        XCTAssertNotNil(omitted)
        XCTAssertNil(omitted?["db3TypeHash"])
        await feed(opened)
        await until("the second opened") { synced.value == 2 }
        XCTAssertEqual(try held()?["cleared"], cleared)
        XCTAssertEqual(binding.heldCleared, ["Note": ["score"]])
        let rewritten = await reopen()
        XCTAssertEqual(rewritten?["db3TypeHash"]?.stringValue, "h1")

        // A type clearing none is held as `cleared: null`, and the hash-only answer keeps what is held.
        var plain = H.opened(lsn: 0)
        plain["db3Type"] = ["name": "notes", "hash": "h2", "models": models]
        await feed(plain)
        await until("the plain opened") { synced.value == 3 }
        XCTAssertEqual(try held()?["cleared"], .null)
        XCTAssertNil(binding.heldCleared)
    }
}
