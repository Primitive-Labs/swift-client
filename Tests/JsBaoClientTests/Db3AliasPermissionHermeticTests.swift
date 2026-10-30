import XCTest
@testable import JsBaoClient

/// #5054 behaviors 1, 4 to 7 and edge cases E1 to E3 and E5 —
/// `client.db3.getOrCreateWithAlias` with `permission`, as the JS client
/// sends and adopts it (#5022).
///
/// The request carries `permission` only when it is set. The create answer
/// names no level, so the client adopts at the level it asked for: a db3 the
/// caller holds at `reader` is bound read-only before any socket, so a save is
/// refused on the device and nothing is sent; `read-write` binds writable. A
/// db3 created for another holder (another user, or `custodian: "app"`) is not
/// adopted on the creating device: it is only known as a db3.
final class Db3AliasPermissionHermeticTests: XCTestCase {

    private static let db3Id = "01JD5054AL1ASPERM1SS10NXXX"
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

    /// A client signed in as `user-a` over its own SQLite store, with no server.
    private func client() async throws -> (JsBaoClient, LockedBox<Int>) {
        let directory = NSTemporaryDirectory() + "/db3-alias-permission-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "db3-alias-permission-5054",
            token: makeTestJwt(userId: "user-a"),
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        client.registerModels([Self.note])
        let commits = LockedBox(0)
        client.documentManager.createRemoteDocument = { _ in
            commits.withValue { $0 += 1 }
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        return (client, commits)
    }

    /// A created alias db3's answer, held by `custodian`.
    private static func created(custodian: String = "user:user-a", createdBy: String = "user-a") -> String {
        """
        {"id": "\(db3Id)", "title": "Inbox", "createdBy": "\(createdBy)", "createdAt": "2026-10-30T00:00:00.000Z",
         "modifiedAt": "2026-10-30T00:00:00.000Z", "custodian": "\(custodian)", "sync": true, "type": null, "tags": [],
         "created": true, "alias": {"aliasKey": "inbox", "scope": "user", "documentId": "\(db3Id)", "userId": "\(createdBy)"}}
        """
    }

    private static let reference = """
    {"id": "\(db3Id)", "created": false, "alias": {"aliasKey": "inbox", "scope": "user", "documentId": "\(db3Id)", "userId": "user-a"}}
    """

    private func api(_ client: JsBaoClient, _ transport: RecordingTransport) -> Db3API {
        Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
    }

    private func options(_ permission: Db3AliasPermission?, userId: String = "user-a") -> Db3GetOrCreateWithAliasOptions {
        Db3GetOrCreateWithAliasOptions(
            alias: AliasRef(scope: .user, aliasKey: "inbox", userId: userId), title: "Inbox", permission: permission
        )
    }

    private func storedIds(_ client: JsBaoClient) async throws -> [String] {
        try await client.db3.stored().map(\.id)
    }

    private func assertNothingAdopted(_ client: JsBaoClient, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertNil(client.recordLogBinding(Self.db3Id), "bound nothing", file: file, line: line)
        XCTAssertNil(client.documentManager.getLocalMetadata(Self.db3Id), "wrote no metadata row", file: file, line: line)
        let stored = try await storedIds(client)
        XCTAssertFalse(stored.contains(Self.db3Id), "stored() does not list it", file: file, line: line)
        let state = try await client.db3.state(Self.db3Id)
        XCTAssertFalse(state.resident, "not resident", file: file, line: line)
    }

    // MARK: - Behavior 1: the request

    func testAPermissionIsSentBesideTheGivenKeys() async throws {
        let reader = RecordingTransport(status: 201, json: Self.created())
        _ = try await Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: reader)
            .getOrCreateWithAlias(Db3GetOrCreateWithAliasOptions(
                alias: AliasRef(scope: .user, aliasKey: "inbox", userId: "user-b"), title: "Inbox", type: "inbox", permission: .reader
            ))
        XCTAssertEqual(reader.lastCall?.method, .post)
        XCTAssertEqual(reader.lastCall?.path, "/db3/get-or-create-with-alias")
        XCTAssertEqual(reader.lastCall?.jsonBody, .object([
            "alias": .object(["scope": "user", "aliasKey": "inbox", "userId": "user-b"]),
            "title": "Inbox", "type": "inbox", "permission": "reader",
        ]))

        let readWrite = RecordingTransport(status: 201, json: Self.created())
        _ = try await Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: readWrite)
            .getOrCreateWithAlias(options(.readWrite))
        XCTAssertEqual(readWrite.lastCall?.jsonBody?["permission"], "read-write")

