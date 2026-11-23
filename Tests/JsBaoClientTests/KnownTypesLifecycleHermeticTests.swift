import JsBaoSQLite
import XCTest
@testable import JsBaoClient

/// The Swift lifecycle's known-type guard at start-up and at registration
/// (#6024 second-opinion findings 6024-C001, C002, C003, C007, C008).
///
/// - With the setting off, the lifecycle reads no held type: start-up
///   binding, `state` and `stored()` add no store read, and nothing is
///   awaited between start-up binding's user check and its bind.
/// - With it on, a user change while start-up binding reads a db3's type
///   stops the binding: the outgoing user's copy is not bound, and nothing
///   of the new user's is unbound.
/// - `registerDb3Types` after start-up bound a stored copy of a type the
///   build does not know refuses that copy: it is unbound and not resident,
///   and a subscription waiting on it hears that final state, then throws.
/// - A subscription made with `allowUnknownType` while a refusal is still
///   closing and unbinding the copy is kept, and its open runs.
/// - A store's stored state reads no type; the type is a read of its own,
///   made only by the guard.
///
/// Hermetic: lifecycles over stub deps, and clients over their own SQLite
/// stores, with no server.
final class KnownTypesLifecycleHermeticTests: XCTestCase {

    // MARK: - 6024-C001

    func testWithTheSettingOffNoHeldTypeIsRead() async throws {
        let reads = LockedBox(0)
        let bound = LockedBox<[String]>([])
        let lifecycle = Db3Lifecycle(deps: Db3LifecycleDeps(
            bind: { id in bound.withValue { $0.append(id) } },
            storedIds: { ["01JD6024OFF0000000000000AA"] },
            heldType: { _ in
                reads.withValue { $0 += 1 }
                return "undeclared"
            },
            knownTypesOnly: { false },
            typeOpens: { _, _ in false },
            isKnownType: { _ in false }
        ))
        await lifecycle.bindStored()
        _ = try await lifecycle.state("01JD6024OFF0000000000000AA")
        let stored = try await lifecycle.stored()
        XCTAssertEqual(bound.value, ["01JD6024OFF0000000000000AA"], "bound as before the guard existed")
        XCTAssertNil(stored.first?.knownType)
        XCTAssertEqual(reads.value, 0, "no held type is read with the setting off")
    }

    func testAUserChangeDuringTheTypeReadStopsStartUpBinding() async throws {
        let bound = LockedBox<[String]>([])
        let unbound = LockedBox<[String]>([])
        let lifecycleBox = LockedBox<Db3Lifecycle?>(nil)
        let lifecycle = Db3Lifecycle(deps: Db3LifecycleDeps(
            bind: { id in bound.withValue { $0.append(id) } },
            unbind: { id in unbound.withValue { $0.append(id) } },
            storedIds: { ["01JD6024SWAP000000000000AA"] },
            heldType: { _ in
                // Another user signs in while the type is read.
                lifecycleBox.value?.forgetStates()
                return "notes"
            },
            knownTypesOnly: { true },
            typeOpens: { _, _ in true },
            isKnownType: { _ in true }
        ))
        lifecycleBox.withValue { $0 = lifecycle }
        await lifecycle.bindStored()
        XCTAssertEqual(bound.value, [], "the outgoing user's copy is not bound")
        XCTAssertEqual(unbound.value, [], "nothing is unbound for the user who signed in")
    }

    // MARK: - 6024-C002 and C003

    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    private func directory() throws -> String {
        let directory = NSTemporaryDirectory() + "/known-types-lifecycle-6024-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    private func client(_ directory: String) async throws -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "known-types-lifecycle-6024",
            token: makeTestJwt(userId: "user-a"),
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        return client
    }

    func testRegisteringAfterStartUpBoundAnUnknownCopyRefusesIt() async throws {
        let directory = try directory()
        // A build without the setting stores a db3 of a type a later build does not know.
        let first = try await client(directory)
        let db3 = try await first.db3.create(title: "Other", type: "undeclared")
        await first.destroy()
        clients.removeAll { $0 === first }
        // The first launch's commit retry may still hold the store's file for a moment.
        try await Task.sleep(nanoseconds: 300_000_000)

        // The next launch binds stored copies before the app registers its types.
        let second = try await client(directory)
        let bindDeadline = Date().addingTimeInterval(5)
        while second.recordLogBinding(db3.id) == nil && Date() < bindDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(second.recordLogBinding(db3.id), "start-up bound the stored copy")

        // A subscription waiting on it (no server: it never opens).
        let subscription = try second.db3.subscribe(db3.id, options: Db3SubscribeOptions(readyTimeout: 30))
        let heard = LockedBox<[Db3State]>([])
        let observation = subscription.observe { event in
            if case .state(let state) = event { heard.withValue { $0.append(state) } }
        }
        defer { observation.cancel() }

        second.registerDb3Types(PrimitiveDb3Types(knownTypesOnly: true, types: [.init(name: "notes")]))

        do {
            try await subscription.ready()
            XCTFail("expected a refusal")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3TypeUnknownToClient)
            XCTAssertEqual(error.details?["type"], .string("undeclared"))
        }
        let unbindDeadline = Date().addingTimeInterval(5)
        while second.recordLogBinding(db3.id) != nil && Date() < unbindDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(second.recordLogBinding(db3.id), "the copy is unbound: no model or record reads it")
        let state = try await second.db3.state(db3.id)
        XCTAssertFalse(state.resident)
        XCTAssertEqual(state.error?.code, "DB3_TYPE_UNKNOWN_TO_CLIENT")

