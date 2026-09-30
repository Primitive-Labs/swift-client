import XCTest
@testable import JsBaoClient
import SQLite3
import YSwift

/// Reopening a large document through the client's public open and model
/// binding folds what changed, and nothing when nothing did (#3782,
/// behaviors 19 and 19a).
///
/// A document whose local row says format 2 is bound at OPEN, before any frame
/// from the room, over the overlay the client persisted. The bind used to fold
/// every registered model's whole overlay there, and each model registration
/// could fold its model whole again. Now the bind compares the overlay's state
/// vector with the store's folded state: equal, and every model covered, it
/// folds nothing and seeds the observer so a registration folds nothing
/// either; a model the state never covered is caught up alone; a vector that
/// differs is caught up whole and re-stamped.
///
/// "Store writes" are counted by SQLite itself — an update hook on the
/// provider's one connection — so a write that went around any wrapper the
/// library has is still seen. The key-value table the client keeps its own
/// metadata in is not the store and is left out.
final class Format2ReopenFoldHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let note = PrimitiveSchema(
        name: "Note",
        fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )
    private static let task = PrimitiveSchema(
        name: "Task",
        fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "/f2-reopen-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    private func makeClient(path: String, schemas: [PrimitiveSchema]) async -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: "ws://127.0.0.1:1",
            appId: "format2-reopen-test-app",
            token: makeTestJwt(userId: "format2-reopen-user"),
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .sqlite(directory: path),
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
        _ = await client.waitForStorageReady()
        client.registerModels(schemas)
        return client
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: @escaping () throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? condition()) == true { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(description)")
    }

    /// Open `documentId` as a large document the local row already knows.
    private func open(
        _ client: JsBaoClient, _ documentId: String
    ) async throws -> Format2DocumentBinding {
        client.documentManager.createRemoteDocument = { (_: [String: Any]) in
            ["documentId": documentId]
        }
        if client.documentManager.getLocalMetadata(documentId) == nil {
            _ = try await client.documentManager.createLocalDocument(
                documentId: documentId, title: "reopen", localOnly: false, documentFormat: 2
            )
        }
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        return try XCTUnwrap(client.format2?.binding(documentId))
    }

    /// Records written into the overlay by a later writer, as one update.
    private func remoteWrite(
        _ binding: Format2DocumentBinding, model: String = "Note", ids: [String]
    ) throws {
        let peer = OverlayDocument()
        try peer.applyUpdate(binding.overlay.encodeStateAsUpdate())
        for id in ids {
            peer.apply(
                OverlayMutation(id: id, kind: .create, fields: ["title": .string(id)]),
                model: model
            )
        }
        try binding.overlay.applyUpdate(peer.encodeStateAsUpdate())
    }

    /// A first session: records folded, the fold stamped, the document closed.
    private func firstSession(
        path: String, documentId: String, ids: [String]
    ) async throws {
        let client = await makeClient(path: path, schemas: [Self.note])
        let binding = try await open(client, documentId)
        try remoteWrite(binding, ids: ids)
        try await waitFor("the fold to stamp the overlay's vector") {
            let pending = binding.observer.pendingKeyCount
            let stamped = try binding.store.foldedState()?.vector
            return pending == 0 && stamped == binding.overlay.stateVector()
        }
        _ = await client.closeDocument(documentId)
        await client.destroy()
    }

    /// The tables SQLite saw written during `run`, the key-value table aside.
    private func storeWrites(
        _ client: JsBaoClient, during run: () async throws -> Void
    ) async throws -> [String] {
        let stored = await client.documentManager.offlineStore?.getStorageProvider()
        let provider = try XCTUnwrap(stored as? SQLiteStorageProvider)
        let log = WriteLog()
        let context = Unmanaged.passRetained(log).toOpaque()
        _ = try provider.withRawConnection { db in
            sqlite3_update_hook(db, { context, _, _, table, _ in
                guard let context, let table else { return }
                Unmanaged<WriteLog>.fromOpaque(context).takeUnretainedValue()
                    .append(String(cString: table))
            }, context)
        }
        defer {
            try? provider.withRawConnection { db in _ = sqlite3_update_hook(db, nil, nil) }
            Unmanaged<WriteLog>.fromOpaque(context).release()
        }
        try await run()
        return log.tables.filter { $0 != "kv_store" }
    }

    // MARK: - Behavior 19 — an unchanged overlay, through the public path

    func testAReopenWhoseOverlayIsUnchangedFoldsAndWritesNothing() async throws {
        let path = newDatabasePath()
        let documentId = "reopen-unchanged"
        try await firstSession(path: path, documentId: documentId, ids: ["a", "b", "c"])

        let second = await makeClient(path: path, schemas: [Self.note])
        defer { Task { await second.destroy() } }
        var binding: Format2DocumentBinding?
        let writes = try await storeWrites(second) {
            binding = try await open(second, documentId)
        }
        let bound = try XCTUnwrap(binding)
        XCTAssertEqual(bound.observer.foldCount, 0, "the bind folded the overlay again")
        XCTAssertEqual(writes, [], "the reopen wrote to the store: \(writes)")
        XCTAssertTrue(bound.observer.hasCaughtUp("Note"), "a registration would fold it whole")
        XCTAssertEqual(try bound.store.read(model: "Note", recordId: "b")?["title"], .string("b"))
        XCTAssertEqual(try bound.store.readAll(model: "Note").count, 3)
    }

    func testAModelTheStampNeverCoveredIsCaughtUpAlone() async throws {
        let path = newDatabasePath()
        let documentId = "reopen-new-model"
        try await firstSession(path: path, documentId: documentId, ids: ["a"])

        let second = await makeClient(path: path, schemas: [Self.note, Self.task])
        defer { Task { await second.destroy() } }
        let binding = try await open(second, documentId)
        XCTAssertEqual(binding.observer.foldCount, 1)
        XCTAssertEqual(binding.observer.lastCatchUpModels, ["Task"])
        XCTAssertEqual(
            Set(try XCTUnwrap(try binding.store.foldedState()).models), ["Note", "Task"]
        )
    }

    // MARK: - Behavior 19a — after the bind, and a crash before it

    func testANetworkUpdateAfterTheReopenFoldsOnlyItsRecords() async throws {
        let path = newDatabasePath()
        let documentId = "reopen-then-update"
        try await firstSession(path: path, documentId: documentId, ids: ["a", "b"])

        let second = await makeClient(path: path, schemas: [Self.note])
        defer { Task { await second.destroy() } }
        let binding = try await open(second, documentId)
        XCTAssertEqual(binding.observer.foldCount, 0)

        let writes = try await storeWrites(second) {
            try remoteWrite(binding, ids: ["z"])
            try await waitFor("the update's fold") {
                let pending = binding.observer.pendingKeyCount
                let row = try binding.store.read(model: "Note", recordId: "z")
                return pending == 0 && row != nil
            }
        }
        XCTAssertNil(binding.observer.lastCatchUpModels, "no whole catch-up ran")
        XCTAssertEqual(binding.observer.foldCount, 1, "one drain, for the update")
        let recordTable = writes.filter { $0.hasPrefix("records_f2_") }
        XCTAssertEqual(recordTable.count, 1, "only the update's record was folded: \(writes)")
        XCTAssertEqual(try binding.store.foldedState()?.vector, binding.overlay.stateVector())
    }

    /// The window a crash can leave: the Y.Doc persisted with an update whose
    /// fold never committed. The overlay's vector then differs from the
    /// stamp, and the next bind catches the whole overlay up.
    func testACrashBetweenThePersistAndTheFoldIsRepairedByAWholeCatchUp() async throws {
        let path = newDatabasePath()
        let documentId = "reopen-crash-window"
        try await firstSession(path: path, documentId: documentId, ids: ["a"])

        // Stage it: the persisted overlay gains a record the store never saw.
        let staging = await makeClient(path: path, schemas: [Self.note])
        let stagingStore = await staging.documentManager.offlineStore?.getStorageProvider()
        let provider = try XCTUnwrap(stagingStore)
        let persistence = YjsSQLitePersistence(storageProvider: provider, documentId: documentId)
        let loaded = try await persistence.loadDocument()
        let persisted = try XCTUnwrap(loaded)
        let overlay = OverlayDocument()
        try overlay.applyUpdate(Array(persisted))
        let peer = OverlayDocument()
        try peer.applyUpdate(overlay.encodeStateAsUpdate())
        peer.apply(
            OverlayMutation(id: "lost", kind: .create, fields: ["title": .string("lost")]),
            model: "Note"
        )
        try overlay.applyUpdate(peer.encodeStateAsUpdate())
        try await persistence.saveDocument(data: Data(overlay.encodeStateAsUpdate()))
        await staging.destroy()

        let third = await makeClient(path: path, schemas: [Self.note])
        defer { Task { await third.destroy() } }
        let binding = try await open(third, documentId)
        XCTAssertEqual(binding.observer.lastCatchUpModels, ["Note"], "the whole catch-up ran")
        XCTAssertEqual(try binding.store.read(model: "Note", recordId: "lost")?["title"], .string("lost"))
        XCTAssertEqual(try binding.store.foldedState()?.vector, binding.overlay.stateVector())
    }

    // MARK: - A broken fold still repairs whole

    func testAFoldBrokenBindingStillCatchesUpWhole() async throws {
        let directory = NSTemporaryDirectory() + "/f2-reopen-broken-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let failing = FailingSqlHost(wrapped: provider)
        let coordinator = Format2Coordinator(host: failing, clientId: "me", logger: Logger(level: .none))
        let binding = try coordinator.bind(documentId: "d", models: ["Note"])
        _ = try binding.writePath.withOperation { try binding.catchUpAtBind() }
        // The fault is armed BEFORE the update lands: the binding's own fold
        // queue may drain it first, and either drain has to be the one that
        // fails.
        failing.failStatementsContaining = "INSERT INTO records_f2_"
        try remoteWrite(binding, ids: ["x"])
        try await waitFor("the fold to break") {
            if !binding.observer.isFoldBroken {
                _ = try? binding.writePath.withOperation { try binding.observer.drain() }
            }
            return binding.observer.isFoldBroken
        }
        failing.failStatementsContaining = nil
        XCTAssertTrue(binding.observer.isFoldBroken)

        let decided = try binding.writePath.withOperation { try binding.catchUpAtBind() }
        XCTAssertEqual(decided, .whole(["Note"]))
        XCTAssertFalse(binding.observer.isFoldBroken, "the whole catch-up is the repair")
        XCTAssertEqual(try binding.store.read(model: "Note", recordId: "x")?["title"], .string("x"))
    }
}

/// What the update hook saw, appended from the provider's queue.
private final class WriteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var written: [String] = []
    func append(_ table: String) { lock.withLock { written.append(table) } }
    var tables: [String] { lock.withLock { written } }
}
