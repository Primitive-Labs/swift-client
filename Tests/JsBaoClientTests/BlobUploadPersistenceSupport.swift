import Foundation
import JsBaoSQLite
import XCTest
@testable import JsBaoClient

/// Shared pieces of the upload-persistence suites (#4592): a client over a
/// SQLite file, a second connection that reads the file's upload rows, and an
/// ordered log of the blob events one client emits.
enum BlobUploadPersistence {
    static let appId = "blob-upload-restart"

    /// One test JWT per user for the whole run: `makeTestJwt` encodes a
    /// dictionary, so two calls for one user need not produce the same text.
    static func token(_ userId: String) -> String {
        tokens.withValue { (cache: inout [String: String]) -> String in
            if let token = cache[userId] { return token }
            let token = makeTestJwt(userId: userId)
            cache[userId] = token
            return token
        }
    }

    private static let tokens = LockedBox([String: String]())

    static func isDocumentPut(_ request: LoopbackAPIServer.Request) -> Bool {
        request.method == "PUT" && request.apiPathOnly.hasPrefix("/documents/")
    }

    static func documentPuts(_ server: SessionUploadServer, _ blobId: String) -> [LoopbackAPIServer.Request] {
        server.requests.filter { isDocumentPut($0) && $0.apiPathOnly.hasSuffix("/blobs/\(blobId)") }
    }

    static func blobId(of request: LoopbackAPIServer.Request) -> String {
        request.apiPathOnly.split(separator: "/").last.map(String.init) ?? ""
    }

    /// A fresh database file in its own temp directory.
    static func databasePath() throws -> String {
        let directory = NSTemporaryDirectory() + "jsbao-upload-restart-\(UUID().uuidString.prefix(8))/"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory + "jsbao_storage.sqlite"
    }

    /// A client over `server` and the SQLite file at `path`, never connecting.
    /// `token: nil` with `signedIn: false` starts with nobody signed in.
    static func client(
        _ server: SessionUploadServer, path: String?, userId: String = "u-a", appId: String = appId,
        signedIn: Bool = true
    ) -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: server.baseUrl, wsUrl: "ws://127.0.0.1:1", appId: appId,
            token: signedIn ? token(userId) : nil, offline: false, logLevel: .none,
            storageConfig: path.map { .sqlite(directory: $0) } ?? .memory, autoNetwork: false
        ))
    }

    /// Hold every retry of a document upload: a blob's first PUT is answered
    /// by the route, every later PUT of the same blob waits.
    static func holdDocumentRetries(_ server: SessionUploadServer) {
        let seen = LockedBox(Set<String>())
        server.hold { request in
            guard isDocumentPut(request) else { return false }
            let blobId = blobId(of: request)
            return seen.withValue { (blobIds: inout Set<String>) -> Bool in
                !blobIds.insert(blobId).inserted
            }
        }
    }

    /// Queue a document upload: `upload` throws the scripted failure and the
    /// upload is listed. Returns its blob id.
    static func queueDocumentUpload(
        _ client: JsBaoClient, documentId: String = "doc-1", data: Data,
        options: BlobUploadSourceOptions = BlobUploadSourceOptions()
    ) async throws -> String {
        let before = Set(await client.documents.uploadsAsync().map(\.blobId))
        let error = await thrown { _ = try await client.documents.blobs(documentId: documentId).upload(data: data, options: options) }
        XCTAssertNotNil(error, "the immediate PUT fails, so the upload is queued")
        let listed = await client.documents.uploadsAsync().map(\.blobId).filter { !before.contains($0) }
        return try XCTUnwrap(listed.first, "the upload is queued")
    }
}

/// The upload rows of one app and user, read through a second connection to
/// the file the client holds open (the provider runs SQLite in WAL mode).
struct UploadRows {
    let records: [PersistedUploadRecord]
    let byteKeys: [String]
    /// Each record as the JSON object stored, by queue id.
    let raw: [String: JSONValue]
    let bytes: [String: Data]

