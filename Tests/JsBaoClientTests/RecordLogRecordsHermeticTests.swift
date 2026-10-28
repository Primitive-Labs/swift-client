import XCTest
import YSwift
@testable import JsBaoClient

/// `DocumentRecords`, the model-free records of one format-3 document, over a
/// real binding and store with no server: writes commit as entries and answer
/// from the view, a write the room would refuse is refused here first and
/// reported once (#4624 behaviour 12), a write to a model a class declares
/// is read by that class's queries at once, and a subscription
/// hears every change to its model (behaviour 19). What the room would send
/// is applied through the binding's store and announced as the session does.
final class RecordLogRecordsHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string),
            "views": FieldDescriptor(type: .number, indexed: true),
            "tags": FieldDescriptor(type: .stringset),
        ]
    )

    private struct Fixture {
        let provider: SQLiteStorageProvider
        let binding: RecordLogDocumentBinding
        let model: DynamicModel
        let records: DocumentRecords
        let refused: LockedBox<[DocumentWriteRefusedEvent]>
    }

    private func makeFixture() async throws -> Fixture {
        let directory = NSTemporaryDirectory() + "/record-log-records-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let documentId = "rl-\(UUID().uuidString.prefix(8))"
        let binding = try RecordLogDocumentBinding(
            host: provider, documentId: documentId, clientId: "client-1",
            logger: Logger(level: .none)
        )
        let model = MultiDocModel(schema: Self.schema).connect(docId: documentId, doc: YDocument())
        try model.bindRecordLog(binding)
        let refused = LockedBox<[DocumentWriteRefusedEvent]>([])
        binding.setRefusalReporter { event in refused.withValue { $0.append(event) } }
        let records = DocumentRecords(documentId: documentId) { binding }
        return Fixture(provider: provider, binding: binding, model: model, records: records, refused: refused)
    }

    private func pending(_ fixture: Fixture) throws -> [RecordLogPendingEntry] {
        try fixture.binding.store.pendingOf(fixture.binding.writer)
    }

    func testWritesCommitAsEntriesAndAnswerFromTheView() async throws {
        let fixture = try await makeFixture()
        let records = fixture.records
        let put = try records.put("Memo", ["title": "a", "tags": ["y", "x"]])
        let id = try XCTUnwrap(put["id"]?.stringValue)
        XCTAssertEqual(id.count, 26, "a new ULID")
        XCTAssertEqual(put.raw, ["id": .string(id), "title": "a", "tags": ["x", "y"]])
        XCTAssertEqual(try records.get("Memo", id: id), put)
        XCTAssertEqual(try records.put("Memo", ["id": "n1", "title": "b"])["id"], "n1")
        XCTAssertNil(try records.patch("Memo", id: "nobody", ["title": "c"]), "a patch of a record the copy lacks answers nil")
        XCTAssertEqual(try pending(fixture).last?.m, RecordLogMutation(model: "Memo", id: "nobody", kind: .patch, fields: ["title": "c"]),
                       "and is sent all the same")
        XCTAssertEqual(try records.patch("Memo", id: "n1", ["title": "d", "n": 2])?.raw, ["id": "n1", "title": "d", "n": 2])
        try records.delete("Memo", id: "n1")
        XCTAssertNil(try records.get("Memo", id: "n1"))
        XCTAssertEqual(try pending(fixture).map(\.m.kind), [.create, .create, .patch, .patch, .delete])
        XCTAssertEqual(try records.count("Memo"), 1)
        XCTAssertEqual(try records.query("Memo", ["tags": ["$contains": "x"]]).data.map(\.raw), [put.raw])
    }

    func testAPutOnAHeldIdIsACreateShowingExactlyTheNewState() async throws {
        let fixture = try await makeFixture()
        try fixture.records.put("Memo", ["id": "m1", "title": "a", "tags": ["x"], "n": 1])
        let replaced = try fixture.records.put("Memo", ["id": "m1", "tags": ["y"]])
        XCTAssertEqual(replaced.raw, ["id": "m1", "tags": ["y"]])
        XCTAssertEqual(try pending(fixture).last?.m.kind, .create)
    }

    func testALocalRefusalThrowsTheRoomsSentenceAndIsReportedOnce() async throws {
        let fixture = try await makeFixture()
        let records = fixture.records
        let cases: [(String, () throws -> Void, String)] = [
            ("model", { try records.put("a b", ["title": "x"]) },
             "Cannot save a b {id}: model \"a b\" is not an identifier (a letter, then letters, digits or _)."),
            ("type", { try records.patch("Memo", id: "m1", ["type": "x"]) },
             "Cannot save Memo m1: Field 'type' is reserved (maps to internal _type column in queries). Rename the field."),
            ("field", { try records.put("Memo", ["id": "m1", "a b": "x"]) },
             "Cannot save Memo m1: field \"a b\" is not an identifier (a letter, then letters, digits or _). Rename the field."),
            ("empty id", { try records.patch("Memo", id: "", ["title": "x"]) }, "Cannot save Memo: a record id is a non-empty string."),
            ("empty id delete", { try records.delete("Memo", id: "") }, "Cannot save Memo: a record id is a non-empty string."),
        ]
        for (what, call, sentence) in cases {
            fixture.refused.value = []
            var thrown: JsBaoError?
            XCTAssertThrowsError(try call(), what) { thrown = $0 as? JsBaoError }
            XCTAssertEqual(thrown?.code, .documentEntryInvalid, what)
            let events = fixture.refused.value
            XCTAssertEqual(events.count, 1, what)
            let id = events.first?.recordId ?? ""
            XCTAssertEqual(thrown?.message, sentence.replacingOccurrences(of: "{id}", with: id), what)
            XCTAssertEqual(events.first?.error.message, thrown?.message, what)
            XCTAssertEqual(events.first?.error.details?["scope"], "local", what)
            XCTAssertEqual(events.first?.writes?.count, 1, what)
        }
        XCTAssertEqual(try pending(fixture).count, 0, "nothing was committed")

        _ = try fixture.binding.store.setState(writer: fixture.binding.writer, permission: .some("read"))
        _ = try fixture.binding.refreshMarks()
        XCTAssertThrowsError(try records.put("Memo", ["title": "x"])) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .accessDenied)
        }
        XCTAssertEqual(try pending(fixture).count, 0, "a read-only document sends nothing")
    }

    func testAWriteToADeclaredModelIsReadByItsQueriesAndNoOther() async throws {
        let fixture = try await makeFixture()
        try fixture.records.put("Note", ["id": "n1", "title": "x", "views": 3, "tags": ["a"]])
        XCTAssertEqual(try fixture.model.query(["views": ["$gt": 1]]).compactMap { $0["id"]?.stringValue }, ["n1"],
                       "Model.query sees a model-free write at once")
        XCTAssertEqual(fixture.model.find(id: "n1")?["tags"], .stringset(["a"]))
        let before = try fixture.model.count()
        try fixture.records.put("Memo", ["title": "other"])
        XCTAssertEqual(try fixture.model.count(), before, "another model's write leaves the class's rows alone")
        XCTAssertEqual(try fixture.records.count("Memo"), 1)
    }

    func testAModelFreeWriteDoesNotJoinATransaction() async throws {
        let fixture = try await makeFixture()
        try fixture.records.put("Memo", ["id": "m1", "n": 1])
        let before = try pending(fixture).count
        try fixture.model.transact {
            _ = try fixture.model.create(id: "t1", values: ["title": .string("staged")])
            try fixture.records.patch("Memo", id: "m1", ["n": 2])
            XCTAssertEqual(try pending(fixture).count, before + 1, "the patch committed on its own, inside the transaction")
            try fixture.records.delete("Memo", id: "m1")
            XCTAssertEqual(try pending(fixture).count, before + 2)
        }
        XCTAssertEqual(try pending(fixture).count, before + 3, "the transaction's one entry followed")
    }

    func testASubscriptionHearsItsModelsChanges() async throws {
        let fixture = try await makeFixture()
        let heard = LockedBox(0)
        let unsubscribe = try fixture.records.subscribe("Memo") { heard.withValue { $0 += 1 } }
        try fixture.records.put("Memo", ["id": "m1", "n": 1])
        XCTAssertEqual(heard.value, 1, "a write through the handle")
        try fixture.records.put("Note", ["id": "n1", "title": "x"])
        XCTAssertEqual(heard.value, 1, "another model's write is not heard")

        // The room's result for the entry, then a catch-up page: each announced as the session announces them.
        let binding = fixture.binding
        let seq = try XCTUnwrap(try pending(fixture).first?.seq)
        binding.notify(binding.acknowledged([seq]))
        XCTAssertEqual(heard.value, 2, "the room's result for the model")
        let page = try binding.store.applyCatchUpPage(writer: binding.writer, rows: [
            RecordLogCatchUpRow(model: "Memo", id: "m2", row: ["id": "m2", "n": 5]),
        ])
        binding.notify(page.changed.map { RecordLogRecordKey(model: $0.model, id: $0.id) })
        XCTAssertEqual(heard.value, 3, "a catch-up")
        XCTAssertEqual(try fixture.records.get("Memo", id: "m2")?["n"], 5)

        unsubscribe()
        unsubscribe()
        try fixture.records.put("Memo", ["id": "m3"])
        XCTAssertEqual(heard.value, 3, "an unsubscribed listener hears nothing, and unsubscribing twice is harmless")

        let late = LockedBox(0)
        _ = try fixture.records.subscribe("Memo") { late.withValue { $0 += 1 } }
        binding.close()
        binding.notify([RecordLogRecordKey(model: "Memo", id: "m3")])
        XCTAssertEqual(late.value, 0, "a listener registered before a close never fires after it")
    }

    /// Edge: `toString` and `valueOf` are ordinary field names on every
    /// path; `__proto__` is refused before anything is sent, with the room's
    /// sentence for a name starting with `_`.
    func testPrototypeNamesAreOrdinaryFieldsAndAnUnderscoreNameIsRefused() async throws {
        let fixture = try await makeFixture()
        let records = fixture.records
        let put = try records.put("Memo", ["id": "m1", "toString": ["a"], "valueOf": "x"])
        XCTAssertEqual(put.raw, ["id": "m1", "toString": ["a"], "valueOf": "x"])
        XCTAssertEqual(try records.patch("Memo", id: "m1", ["toString": DocumentRecordValue.setChange(add: ["b"])])?.raw["toString"], ["a", "b"])
        XCTAssertEqual(try records.query("Memo", ["toString": ["$contains": "b"], "valueOf": "x"]).data.map { $0.raw["id"] }, ["m1"])
        XCTAssertEqual(try records.count("Memo", ["valueOf": ["$exists": true]]), 1)
        XCTAssertEqual(try records.get("Memo", id: "m1")?.raw["valueOf"], "x")

        fixture.refused.value = []
        XCTAssertThrowsError(try records.patch("Memo", id: "m1", ["__proto__": "x"])) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .documentEntryInvalid)
            XCTAssertEqual(
                (error as? JsBaoError)?.message,
                "Cannot save Memo m1: Field '__proto__' is reserved (fields starting with '_' are internal). Rename the field."
            )
        }
        XCTAssertEqual(fixture.refused.value.count, 1)
        XCTAssertEqual(try pending(fixture).count, 2, "the refused patch was not committed")
    }
}

