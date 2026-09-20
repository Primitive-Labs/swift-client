import Foundation
import SQLite3

/// Direct, serialized SQL access to a storage provider's own database
/// connection (#3436).
///
/// A large document's records live in real SQL tables, not in the `kv_store`
/// key-value API the public ``StorageProvider`` protocol exposes — a 2 GB
/// document read one JSON blob at a time is not a document. So the record
/// store needs the connection itself.
///
/// It needs THAT connection specifically, never a second one on the same file.
/// `JsBaoClient.setupStorage` records why in its own comment: a second handle
/// on one WAL file produced `SQLITE_BUSY` under concurrent auth and data
/// writes. Everything the format-2 layer does — the store, the fold, the
/// file-backed query engine — runs on the provider's single serialized handle.
///
/// The protocol is deliberately NOT part of ``StorageProvider``: a provider
/// that cannot host a large document simply does not conform, which is what
/// makes the refusal a type-level fact rather than a runtime capability probe.
/// ``MemoryStorageProvider`` does not conform.
public protocol Format2SqlHost: AnyObject, Sendable {
    /// Run `body` on the provider's serial queue with its connection.
    ///
    /// The handle is valid only for the duration of the call: it belongs to
    /// the provider, which may close it. Every SQL failure throws — none is
    /// discarded, which is the defect `BaoModelQueryEngine` shipped with
    /// (3436-SO-05).
    func withConnection<T>(_ body: (any Format2SqlConnection) throws -> T) throws -> T

    /// The directory the database file lives in, when there is one.
    ///
    /// Read by the storage probe (#3437, behavior 33): what a large document
    /// may keep is a property of the VOLUME it is written to, and the only
    /// thing that knows which volume that is is the provider. `nil` for a host
    /// with no file — an in-memory provider is refused before this is ever
    /// asked, because a large document IS its local store.
    var databaseDirectory: String? { get }
}

public extension Format2SqlHost {
    /// A host that does not say reads as "no capacity API answered", which is
    /// an unknown quota rather than a refusal.
    var databaseDirectory: String? { nil }
}

/// One SQLite connection, as the format-2 layer uses it.
///
/// A protocol rather than the concrete class so a caller can WRAP one — the
/// fault injection the tests need is a decorator over a real connection, which
/// keeps the failure path honest (a real statement really fails) and keeps the
/// library free of a test seam it would otherwise have to carry.
public protocol Format2SqlConnection: AnyObject {
    /// Run a statement for effect. Every failure throws.
    func execute(_ sql: String, _ bindings: [Format2SqlValue]) throws
    /// Run a statement and collect its rows.
    func query(_ sql: String, _ bindings: [Format2SqlValue]) throws -> [Format2SqlRow]
    /// Run DDL, unbound — the statements come from this library, never a caller.
    func executeScript(_ sql: String) throws
    /// Run `body` as one commit, rolling back if it throws. Nesting reuses the
    /// open transaction.
    func transaction<T>(_ body: () throws -> T) throws -> T
    /// Whether a transaction opened through ``transaction(_:)`` is in flight.
    var inTransaction: Bool { get }
    /// The underlying SQLite handle, valid only inside the
    /// ``Format2SqlHost/withConnection(_:)`` call that produced this
    /// connection.
    ///
    /// For the ONE caller that speaks SQLite's C API directly rather than
    /// through the statements above: the file-backed query engine, which
    /// builds its SELECTs column by column and binds its own parameters
    /// (#3436, behavior 13). It gets the same connection so its statements are
    /// serialized with the record store's and join whatever transaction is
    /// open — which is what lets a projected row commit with its merged row.
    ///
    /// A wrapper that cannot supply one answers `nil`, and the engine refuses
    /// rather than opening a second handle on the file.
    var rawHandle: OpaquePointer? { get }
}

extension Format2SqlConnection {
    public func execute(_ sql: String) throws { try execute(sql, []) }
    public func query(_ sql: String) throws -> [Format2SqlRow] { try query(sql, []) }
}

/// The real connection over a raw SQLite handle.
///
/// Wraps the handle so callers bind values rather than interpolating them, and
/// so a failed step is an error rather than a return code nobody read.
public final class SQLiteFormat2Connection: Format2SqlConnection {

    private let db: OpaquePointer
    /// Depth of nested ``transaction(_:)`` calls. SQLite has no nested
    /// transactions, so an inner call reuses the open one — a catch-up fold
    /// calling `applyRemote` inside its own transaction must not commit
    /// halfway through.
    private var transactionDepth = 0

    init(db: OpaquePointer) {
        self.db = db
    }

    /// Whether this wrapper still wraps `handle` — a provider that closed and
    /// reopened has a new one, and the old depth counter with it.
    func owns(_ handle: OpaquePointer) -> Bool { db == handle }

    // MARK: - Statements

