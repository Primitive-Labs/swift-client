import Foundation
import JsBaoSQLite
import XCTest
import YSwift
@testable import JsBaoClient

/// db3s on one real file-backed provider, for the view-path suites (#4700):
/// each document bound as the client binds it, rows seeded as the room sends
/// them (`record.results` through the store), and models connected through
/// the same `MultiDocModel` the generated `Model.*` facade reads. No server.
final class RecordLogViewFixture {

    let provider: SQLiteStorageProvider
    let directory: String
    private(set) var bindings: [String: RecordLogDocumentBinding] = [:]
    /// The level the bindings opened from now on log at.
    var logLevel: LogLevel = .none
    private var shared: [String: MultiDocModel] = [:]
    private var log: [String: Int] = [:]

    private init(provider: SQLiteStorageProvider, directory: String) {
        self.provider = provider
        self.directory = directory
    }

    /// A fresh provider on its own file. Remove it with ``remove()``.
    static func make(_ label: String = "view") async throws -> RecordLogViewFixture {
        let directory = NSTemporaryDirectory() + "/record-log-\(label)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return RecordLogViewFixture(provider: provider, directory: directory)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// `documentId`'s binding, opened on first use.
    @discardableResult
    func open(_ documentId: String) throws -> RecordLogDocumentBinding {
        if let existing = bindings[documentId] { return existing }
        let binding = try RecordLogDocumentBinding(
            host: provider, documentId: documentId, clientId: "client-1",
            logger: Logger(level: logLevel)
        )
        bindings[documentId] = binding
        return binding
    }

    /// Write `rows` of `model` into `documentId` as the room's results for
    /// another writer's entries, one entry per row, in order.
    func seed(_ documentId: String, _ model: String, _ rows: [JSONValue]) throws {
        let binding = try open(documentId)
        var items: [RecordLogResultItem] = []
        for row in rows {
            let next = (log[documentId] ?? 0) + 1
            log[documentId] = next
            let id = try XCTUnwrap(row["id"]?.stringValue, "a seeded row names its id")
            items.append(.result(RecordLogResult(
                l: next, e: 1, changes: [RecordLogChange(model: model, id: id, row: row.objectValue)]
            )))
        }
        let reply = try binding.withOperation {
            try binding.store.receive(writer: binding.writer, items: items)
        }
        binding.notify(reply.changed.map { RecordLogRecordKey(model: $0.model, id: $0.id) })
    }

    /// The cross-document model for `schema`, as `client.sharedModel(for:)` keeps one.
    func shared(_ schema: PrimitiveSchema) -> MultiDocModel {
        if let existing = shared[schema.name] { return existing }
        let made = MultiDocModel(schema: schema)
        shared[schema.name] = made
        return made
    }

    /// `schema`'s member for `documentId`: connected to the shared model and
    /// bound to the document's store.
    @discardableResult
    func member(_ schema: PrimitiveSchema, _ documentId: String) throws -> DynamicModel {
        let model = shared(schema)
        if let existing = model.member(docId: documentId) { return existing }
        let member = model.connect(docId: documentId, doc: YDocument())
        try member.bindRecordLog(try open(documentId))
        return member
    }

    /// `client.documents.records(documentId)` over this document's binding.
    func records(_ documentId: String) throws -> DocumentRecords {
        let binding = try open(documentId)
        return DocumentRecords(documentId: documentId) { binding }
    }
}

/// The text of every statement one provider's connection runs, read back
/// through `sqlite3_trace_v2` (#4700): what a read ran, or that it ran nothing.
final class RecordLogStatementTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var _statements: [String] = []

    var statements: [String] { lock.withLock { _statements } }
    func clear() { lock.withLock { _statements = [] } }
    fileprivate func ran(_ text: String) { lock.withLock { _statements.append(text) } }

    /// The statements that read `record_log_view` (a reader's statements).
    var viewReads: [String] {
        statements.filter {
            $0.contains("record_log_view") && $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("SELECT")
        }
    }
}

extension RecordLogViewFixture {
    /// Start recording every statement the provider's connection runs; the
    /// recording stops when `testCase` tears down.
    func trace(_ testCase: XCTestCase) throws -> RecordLogStatementTrace {
        try RecordLogStatementTrace.install(on: provider, testCase)
    }
}

extension RecordLogStatementTrace {
    /// Record every statement `provider`'s connection runs until `testCase` tears down.
    static func install(on provider: SQLiteStorageProvider, _ testCase: XCTestCase) throws -> RecordLogStatementTrace {
        let trace = RecordLogStatementTrace()
        let context = Unmanaged.passRetained(trace).toOpaque()
        _ = try provider.withRecordLogConnection { connection in
            sqlite3_trace_v2(connection.rawHandle, UInt32(SQLITE_TRACE_STMT), { _, context, _, text in
                guard let context, let text else { return 0 }
                Unmanaged<RecordLogStatementTrace>.fromOpaque(context).takeUnretainedValue()
                    .ran(String(cString: text.assumingMemoryBound(to: CChar.self)))
                return 0
            }, context)
        }
        testCase.addTeardownBlock { [provider] in
            _ = try? provider.withRecordLogConnection { sqlite3_trace_v2($0.rawHandle, 0, nil, nil) }
            Unmanaged<RecordLogStatementTrace>.fromOpaque(context).release()
        }
        return trace
    }
}