    static func read(
        _ path: String, appId: String = BlobUploadPersistence.appId, userId: String = "u-a"
    ) async throws -> UploadRows {
        let provider = SQLiteStorageProvider(path: path)
        try await provider.initialize(namespace: "probe")
        let recordStore = OfflineStore.blobUploadsStore(appId: appId, userId: userId)
        let byteStore = OfflineStore.blobUploadBytesStore(appId: appId, userId: userId)
        var records: [PersistedUploadRecord] = []
        var raw: [String: JSONValue] = [:]
        for key in try await provider.keys(store: recordStore) {
            let row: StorageRecord<PersistedUploadRecord>? = try await provider.get(store: recordStore, key: key)
            if let row { records.append(row.value) }
            let json: StorageRecord<JSONValue>? = try await provider.get(store: recordStore, key: key)
            raw[key] = json?.value
        }
        let byteKeys = try await provider.keys(store: byteStore)
        var bytes: [String: Data] = [:]
        for key in byteKeys {
            let row: StorageRecord<Data>? = try await provider.get(store: byteStore, key: key)
            bytes[key] = row?.value
        }
        await provider.close()
        return UploadRows(records: records, byteKeys: byteKeys, raw: raw, bytes: bytes)
    }

    /// Every upload row in the file, whatever app or user it is under.
    static func countAll(_ path: String) async throws -> Int {
        let provider = SQLiteStorageProvider(path: path)
        try await provider.initialize(namespace: "probe")
        defer { Task { await provider.close() } }
        return try provider.withRawConnection { db -> Int in
            var statement: OpaquePointer?
            let sql = "SELECT COUNT(*) FROM kv_store WHERE store LIKE 'blobUpload%'"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    /// Write a record and, when given, its bytes, as another launch left them.
    static func seed(
        _ path: String, _ record: PersistedUploadRecord, bytes: Data?,
        appId: String = BlobUploadPersistence.appId, userId: String = "u-a"
    ) async throws {
        let provider = SQLiteStorageProvider(path: path)
        let store = OfflineStore()
        await store.setStorageProvider(provider)
        try await store.putBlobUpload(appId: appId, userId: userId, record: record, bytes: bytes)
        await store.closeStorage()
    }

    func record(_ queueId: String) -> PersistedUploadRecord? {
        records.first { $0.queueId == queueId }
    }
}

/// Every blob event a client emits, in order, as short labels per blob id:
/// `progress:<status>`, `failed:<willRetry>`, `completed`, `paused`,
/// `resumed`; and the `queue-drained` count.
final class OrderedBlobEvents: @unchecked Sendable {
    private let entries = LockedBox([(blobId: String, label: String)]())
    private let failedBox = LockedBox([BlobUploadFailedEvent]())
    private let drainedBox = LockedBox(0)
    private var subscriptions: [EventSubscription] = []

    init(_ client: JsBaoClient) {
        let entries = self.entries
        let failedBox = self.failedBox
        let drainedBox = self.drainedBox
        let emitter = client.eventEmitter
        subscriptions = [
            emitter.subscribe(BlobUploadProgressEvent.self) { event in
                entries.withValue { $0.append((event.blobId, "progress:\(event.status)")) }
            },
            emitter.subscribe(BlobUploadFailedEvent.self) { event in
                entries.withValue { $0.append((event.blobId, "failed:\(event.willRetry)")) }
                failedBox.withValue { $0.append(event) }
            },
            emitter.subscribe(BlobUploadCompletedEvent.self) { event in
                entries.withValue { $0.append((event.blobId, "completed")) }
            },
            emitter.subscribe(BlobUploadPausedEvent.self) { event in
                entries.withValue { $0.append((event.blobId, "paused")) }
            },
            emitter.subscribe(BlobUploadResumedEvent.self) { event in
                entries.withValue { $0.append((event.blobId, "resumed")) }
            },
            emitter.subscribe(BlobsQueueDrainedEvent.self) { _ in drainedBox.withValue { $0 += 1 } },
        ]
    }

    func labels(_ blobId: String) -> [String] { entries.value.filter { $0.blobId == blobId }.map(\.label) }
    func failed(_ blobId: String) -> [BlobUploadFailedEvent] { failedBox.value.filter { $0.blobId == blobId } }
    var drained: Int { drainedBox.value }

    func cancel() { subscriptions.forEach { $0.cancel() } }
}

/// A provider over another one whose upload-record listing for one store
/// waits until the test opens the gate (and, with `gatingPuts`, every
/// upload write too), whose first `failPuts` writes throw, and whose first
/// `failByteReads` reads of upload bytes throw.
final class GatedStorageProvider: StorageProvider, @unchecked Sendable {
    let base: StorageProvider
    private let gatedStore: String?
    private let gatingPuts: Bool
    private let gate = LockedBox<(open: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))
    let reads = LockedBox(0)
    /// Upload writes that reached the gate.
    let gatedPuts = LockedBox(0)
    let failPuts: LockedBox<Int>
    let failByteReads: LockedBox<Int>

    init(
        _ base: StorageProvider, gating store: String? = nil, gatingPuts: Bool = false, failPuts: Int = 0,
        failByteReads: Int = 0
    ) {
        self.base = base
        self.gatedStore = store
        self.gatingPuts = gatingPuts
        self.failPuts = LockedBox(failPuts)
        self.failByteReads = LockedBox(failByteReads)
    }

    private func waitForGate() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let parked = gate.withValue { (state: inout (open: Bool, waiting: [CheckedContinuation<Void, Never>])) in
                if state.open { return false }
                state.waiting.append(continuation)
                return true
            }
            if !parked { continuation.resume() }
        }
    }

    func release() {
        let parked = gate.withValue { (state: inout (open: Bool, waiting: [CheckedContinuation<Void, Never>])) in
            state.open = true
            defer { state.waiting.removeAll() }
            return state.waiting
        }
        parked.forEach { $0.resume() }
    }

    func initialize(namespace: String) async throws { try await base.initialize(namespace: namespace) }
    func close() async { await base.close() }
    func isReady() -> Bool { base.isReady() }
    func get<T: Codable>(store: String, key: String) async throws -> StorageRecord<T>? {
        let fail = failByteReads.withValue { (left: inout Int) -> Bool in
            guard left > 0, store.hasPrefix("blobUploadBytes") else { return false }
            left -= 1
            return true
        }
        if fail { throw SQLiteStorageError.executionFailed(message: "scripted read failure") }
        return try await base.get(store: store, key: key)
    }
    func put<T: Codable>(store: String, key: String, value: T, metadata: [String: String]?) async throws {
        if gatingPuts, store.hasPrefix("blobUpload") {
            gatedPuts.withValue { $0 += 1 }
            await waitForGate()
        }
        let fail = failPuts.withValue { (left: inout Int) -> Bool in
            guard left > 0, store.hasPrefix("blobUpload") else { return false }
            left -= 1
            return true
        }
        if fail { throw SQLiteStorageError.executionFailed(message: "scripted write failure") }
        try await base.put(store: store, key: key, value: value, metadata: metadata)
    }
    func putBatch<T: Codable>(store: String, records: [(key: String, value: T, metadata: [String: String]?)]) async throws {
        try await base.putBatch(store: store, records: records)
    }
    func delete(store: String, key: String) async throws { try await base.delete(store: store, key: key) }
    func clear(store: String) async throws { try await base.clear(store: store) }
    func iterate<T: Codable>(store: String, callback: @escaping (StorageRecord<T>) throws -> Void) async throws {
        try await base.iterate(store: store, callback: callback)
    }
    func keys(store: String) async throws -> [String] {
        if store == gatedStore {
            reads.withValue { $0 += 1 }
            await waitForGate()
        }
        return try await base.keys(store: store)
    }
    func has(store: String, key: String) async throws -> Bool { try await base.has(store: store, key: key) }
}