/// `Model.find` decodes a stored value that does not fit its declared type as
/// missing (#4624 behaviour 22); a fitting value is unchanged, and a scalar in
/// a declared set reads as an empty set. `Model.query` reads a db3 from its
/// view since #4700, so it answers each field as stored, the room's answer
/// (moved by the intent's "Whose semantics?" decision, with the query tables
/// that projected a misfit as NULL).
final class RecordLogProjectionMisfitHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let schema = PrimitiveSchema(
        name: "Item",
        fields: [
            "id": FieldDescriptor(type: .id),
            "n": FieldDescriptor(type: .number),
            "s": FieldDescriptor(type: .string),
            "ok": FieldDescriptor(type: .boolean),
            "flag": FieldDescriptor(type: .boolean),
            "x": FieldDescriptor(type: .string),
            "at": FieldDescriptor(type: .date),
            "tags": FieldDescriptor(type: .stringset),
        ]
    )

    func testAMisfitDecodesMissingOnFindAndAnswersAsStoredOnQuery() async throws {
        let directory = NSTemporaryDirectory() + "/record-log-misfit-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let binding = try RecordLogDocumentBinding(
            host: provider, documentId: "rl-misfit", clientId: "client-1", logger: Logger(level: .none)
        )
        let model = MultiDocModel(schema: Self.schema).connect(docId: "rl-misfit", doc: YDocument())
        try model.bindRecordLog(binding)
        // What the room holds: rows written before the declaration, by any writer.
        _ = try binding.store.applyCatchUpPage(writer: binding.writer, rows: [
            RecordLogCatchUpRow(model: "Item", id: "bad", row: [
                "id": "bad", "n": "5", "s": 3, "ok": "true", "flag": 1, "x": ["x"], "at": 7, "tags": "a",
            ]),
            RecordLogCatchUpRow(model: "Item", id: "good", row: [
                "id": "good", "n": 5, "s": "a", "ok": true, "flag": false, "x": "y", "at": "2026-01-02", "tags": ["a"],
            ]),
        ])

        let queried = try model.query([:])
        let bad = try XCTUnwrap(queried.first { $0["id"]?.stringValue == "bad" })
        let stored: [String: JSONValue] = ["n": "5", "s": 3, "ok": "true", "flag": 1, "x": ["x"], "at": 7]
        for (field, value) in stored {
            XCTAssertEqual(bad[field], value, "query: \(field) answers as stored")
        }
        let found = try XCTUnwrap(model.find(id: "bad"))
        for field in ["n", "s", "ok", "flag", "x", "at"] {
            XCTAssertNil(found[field], "find: \(field) is missing")
        }
        XCTAssertEqual(found["tags"] ?? .stringset([]), .stringset([]), "a scalar in a declared set reads as an empty set")
        XCTAssertEqual(try model.query(["n": 5]).compactMap { $0["id"]?.stringValue }, ["good"])
        XCTAssertEqual(try model.query(["s": "3"]).compactMap { $0["id"]?.stringValue }, [])

        let good = try XCTUnwrap(model.find(id: "good"))
        XCTAssertEqual(good["n"], .number(5))
        XCTAssertEqual(good["s"], .string("a"))
        XCTAssertEqual(good["ok"], .boolean(true))
        XCTAssertEqual(good["flag"], .boolean(false))
        XCTAssertEqual(good["tags"], .stringset(["a"]))
        let goodRow = try XCTUnwrap(try model.query([:]).first { $0["id"]?.stringValue == "good" })
        XCTAssertEqual(goodRow["n"], 5)
        XCTAssertEqual(goodRow["s"], "a")
        XCTAssertEqual(goodRow["x"], "y")
    }

    /// Edge: a declared `required` field whose stored value misfits does not
    /// decode, so the generated `query` facade skips the row with the
    /// decoder's report and `findAll`'s decode refuses it, as for any row
    /// that no longer decodes.
    func testARequiredFieldThatMisfitsIsSkippedByQueryAndRefusedByFindAll() async throws {
        typealias Txn = DroppedRowDiagnosticHermeticTests.Txn
        let directory = NSTemporaryDirectory() + "/record-log-required-misfit-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let binding = try RecordLogDocumentBinding(
            host: provider, documentId: "rl-required", clientId: "client-1", logger: Logger(level: .none)
        )
        let model = MultiDocModel(schema: Txn.primitiveSchema).connect(docId: "rl-required", doc: YDocument())
        try model.bindRecordLog(binding)
        _ = try binding.store.applyCatchUpPage(writer: binding.writer, rows: [
            RecordLogCatchUpRow(model: Txn.modelName, id: "bad", row: ["id": "bad", "amount": "5", "pending": false, "tags": ["a"]]),
            RecordLogCatchUpRow(model: Txn.modelName, id: "ok", row: ["id": "ok", "amount": 5, "pending": false, "tags": ["a"]]),
        ])

        let reported = LockedBox<[PrimitiveDecodeError]>([])
        PrimitiveRowDecoder.onDecodeFailure = { error in reported.withValue { $0.append(error) } }
        defer { PrimitiveRowDecoder.onDecodeFailure = nil }
        let rows: [[String: JSONValue]] = try model.query([:])
        XCTAssertEqual(PrimitiveRowDecoder.decodeAll(rows, as: Txn.self).map(\.id), ["ok"])
        XCTAssertEqual(reported.value.map(\.recordId), ["bad"])
        XCTAssertEqual(reported.value.first?.fields, ["amount"])
        let bad = try XCTUnwrap(rows.first { $0["id"]?.stringValue == "bad" })
        XCTAssertNil(Txn(row: bad), "findAll throws PrimitiveDecodeError for the row its decode refuses")
    }

}

