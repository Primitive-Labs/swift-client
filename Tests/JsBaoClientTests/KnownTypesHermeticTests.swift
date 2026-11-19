import XCTest
@testable import JsBaoClient

/// The Swift client's known-type guard (#6024 behaviors 30, 31, 32, 34, 47).
///
/// With `registerDb3Types` turning the setting on, `create` refuses a type
/// the build was not generated with, or one archived in it, with
/// `.invalidArgument` (`details.reason` `unknown-type`) before anything is
/// created; `getOrCreateWithAlias` refuses an unknown type and sends an
/// archived one; `allowUnknownType` skips both. A stored copy of a type the
/// build does not know is listed `knownType == false`, its subscribe throws
/// `.db3TypeUnknownToClient` from the held type, and it is evicted as any
/// copy. Nothing registered, everything is as before.
///
/// Hermetic: clients over their own SQLite stores, with no server.
final class KnownTypesHermeticTests: XCTestCase {

    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    private func directory() throws -> String {
        let directory = NSTemporaryDirectory() + "/known-types-6024-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    /// A client signed in as `user-a` over the store in `directory`, with no
    /// server; its commits are counted and refused.
    private func client(_ directory: String, types: PrimitiveDb3Types?) async throws -> (JsBaoClient, LockedBox<Int>) {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "known-types-6024",
            token: makeTestJwt(userId: "user-a"),
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        if let types { client.registerDb3Types(types) }
        _ = await client.waitForStorageReady()
        client.registerModels([Self.note])
        let commits = LockedBox(0)
        client.documentManager.createRemoteDocument = { _ in
            commits.withValue { $0 += 1 }
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        return (client, commits)
    }

    private static let on = PrimitiveDb3Types(knownTypesOnly: true, types: [
        PrimitiveDb3Types.DeclaredType(name: "notes"),
        PrimitiveDb3Types.DeclaredType(name: "ledgers", archived: true),
    ])

    private func assertUnknownType(
        _ error: Error, type: String, archived: Bool = false, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let error = error as? JsBaoError else { return XCTFail("not a JsBaoError: \(error)", file: file, line: line) }
        XCTAssertEqual(error.code, .invalidArgument, file: file, line: line)
        XCTAssertEqual(error.details?["reason"], .string("unknown-type"), file: file, line: line)
        XCTAssertEqual(error.details?["type"], .string(type), file: file, line: line)
        XCTAssertEqual(error.details?["knownTypes"], .array([.string("notes")]), file: file, line: line)
        XCTAssertEqual(error.details?["archived"], archived ? .bool(true) : nil, file: file, line: line)
    }

    func testTheCodeIsAnErrorCode() {
        XCTAssertEqual(JsBaoErrorCode(rawValue: "DB3_TYPE_UNKNOWN_TO_CLIENT"), .db3TypeUnknownToClient)
    }

    // MARK: - Behavior 30

    func testCreateRefusesAnUnknownOrArchivedTypeBeforeAnythingIsCreated() async throws {
        let (client, commits) = try await client(try directory(), types: Self.on)
        for (type, archived) in [("undeclared", false), ("ledgers", true)] {
            do {
                _ = try await client.db3.create(title: "Nope", type: type)
                XCTFail("expected a refusal of \(type)")
            } catch {
                assertUnknownType(error, type: type, archived: archived)
            }
            do {
                _ = try await client.db3.create(title: "Nope", type: type, sync: false)
                XCTFail("expected a refusal of \(type)")
            } catch {
                assertUnknownType(error, type: type, archived: archived)
            }
        }
        let stored = try await client.db3.stored()
        XCTAssertEqual(stored, [])
        XCTAssertEqual(commits.value, 0)

        let escaped = try await client.db3.create(title: "Escaped", type: "undeclared", allowUnknownType: true)
        XCTAssertEqual(escaped.type, "undeclared")
        let known = try await client.db3.create(title: "Known", type: "notes")
        XCTAssertEqual(known.type, "notes")
        let untyped = try await client.db3.create(title: "Untyped")
        XCTAssertNil(untyped.type)
    }

    // MARK: - Behavior 31

    func testTheAliasCallRefusesAnUnknownTypeAndSendsAnArchivedOne() async throws {
        let (client, _) = try await client(try directory(), types: Self.on)
        let refused = RecordingTransport(status: 201, json: "{}")
        let api = Db3API(lifecycle: client._db3Lifecycle, transport: refused, client: client)
        let alias = AliasRef(scope: .user, aliasKey: "inbox", userId: "user-a")
        do {
            _ = try await api.getOrCreateWithAlias(Db3GetOrCreateWithAliasOptions(alias: alias, title: "Inbox", type: "undeclared"))
            XCTFail("expected a refusal")
        } catch {
            assertUnknownType(error, type: "undeclared")
        }
        XCTAssertNil(refused.lastCall, "nothing was sent")

        let reference = """
        {"id": "01JD6024AL1ASXXXXXXXXXXXXX", "created": false, "alias": {"aliasKey": "inbox", "scope": "user", "documentId": "01JD6024AL1ASXXXXXXXXXXXXX", "userId": "user-a"}}
        """
        let archived = RecordingTransport(status: 200, json: reference)
        _ = try await Db3API(lifecycle: client._db3Lifecycle, transport: archived, client: client)
            .getOrCreateWithAlias(Db3GetOrCreateWithAliasOptions(alias: alias, title: "Inbox", type: "ledgers"))
        XCTAssertEqual(archived.lastCall?.jsonBody?["type"], "ledgers")

        let escaped = RecordingTransport(status: 200, json: reference)
        var options = Db3GetOrCreateWithAliasOptions(alias: alias, title: "Inbox", type: "undeclared")
        options.allowUnknownType = true
        _ = try await Db3API(lifecycle: client._db3Lifecycle, transport: escaped, client: client).getOrCreateWithAlias(options)
        XCTAssertEqual(escaped.lastCall?.jsonBody?["type"], "undeclared")
        XCTAssertNil(escaped.lastCall?.jsonBody?["allowUnknownType"], "the option is never sent")
    }

    // MARK: - Behaviors 32 and 47

    func testAStoredCopyOfAnUnknownTypeIsListedRefusedAndEvicted() async throws {
        let directory = try directory()
        let (first, _) = try await client(directory, types: PrimitiveDb3Types(knownTypesOnly: true, types: []))
        let db3 = try await first.db3.create(title: "Escaped", type: "undeclared", allowUnknownType: true)
        var entry = try await first.db3.stored().first { $0.id == db3.id }
        XCTAssertEqual(entry?.knownType, false, "listed knownType == false after the escape too")
        XCTAssertEqual(entry?.type, "undeclared")
        await first.destroy()
        clients.removeAll { $0 === first }
        // The first launch's commit retry may still hold the store's file for a moment.
        try await Task.sleep(nanoseconds: 300_000_000)

        // Another launch of the same build: nothing was let in.
        let (second, _) = try await client(directory, types: PrimitiveDb3Types(knownTypesOnly: true, types: []))
        entry = try await second.db3.stored().first { $0.id == db3.id }
        XCTAssertEqual(entry?.knownType, false)
        XCTAssertEqual(entry?.type, "undeclared")
        XCTAssertEqual(entry?.resident, false)
        let subscription = try second.db3.subscribe(db3.id)
        do {
            try await subscription.ready()
            XCTFail("expected a refusal")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3TypeUnknownToClient)
            XCTAssertEqual(error.details?["db3Id"], .string(db3.id))
            XCTAssertEqual(error.details?["type"], .string("undeclared"))
        }
        let state = try await second.db3.state(db3.id)
        XCTAssertEqual(state.error?.code, "DB3_TYPE_UNKNOWN_TO_CLIENT")
        XCTAssertFalse(state.resident)

        // The subscribe option opens it (no refusal from the held type).
        let escaped = try second.db3.subscribe(db3.id, options: {
            var options = Db3SubscribeOptions(readyTimeout: 0.5)
            options.allowUnknownType = true
            return options
        }())
        do {
            try await escaped.ready()
        } catch let error as JsBaoError {
            XCTAssertNotEqual(error.code, .db3TypeUnknownToClient)
        }
        escaped.dispose()
        entry = try await second.db3.stored().first { $0.id == db3.id }
        XCTAssertEqual(entry?.knownType, false, "still knownType == false once the option opened it")

        try await second.db3.evict(db3.id, options: Db3EvictOptions(force: true))
        let left = try await second.db3.stored().map(\.id)
        XCTAssertFalse(left.contains(db3.id))

        let untyped = try await second.db3.create(title: "Untyped")
        let untypedEntry = try await second.db3.stored().first { $0.id == untyped.id }
        XCTAssertNotNil(untypedEntry)
        XCTAssertNil(untypedEntry?.knownType, "an untyped copy carries no knownType")
        XCTAssertNil(untypedEntry?.type)
    }

    func testABuildWithAnEmptyTypeListRefusesEveryTypedCreateAndCreatesUntyped() async throws {
        let (client, _) = try await client(try directory(), types: PrimitiveDb3Types(knownTypesOnly: true, types: []))
        do {
            _ = try await client.db3.create(title: "Typed", type: "notes")
            XCTFail("expected a refusal")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertEqual(error.details?["knownTypes"], .array([]))
        }
        let untyped = try await client.db3.create(title: "Untyped")
        XCTAssertNil(untyped.type)
    }

    // MARK: - Behavior 34 (pin)

    func testNothingRegisteredChangesNothing() async throws {
        let (client, _) = try await client(try directory(), types: nil)
        let typed = try await client.db3.create(title: "Any", type: "undeclared")
        XCTAssertEqual(typed.type, "undeclared")
        for entry in try await client.db3.stored() {
            XCTAssertNil(entry.knownType)
            XCTAssertNil(entry.type)
        }
        let (off, _) = try await self.client(try directory(), types: PrimitiveDb3Types(knownTypesOnly: false, types: []))
        let alsoTyped = try await off.db3.create(title: "Any", type: "undeclared")
        XCTAssertEqual(alsoTyped.type, "undeclared")
    }
}
