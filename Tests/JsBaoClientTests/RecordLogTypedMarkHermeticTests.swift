import XCTest
@testable import JsBaoClient

/// #5020 behavior 13, E4, E5, E10 and E13 (the Swift halves) — the twin of
/// js-bao's `record-log-client-typed-mark-5020` suite.
///
/// The store keeps what the room said of the db3's type: `unknown` until a
/// `record.opened` answered on this device, then untyped, or typed with the
/// name, the revision hash and the declarations. A client's session
/// (`waitsForTypeBeforeDeclaring`) sends no declaration ahead of an open on an
/// unknown store, and none at all while the store is typed, telling the
/// `declared` hook once per open; the open carries `db3TypeHash` when it holds
/// declarations. The typed refusal marks the store at debug. A db3 created
/// here with a type is seeded typed.
final class RecordLogTypedMarkHermeticTests: XCTestCase {
    typealias H = RecordLogReceiptHarness

    private var directories: [String] = []
    private var clients: [JsBaoClient] = []
    private var lines = H.Lines()

    override func setUp() {
        super.setUp()
        let lines = H.Lines()
        self.lines = lines
        Logger.lineForTest = { level, _, message in
            if message.contains(H.documentId) { lines.append(level, message) }
        }
    }

    override func tearDown() async throws {
        Logger.lineForTest = nil
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    private struct Fixture {
        let provider: SQLiteStorageProvider
        let binding: RecordLogDocumentBinding
        let session: RecordLogSession
        let connection: H.Connection
        let declared: LockedBox<Int>
        let synced: LockedBox<Int>
        let failed: LockedBox<[String]>

        func feed(_ frame: [String: JSONValue]) async {
            var frame = frame
            frame["documentId"] = .string(H.documentId)
            await session.receive(frame)
        }

        func types(from: Int = 0) -> [String] {
            connection.frames.dropFirst(from).compactMap { $0["type"]?.stringValue }
        }

        /// A new connection's first open; answers where its frames start.
        func reconnect() async -> Int {
            await session.disconnected()
            let at = connection.frames.count
            await session.start()
            return at
        }

        func save(_ id: String) throws {
            _ = try binding.commit([RecordLogWrite(mutations: [
                RecordLogMutation(model: "Note", id: id, kind: .create, fields: ["title": "t"]),
            ])])
            try binding.store.flush()
        }
    }

    private func fixture(provider given: SQLiteStorageProvider? = nil, awaitType: Bool = true) async throws -> Fixture {
        let provider: SQLiteStorageProvider
        if let given {
            provider = given
        } else {
            let directory = NSTemporaryDirectory() + "/record-log-typed-mark-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            directories.append(directory)
            provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
            try await provider.initialize(namespace: "test")
        }
        let binding = try RecordLogDocumentBinding(host: provider, documentId: H.documentId, clientId: "client-a", logger: Logger(level: .none))
        try binding.registerModel(H.schema)
        let connection = H.Connection(fetches: false)
        let declared = LockedBox(0)
        let synced = LockedBox(0)
        let failed = LockedBox<[String]>([])
        let session = RecordLogSession(
            documentId: H.documentId, binding: binding,
            host: RecordLogSessionHost(
                connection: { connection },
                declarations: { ["Note": .object(["fields": .object(["title": .object(["type": "string"])])])] },
                synced: { _ in synced.withValue { $0 += 1 } },
                syncFailed: { _, reason in failed.withValue { $0.append(reason) } },
                declared: { _ in declared.withValue { $0 += 1 } },
                waitsForTypeBeforeDeclaring: awaitType
            ),
            timings: H.timings, logger: Logger(level: .verbose)
        )
        await session.attach()
        return Fixture(
            provider: provider, binding: binding, session: session, connection: connection, declared: declared, synced: synced,
            failed: failed
        )
    }

    private func until(
        _ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for: \(what)", file: file, line: line)
    }

    private static let models: JSONValue = ["Note": ["title": "string", "closedAt": "date"], "Draft": .object([:])]
    private static let declarations = ["Note": ["title": "string", "closedAt": "date"], "Draft": [:]]

    private static func opened(_ db3Type: JSONValue? = nil) -> [String: JSONValue] {
        var frame = H.opened(lsn: 0)
        if let db3Type { frame["db3Type"] = db3Type }
        return frame
    }

    private static let typed: JSONValue = ["name": "notes", "hash": "h1", "models": models]

    private let typedRefusal: [String: JSONValue] = [
        "type": "error", "messageType": "record.declare", "code": "DB3_DECLARATION_REFUSED_TYPED", "db3Type": "notes",
        "message": "This db3 is typed by notes: its type declares its models, and nothing was declared",
    ]

    // MARK: - The mark (behavior 8's twin, E4, E5)

    func testAFreshStoreIsUnknownAndATypedOpenedIsHeldAcrossAReopenOfTheStore() async throws {
        let f = try await fixture()
        XCTAssertEqual(f.binding.marks.typed, .unknown)
        XCTAssertNil(f.binding.declaredType)
        await f.session.start()
        await f.feed(Self.opened(Self.typed))
        await until("open") { f.synced.value == 1 }
        let marks = try f.binding.refreshMarks()
        XCTAssertEqual(marks.typed, .yes)
        XCTAssertEqual(marks.db3Type, RecordLogDb3Type(name: "notes", hash: "h1"))
        XCTAssertEqual(f.binding.declaredType?.models, Self.declarations)
        XCTAssertEqual(f.binding.declaredType?.name, "notes")
        let again = try RecordLogDocumentBinding(host: f.provider, documentId: H.documentId, clientId: "client-a", logger: Logger(level: .none))
        XCTAssertEqual(try again.refreshMarks().typed, .yes)
        XCTAssertEqual(again.declaredType?.models, Self.declarations)
    }

    func testTheHeldDeclarationsAreKeptForTheirHashAndReplacedForAnother() async throws {
        let f = try await fixture()
        await f.session.start()
        await f.feed(Self.opened(Self.typed))
        await until("open") { f.synced.value == 1 }
        let at = await f.reconnect()
        XCTAssertEqual(f.connection.frames[at]["db3TypeHash"]?.stringValue, "h1")
        await f.feed(Self.opened(["name": "notes", "hash": "h1"]))
        await until("second open") { f.synced.value == 2 }
        XCTAssertEqual(f.binding.declaredType?.models, Self.declarations)
        _ = await f.reconnect()
        await f.feed(Self.opened(["name": "notes", "hash": "h2", "models": ["Note": ["title": "string"]]]))
        await until("third open") { f.synced.value == 3 }
        XCTAssertEqual(try f.binding.refreshMarks().db3Type, RecordLogDb3Type(name: "notes", hash: "h2"))
        XCTAssertEqual(f.binding.declaredType?.models, ["Note": ["title": "string"]])
    }

    func testAnOpenedWithoutDb3TypeMarksTheStoreUntypedAndTheOpenDeclares() async throws {
        let f = try await fixture()
        await f.session.start()
        await f.feed(Self.opened(Self.typed))
        await until("open") { f.synced.value == 1 }
        let at = await f.reconnect()
        XCTAssertEqual(f.types(from: at), ["record.open"])
        await f.feed(Self.opened())
        await until("second open") { f.synced.value == 2 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(try f.binding.refreshMarks().typed, .no)
        XCTAssertNil(f.binding.declaredType)
        XCTAssertEqual(f.types(from: at).filter { $0 == "record.declare" }.count, 1)
    }

    func testAMalformedDb3TypeLeavesTheMarksAndTheOpenProceeds() async throws {
        let malformed: [JSONValue] = [
            "notes", ["hash": "h1"], ["name": "notes"], ["name": "notes", "hash": "h1", "models": "Note"],
            ["name": "notes", "hash": "h1", "models": ["Note": "string"]],
        ]
        for bad in malformed {
            let f = try await fixture()
            await f.session.start()
            await f.feed(Self.opened(bad))
            await until("open") { f.synced.value == 1 }
            XCTAssertEqual(try f.binding.refreshMarks().typed, .unknown, "\(bad)")
            XCTAssertNil(f.binding.declaredType)
        }
    }

    // MARK: - No declaration to a typed db3 (behavior 9's twin, E9)

    func testAnUnknownStoreSendsNoDeclarationAheadAndOneAfterAnUntypedOpened() async throws {
        let f = try await fixture()
        try f.save("n1")
        await f.session.start()
        XCTAssertEqual(f.types(), ["record.open"])
        XCTAssertNil(f.connection.frames[0]["db3TypeHash"])
        await f.feed(Self.opened())
        await until("entries") { f.types().contains("record.entries") }
        XCTAssertEqual(f.types(), ["record.open", "record.declare", "record.entries"])
    }

    func testAnUnknownStoreWhoseOpenedSaysTypedNeverDeclaresAndTellsDeclaredOnce() async throws {
        let f = try await fixture()
        try f.save("n1")
        await f.session.start()
        await f.feed(Self.opened(Self.typed))
        await until("entries") { f.types().contains("record.entries") }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(f.connection.all("record.declare").count, 0)
        XCTAssertEqual(f.declared.value, 1)
    }

    func testATypedStoreCarriesItsHashAndDeclaresOnNoOpen() async throws {
        let f = try await fixture()
        await f.session.start()
        await f.feed(Self.opened(Self.typed))
        await until("open") { f.synced.value == 1 }
        XCTAssertEqual(f.declared.value, 1)
        try f.save("n1")
        let at = await f.reconnect()
        XCTAssertEqual(f.types(from: at), ["record.open", "record.entries"])
        XCTAssertEqual(f.connection.frames[at]["db3TypeHash"]?.stringValue, "h1")
        await f.feed(Self.opened(["name": "notes", "hash": "h1"]))
        await until("second open") { f.synced.value == 2 }
        // A model registered after the open is not declared.
        try f.binding.registerModel(PrimitiveSchema(name: "Draft", fields: ["id": FieldDescriptor(type: .id)]))
        await f.session.declare()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(f.connection.all("record.declare").count, 0)
        XCTAssertEqual(f.declared.value, 2)
        XCTAssertEqual(f.failed.value, [])
    }

    func testAnUntypedStoreStillDeclaresAheadOfANewConnectionsFirstOpen() async throws {
        let f = try await fixture()
        await f.session.start()
        await f.feed(Self.opened())
        await until("open") { f.synced.value == 1 }
        let at = await f.reconnect()
        XCTAssertEqual(f.types(from: at), ["record.open", "record.declare"])
    }

    func testASessionThatDoesNotWaitForTheTypeDeclaresAheadAsBefore() async throws {
        let f = try await fixture(awaitType: false)
        await f.session.start()
        XCTAssertEqual(f.types(), ["record.open", "record.declare"])
    }

    // MARK: - The typed refusal (behavior 10's twin, E13)

    func testATypedRefusalMarksTheStoreTellsDeclaredOnceAndLogsAtDebug() async throws {
        let f = try await fixture()
        await f.session.start()
        await f.feed(Self.opened())
        await until("open") { f.synced.value == 1 }
        await until("declared") { f.connection.all("record.declare").count == 1 }
        await f.feed(typedRefusal)
        await until("declared hook") { f.declared.value == 1 }
        XCTAssertEqual(try f.binding.refreshMarks().typed, .yes)
        XCTAssertEqual(try f.binding.refreshMarks().db3Type, RecordLogDb3Type(name: "notes", hash: nil))
        XCTAssertEqual(f.failed.value, [])
        XCTAssertFalse(lines.messages(.warn).contains { $0.contains("typed by") })
        XCTAssertTrue(lines.messages(.debug).contains { $0.contains("typed by notes") })
        let at = await f.reconnect()
        XCTAssertEqual(f.types(from: at), ["record.open"])
        XCTAssertNil(f.connection.frames[at]["db3TypeHash"])
    }

    // MARK: - The create seeds the mark (E10)

    private static let db3Id = "01JD5020SEEDSW1FTXXXXXXXXX"

    func testADb3CreatedHereWithATypeIsSeededTypedAndOneWithoutIsNot() async throws {
        let directory = NSTemporaryDirectory() + "/db3-typed-seed-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "db3-typed-seed-5020",
            token: makeTestJwt(userId: "user-a"), logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"), autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        await client.goOffline()
        client.registerModels([H.schema])
        let typed = try await client.db3.create(title: "Typed", type: "notes")
        let typedMarks = try XCTUnwrap(client.recordLogBinding(typed.id)).refreshMarks()
        XCTAssertEqual(typedMarks.typed, .yes)
        XCTAssertEqual(typedMarks.db3Type, RecordLogDb3Type(name: "notes", hash: nil))
        let plain = try await client.db3.create(title: "Plain")
        XCTAssertEqual(try XCTUnwrap(client.recordLogBinding(plain.id)).refreshMarks().typed, .unknown)

        let adopted = RecordingTransport(status: 201, json: """
        {"id": "\(Self.db3Id)", "title": "Orders", "createdBy": "user-a", "createdAt": "2026-10-26T00:00:00.000Z",
         "modifiedAt": "2026-10-26T00:00:00.000Z", "custodian": "user:user-a", "sync": true, "type": "orders", "tags": []}
        """)
        _ = try await Db3API(lifecycle: client._db3Lifecycle, transport: adopted, client: client)
            .create(title: "Orders", type: "orders", custodian: "user:user-a")
        let adoptedMarks = try XCTUnwrap(client.recordLogBinding(Self.db3Id)).refreshMarks()
        XCTAssertEqual(adoptedMarks.typed, .yes)
        XCTAssertEqual(adoptedMarks.db3Type, RecordLogDb3Type(name: "orders", hash: nil))
    }
}