/// A row that changes only in the spelling of a string (U+00E9 against
/// U+0065 U+0301) is a changed row: the view is rewritten and the record
/// reported changed, as the room and the JS client keep the two apart
/// (#4624 behaviour 16, D4624-002). `JSONValue`'s `==` calls them equal.
final class RecordLogSpellingHermeticTests: XCTestCase {

    func testACatchUpChangingOnlyASpellingRewritesTheViewRow() async throws {
        let directory = NSTemporaryDirectory() + "/record-log-spelling-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let store = RecordLogStore(host: provider, documentId: "doc-1", clientId: "client-a")
        try store.initialize()
        let writer = try store.mintWriter()
        let pre = "\u{E9}", decomposed = "e\u{301}"
        _ = try store.applyCatchUpPage(writer: writer, rows: [
            RecordLogCatchUpRow(model: "Memo", id: "m1", row: ["id": "m1", "title": .string(pre), "tags": [.string(pre)]]),
        ])
        let reply = try store.applyCatchUpPage(writer: writer, rows: [
            RecordLogCatchUpRow(model: "Memo", id: "m1", row: ["id": "m1", "title": .string(decomposed), "tags": [.string(decomposed)]]),
        ])
        XCTAssertEqual(reply.changed.map(\.id), ["m1"])
        let row = try XCTUnwrap(try store.read(model: "Memo", id: "m1"))
        XCTAssertEqual(row["title"]?.stringValue.map { Array($0.utf8) }, Array(decomposed.utf8))
        XCTAssertEqual(row["tags"]?.arrayValue?.compactMap(\.stringValue).map { Array($0.utf8) }, [Array(decomposed.utf8)])
    }
}
