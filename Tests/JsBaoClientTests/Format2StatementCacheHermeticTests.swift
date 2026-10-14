import XCTest
import SQLite3
@testable import JsBaoClient

/// `SQLiteFormat2Connection` compiles a SQL text once and runs the compiled
/// statement again on the next call, over a real `SQLiteStorageProvider` on a
/// temp file.
///
/// The compiled statements are read back from the handle itself
/// (`sqlite3_next_stmt`, `sqlite3_stmt_status`), so nothing stands in for
/// SQLite. Results, errors and transactions behave as they did when every call
/// compiled its own statement, and closing the provider leaves no statement
/// behind: another connection can then take the file out of WAL mode, which
/// SQLite refuses while the provider's connection is still open.
final class Format2StatementCacheHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> (SQLiteStorageProvider, String) {
        let directory = NSTemporaryDirectory() + "/format2-statements-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let path = directory + "/store.sqlite"
        let provider = SQLiteStorageProvider(path: path)
        try await provider.initialize(namespace: "test")
        try provider.withConnection { connection in
            try connection.executeScript("CREATE TABLE t (id TEXT PRIMARY KEY, n INTEGER NOT NULL)")
        }
        return (provider, path)
    }

    /// The compiled statements open on the connection's handle for `sql`, with
    /// the number of times each has run.
    private func compiled(_ sql: String, on connection: any Format2SqlConnection) -> [Int32] {
        guard let db = connection.rawHandle else { return [] }
        var runs: [Int32] = []
        var statement = sqlite3_next_stmt(db, nil)
        while let current = statement {
            if let text = sqlite3_sql(current), String(cString: text) == sql {
                runs.append(sqlite3_stmt_status(current, SQLITE_STMTSTATUS_RUN, 0))
            }
            statement = sqlite3_next_stmt(db, current)
        }
        return runs
    }

    private static let insert = "INSERT INTO t (id, n) VALUES (?, ?)"
    private static let select = "SELECT id, n FROM t WHERE n >= ? ORDER BY id"

    // MARK: - Compiled once

    func testRunningTheSameSQLTwiceCompilesItOnce() async throws {
        let (provider, _) = try await makeProvider()
        try provider.withConnection { connection in
            try connection.execute(Self.insert, [.text("a"), .integer(1)])
            try connection.execute(Self.insert, [.text("b"), .integer(2)])
            XCTAssertEqual(compiled(Self.insert, on: connection), [2])

            _ = try connection.query(Self.select, [.integer(0)])
            let rows = try connection.query(Self.select, [.integer(2)])
            XCTAssertEqual(compiled(Self.select, on: connection), [2])
            XCTAssertEqual(rows.map { $0["id"] }, [.text("b")])
        }
        // A later call on the provider reaches the same compiled statement.
        try provider.withConnection { connection in
            try connection.execute(Self.insert, [.text("c"), .integer(3)])
            XCTAssertEqual(compiled(Self.insert, on: connection), [3])
        }
        await provider.close()
    }

    // MARK: - Unchanged behavior

    func testBindingsFromAnEarlierRunDoNotCarryOver() async throws {
        let (provider, _) = try await makeProvider()
        try provider.withConnection { connection in
            let upsert = "INSERT INTO t (id, n) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET n = excluded.n"
            try connection.execute(upsert, [.text("a"), .integer(5)])
            // Too few bindings: the missing one is NULL, not the 5 bound before.
            XCTAssertThrowsError(try connection.execute(upsert, [.text("b")])) { error in
                guard case Format2SqlError.executionFailed(_, let message) = error else {
                    return XCTFail("expected executionFailed, got \(error)")
                }
                XCTAssertTrue(message.contains("NOT NULL"), message)
            }
            let rows = try connection.query("SELECT id, n FROM t ORDER BY id")
            XCTAssertEqual(rows.map { $0["id"] }, [.text("a")])
            XCTAssertEqual(rows.map { $0["n"] }, [.integer(5)])
        }
        await provider.close()
    }

    func testErrorsAreThrownAsBeforeAndTheStatementRunsAgainAfterOne() async throws {
        let (provider, _) = try await makeProvider()
        try provider.withConnection { connection in
            XCTAssertThrowsError(try connection.query("SELECT nope FROM missing")) { error in
                guard case Format2SqlError.prepareFailed(let sql, let message) = error else {
                    return XCTFail("expected prepareFailed, got \(error)")
                }
                XCTAssertEqual(sql, "SELECT nope FROM missing")
                XCTAssertTrue(message.contains("no such table"), message)
            }
            try connection.execute(Self.insert, [.text("a"), .integer(1)])
            XCTAssertThrowsError(try connection.execute(Self.insert, [.text("a"), .integer(2)])) { error in
                guard case Format2SqlError.executionFailed(let sql, let message) = error else {
                    return XCTFail("expected executionFailed, got \(error)")
                }
                XCTAssertEqual(sql, Self.insert)
                XCTAssertTrue(message.contains("UNIQUE"), message)
            }
            try connection.execute(Self.insert, [.text("b"), .integer(2)])
            XCTAssertEqual(try connection.query(Self.select, [.integer(0)]).map { $0["id"] }, [.text("a"), .text("b")])
        }
        await provider.close()
    }

    func testATableDroppedAndRecreatedIsReadAfresh() async throws {
        let (provider, _) = try await makeProvider()
        try provider.withConnection { connection in
            try connection.execute(Self.insert, [.text("a"), .integer(1)])
            XCTAssertEqual(try connection.query(Self.select, [.integer(0)]).count, 1)
            try connection.executeScript("DROP TABLE t")
            XCTAssertThrowsError(try connection.query(Self.select, [.integer(0)]))
            try connection.executeScript("CREATE TABLE t (id TEXT PRIMARY KEY, n INTEGER NOT NULL, extra TEXT)")
            try connection.execute(Self.insert, [.text("z"), .integer(9)])
            XCTAssertEqual(try connection.query(Self.select, [.integer(0)]).map { $0["id"] }, [.text("z")])
        }
        await provider.close()
    }

    /// No failed query in between: the cached statement's next step recompiles
    /// it against the new table, and the row is read by the new columns.
    func testATableRecreatedWithOtherColumnsIsReadByItsNewColumns() async throws {
        let (provider, _) = try await makeProvider()
        try provider.withConnection { connection in
            let all = "SELECT * FROM t"
            try connection.execute(Self.insert, [.text("a"), .integer(1)])
            XCTAssertEqual(try connection.query(all).map(\.columns), [["id": .text("a"), "n": .integer(1)]])
            try connection.executeScript(
                "DROP TABLE t; CREATE TABLE t (n INTEGER NOT NULL, id TEXT PRIMARY KEY, extra TEXT)"
            )
            try connection.execute("INSERT INTO t (n, id, extra) VALUES (?, ?, ?)", [.integer(9), .text("z"), .text("e")])
            XCTAssertEqual(
                try connection.query(all).map(\.columns),
                [["n": .integer(9), "id": .text("z"), "extra": .text("e")]]
            )
            XCTAssertEqual(compiled(all, on: connection).count, 1)
        }
        await provider.close()
    }

    /// Swift's `String` equality is canonical equivalence, so `é` written as
    /// one scalar and as `e` with a combining accent compare equal — but they
    /// are two SQL texts naming two tables, and each runs its own statement.
    func testCanonicallyEquivalentTextsAreTwoStatements() async throws {
        let (provider, _) = try await makeProvider()
        let composed = "\u{E9}"
        let decomposed = "e\u{301}"
        XCTAssertEqual(composed, decomposed)
        try provider.withConnection { connection in
            try connection.executeScript(
                "CREATE TABLE \"\(composed)\" (v INTEGER); CREATE TABLE \"\(decomposed)\" (v INTEGER)"
            )
            try connection.execute("INSERT INTO \"\(composed)\" (v) VALUES (?)", [.integer(1)])
            try connection.execute("INSERT INTO \"\(decomposed)\" (v) VALUES (?)", [.integer(2)])
            let rows = try connection.query(
                "SELECT (SELECT group_concat(v) FROM \"\(composed)\") AS one, "
                    + "(SELECT group_concat(v) FROM \"\(decomposed)\") AS two"
            )
            XCTAssertEqual(rows.map { $0["one"] }, [.text("1")])
            XCTAssertEqual(rows.map { $0["two"] }, [.text("2")])
        }
        await provider.close()
    }

    func testATransactionThatThrowsStillRollsBackAndOneThatReturnsCommits() async throws {
        struct Abort: Error {}
        let (provider, _) = try await makeProvider()
        try provider.withConnection { connection in
            XCTAssertThrowsError(try connection.transaction {
                try connection.execute(Self.insert, [.text("a"), .integer(1)])
                _ = try connection.query(Self.select, [.integer(0)])
                throw Abort()
            })
            XCTAssertFalse(connection.inTransaction)
            XCTAssertEqual(try connection.query(Self.select, [.integer(0)]).count, 0)

            try connection.transaction {
                try connection.execute(Self.insert, [.text("b"), .integer(2)])
                // A statement that returns a row from `execute` is put back too,
                // or the COMMIT below would be refused while it is still running.
                try connection.execute("SELECT id FROM t", [])
            }
            XCTAssertEqual(try connection.query(Self.select, [.integer(0)]).map { $0["id"] }, [.text("b")])
        }
        await provider.close()
    }

    func testManyDistinctTextsStillRunAndTheCacheStaysBounded() async throws {
        let (provider, _) = try await makeProvider()
        try provider.withConnection { connection in
            for i in 0..<300 {
                try connection.execute(Self.insert, [.text("id\(i)"), .integer(Int64(i))])
                let marks = Array(repeating: "?", count: i + 1).joined(separator: ", ")
                let rows = try connection.query(
                    "SELECT id FROM t WHERE n IN (\(marks))", (0...i).map { .integer(Int64($0)) }
                )
                XCTAssertEqual(rows.count, i + 1)
            }
            var open = 0
            var statement = sqlite3_next_stmt(connection.rawHandle, nil)
            while let current = statement { open += 1; statement = sqlite3_next_stmt(connection.rawHandle, current) }
            XCTAssertLessThanOrEqual(open, 128)
        }
        await provider.close()
    }

    // MARK: - Closing

    func testClosingTheProviderLeavesNoStatementOpenAndItReopensCleanly() async throws {
        let (provider, path) = try await makeProvider()
        try provider.withConnection { connection in
            try connection.execute(Self.insert, [.text("a"), .integer(1)])
            _ = try connection.query(Self.select, [.integer(0)])
            _ = try connection.query(Self.select, [.integer(0)])
        }
        await provider.close()
        XCTAssertEqual(try leaveWAL(path), "delete")

        try await provider.initialize(namespace: "test")
        try provider.withConnection { connection in
            try connection.execute(Self.insert, [.text("b"), .integer(2)])
            XCTAssertEqual(try connection.query(Self.select, [.integer(0)]).map { $0["id"] }, [.text("a"), .text("b")])
        }
        await provider.close()
        XCTAssertEqual(try leaveWAL(path), "delete")
    }

    /// Take the file out of WAL mode from a connection of the test's own and
    /// answer the mode it is left in. SQLite refuses while any other connection
    /// still has the file open — and `sqlite3_close_v2` keeps a connection open
    /// for as long as one of its statements is unfinalized.
    private func leaveWAL(_ path: String) throws -> String? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw JsBaoError(code: .unavailable, message: "cannot open \(path)")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA journal_mode=DELETE", -1, &statement, nil) == SQLITE_OK else {
            throw JsBaoError(code: .unavailable, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            return String(cString: sqlite3_errmsg(db))
        }
        return String(cString: text)
    }
}