    /// Run a statement for effect.
    public func execute(_ sql: String, _ bindings: [Format2SqlValue]) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw Format2SqlError.executionFailed(sql: sql, message: lastError())
        }
    }

    /// Run a statement and collect its rows.
    public func query(_ sql: String, _ bindings: [Format2SqlValue]) throws -> [Format2SqlRow] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }

        var rows: [Format2SqlRow] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw Format2SqlError.executionFailed(sql: sql, message: lastError())
            }
            var columns: [String: Format2SqlValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                guard let namePtr = sqlite3_column_name(statement, index) else { continue }
                columns[String(cString: namePtr)] = Self.value(of: statement, at: index)
            }
            rows.append(Format2SqlRow(columns: columns))
        }
        return rows
    }

    /// Run several statements separated by semicolons — DDL only, so nothing
    /// is bound. Used for the schema, where the statements come from this
    /// library and never from a caller.
    public func executeScript(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        let message = errorPointer.map { String(cString: $0) } ?? lastError()
        if errorPointer != nil { sqlite3_free(errorPointer) }
        guard rc == SQLITE_OK else {
            throw Format2SqlError.executionFailed(sql: sql, message: message)
        }
    }

    // MARK: - Transactions

    /// Run `body` as one commit, rolling back if it throws.
    ///
    /// `BEGIN IMMEDIATE` rather than the deferred default: the fold and the
    /// local-write commit both read before they write, and a deferred
    /// transaction that upgrades to a writer mid-way can lose the lock to
    /// another connection and be asked to retry the whole thing.
    ///
    /// Nesting reuses the open transaction. A catch-up fold is one commit for
    /// a whole overlay — thousands of records — and the per-entry projection
    /// inside it must not commit on its own.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }
        try executeScript("BEGIN IMMEDIATE")
        transactionDepth = 1
        do {
            let result = try body()
            transactionDepth = 0
            try executeScript("COMMIT")
            return result
        } catch {
            transactionDepth = 0
            // A failed ROLLBACK is reported as the original error: the caller
            // needs the reason the write failed, not the reason the cleanup
            // after it did.
            try? executeScript("ROLLBACK")
            throw error
        }
    }

    /// Whether a transaction opened through ``transaction(_:)`` is in flight.
    public var inTransaction: Bool { transactionDepth > 0 }

    public var rawHandle: OpaquePointer? { db }

    // MARK: - Private

    private func prepare(
        _ sql: String, _ bindings: [Format2SqlValue]
    ) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw Format2SqlError.prepareFailed(sql: sql, message: lastError())
        }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .null:
                sqlite3_bind_null(statement, index)
            case .text(let text):
                sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .integer(let value):
                sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                sqlite3_bind_double(statement, index, value)
            }
        }
        return statement
    }

    private static func value(
        of statement: OpaquePointer?, at index: Int32
    ) -> Format2SqlValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        default:
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: text))
        }
    }

    private func lastError() -> String { String(cString: sqlite3_errmsg(db)) }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

/// A bound or returned SQL value.
public enum Format2SqlValue: Equatable, Sendable {
    case null
    case text(String)
    case integer(Int64)
    case real(Double)

    public var stringValue: String? {
        switch self {
        case .text(let text): return text
        case .integer(let value): return String(value)
        case .real(let value): return String(value)
        case .null: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .integer(let value): return Int(value)
        case .real(let value): return Int(value)
        case .text(let text): return Int(text)
        case .null: return nil
        }
    }

    public var isNull: Bool { self == .null }

    /// Bind a `JSONValue` the way the JS store binds one: a string, a number
    /// or a bool, and null for anything structured. The fold never binds a
    /// structured value — those travel inside the `_data` JSON text.
    public init(json: JSONValue) {
        switch json {
        case .string(let text): self = .text(text)
        case .number(let value):
            self = value == value.rounded() && abs(value) < 9_007_199_254_740_992
                ? .integer(Int64(value))
                : .real(value)
        case .bool(let value): self = .integer(value ? 1 : 0)
        case .null, .object, .array: self = .null
        }
    }
}

/// One returned row.
public struct Format2SqlRow: Sendable {
    public let columns: [String: Format2SqlValue]
    public subscript(column: String) -> Format2SqlValue { columns[column] ?? .null }
}

public enum Format2SqlError: Error, LocalizedError {
    case notInitialized
    case prepareFailed(sql: String, message: String)
    case executionFailed(sql: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "the storage provider's database is not open"
        case .prepareFailed(let sql, let message):
            return "failed to prepare SQL: \(message) — \(sql)"
        case .executionFailed(let sql, let message):
            return "SQL execution failed: \(message) — \(sql)"
        }
    }
}

// MARK: - The provider's conformance

extension SQLiteStorageProvider: Format2SqlHost {

    /// The provider's own connection, on its own serial queue.
    ///
    /// Reusing the serial queue is what makes this safe beside the `kv_store`
    /// API: a format-2 write and an auth write cannot be in flight at once, so
    /// there is no second writer to contend with and the `SQLITE_BUSY` that
    /// a second handle produced cannot arise.
    public func withConnection<T>(
        _ body: (any Format2SqlConnection) throws -> T
    ) throws -> T {
        try withRawConnection { db in
            try body(format2ConnectionOnQueue(db))
        }
    }
}
