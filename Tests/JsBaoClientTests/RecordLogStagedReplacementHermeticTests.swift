import XCTest
@testable import JsBaoClient

/// #4701 behaviours 1–4: a full replacement of a db3 whose view holds a
/// completed generation is staged. The view keeps the previous generation
/// (and this client's guesses over it) while the replacement's pages land,
/// and becomes the completed generation, with the guesses applied again, when
/// the replacement commits. The residency predicate reads the marks this
/// leaves. A port of js-bao's staged replacement (`store.ts`, #4698) onto the
/// Swift store, over a real `SQLiteStorageProvider` on a temp file.
final class RecordLogStagedReplacementHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-staged-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func makeStore(_ provider: SQLiteStorageProvider) throws -> (RecordLogStore, String) {
        let store = RecordLogStore(host: provider, documentId: "doc-1", clientId: "client-1")
        try store.initialize()
        return (store, try store.mintWriter())
    }

    private func row(_ id: String, _ title: String) -> RecordLogCatchUpRow {
        RecordLogCatchUpRow(model: "Note", id: id, row: ["id": .string(id), "title": .string(title)])
    }

    private func key(_ id: String) -> RecordLogRecordKey { RecordLogRecordKey(model: "Note", id: id) }

    private func patch(_ store: RecordLogStore, _ writer: String, _ id: String, _ fields: [String: JSONValue]) throws {
        _ = try store.commitEntries(writer: writer, writes: [RecordLogWrite(mutations: [
            RecordLogMutation(model: "Note", id: id, kind: .patch, fields: fields),
        ])])
        try store.flush()
    }

    /// The document's view rows, by id, as stored.
    private func view(_ provider: SQLiteStorageProvider) throws -> [String: RecordLogRow] {
        var out: [String: RecordLogRow] = [:]
        for found in try provider.withConnection({
            try $0.query("SELECT _id, _data FROM record_log_view WHERE doc_id = 'doc-1'")
        }) {
            if let id = found["_id"].stringValue { out[id] = RecordLogJSON.row(found["_data"].stringValue) }
        }
        return out
    }

    private func titles(_ provider: SQLiteStorageProvider) throws -> [String: String] {
        try view(provider).compactMapValues { $0["title"]?.stringValue }
    }

    private func stateColumn(_ provider: SQLiteStorageProvider, _ column: String) throws -> Format2SqlValue {
        try provider.withConnection {
            try $0.query("SELECT \(column) AS v FROM record_log_state WHERE doc_id = 'doc-1'")
        }.first?["v"] ?? .null
    }

    private func baseIds(_ provider: SQLiteStorageProvider) throws -> [String] {
        try provider.withConnection {
            try $0.query("SELECT _id FROM record_log_staged_base WHERE doc_id = 'doc-1' ORDER BY _id")
        }.compactMap { $0["_id"].stringValue }
    }

    /// A store caught up once through a cold full load of `rows`, at log number 5.
    private func caughtUp(_ provider: SQLiteStorageProvider, _ rows: [RecordLogCatchUpRow]) throws -> (RecordLogStore, String) {
        let (store, writer) = try makeStore(provider)
        let generation = try store.beginFencedCatchUp(writer: writer, full: true)
        _ = try store.applyCatchUpPage(writer: writer, rows: rows, lsn: 5, generation: generation)
        _ = try store.completeCatchUp(writer: writer, lsn: 5, full: true, generation: generation, at: 1_000)
        return (store, writer)
    }

    // MARK: - Behaviour 1

    func testAReplacementOverACaughtUpViewIsStagedAndTheViewKeepsThePreviousGeneration() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try caughtUp(provider, [row("a", "a1"), row("b", "b1"), row("c", "c1")])
        try patch(store, writer, "b", ["title": "mine"])
        let before = try view(provider)
        XCTAssertEqual(before["b"]?["title"], "mine", "a guess over b")

        let generation = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        XCTAssertEqual(try stateColumn(provider, "staged"), try stateColumn(provider, "replacing"), "staged equals replacing")
        XCTAssertEqual(try stateColumn(provider, "staged").intValue, generation)
        XCTAssertTrue(try store.storedState().staged)
        XCTAssertTrue(try store.marks().staged)

        let page = try store.applyCatchUpPage(
            writer: writer, rows: [row("a", "a2"), row("b", "b2")], lsn: 9, generation: generation
        )
        XCTAssertFalse(page.stale)
        XCTAssertEqual(page.changed, [], "a staged replacement's page reaches the view at its completion")
        XCTAssertEqual(try view(provider), before, "mid-replacement the view is the pre-replacement rows, a and b included")
        XCTAssertEqual(try baseIds(provider), ["a", "b"], "the previous row of each rewritten record is staged once")

        // A guess over a record the replacement rewrote reads the staged base.
        try patch(store, writer, "a", ["n": 1])
        let guessed = try view(provider)["a"]
        XCTAssertEqual(guessed?["title"], "a1", "the guess applies over the previous generation's row, not the replacement's")
        XCTAssertEqual(guessed?["n"], 1)
        XCTAssertEqual(try titles(provider)["c"], "c1")
    }

    // MARK: - Behaviour 2

    func testCompletingAStagedReplacementRebuildsTheViewAndNamesExactlyTheRecordsThatChanged() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try caughtUp(provider, [row("a", "a1"), row("b", "b1"), row("c", "c1"), row("e", "e1")])
        try patch(store, writer, "b", ["title": "mine"])
        let generation = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        _ = try store.applyCatchUpPage(writer: writer, rows: [row("a", "a2"), row("b", "b2")], lsn: 9, generation: generation)
        try patch(store, writer, "a", ["n": 1])
        _ = try store.applyCatchUpPage(writer: writer, rows: [row("d", "d1"), row("e", "e1")], lsn: 9, generation: generation)
        XCTAssertNil(try store.read(model: "Note", id: "d"), "d appears only at the completion")

        let done = try store.completeCatchUp(writer: writer, lsn: 9, full: true, generation: generation, at: 2_000)
        XCTAssertFalse(done.stale)
        let after = try view(provider)
        XCTAssertEqual(after["a"]?["title"], "a2", "the completed generation's row")
        XCTAssertEqual(after["a"]?["n"], 1, "with this client's guess applied again")
        XCTAssertEqual(after["b"]?["title"], "mine", "the guess over b still wins")
        XCTAssertNil(after["c"], "c left with the replacement")
        XCTAssertEqual(after["d"]?["title"], "d1")
        XCTAssertEqual(after["e"]?["title"], "e1")
        XCTAssertTrue(try stateColumn(provider, "staged").isNull)
        XCTAssertTrue(try stateColumn(provider, "replacing").isNull)
        XCTAssertEqual(try baseIds(provider), [], "the staged base is cleared")
        XCTAssertFalse(try store.storedState().staged)

        // Exactly the records whose view row changed, appeared or left, each once.
        XCTAssertEqual(done.changed.map(\.id).sorted(), ["a", "c", "d"], "b's view row and e's did not change")
        XCTAssertEqual(done.changed.first { $0.id == "c" }?.row, nil)
        XCTAssertEqual(done.changed.first { $0.id == "d" }?.row?["title"], "d1")
        XCTAssertEqual(done.changed.first { $0.id == "a" }?.row?["title"], "a2")
    }

    // MARK: - Behaviour 3

    func testAFirstLoadAndAReplacementOverAnInterruptedUnstagedOneAreUnstaged() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)
        let first = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        XCTAssertTrue(try stateColumn(provider, "staged").isNull, "a first load is unstaged")
        XCTAssertFalse(try store.storedState().staged)
        _ = try store.applyCatchUpPage(writer: writer, rows: [row("a", "a1")], lsn: 5, generation: first)
        XCTAssertEqual(try titles(provider), ["a": "a1"], "its rows reach the view as they arrive")

        // Interrupted; another client of the store completed a catch-up of its own since.
        try provider.withConnection {
            try $0.execute("UPDATE record_log_state SET last_catch_up_at = 1 WHERE doc_id = 'doc-1'", [])
        }
        let second = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(try stateColumn(provider, "staged").isNull, "over an interrupted unstaged replacement: unstaged")
        _ = try store.applyCatchUpPage(writer: writer, rows: [row("b", "b1")], lsn: 6, generation: second)
        XCTAssertEqual(try titles(provider)["b"], "b1")
        XCTAssertEqual(try baseIds(provider), [])
    }

    func testASecondStagedAttemptAfterAnInterruptedStagedOneKeepsTheFirstAttemptsBase() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try caughtUp(provider, [row("a", "a1")])
        let first = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true))
        _ = try store.applyCatchUpPage(writer: writer, rows: [row("a", "a2")], lsn: 9, generation: first)
        // Interrupted, then a new attempt.
        let reopened = RecordLogStore(host: provider, documentId: "doc-1", clientId: "client-1")
        let second = try XCTUnwrap(try reopened.beginFencedCatchUp(writer: writer, full: true))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try stateColumn(provider, "staged").intValue, second, "staged again")
        XCTAssertEqual(try baseIds(provider), ["a"], "the first attempt's base is kept")
        _ = try reopened.applyCatchUpPage(writer: writer, rows: [row("a", "a3")], lsn: 10, generation: second)
        XCTAssertEqual(try titles(provider)["a"], "a1", "the view still shows the completed generation")
        let staged = try provider.withConnection {
            try $0.query("SELECT _data FROM record_log_staged_base WHERE doc_id = 'doc-1' AND _id = 'a'")
        }.first.map { RecordLogJSON.row($0["_data"].stringValue) }
        XCTAssertEqual(staged?["title"], "a1", "the base holds the completed generation's row, not the interrupted attempt's")
        _ = try reopened.completeCatchUp(writer: writer, lsn: 10, full: true, generation: second)
        XCTAssertEqual(try titles(provider), ["a": "a3"])
    }

    // MARK: - Behaviour 4

    func testStoredStateAndMarksAnswerTheResidencyMarksAndThePredicateReadsThem() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider)
        var state = try store.storedState()
        XCTAssertNil(state.lastCatchUpAt)
        XCTAssertFalse(state.staged)
        XCTAssertFalse(RecordLogStore.isResident(state), "before any catch-up")
        XCTAssertFalse(RecordLogStore.isResident(try store.marks()))
        XCTAssertTrue(RecordLogStore.isResident(state, createdLocally: true), "a db3 created here")
        XCTAssertTrue(RecordLogStore.isResident(try store.marks(), createdLocally: true))

        // During a cold load (an unstaged replacement): not resident.
        let cold = try store.beginFencedCatchUp(writer: writer, full: true)
        _ = try store.applyCatchUpPage(writer: writer, rows: [row("a", "a1")], lsn: 5, generation: cold)
        XCTAssertFalse(RecordLogStore.isResident(try store.storedState()))
        _ = try store.completeCatchUp(writer: writer, lsn: 5, full: true, generation: cold, at: 1_234)
        state = try store.storedState()
        XCTAssertEqual(state.lastCatchUpAt, 1_234)
        XCTAssertEqual(try store.marks().lastCatchUpAt, 1_234)
        XCTAssertTrue(RecordLogStore.isResident(state), "after a catch-up")

        // During a staged replacement, and after it was interrupted (a store opened again).
        let staged = try store.beginFencedCatchUp(writer: writer, full: true)
        _ = try store.applyCatchUpPage(writer: writer, rows: [row("a", "a2")], lsn: 9, generation: staged)
        XCTAssertTrue(RecordLogStore.isResident(try store.storedState()))
        let reopened = RecordLogStore(host: provider, documentId: "doc-1", clientId: "client-1")
        state = try reopened.storedState()
        XCTAssertTrue(state.replacing)
        XCTAssertTrue(state.staged)
        XCTAssertTrue(RecordLogStore.isResident(state), "an interrupted staged replacement keeps the view readable")
        XCTAssertTrue(RecordLogStore.isResident(try reopened.marks()))

        // An interrupted unstaged replacement (over an interrupted cold load) is not.
        let other = try await makeProvider()
        let (fresh, freshWriter) = try makeStore(other)
        _ = try fresh.beginFencedCatchUp(writer: freshWriter, full: true)
        try other.withConnection {
            try $0.execute("UPDATE record_log_state SET last_catch_up_at = 1 WHERE doc_id = 'doc-1'", [])
        }
        state = try fresh.storedState()
        XCTAssertEqual(state.lastCatchUpAt, 1)
        XCTAssertTrue(state.replacing)
        XCTAssertFalse(state.staged)
        XCTAssertFalse(RecordLogStore.isResident(state), "an interrupted unstaged replacement is not resident")
        XCTAssertTrue(RecordLogStore.isResident(state, createdLocally: true))
    }
}
