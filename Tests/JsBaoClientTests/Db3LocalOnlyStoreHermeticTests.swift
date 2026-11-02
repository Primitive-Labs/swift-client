import XCTest
@testable import JsBaoClient

/// #5155 behaviour 34 and the store half of behaviours 22 to 24 — a db3 that
/// lives only on this device, in the record-log store itself.
///
/// A store from storage version 3 opens at version 4 with `local_only` (and
/// the registrations column beside it), and every db3 it held reads synced
/// with its rows, cursor and pending entries as they were. A store marked
/// local-only judges each commit as the room would — the upsert's holder,
/// the unique constraints, `ifNotExists`, a `condition`, an increment's
/// record — and confirms what it accepts in the same transaction: the cursor
/// moves one per entry, nothing stays pending, and the reply says what a
/// `receive` would have. A synced store's commit reply carries none of that.
final class Db3LocalOnlyStoreHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func provider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/db3-local-only-store-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func store(_ provider: SQLiteStorageProvider, _ documentId: String = "db3-local") throws -> (RecordLogStore, String) {
        let store = RecordLogStore(host: provider, documentId: documentId, clientId: "client-1")
        try store.initialize()
        return (store, try store.mintWriter())
    }

    private static let slug = RecordLogConstraint(model: "Note", name: "slug_unique", fields: ["slug"])
    private static let pair = RecordLogConstraint(model: "Note", name: "owner_day", fields: ["owner", "day"])

    /// A store for one db3 marked local-only, enforcing `slug` and `(owner, day)`.
    private func localStore() async throws -> (RecordLogStore, String) {
        let (store, writer) = try store(try await provider())
        try store.setState(writer: writer, constraints: [Self.slug, Self.pair], localOnly: true)
        return (store, writer)
    }

    private func create(_ id: String, _ fields: [String: JSONValue], ifNotExists: Bool = false) -> RecordLogMutation {
        RecordLogMutation(model: "Note", id: id, kind: .create, fields: fields, ifNotExists: ifNotExists)
    }

    @discardableResult
    private func commit(_ store: RecordLogStore, _ writer: String, _ mutations: [RecordLogMutation], upsertOn: String? = nil) throws -> RecordLogCommitReply {
        let reply = try store.commitEntries(writer: writer, writes: [RecordLogWrite(mutations: mutations, upsertOn: upsertOn)])
        try store.flush()
        return reply
    }

    private func refusal(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) -> JsBaoError? {
        do {
            try body()
            XCTFail("the write was not refused", file: file, line: line)
            return nil
        } catch let error as JsBaoError {
            return error
        } catch {
            XCTFail("refused with \(error), not a JsBaoError", file: file, line: line)
            return nil
        }
    }

    // MARK: - Behaviour 34: storage version 4

    func testAVersion3StoreOpensAtVersion4WithTheLocalOnlyColumnAndItsSyncedDb3Unchanged() async throws {
        let provider = try await provider()
        let (synced, writer) = try store(provider, "db3-synced")
        // One confirmed row, one pending entry.
        try commit(synced, writer, [create("r1", ["title": "confirmed"])])
        _ = try synced.receive(writer: writer, items: [.result(RecordLogResult(l: 1, e: 1, changes: nil, w: writer, seq: 1))])
        try commit(synced, writer, [create("r2", ["title": "pending"])])
        let before = try synced.storedState()
        XCTAssertEqual(before.cursor, 1)
        XCTAssertEqual(before.rows, 2)
        XCTAssertEqual(before.writers.map(\.pending), [1])
        // The store as storage version 3 left it: no local-only columns.
        try provider.withConnection { connection in
            try connection.executeScript("ALTER TABLE record_log_state DROP COLUMN local_only")
            try connection.executeScript("ALTER TABLE record_log_state DROP COLUMN local_indexes")
            try connection.execute("UPDATE record_log_meta SET value = '3' WHERE key = 'storage_version'", [])
        }

        let reopened = RecordLogStore(host: provider, documentId: "db3-synced", clientId: "client-1")
        try reopened.initialize()
        let version = try provider.withConnection {
            try $0.query("SELECT value FROM record_log_meta WHERE key = 'storage_version'", []).first?["value"].stringValue
        }
        XCTAssertEqual(version, "4")
        let columns = try provider.withConnection {
            try $0.query("SELECT name FROM pragma_table_info('record_log_state')", []).compactMap { $0["name"].stringValue }
        }
        XCTAssertTrue(columns.contains("local_only"), "\(columns)")
        XCTAssertTrue(columns.contains("local_indexes"), "\(columns)")
        let after = try reopened.storedState()
        XCTAssertFalse(after.localOnly)
        XCTAssertFalse(try reopened.marks().localOnly)
        XCTAssertEqual(after.cursor, before.cursor)
        XCTAssertEqual(after.rows, before.rows)
        XCTAssertEqual(after.writers, before.writers)
        XCTAssertEqual(try reopened.read(model: "Note", id: "r2")?["title"], "pending")
    }

    // MARK: - Writes confirmed in the commit

    func testALocalOnlyStoreConfirmsEachEntryInItsCommitAndSaysSoInTheReply() async throws {
        let (store, writer) = try await localStore()
        XCTAssertTrue(try store.marks().localOnly)
        XCTAssertTrue(try store.storedState().localOnly)

        let first = try commit(store, writer, [create("n1", ["slug": "a", "views": 1])])
        XCTAssertEqual(first.cursor, 1)
        XCTAssertEqual(first.acknowledged, [RecordLogEntryRef(writer: writer, seq: 1)])
        XCTAssertEqual(first.settled, [RecordLogEntryRef(writer: writer, seq: 1)])
        XCTAssertEqual(
            first.settlements?[RecordLogEntryRef(writer: writer, seq: 1)]?.rows.first?.row?["slug"], "a",
            "the settlement carries the confirmed row"
        )
        XCTAssertEqual(first.changed.map(\.id), ["n1"])

        // A patch, an increment, a two-record entry and a delete: one log number each.
        try commit(store, writer, [RecordLogMutation(model: "Note", id: "n1", kind: .patch, fields: ["title": "t"])])
        try commit(store, writer, [RecordLogMutation(model: "Note", id: "n1", kind: .increment, fields: ["views": 2])])
        try commit(store, writer, [create("n2", ["slug": "b"]), create("n3", ["slug": "c"])])
        try commit(store, writer, [RecordLogMutation(model: "Note", id: "n3", kind: .delete)])
        let marks = try store.marks()
        XCTAssertEqual(marks.cursor, 5)
        XCTAssertEqual(marks.pending, 0)
        XCTAssertNil(marks.lowestPending)
        XCTAssertTrue(marks.unacked.isEmpty)
        XCTAssertEqual(try store.storedState().writers, [], "no writer holds an unjudged entry")
        XCTAssertEqual(try store.pendingOf(writer), [])
        XCTAssertEqual(try store.read(model: "Note", id: "n1")?["views"], 3)
        XCTAssertEqual(try store.read(model: "Note", id: "n1")?["title"], "t")
        XCTAssertNil(try store.read(model: "Note", id: "n3"))
        XCTAssertEqual(
            Set(try store.confirmedRows().compactMap { $0["id"]?.stringValue }), ["n1", "n2"],
            "the confirmed rows hold what the view shows"
        )
    }

    // MARK: - Judged as the room judges

    func testAWriteSharingAUniqueKeyIsRefusedWithTheHolderAndLandsNothing() async throws {
        let (store, writer) = try await localStore()
        try commit(store, writer, [create("n1", ["slug": "a"])])
        let error = refusal { try commit(store, writer, [create("n2", ["slug": "a"])]) }
        XCTAssertEqual(error?.code, .documentConstraintViolated)
        XCTAssertEqual(error?.details?["scope"], "local")
        XCTAssertEqual(error?.details?["constraint"], "slug_unique")
        XCTAssertEqual(error?.details?["conflicting"], .object(["model": "Note", "id": "n1"]))
        XCTAssertNil(try store.read(model: "Note", id: "n2"))
        XCTAssertEqual(try store.marks().cursor, 1, "nothing landed")
        XCTAssertEqual(try store.marks().nextSeq, 2, "its number was rolled back with it")

        // Two records of one entry taking one compound key: refused as a whole.
        let both = refusal {
            try commit(store, writer, [create("n3", ["owner": "u", "day": 1]), create("n4", ["owner": "u", "day": 1])])
        }
        XCTAssertEqual(both?.code, .documentConstraintViolated)
        XCTAssertEqual(both?.details?["constraint"], "owner_day")
        XCTAssertNil(try store.read(model: "Note", id: "n3"))
        // A key the entry frees and takes in one go stands.
        try commit(store, writer, [
            RecordLogMutation(model: "Note", id: "n1", kind: .patch, fields: ["slug": "z"]), create("n5", ["slug": "a"]),
        ])
        XCTAssertEqual(try store.read(model: "Note", id: "n5")?["slug"], "a")
    }

    func testAnUpsertLandsOnTheRecordHoldingItsValue() async throws {
        let (store, writer) = try await localStore()
        try commit(store, writer, [create("n1", ["slug": "a", "title": "first"])])
        let reply = try commit(store, writer, [create("n2", ["slug": "a", "title": "second"])], upsertOn: "slug")
        XCTAssertEqual(reply.aliases, [RecordLogAlias(model: "Note", from: "n2", to: "n1")])
        XCTAssertEqual(try store.read(model: "Note", id: "n1")?["title"], "second")
        XCTAssertNil(try store.read(model: "Note", id: "n2"))
        XCTAssertEqual(try store.marks().cursor, 2)
        // No holder: the create stands.
        try commit(store, writer, [create("n3", ["slug": "b"])], upsertOn: "slug")
        XCTAssertEqual(try store.read(model: "Note", id: "n3")?["slug"], "b")
        // An upsert on a field no single-field constraint covers is invalid, as the room says.
        let error = refusal { try commit(store, writer, [create("n4", ["title": "x"])], upsertOn: "title") }
        XCTAssertEqual(error?.code, .documentEntryInvalid)
    }

    func testGuardsAndIncrementsAreJudgedOnTheStoredRow() async throws {
        let (store, writer) = try await localStore()
        try commit(store, writer, [create("n1", ["slug": "a", "status": "open", "views": 1])])

        let exists = refusal { try commit(store, writer, [create("n1", ["slug": "a"], ifNotExists: true)]) }
        XCTAssertEqual(exists?.code, .db3ConditionNotMet)
        XCTAssertEqual(exists?.details?["current"]?["id"], "n1")
        XCTAssertEqual(exists?.details?["current"]?["row"]?["status"], "open")

        let unmet = refusal {
            try commit(store, writer, [RecordLogMutation(
                model: "Note", id: "n1", kind: .patch, fields: ["status": "closed"], condition: ["status": "draft"]
            )])
        }
        XCTAssertEqual(unmet?.code, .db3ConditionNotMet)
        XCTAssertEqual(unmet?.details?["current"]?["model"], "Note")
        XCTAssertEqual(try store.read(model: "Note", id: "n1")?["status"], "open")

        // A condition that holds applies at once: the view shows it, no guess held back.
        try commit(store, writer, [RecordLogMutation(
            model: "Note", id: "n1", kind: .patch, fields: ["status": "closed"], condition: ["status": "open", "views": ["$gte": 1]]
        )])
        XCTAssertEqual(try store.read(model: "Note", id: "n1")?["status"], "closed")

        let missing = refusal {
            try commit(store, writer, [RecordLogMutation(model: "Note", id: "ghost", kind: .increment, fields: ["views": 1])])
        }
        XCTAssertEqual(missing?.code, .db3RecordNotFound)
        // An increment of a record the same entry creates stands.
        try commit(store, writer, [
            create("n2", ["slug": "b", "views": 1]), RecordLogMutation(model: "Note", id: "n2", kind: .increment, fields: ["views": 4]),
        ])
        XCTAssertEqual(try store.read(model: "Note", id: "n2")?["views"], 5)
        XCTAssertEqual(try store.marks().cursor, 3)
    }

    func testNoWriteBudgetApplies() async throws {
        let (store, writer) = try await localStore()
        try store.setState(writer: writer, notice: (current: 1, next: 2, entries: 5))
        for index in 0..<12 { try commit(store, writer, [create("n\(index)", ["slug": .string("s\(index)")])]) }
        XCTAssertEqual(try store.marks().cursor, 12)
        XCTAssertEqual(try store.marks().pending, 0)
    }

    // MARK: - E11's Swift half: a synced store's reply is unchanged

    func testASyncedStoresCommitReplyCarriesNoConfirmation() async throws {
        let (store, writer) = try store(try await provider(), "db3-synced")
        let reply = try commit(store, writer, [create("n1", ["slug": "a"])])
        XCTAssertNil(reply.acknowledged)
        XCTAssertNil(reply.settled)
        XCTAssertNil(reply.settlements)
        XCTAssertEqual(try store.marks().pending, 1)
        XCTAssertEqual(try store.marks().cursor, 0)
        XCTAssertFalse(try store.storedState().localOnly)
    }
}
