import XCTest
import SQLite3
@testable import JsBaoClient

/// The record-log store's durability and its group commit, on a real
/// `SQLiteStorageProvider`: saves issued together share one `COMMIT` at
/// `synchronous=NORMAL`, the connection's own setting is put back after it,
/// and work that is not the store's never lands inside a group.
///
/// Commits are counted by a real `sqlite3_commit_hook` on the provider's
/// handle, and the statements the connection ran are read back through
/// `sqlite3_trace_v2` — no double stands in for SQLite.
final class RecordLogGroupCommitHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-group-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func makeStore(_ host: any Format2SqlHost, provider: SQLiteStorageProvider) throws -> (RecordLogStore, String) {
        let store = RecordLogStore(host: host, documentId: "doc-1", clientId: "client-1")
        try store.initialize()
        try RecordLogQueryProjection.prepare(schema: Self.schema, engine: BaoModelQueryEngine(host: provider), host: provider)
        return (store, try store.mintWriter())
    }

    private var spec: RecordLogProjectionSpec { RecordLogProjectionSpec(schema: Self.schema) }

    @discardableResult
    private func save(_ store: RecordLogStore, _ writer: String, _ id: String,
                      listener: RecordLogGroupCommit.Listener? = nil) throws -> RecordLogPendingEntry {
        try store.commitEntries(
            writer: writer,
            writes: [RecordLogWrite(mutations: [RecordLogMutation(model: "Note", id: id, kind: .create, fields: ["title": .string(id)])])],
            project: [spec], listener: listener
        ).entries[0]
    }

    // MARK: - SQLite's own counters

    /// Counts the connection's commits, and keeps the text of every statement it ran.
    private final class Hooks: @unchecked Sendable {
        private let lock = NSLock()
        private var _commits = 0
        private var _statements: [String] = []
        var commits: Int { lock.withLock { _commits } }
        var statements: [String] { lock.withLock { _statements } }
        func committed() { lock.withLock { _commits += 1 } }
        func ran(_ text: String) { lock.withLock { _statements.append(text) } }
        func clearStatements() { lock.withLock { _statements = [] } }
    }

    private func install(_ hooks: Hooks, on provider: SQLiteStorageProvider) throws {
        let context = Unmanaged.passUnretained(hooks).toOpaque()
        try provider.withRecordLogConnection { connection in
            let db = connection.rawHandle
            sqlite3_commit_hook(db, { context in
                Unmanaged<Hooks>.fromOpaque(context!).takeUnretainedValue().committed()
                return 0
            }, context)
            sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_STMT), { _, context, _, text in
                guard let context, let text else { return 0 }
                Unmanaged<Hooks>.fromOpaque(context).takeUnretainedValue()
                    .ran(String(cString: text.assumingMemoryBound(to: CChar.self)))
                return 0
            }, context)
        }
        addTeardownBlock {
            try? provider.withRecordLogConnection { connection in
                sqlite3_commit_hook(connection.rawHandle, nil, nil)
                sqlite3_trace_v2(connection.rawHandle, 0, nil, nil)
            }
        }
    }

    /// `PRAGMA synchronous` as the connection answers it now, without closing an open group.
    private func synchronous(_ provider: SQLiteStorageProvider) throws -> Int? {
        try provider.withRecordLogConnection { try $0.query("PRAGMA synchronous").first?["synchronous"].intValue }
    }

    private func groupOpen(_ provider: SQLiteStorageProvider) throws -> Bool {
        try provider.withRecordLogConnection { _ in provider.recordLogGroupCommit.isGroupOpen }
    }

    // MARK: - Behavior 11: synchronous=NORMAL, and the connection's own setting put back

    func testAGroupRunsAtNormalAndPutsTheConnectionsOwnSettingBack() async throws {
        let provider = try await makeProvider()
        // What this platform's SQLite gives a WAL connection, recorded rather
        // than assumed: Apple's builds already answer NORMAL (1).
        let platformDefault = try synchronous(provider)
        print("[#4309] the provider's own synchronous on this platform: \(platformDefault.map(String.init) ?? "?")")
        // A connection at FULL, as SQLite's own default would leave it, so the
        // restore is observable.
        try provider.withConnection { try $0.executeScript("PRAGMA synchronous=FULL") }
        XCTAssertEqual(try synchronous(provider), 2)

        let (store, writer) = try makeStore(provider, provider: provider)
        provider.recordLogGroupCommit.commitAfterMs = 60_000
        let hooks = Hooks()
        try install(hooks, on: provider)

        try save(store, writer, "a")
        XCTAssertTrue(try groupOpen(provider))
        XCTAssertEqual(try synchronous(provider), 1, "inside an open group the connection is at NORMAL")

        // Work that is not the store's closes the group before it runs, and runs at the default.
        hooks.clearStatements()
        try await provider.put(store: "kv", key: "k", value: "v", metadata: nil)
        XCTAssertFalse(try groupOpen(provider))
        let statements = hooks.statements
        let commit = try XCTUnwrap(statements.firstIndex(of: "COMMIT"), "\(statements)")
        let restore = try XCTUnwrap(statements.firstIndex(of: "PRAGMA synchronous=2"), "\(statements)")
        let put = try XCTUnwrap(statements.firstIndex { $0.contains("INSERT INTO kv_store") }, "\(statements)")
        XCTAssertLessThan(commit, restore)
        XCTAssertLessThan(restore, put, "the key-value write runs after the group committed and its setting was put back")
        XCTAssertFalse(statements[restore...].contains { $0.contains("synchronous=NORMAL") }, "\(statements)")
        XCTAssertEqual(try synchronous(provider), 2, "after the group, the connection's own setting")

        // The next save opens a new group the same way.
        hooks.clearStatements()
        try save(store, writer, "b")
        XCTAssertEqual(Array(hooks.statements.prefix(4)), [
            "PRAGMA synchronous", "PRAGMA synchronous=NORMAL", "BEGIN IMMEDIATE", "SAVEPOINT record_log_save_2",
        ])

        // A store call nested inside a save issues no pragma and opens no second group.
        hooks.clearStatements()
        try store.save { _ in
            try store.setState(writer: writer, notice: (current: 1, next: 2, entries: nil))
            try self.save(store, writer, "c")
            _ = try store.marks()
        }
        XCTAssertFalse(hooks.statements.contains { $0.hasPrefix("PRAGMA synchronous") }, "\(hooks.statements)")
        XCTAssertEqual(hooks.statements.filter { $0.hasPrefix("BEGIN") }, [])
        XCTAssertEqual(hooks.statements.filter { $0.hasPrefix("SAVEPOINT") }.count, 1)

        try store.flush()
        XCTAssertEqual(try synchronous(provider), 2)
        XCTAssertEqual(try store.readRowsAfter(model: "Note", after: nil, limit: 10).count, 3)
    }

    func testAProviderAlreadyAtNormalIsLeftAsItIs() async throws {
        let provider = try await makeProvider()
        try provider.withConnection { try $0.executeScript("PRAGMA synchronous=NORMAL") }
        let (store, writer) = try makeStore(provider, provider: provider)
        let hooks = Hooks()
        try install(hooks, on: provider)
        try save(store, writer, "a")
        try store.flush()
        XCTAssertFalse(hooks.statements.contains { $0.hasPrefix("PRAGMA synchronous=") }, "\(hooks.statements)")
        XCTAssertEqual(try synchronous(provider), 1)
        let fullfsync = try provider.withConnection { try $0.query("PRAGMA fullfsync").first?["fullfsync"].intValue }
        XCTAssertEqual(fullfsync, 0, "fullfsync is never set")
    }

    // MARK: - Behavior 50: saves issued together share a commit

    func testFiftySavesInALoopLandInOneCommitEachReadableAtOnce() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider, provider: provider)
        provider.recordLogGroupCommit.commitAfterMs = 60_000
        let hooks = Hooks()
        try install(hooks, on: provider)

        for index in 0..<50 {
            try save(store, writer, "n\(index)")
            XCTAssertEqual(try store.read(model: "Note", id: "n\(index)")?["title"], .string("n\(index)"),
                           "a save is readable the moment it returns")
        }
        XCTAssertEqual(hooks.commits, 0, "nothing has committed while the group is open")
        try store.flush()
        XCTAssertEqual(hooks.commits, 1, "fifty saves, one COMMIT")
        XCTAssertEqual(try store.pendingOf(writer).map(\.seq), Array(1...50))
    }

    func testFiftySavesFromTwoThreadsLandInOneCommit() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider, provider: provider)
        provider.recordLogGroupCommit.commitAfterMs = 60_000
        let hooks = Hooks()
        try install(hooks, on: provider)
        let failures = LockedBox<[String]>([])
        let spec = spec
        DispatchQueue.concurrentPerform(iterations: 2) { thread in
            for index in 0..<25 {
                let id = "t\(thread)-\(index)"
                let write = RecordLogWrite(mutations: [
                    RecordLogMutation(model: "Note", id: id, kind: .create, fields: ["title": .string(id)]),
                ])
                do { _ = try store.commitEntries(writer: writer, writes: [write], project: [spec]) } catch {
                    failures.withValue { $0.append("\(error)") }
                }
            }
        }
        XCTAssertEqual(failures.value, [])
        try store.flush()
        XCTAssertEqual(hooks.commits, 1)
        XCTAssertEqual(try store.pendingOf(writer).map(\.seq), Array(1...50))
        XCTAssertEqual(try store.readRowsAfter(model: "Note", after: nil, limit: 100).count, 50)
    }

    func testTheCommitTimerClosesAGroupAndALoopCommitsFarFewerTimesThanItSaves() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider, provider: provider)
        let hooks = Hooks()
        try install(hooks, on: provider)
        for index in 0..<50 { try save(store, writer, "n\(index)") }
        // Nothing else runs on the queue: only the 5 ms timer can close the last group.
        let deadline = Date().addingTimeInterval(5)
        while try groupOpen(provider), Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertFalse(try groupOpen(provider), "the timer committed the group")
        XCTAssertGreaterThanOrEqual(hooks.commits, 1)
        XCTAssertLessThan(hooks.commits, 50, "saves issued together share commits: \(hooks.commits) for 50 saves")
        print("[#4309] 50 saves in a loop with the 5 ms group timer: \(hooks.commits) commits")
    }

    func testAKeyValueWriteOrASessionCommandBetweenSavesClosesTheGroupFirst() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider, provider: provider)
        provider.recordLogGroupCommit.commitAfterMs = 60_000
        let hooks = Hooks()
        try install(hooks, on: provider)
        let groups = provider.recordLogGroupCommit.groupsCommitted

        try save(store, writer, "a")
        try await provider.put(store: "kv", key: "k", value: "v", metadata: nil)
        XCTAssertEqual(hooks.commits, 2, "the group's commit, then the key-value write's own")
        XCTAssertEqual(provider.recordLogGroupCommit.groupsCommitted, groups + 1)

        try save(store, writer, "b")
        _ = try store.receive(writer: writer, items: [.void(seq: 99)], project: [spec])
        XCTAssertEqual(provider.recordLogGroupCommit.groupsCommitted, groups + 2, "a session command closed the group before it ran")
        XCTAssertEqual(hooks.commits, 4, "the group, then the command's own transaction")
        XCTAssertFalse(try groupOpen(provider))
    }

    func testAListenerHearsItsSaveOnlyAfterTheCommit() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider, provider: provider)
        provider.recordLogGroupCommit.commitAfterMs = 60_000
        let hooks = Hooks()
        try install(hooks, on: provider)
        let heard = LockedBox<[(seq: Int, commitsSeen: Int, error: String?)]>([])
        for id in ["a", "b"] {
            let seq = try store.pendingOf(writer).count + 1
            try save(store, writer, id) { error in
                heard.withValue { $0.append((seq, hooks.commits, error.map { "\($0)" })) }
            }
        }
        XCTAssertTrue(heard.value.isEmpty, "nothing is heard while the group is open")
        try store.flush()
        XCTAssertEqual(heard.value.map(\.seq), [1, 2])
        XCTAssertEqual(heard.value.map(\.commitsSeen), [1, 1], "each listener ran after the COMMIT")
        XCTAssertEqual(heard.value.compactMap(\.error), [])
    }

    func testAHostThatCannotDeferCommitsEverySaveOnItsOwn() async throws {
        let provider = try await makeProvider()
        let plain = PlainHost(provider)
        let (store, writer) = try makeStore(plain, provider: provider)
        let hooks = Hooks()
        try install(hooks, on: provider)
        for index in 0..<5 { try save(store, writer, "n\(index)") }
        XCTAssertEqual(hooks.commits, 5)
        XCTAssertFalse(try groupOpen(provider))
    }

    /// A host that adopts only the public protocol.
    private final class PlainHost: Format2SqlHost, @unchecked Sendable {
        let inner: SQLiteStorageProvider
        init(_ inner: SQLiteStorageProvider) { self.inner = inner }
        func withConnection<T>(_ body: (any Format2SqlConnection) throws -> T) throws -> T {
            try inner.withConnection(body)
        }
    }

    // MARK: - Edge 42: a failed save, and a failed COMMIT

    func testASaveThatThrowsRollsBackOnlyItselfAndTheGroupsEarlierSavesCommit() async throws {
        let provider = try await makeProvider()
        let (store, writer) = try makeStore(provider, provider: provider)
        provider.recordLogGroupCommit.commitAfterMs = 60_000
        try store.setState(writer: writer, notice: (current: 1, next: 2, entries: 1))
        let hooks = Hooks()
        try install(hooks, on: provider)
        try save(store, writer, "a")             // fills epoch 1
        try save(store, writer, "b")             // spills to epoch 2, which it fills
        XCTAssertThrowsError(try save(store, writer, "c")) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .documentEpochBudget)
        }
        XCTAssertTrue(try groupOpen(provider), "the failed save left the group open")
        XCTAssertNil(try store.read(model: "Note", id: "c"))
        try store.flush()
        XCTAssertEqual(hooks.commits, 1)
        XCTAssertEqual(try store.pendingOf(writer).map(\.m.id), ["a", "b"])
        XCTAssertEqual(try store.marks().nextSeq, 3, "the failed save's number was rolled back with it")
    }

    func testAGroupWhoseCommitFailsRollsBackRestoresTheSettingAndReportsTheFailure() async throws {
        let provider = try await makeProvider()
        try provider.withConnection { connection in
            try connection.executeScript("PRAGMA foreign_keys=ON")
            try connection.executeScript("CREATE TABLE commit_parent (id TEXT PRIMARY KEY)")
            try connection.executeScript(
                "CREATE TABLE commit_child (pid TEXT REFERENCES commit_parent(id) DEFERRABLE INITIALLY DEFERRED)"
            )
            try connection.executeScript("PRAGMA synchronous=FULL")
        }
        let (store, writer) = try makeStore(provider, provider: provider)
        provider.recordLogGroupCommit.commitAfterMs = 60_000
        let heard = LockedBox<[JsBaoError?]>([])
        try save(store, writer, "a") { error in heard.withValue { $0.append(error as? JsBaoError) } }
        // A statement in the same group that only the COMMIT finds wrong.
        try store.save { sql in try sql.exec("INSERT INTO commit_child (pid) VALUES ('missing')") }
        XCTAssertEqual(try synchronous(provider), 1)

        try store.flush()
        XCTAssertEqual(heard.value.count, 1)
        let error = try XCTUnwrap(heard.value.first ?? nil)
        XCTAssertEqual(error.code, .unavailable)
        XCTAssertEqual(error.details?["documentId"], "doc-1")
        XCTAssertEqual(error.details?["reason"], "commit-failed")
        XCTAssertFalse(try groupOpen(provider))
        XCTAssertEqual(try synchronous(provider), 2, "the setting is put back after a rollback too")
        XCTAssertEqual(try store.pendingOf(writer), [], "the group's pending entries are gone")
        XCTAssertNil(try store.read(model: "Note", id: "a"), "and so is the view's guess")
        let projected = try provider.withConnection { try $0.query("SELECT COUNT(*) AS n FROM \"Note\"").first?["n"].intValue }
        XCTAssertEqual(projected, 0)

        // The store carries on.
        try save(store, writer, "b")
        try store.flush()
        XCTAssertEqual(try store.pendingOf(writer).map(\.m.id), ["b"])
    }
}
