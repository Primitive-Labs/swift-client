import XCTest
@testable import JsBaoClient

/// #4942 behaviors 7–10, edge cases E1, E3 and E4 — a generated model's db3
/// writes through `client.codegen`, with no server.
///
/// The db3 is adopted from a `POST db3` answer (the #4806 world), so it is
/// resident at once and every write stays in this device's store: what is
/// checked here is the local view, the facade's error routing and the
/// format-1 pass-through. What the room judges is in
/// `CodegenDb3WritesLiveTests`.
final class CodegenDb3WritesHermeticTests: XCTestCase {

    private static let db3Id = "01JD4942C0DEGENXXXXXXXXXXX"
    private static let otherDb3Id = "01JD4942C0DEGENYYYYYYYYYYY"
    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        Logger.lineForTest = nil
        JsBaoClient.clearDefault()
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    private func directory() throws -> String {
        let directory = NSTemporaryDirectory() + "/codegen-db3-writes-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    /// A client over its own SQLite store with no server, `TaskRecord`
    /// registered and configured as the default client.
    private func client(logLevel: LogLevel = .none) async throws -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "codegen-db3-writes-4942",
            token: makeTestJwt(userId: "user-a"),
            logLevel: logLevel,
            storageConfig: .sqlite(directory: try directory() + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        client.registerModels([TaskRecord.self])
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        JsBaoClient.configureDefault(client)
        return client
    }

    /// A client holding the db3 `db3Id`, adopted from its create answer.
    private func db3Client() async throws -> JsBaoClient {
        let client = try await client()
        let answer = """
        {"id": "\(Self.db3Id)", "title": "Tasks", "createdBy": "user-a", "createdAt": "2026-10-27T00:00:00.000Z",
         "modifiedAt": "2026-10-27T00:00:00.000Z", "custodian": "user:user-a", "sync": true, "type": null, "tags": []}
        """
        let transport = RecordingTransport(status: 201, json: answer)
        // Request-first (it names the custodian), so the db3 is adopted from the
        // answer; since #5000 a create naming none is a pending create.
        _ = try await Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
            .create(title: "Tasks", custodian: "user:user-a")
        XCTAssertTrue(try XCTUnwrap(client.recordLogBinding(Self.db3Id)).isResident)
        return client
    }

    /// A client with an open format-1 document.
    private func format1Client() async throws -> (JsBaoClient, String) {
        let client = try await client(logLevel: .warn)
        let created = try await client.createDocument(options: CreateDocumentOptions(title: "plain"))
        let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        _ = try await client.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false))
        return (client, documentId)
    }

    private func pendingWrites(_ client: JsBaoClient) async throws -> Int {
        try await client.db3.state(Self.db3Id).pendingWrites
    }

    private func ids() throws -> [String] {
        try TaskRecord.query(options: QueryOptions(db3: [Self.db3Id])).map(\.id).sorted()
    }

    /// What a write did: the values it answered, or the code it was refused with.
    private func outcome(_ body: () async throws -> [String: Double]) async -> String {
        do {
            let values = try await body()
            return "values \(values.sorted { $0.key < $1.key })"
        } catch let error as JsBaoError {
            return "refused \(error.code.rawValue)"
        } catch {
            return "error \(error)"
        }
    }

    private func refusal(_ body: () async throws -> Void) async -> JsBaoError? {
        do {
            try await body()
            return nil
        } catch let error as JsBaoError {
            return error
        } catch {
            XCTFail("not a JsBaoError: \(error)")
            return nil
        }
    }

    // MARK: - Behavior 7

    func testAnIncrementAnswersTheSumAndTheViewShowsItAtOnce() async throws {
        let client = try await db3Client()
        try TaskRecord(id: "t1", title: "Count", priority: 3).save(in: Self.db3Id)
        let values = try await TaskRecord.increment(id: "t1", fields: ["priority": 2], in: Self.db3Id)
        XCTAssertEqual(values, ["priority": 5])
        XCTAssertEqual(try TaskRecord.find("t1")?.priority, 5, "an unguarded increment is not held")
        let pending = try await pendingWrites(client)
        XCTAssertEqual(pending, 2)
    }

    func testAnIncrementOfARecordTheViewDoesNotHoldIsRefusedAndSendsNothing() async throws {
        let client = try await db3Client()
        try TaskRecord(id: "t1", title: "Count", priority: 3).save(in: Self.db3Id)
        let error = await refusal { _ = try await TaskRecord.increment(id: "missing", fields: ["priority": 1], in: Self.db3Id) }
        XCTAssertEqual(error?.code, .db3RecordNotFound)
        let pending = try await pendingWrites(client)
        XCTAssertEqual(pending, 1, "only the save is pending")
        XCTAssertEqual(try ids(), ["t1"])
        XCTAssertEqual(try TaskRecord.find("t1")?.priority, 3)
    }

    func testAnIfNotExistsSaveIsPendingAndHeldOutOfTheView() async throws {
        let client = try await db3Client()
        let returned = try await TaskRecord(id: "free", title: "Standup").save(in: Self.db3Id, options: Db3WriteOptions(ifNotExists: true))
        XCTAssertEqual(returned.id, "free")
        XCTAssertEqual(returned.title, "Standup")
        let pending = try await pendingWrites(client)
        XCTAssertEqual(pending, 1)
        XCTAssertNil(try TaskRecord.find("free"), "a guarded guess is held until the room acknowledges it")
        XCTAssertEqual(try ids(), [])

        // An id the auto-id initializer minted is held the same way.
        let minted = TaskRecord(title: "Minted")
        _ = try await minted.save(in: Self.db3Id, options: Db3WriteOptions(ifNotExists: true))
        let pendingAfter = try await pendingWrites(client)
        XCTAssertEqual(pendingAfter, 2)
        XCTAssertNil(try TaskRecord.find(minted.id))
        XCTAssertEqual(try ids(), [])
    }

    // MARK: - Edge case E1: a guarded save without confirm answers what the view shows

    func testAConditionalSaveWithoutConfirmAnswersTheRowTheViewStillShows() async throws {
        let client = try await db3Client()
        var task = try TaskRecord(id: "t1", title: "Claim me", priority: 1).save(in: Self.db3Id)
        task.priority = 5
        let returned = try await task.save(in: Self.db3Id, options: Db3WriteOptions(condition: ["priority": 1]))
        XCTAssertEqual(returned.priority, 1, "the guess is held, so the pre-write row comes back")
        XCTAssertTrue(returned._changedFields.isEmpty)
        XCTAssertEqual(try TaskRecord.find("t1")?.priority, 1)
        let pending = try await pendingWrites(client)
        XCTAssertEqual(pending, 2)
    }

    // MARK: - Edge case E3: no guards deletes as delete(in:)

    func testADeleteWithNoGuardsDeletesAtOnce() async throws {
        _ = try await db3Client()
        let task = try TaskRecord(id: "t1", title: "Gone").save(in: Self.db3Id)
        try await task.delete(in: Self.db3Id, options: Db3WriteOptions())
        XCTAssertNil(try TaskRecord.find("t1"))
        XCTAssertEqual(try ids(), [])
    }

    // MARK: - Edge case E4: the facade adds and removes no refusal

    func testTheFacadePassesAnEmptyIncrementAndAStringFieldThroughUnchanged() async throws {
        let client = try await db3Client()
        for id in ["via-facade", "direct"] { try TaskRecord(id: id, title: "Same", priority: 1).save(in: Self.db3Id) }
        let member = try XCTUnwrap(client.sharedModel("tasks")?.member(docId: Self.db3Id))
        for fields in [[:], ["title": 1]] as [[String: Double]] {
            let viaFacade = await outcome { try await TaskRecord.increment(id: "via-facade", fields: fields, in: Self.db3Id) }
            let direct = await outcome { try await member.increment(id: "direct", fields: fields) }
            XCTAssertEqual(viaFacade, direct, "fields \(fields)")
        }
    }

    // MARK: - Behavior 8: format 1

    func testOnAFormat1DocumentTheGuardsAreIgnoredAndIncrementIsRefused() async throws {
        let warnings = LockedBox<[String]>([])
        Logger.lineForTest = { level, _, message in
            if level == .warn, message.contains("is deprecated: records belong in a db3") { warnings.withValue { $0.append(message) } }
        }
        let (_, documentId) = try await format1Client()
        let saved = try await TaskRecord(id: "f1", title: "one", priority: 1)
            .save(in: documentId, options: Db3WriteOptions(condition: ["title": "nope"], confirm: true))
        XCTAssertEqual(saved.title, "one")
        XCTAssertEqual(try TaskRecord.find("f1")?.title, "one")
        XCTAssertEqual(warnings.value, ["saving `tasks` into format-1 document \(documentId) is deprecated: records belong in a db3"])

        let error = await refusal { _ = try await TaskRecord.increment(id: "f1", fields: ["priority": 1], in: documentId) }
        XCTAssertEqual(error?.code, .invalidArgument)
        XCTAssertEqual(try TaskRecord.find("f1")?.priority, 1)

        try await saved.delete(in: documentId, options: Db3WriteOptions(condition: ["title": "nope"]))
        XCTAssertNil(try TaskRecord.find("f1"))
        XCTAssertEqual(warnings.value.count, 1)
    }

    // MARK: - Behavior 9: a closed document and a db3 that is not resident

    func testADocumentThatIsNotOpenIsRefusedNotFoundByEachWrite() async throws {
        _ = try await client()
        let task = TaskRecord(id: "t1", title: "Nowhere")
        let save = await refusal { _ = try await task.save(in: "not-open", options: Db3WriteOptions()) }
        let delete = await refusal { try await task.delete(in: "not-open", options: Db3WriteOptions(confirm: true)) }
        let increment = await refusal { _ = try await TaskRecord.increment(id: "t1", fields: ["priority": 1], in: "not-open") }
        XCTAssertEqual([save?.code, delete?.code, increment?.code], [.notFound, .notFound, .notFound])
    }

    func testABoundDb3ThatIsNotResidentIsRefusedNamingTheVerb() async throws {
        let client = try await db3Client()
        try await client.bindStoredDb3(Self.otherDb3Id)
        XCTAssertTrue(client.isRecordLogDocument(Self.otherDb3Id))
        XCTAssertFalse(try XCTUnwrap(client.recordLogBinding(Self.otherDb3Id)).isResident)
        let task = TaskRecord(id: "t1", title: "Not here yet")
        let errors: [(String, JsBaoError?)] = [
            ("save", await refusal { _ = try await task.save(in: Self.otherDb3Id, options: Db3WriteOptions(confirm: true)) }),
            ("delete", await refusal { try await task.delete(in: Self.otherDb3Id, options: Db3WriteOptions(condition: ["priority": 1])) }),
            ("increment", await refusal { _ = try await TaskRecord.increment(id: "t1", fields: ["priority": 1], in: Self.otherDb3Id) }),
        ]
        for (verb, error) in errors {
            XCTAssertEqual(error?.code, .db3NotResident, verb)
            XCTAssertTrue(error?.message.contains("(named by \(verb))") == true, "\(verb): \(error?.message ?? "no error")")
            XCTAssertEqual(error?.details?["source"], .string(verb))
        }
    }

    // MARK: - Behavior 10: public on the facade, internal on the client

    func testTheFacadeMethodsArePublicAndTheModelStoreStaysInternal() throws {
        let flatten = { (source: String) in
            ClientSourceText.stripComments(source).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let codegen = flatten(try ClientSourceText.clientSource("API/CodegenAPI.swift"))
        for signature in [
            "public func save( _ schema: PrimitiveSchema, id: String, values: [String: PrimitiveValue], in docId: String, "
                + "changedFields: Set<String>? = nil, options: Db3WriteOptions ) async throws -> PrimitiveRecord",
            "public func delete( _ schema: PrimitiveSchema, id: String, in docId: String, options: Db3WriteOptions ) async throws",
            "public func increment( _ schema: PrimitiveSchema, id: String, fields: [String: Double], in docId: String, "
                + "options: Db3WriteOptions = Db3WriteOptions() ) async throws -> [String: Double]",
        ] {
            XCTAssertTrue(codegen.contains(signature), "CodegenAPI declares: \(signature)")
        }
        let client = ClientSourceText.stripComments(try ClientSourceText.clientSource("JsBaoClient.swift"))
        let lines = client.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for internalName in ["func sharedModel(", "func requireMember("] {
            XCTAssertFalse(lines.contains { $0.hasPrefix("public \(internalName)") || $0.hasPrefix("open \(internalName)") }, internalName)
            XCTAssertTrue(lines.contains { $0.hasPrefix(internalName) }, "\(internalName) is still declared, internal")
        }
        XCTAssertTrue(lines.contains { $0.hasPrefix("public func inspectableSharedMembers()") })
    }
}
