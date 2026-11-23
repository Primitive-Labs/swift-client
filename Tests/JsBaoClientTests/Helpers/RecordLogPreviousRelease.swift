import Foundation
@testable import JsBaoClient

/// A record-log store as the release before #5136 kept it (storage version
/// 2): every `_data` the JSON text of its row with `id`, keys sorted, as
/// `RecordLogJSON.text` wrote it; the version 2.
enum RecordLogPreviousRelease {
    /// Rewrite the store `host` holds into the previous release's form, row for row.
    static func downgrade(_ host: any Format2SqlHost) throws {
        try host.withConnection { connection in
            try connection.transaction {
                for table in ["record_log_rows", "record_log_view", "record_log_staged_base"] {
                    for row in try connection.query("SELECT rowid AS r, _id, json(_data) AS text FROM \(table) WHERE _data IS NOT NULL") {
                        let text = RecordLogJSON.text(.object(RecordLogJSON.row(row["text"].stringValue, id: row["_id"].stringValue)))
                        try connection.execute("UPDATE \(table) SET _data = ? WHERE rowid = ?", [.text(text), row["r"]])
                    }
                }
                try connection.execute(
                    """
                    INSERT INTO record_log_meta (key, value) VALUES ('storage_version', '2')
                      ON CONFLICT (key) DO UPDATE SET value = excluded.value
                    """,
                    []
                )
            }
        }
    }

    /// `page_count − freelist_count`: the pages that hold something.
    static func livePages(_ host: any Format2SqlHost) throws -> Int {
        try host.withConnection { connection in
            let pages = try connection.query("PRAGMA page_count").first?["page_count"].intValue ?? 0
            let free = try connection.query("PRAGMA freelist_count").first?["freelist_count"].intValue ?? 0
            return pages - free
        }
    }
}

/// A host over a real provider whose connection fails the `failAt`th
/// statement containing `match`, once: a real statement really fails, as
/// `Format2SqlConnection` was made a protocol for.
final class RecordLogFaultingHost: Format2SqlHost, @unchecked Sendable {
    let provider: SQLiteStorageProvider
    let match: String
    private let lock = NSLock()
    private var remaining: Int

    init(_ provider: SQLiteStorageProvider, failing match: String, at failAt: Int) {
        self.provider = provider
        self.match = match
        self.remaining = failAt
    }

    func withConnection<T>(_ body: (any Format2SqlConnection) throws -> T) throws -> T {
        try provider.withConnection { real in try body(Connection(real: real, host: self)) }
    }

    /// Whether `sql` is the statement to fail.
    fileprivate func fails(_ sql: String) -> Bool {
        guard sql.contains(match) else { return false }
        return lock.withLock {
            remaining -= 1
            return remaining == 0
        }
    }

    struct Injected: Error, CustomStringConvertible {
        let sql: String
        var description: String { "injected failure: \(sql)" }
    }

    private final class Connection: Format2SqlConnection {
        let real: any Format2SqlConnection
        let host: RecordLogFaultingHost

        init(real: any Format2SqlConnection, host: RecordLogFaultingHost) {
            self.real = real
            self.host = host
        }

        func execute(_ sql: String, _ bindings: [Format2SqlValue]) throws {
            if host.fails(sql) { throw Injected(sql: sql) }
            try real.execute(sql, bindings)
        }

        func query(_ sql: String, _ bindings: [Format2SqlValue]) throws -> [Format2SqlRow] {
            if host.fails(sql) { throw Injected(sql: sql) }
            return try real.query(sql, bindings)
        }

        func executeScript(_ sql: String) throws {
            if host.fails(sql) { throw Injected(sql: sql) }
            try real.executeScript(sql)
        }

        func transaction<T>(_ body: () throws -> T) throws -> T { try real.transaction(body) }
        var inTransaction: Bool { real.inTransaction }
        var rawHandle: OpaquePointer? { real.rawHandle }
    }
}
