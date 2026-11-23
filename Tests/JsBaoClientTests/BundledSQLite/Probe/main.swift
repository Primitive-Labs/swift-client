// JsBaoSQLiteProbe — the bundled SQLite's first use, in a fresh process.
//
// vec1 is set up by SQLite on every connection it opens, and SQLite's own
// initialization, which a process runs once (again after `sqlite3_shutdown`),
// is left as SQLite ships it. Inside the XCTest process that initialization
// happened long ago, so `BundledSQLiteFreshProcessHermeticTests` spawns this
// probe instead. Before its first SQLite call it sets a global option with
// `sqlite3_config`, which SQLite accepts only before it initializes. Then, in
// two rounds, two threads held at one barrier each open their own `:memory:`
// connection at once, ask `vec1_info()` and run the nearest-neighbour fixture
// js-bao's browser probe runs: the first round initializes SQLite, and between
// the rounds the probe closes both connections and shuts SQLite down, so the
// second round initializes it again. It prints one JSON line per step:
// `{"step":"config","rc":0}`, `{"step":"shutdown","rc":0}`,
// `{"step":"config after shutdown","rc":0}`, and for each connection
// `{"round":r,"thread":n,"vec1":"0.8","rowid":2,"d":0.02}` or
// `{"round":r,"thread":n,"error":"<SQLite's message>"}`. The exit status is 0
// when every step answered, 1 otherwise.

import Foundation
import JsBaoSQLite

private struct ProbeFailure: Error {
    let message: String
}

private func failure(_ db: OpaquePointer?, _ step: String) -> ProbeFailure {
    ProbeFailure(message: "\(step): " + (db.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"))
}

private func exec(_ db: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure(db, sql) }
}

/// The first row of `sql`, each column as text.
private func firstRow(_ db: OpaquePointer, _ sql: String) throws -> [String] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw failure(db, sql)
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw failure(db, sql) }
    return (0..<sqlite3_column_count(statement)).map { column in
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}

/// `sqlite3_config(SQLITE_CONFIG_SERIALIZED)`, the build's default threading
/// mode. Swift does not import C's variadic `sqlite3_config`; this option takes
/// no argument after `op`, so calling it through a fixed-argument pointer
/// passes exactly what C would.
private func configSerialized() -> Int32 {
    typealias Config = @convention(c) (Int32) -> Int32
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sqlite3_config") else { return -1 }
    return unsafeBitCast(symbol, to: Config.self)(SQLITE_CONFIG_SERIALIZED)
}

private func probe(round: Int, thread: Int) -> [String: Any] {
    var handle: OpaquePointer?
    let opened = sqlite3_open_v2(":memory:", &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    defer { if let handle { sqlite3_close_v2(handle) } }
    do {
        guard opened == SQLITE_OK, let db = handle else { throw failure(handle, "open") }
        let info = try firstRow(db, "SELECT vec1_info()")[0].split(separator: " ")
        try exec(db, "CREATE VIRTUAL TABLE v USING vec1")
        try exec(db, #"INSERT INTO v(cmd, arg) VALUES ('rebuild', '{index:"flat",distance:"l2"}')"#)
        for (rowid, vector) in [(1, "[0,0,1]"), (2, "[1,0,0]"), (3, "[0,1,0]")] {
            try exec(db, "INSERT INTO v(rowid, vector) VALUES (\(rowid), vec1_from_json('\(vector)'))")
        }
        let nearest = try firstRow(
            db,
            "SELECT rowid, vec1_l2_distance(vector, vec1_from_json('[0.9,0.1,0]')) AS d "
                + "FROM v(vec1_from_json('[0.9,0.1,0]'), '{K:3}') ORDER BY d LIMIT 1"
        )
        return [
            "round": round,
            "thread": thread,
            "vec1": info.count > 1 && info[0] == "version" ? String(info[1]) : info.joined(separator: " "),
            "rowid": Int(nearest[0]) ?? -1,
            "d": Double(nearest[1]) ?? -1,
        ]
    } catch {
        return ["round": round, "thread": thread, "error": (error as? ProbeFailure)?.message ?? "\(error)"]
    }
}

/// The printed lines, behind a lock, and whether every step answered.
private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var failed = false

    func append(_ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        lock.lock()
        lines.append(String(decoding: data, as: UTF8.self))
        failed = failed || object["error"] != nil || (object["rc"].map { ($0 as? Int32) != SQLITE_OK } ?? false)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    var answered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !failed && lines.count == 7
    }
}

/// Two threads, released at one barrier, each probing its own connection; the
/// connections are closed when this returns.
private func concurrentFirstConnections(round: Int, into lines: Lines) {
    let ready = DispatchSemaphore(value: 0)
    let go = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    for thread in 1...2 {
        Thread {
            ready.signal()
            go.wait()
            lines.append(probe(round: round, thread: thread))
            done.signal()
        }.start()
    }
    ready.wait()
    ready.wait()
    go.signal()
    go.signal()
    done.wait()
    done.wait()
}

private func run() -> Lines {
    let lines = Lines()
    lines.append(["step": "config", "rc": configSerialized()])
    concurrentFirstConnections(round: 1, into: lines)
    lines.append(["step": "shutdown", "rc": sqlite3_shutdown()])
    lines.append(["step": "config after shutdown", "rc": configSerialized()])
    concurrentFirstConnections(round: 2, into: lines)
    return lines
}

private let probed = run()
for line in probed.all { print(line) }
exit(probed.answered ? 0 : 1)