        // The subscription heard the final state before it was released.
        let last = try XCTUnwrap(heard.value.last, "the subscription heard a state")
        XCTAssertFalse(last.resident)
        XCTAssertEqual(last.error?.code, "DB3_TYPE_UNKNOWN_TO_CLIENT")

        // The copy is kept until evicted, and listed as unknown.
        let entry = try await second.db3.stored().first { $0.id == db3.id }
        XCTAssertEqual(entry?.knownType, false)
        XCTAssertEqual(entry?.type, "undeclared")
    }

    // MARK: - 6024-C007

    func testAnEscapedSubscriptionMadeDuringTheRefusalIsKeptAndOpens() async throws {
        let id = "01JD6024ESCAPE0000000000AA"
        let bound = LockedBox<Set<String>>([id])
        let allowed = LockedBox<Set<String>>([])
        let opens = LockedBox<[String]>([])
        let lifecycle = Db3Lifecycle(deps: Db3LifecycleDeps(
            resolveFormat: { _ in RecordLogTransport.documentFormat },
            open: { id in opens.withValue { $0.append(id) } },
            unbind: { id in
                // The refusal is still cleaning up when the app retries.
                try? await Task.sleep(nanoseconds: 100_000_000)
                bound.withValue { _ = $0.remove(id) }
            },
            isBound: { id in bound.value.contains(id) },
            heldType: { _ in "undeclared" },
            knownTypesOnly: { true },
            typeOpens: { id, _ in allowed.value.contains(id) },
            isKnownType: { _ in false },
            allowUnknownType: { id in allowed.withValue { _ = $0.insert(id) } }
        ))
        let first = try lifecycle.subscribe(id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        var escaped: Db3Subscription?
        do {
            try await first.ready()
            XCTFail("expected a refusal")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3TypeUnknownToClient)
            var options = Db3SubscribeOptions(readyTimeout: .infinity)
            options.allowUnknownType = true
            escaped = try lifecycle.subscribe(id, options: options)
        }
        XCTAssertNotNil(escaped)
        let deadline = Date().addingTimeInterval(5)
        while opens.value.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(opens.value, [id], "the escaped subscription's open ran")
        XCTAssertTrue(lifecycle.isSubscribed(id), "the escaped subscription is still attached")
        let state = try await lifecycle.state(id)
        XCTAssertNotEqual(state.error?.code, "DB3_TYPE_UNKNOWN_TO_CLIENT")
    }

    // MARK: - 6024-C008

    /// Every statement the provider's connection runs, with its bound values.
    private final class ExpandedTrace: @unchecked Sendable {
        let lock = NSLock()
        var statements: [String] = []
    }

    func testStoredStateReadsNoTypeAndTheTypeIsAReadOfItsOwn() async throws {
        let directory = try directory()
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let store = RecordLogStore(host: provider, documentId: "doc-6024", clientId: "client-1")
        try store.initialize()
        _ = try provider.withRecordLogConnection { connection in
            try connection.execute(
                "INSERT INTO record_log_meta (key, value) VALUES (?, ?)",
                [.text("db3_type:doc-6024"), .text(#"{"typed":"yes","name":"undeclared"}"#)]
            )
        }
        let trace = ExpandedTrace()
        let context = Unmanaged.passRetained(trace).toOpaque()
        defer { Unmanaged<ExpandedTrace>.fromOpaque(context).release() }
        _ = try provider.withRecordLogConnection { connection in
            sqlite3_trace_v2(connection.rawHandle, UInt32(SQLITE_TRACE_STMT), { _, context, statement, _ in
                guard let context, let statement, let expanded = sqlite3_expanded_sql(OpaquePointer(statement)) else { return 0 }
                defer { sqlite3_free(expanded) }
                let trace = Unmanaged<ExpandedTrace>.fromOpaque(context).takeUnretainedValue()
                let text = String(cString: expanded)
                trace.lock.withLock { trace.statements.append(text) }
                return 0
            }, context)
        }
        _ = try store.storedState()
        let stateReads = trace.lock.withLock { trace.statements }
        trace.lock.withLock { trace.statements = [] }
        let type = try store.storedTypeName()
        let typeReads = trace.lock.withLock { trace.statements }
        _ = try provider.withRecordLogConnection { sqlite3_trace_v2($0.rawHandle, 0, nil, nil) }

        XCTAssertFalse(stateReads.isEmpty, "the trace saw the stored state's reads")
        XCTAssertFalse(stateReads.contains { $0.contains("db3_type:") }, "the stored state reads no type: \(stateReads)")
        XCTAssertEqual(type, "undeclared")
        XCTAssertTrue(typeReads.contains { $0.contains("db3_type:doc-6024") }, "\(typeReads)")
    }
}
