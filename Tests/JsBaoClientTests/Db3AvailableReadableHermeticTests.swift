import XCTest
import YSwift
@testable import JsBaoClient

/// #5044 — `available()` means a query answers: `Db3State.resident` is true
/// only for a store bound to this client, with its models attached, that
/// holds a readable copy.
///
/// - 5: over the lifecycle's deps, a stored copy that is not bound reads
///   `resident: false` in `state()` and `stored()` (its rows and cursor
///   unchanged), and true once bound; a subscribe's `available()` stays
///   pending until the open binds the store.
/// - 19: over a client with no server, a binding published but not yet
///   attached to the registered models reads not resident; once
///   `connectToSharedModels` ran it is resident and a scoped query answers.
final class Db3AvailableReadableHermeticTests: XCTestCase {

    private static let id = "01JD5044AVA1LAB1EXXXXXXXXX"

    /// What the client would answer: a copy the store holds, unbound until the
    /// open (held at `openGate`) binds it.
    final class World: @unchecked Sendable {
        private let lock = NSLock()
        var marks: Db3SyncMarks?
        var stored: RecordLogStoredState? = RecordLogStoredState(cursor: 4, rows: 2, writers: [], replacing: false, lastCatchUpAt: 1_000)
        var opens: [String] = []
        let openGate = RecordLogReceiptHarness.Gate()

        func with<T>(_ body: (World) -> T) -> T { lock.withLock { body(self) } }

        func bind() {
            with { $0.marks = Db3SyncMarks(cursor: 4, permission: nil, lastCatchUpAt: 1_000, replacing: false, staged: false) }
        }

        func deps() -> Db3LifecycleDeps {
            Db3LifecycleDeps(
                socketUp: { true },
                resolveFormat: { _ in 3 },
                open: { [self] id in
                    with { $0.opens.append(id) }
                    await openGate.wait()
                    bind()
                },
                isBound: { [self] _ in with { $0.marks != nil } },
                syncMarks: { [self] _ in with { $0.marks } },
                storedState: { [self] _ in with { $0.stored } },
                storedIds: { [self] in with { $0.stored == nil ? [] : [Db3AvailableReadableHermeticTests.id] } }
            )
        }
    }

    // MARK: - Behaviour 5

    func testAnUnboundStoredCopyIsNotResidentAndAvailableWaitsForTheBind() async throws {
        let world = World()
        let lifecycle = Db3Lifecycle(deps: world.deps())

        let unbound = try await lifecycle.state(Self.id)
        XCTAssertFalse(unbound.resident, "a stored copy no store of this client binds answers no query")
        XCTAssertEqual(unbound.rows, 2)
        XCTAssertEqual(unbound.cursor, 4)
        let listed = try await lifecycle.stored()
        XCTAssertEqual(listed.map(\.id), [Self.id])
        XCTAssertEqual(listed.first?.resident, false)
        XCTAssertEqual(listed.first?.rows, 2)
        XCTAssertEqual(listed.first?.cursor, 4)

        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(handle.availableResult, "available() waits while the open has not bound the store")
        let waiting = try await lifecycle.state(Self.id)
        XCTAssertFalse(waiting.resident)

        world.openGate.open()
        try await handle.available()
        let bound = try await lifecycle.state(Self.id)
        XCTAssertTrue(bound.resident)
        let listedBound = try await lifecycle.stored()
        XCTAssertEqual(listedBound.first?.resident, true)
        handle.dispose()
    }

    // MARK: - Behaviour 19

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )
    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    /// A client signed in as `user-a` over its own SQLite store, with no server.
    private func client() async throws -> JsBaoClient {
        let directory = NSTemporaryDirectory() + "/db3-available-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "db3-available-5044",
            token: makeTestJwt(userId: "user-a"),
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        client.registerModels([Self.note])
        return client
    }

    func testABindingNotYetAttachedToTheModelsIsNotResident() async throws {
        let client = try await client()
        client.documentManager.noteDocumentFormat(Self.id, RecordLogTransport.documentFormat)
        let binding = try await client.bindRecordLogDocument(Self.id)
        try binding.markCaughtUpAtCreate()
        XCTAssertTrue(binding.isResident, "the store holds a readable copy")

        XCTAssertNil(client.db3SyncMarks(Self.id), "no model reads the binding yet")
        let detached = try await client.db3.state(Self.id)
        XCTAssertFalse(detached.resident)
        XCTAssertThrowsError(try client.sharedModel(for: Self.note).query(nil, options: QueryOptions(db3: [Self.id]))) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .db3NotResident)
        }

        client.connectToSharedModels(documentId: Self.id, doc: YDocument())
        XCTAssertNotNil(client.db3SyncMarks(Self.id))
        let attached = try await client.db3.state(Self.id)
        XCTAssertTrue(attached.resident)
        XCTAssertEqual(try client.sharedModel(for: Self.note).query(nil, options: QueryOptions(db3: [Self.id])).count, 0)
    }
}