        let owner = RecordingTransport(status: 201, json: Self.created())
        _ = try await Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: owner)
            .getOrCreateWithAlias(options(.owner))
        XCTAssertEqual(owner.lastCall?.jsonBody?["permission"], "owner")

        let none = RecordingTransport(status: 201, json: Self.created())
        _ = try await Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: none)
            .getOrCreateWithAlias(options(nil))
        XCTAssertNil(none.lastCall?.jsonBody?["permission"], "no permission member when none is set")
    }

    // MARK: - Behaviors 4 and 5: a reader copy is read-only on the device

    func testACreatedReaderDb3YouHoldIsAdoptedReadOnly() async throws {
        let (client, commits) = try await client()
        let transport = RecordingTransport(status: 201, json: Self.created())
        let result = try await api(client, transport).getOrCreateWithAlias(options(.reader))
        XCTAssertTrue(result.created)

        let binding = try XCTUnwrap(client.recordLogBinding(Self.db3Id), "bound at once")
        XCTAssertTrue(binding.isResident)
        XCTAssertTrue(binding.isReadOnly, "bound read-only before any socket")
        XCTAssertEqual(try binding.refreshMarks().permission, RecordLogPermission.read)
        XCTAssertNotNil(binding.marks.lastCatchUpAt, "marked caught up")
        let state = try await client.db3.state(Self.db3Id)
        XCTAssertTrue(state.resident)
        XCTAssertFalse(state.subscribed)
        XCTAssertEqual(state.permission, .reader)
        let stored = try await storedIds(client)
        XCTAssertEqual(stored, [Self.db3Id])
        let row = try XCTUnwrap(client.documentManager.getLocalMetadata(Self.db3Id))
        XCTAssertEqual(row.documentFormat, 3)
        XCTAssertEqual(row.lastKnownPermission, "reader")
        XCTAssertEqual(commits.value, 0)
    }

    func testASaveOnAReaderCopyIsRefusedHereAndSendsNothing() async throws {
        let (client, commits) = try await client()
        let frames = LockedBox<[String]>([])
        client.recordLogFrameSentForTest = { text in frames.withValue { $0.append(text) } }
        let transport = RecordingTransport(status: 201, json: Self.created())
        _ = try await api(client, transport).getOrCreateWithAlias(options(.reader))

        let notes = try XCTUnwrap(client.sharedModel("Note")?.member(docId: Self.db3Id))
        do {
            _ = try notes.save(id: "n1", values: ["title": .string("mine?")])
            XCTFail("a save on a reader copy should throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .accessDenied)
        }
        XCTAssertNil(notes.find(id: "n1"), "nothing is in the store")
        let state = try await client.db3.state(Self.db3Id)
        XCTAssertEqual(state.pendingWrites, 0)
        XCTAssertEqual(state.rows, 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(transport.calls.map(\.path), ["/db3/get-or-create-with-alias"], "only the create's request")
        XCTAssertEqual(frames.value, [], "no frame")
        XCTAssertEqual(commits.value, 0)
    }

    // MARK: - Behavior 6: a read-write copy is writable

    func testACreatedReadWriteDb3YouHoldIsAdoptedWritable() async throws {
        let (client, _) = try await client()
        _ = try await api(client, RecordingTransport(status: 201, json: Self.created())).getOrCreateWithAlias(options(.readWrite))
        let binding = try XCTUnwrap(client.recordLogBinding(Self.db3Id))
        XCTAssertTrue(binding.isResident)
        XCTAssertFalse(binding.isReadOnly)
        let notes = try XCTUnwrap(client.sharedModel("Note")?.member(docId: Self.db3Id))
        _ = try notes.save(id: "n1", values: ["title": .string("writable")])
        XCTAssertEqual(notes.find(id: "n1")?["title"], .string("writable"))
        let state = try await client.db3.state(Self.db3Id)
        XCTAssertEqual(state.pendingWrites, 1)
        XCTAssertEqual(state.permission, .readWrite)
        XCTAssertEqual(client.documentManager.getLocalMetadata(Self.db3Id)?.lastKnownPermission, "read-write")
    }

    // MARK: - Behavior 7: a db3 another holder holds is not adopted

    func testADb3CreatedForAnotherUserIsKnownButNotAdopted() async throws {
        let (client, _) = try await client()
        let transport = RecordingTransport(status: 201, json: Self.created(custodian: "user:user-b", createdBy: "user-b"))
        let result = try await api(client, transport).getOrCreateWithAlias(options(.reader, userId: "user-b"))
        XCTAssertTrue(result.created)
        XCTAssertEqual(result.db3?.custodian, "user:user-b", "the answer is returned whole")
        XCTAssertEqual(result.db3?.createdBy, "user-b")
        XCTAssertEqual(result.alias?.userId, "user-b")
        try await assertNothingAdopted(client)
        XCTAssertEqual(client.recordLogState.resolvedFormat(Self.db3Id), 3, "known as a db3")
    }

    func testAnAppHeldCreateIsKnownButNotAdopted() async throws {
        let (client, _) = try await client()
        let answer = """
        {"id": "\(Self.db3Id)", "title": "Shared", "createdBy": "user-a", "createdAt": "2026-10-30T00:00:00.000Z",
         "modifiedAt": "2026-10-30T00:00:00.000Z", "custodian": "app", "sync": true, "type": null, "tags": []}
        """
        let info = try await api(client, RecordingTransport(status: 201, json: answer)).create(title: "Shared", custodian: "app")
        XCTAssertEqual(info.custodian, "app")
        try await assertNothingAdopted(client)
        XCTAssertEqual(client.recordLogState.resolvedFormat(Self.db3Id), 3)
    }

    // MARK: - Edge cases

    /// E1: an alias that already names a db3 adopts nothing at any level.
    func testAReferenceWithAPermissionAdoptsNothing() async throws {
        let (client, _) = try await client()
        let result = try await api(client, RecordingTransport(status: 200, json: Self.reference)).getOrCreateWithAlias(options(.reader))
        XCTAssertFalse(result.created)
        XCTAssertNil(result.db3)
        XCTAssertEqual(result.id, Self.db3Id)
        try await assertNothingAdopted(client)
        XCTAssertEqual(client.recordLogState.resolvedFormat(Self.db3Id), 3, "noted as a db3")
    }

    /// E2: the account changes while a reader create is out.
    func testAReaderCreateAnsweredAfterAnotherUserSignedInAdoptsNothing() async throws {
        let (client, _) = try await client()
        let gate = RecordLogReceiptHarness.Gate()
        let json = Self.created()
        let transport = RecordingTransport(responder: { _ in
            await gate.wait()
            return TransportResponse(status: 201, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
        })
        let db3 = api(client, transport)
        let reader = options(.reader)
        let pending = Task { try await db3.getOrCreateWithAlias(reader) }
        try await eventually(description: "the request out") { !transport.calls.isEmpty }
        client.updateToken(makeTestJwt(userId: "user-b"))
        gate.open()
        let result = try await pending.value
        XCTAssertTrue(result.created, "the answer is returned")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(client.recordLogBinding(Self.db3Id), "bound nothing")
        XCTAssertNil(client.documentManager.getLocalMetadata(Self.db3Id), "wrote no metadata row")
    }

    /// E3: a retry's second adoption keeps the read mark, the catch-up mark and the rows.
    func testAdoptingAReaderCopyAgainKeepsItsMarks() async throws {
        let (client, _) = try await client()
        let first = try await api(client, RecordingTransport(status: 201, json: Self.created())).getOrCreateWithAlias(options(.reader))
        let info = try XCTUnwrap(first.db3)
        let binding = try XCTUnwrap(client.recordLogBinding(Self.db3Id))
        let mark = try binding.refreshMarks().lastCatchUpAt
        try await Task.sleep(nanoseconds: 20_000_000)

        let again = try await api(client, RecordingTransport(status: 201, json: Self.created())).getOrCreateWithAlias(options(.reader))
        XCTAssertEqual(again.id, info.id)
        XCTAssertTrue(client.recordLogBinding(Self.db3Id) === binding, "the same binding")
        let marks = try binding.refreshMarks()
        XCTAssertEqual(marks.permission, RecordLogPermission.read)
        XCTAssertEqual(marks.lastCatchUpAt, mark)
        let state = try await client.db3.state(Self.db3Id)
        XCTAssertEqual(state.permission, .reader)
        XCTAssertEqual(state.rows, 0)
        XCTAssertEqual(state.pendingWrites, 0)
    }

    /// E5: a member's refused reader create throws the route's 403 and writes nothing.
    func testARefusedReaderCreateThrowsAndWritesNothing() async throws {
        let (client, _) = try await client()
        let failures = LockedBox<[Db3CreateFailedEvent]>([])
        let heard = client.eventEmitter.subscribe(Db3CreateFailedEvent.self) { event in failures.withValue { $0.append(event) } }
        defer { heard.cancel() }
        let before = client.documentManager.getMetadataIndex().count
        do {
            _ = try await api(client, RecordingTransport(status: 403, json: #"{"error":"Forbidden"}"#)).getOrCreateWithAlias(options(.reader))
            XCTFail("a refused create should throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 403)
        }
        try await eventually(description: "the refusal event") { !failures.value.isEmpty }
        XCTAssertEqual(failures.value.count, 1)
        XCTAssertEqual(failures.value.first?.code, "DB3_CREATE_FAILED")
        XCTAssertEqual(client.documentManager.getMetadataIndex().count, before)
        try await assertNothingAdopted(client)
    }
}
