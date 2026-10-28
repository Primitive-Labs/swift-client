import XCTest
@testable import JsBaoClient

/// #4806 behaviors 22 and 23, edge cases 033, 035 and 037 — a db3 created on
/// the server is resident here from its answer on, and only for the account
/// that asked.
///
/// `client.db3.create` waits for `POST db3`. A synced db3 is then adopted: its
/// metadata row is written from the answer, its fresh store is marked caught
/// up at cursor 0 (the room's log is empty at create), and it is bound with no
/// pending create and no commit, so it answers reads and takes writes before
/// any socket. A sync-off db3 is never adopted. When the account changed while
/// the request was out, the answer is returned and nothing is written or
/// bound under the new account.
final class Db3CreateAdoptionHermeticTests: XCTestCase {

    private static let db3Id = "01JD4806AD0PT10NXXXXXXXXXX"
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
    private func client(offline: Bool = false) async throws -> (JsBaoClient, LockedBox<Int>) {
        let directory = NSTemporaryDirectory() + "/db3-adoption-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "db3-adoption-4806",
            token: makeTestJwt(userId: "user-a"),
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        if offline { await client.goOffline() }
        client.registerModels([Self.note])
        // Any background commit of a create would come through here.
        let commits = LockedBox(0)
        client.documentManager.createRemoteDocument = { _ in
            commits.withValue { $0 += 1 }
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        return (client, commits)
    }

    private static func answer(sync: Bool = true, created: Bool? = nil) -> String {
        let alias = created.map {
            #", "created": \#($0), "alias": {"aliasKey": "home", "scope": "user", "documentId": "\#(db3Id)", "userId": "user-a"}"#
        } ?? ""
        return """
        {"id": "\(db3Id)", "title": "Orders", "createdBy": "user-a", "createdAt": "2026-10-26T00:00:00.000Z",
         "modifiedAt": "2026-10-26T00:00:00.000Z", "custodian": "user:user-a", "sync": \(sync), "type": null, "tags": ["t"]\(alias)}
        """
    }

    /// A `client.db3` over `transport`, adopting into `client`.
    private func api(_ client: JsBaoClient, _ transport: RecordingTransport) -> Db3API {
        Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
    }

    private func storedIds(_ client: JsBaoClient) async throws -> [String] {
        try await client.db3.stored().map(\.id)
    }

    // MARK: - Behavior 23: adoption

    func testASyncedCreateIsResidentAtOnceWithNoPendingCreateAndNoCommit() async throws {
        let (client, commits) = try await client()
        let transport = RecordingTransport(status: 201, json: Self.answer())
        let info = try await api(client, transport).create(title: "Orders")
        XCTAssertEqual(info.id, Self.db3Id)
        XCTAssertEqual(transport.calls.map(\.path), ["/db3"])

        let binding = try XCTUnwrap(client.recordLogBinding(Self.db3Id), "bound at once")
        XCTAssertFalse(binding.createdLocally)
        let marks = try binding.refreshMarks()
        XCTAssertNotNil(marks.lastCatchUpAt, "marked caught up")
        XCTAssertEqual(marks.cursor, 0)
        XCTAssertFalse(marks.replacing)
        XCTAssertTrue(binding.isResident)
        XCTAssertTrue(RecordLogStore.isResident(marks))

        let row = try XCTUnwrap(client.documentManager.getLocalMetadata(Self.db3Id))
        XCTAssertEqual(row.documentFormat, 3)
        XCTAssertEqual(row.title, "Orders")
        XCTAssertNotEqual(row.pendingCreate, true)
        XCTAssertFalse(client.documentManager.isPendingCreate(Self.db3Id))

        let state = try await client.db3.state(Self.db3Id)
        XCTAssertTrue(state.resident)
        XCTAssertEqual(state.phase, .idle)
        let listed1 = try await storedIds(client)
        XCTAssertEqual(listed1, [Self.db3Id])

        // A declared model saves and reads before any socket.
        let notes = try XCTUnwrap(client.sharedModel("Note")?.member(docId: Self.db3Id))
        _ = try notes.save(id: "n1", values: ["title": .string("before subscribing")])
        XCTAssertEqual(notes.find(id: "n1")?["title"], .string("before subscribing"))
        let rows = try notes.query()
        XCTAssertEqual(rows.compactMap { $0["id"]?.stringValue }, ["n1"])
        let pending = try await client.db3.state(Self.db3Id).pendingWrites
        XCTAssertEqual(pending, 1)

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(commits.value, 0, "no POST /documents for a db3 the server created")
    }

    /// #4921 behavior 35: online, a create of your own synced db3 sends the id
    /// it minted and is adopted from the answer; a sync-off or custodian-naming
    /// create sends no id.
    func testAnOnlineCreateSendsAClientMintedIdOnlyWhenItHoldsTheDb3() async throws {
        let (client, commits) = try await client()
        let minted = RecordingTransport(status: 201, json: Self.answer())
        let info = try await api(client, minted).create(title: "Orders", tags: ["t"])
        let body = try XCTUnwrap(minted.lastCall(to: "/db3")?.jsonBody)
        let id = try XCTUnwrap(body["id"]?.stringValue)
        XCTAssertNotNil(id.range(of: "^[0-7][0-9A-HJKMNP-TV-Z]{25}$", options: .regularExpression), id)
        XCTAssertEqual(body["title"]?.stringValue, "Orders")
        XCTAssertEqual(info.id, Self.db3Id, "the answer is adopted")
        XCTAssertNotNil(client.recordLogBinding(Self.db3Id))
        XCTAssertFalse(client.documentManager.isPendingCreate(id))

        let off = RecordingTransport(status: 201, json: Self.answer(sync: false))
        _ = try await api(client, off).create(title: "Orders", sync: false)
        XCTAssertNil(off.lastCall(to: "/db3")?.jsonBody?["id"])
        let named = RecordingTransport(status: 201, json: Self.answer())
        _ = try await api(client, named).create(title: "Orders", custodian: "user:user-a")
        XCTAssertNil(named.lastCall(to: "/db3")?.jsonBody?["id"])

        let refused = RecordingTransport(status: 404, json: #"{"error":"No db3 type","code":"DB3_TYPE_NOT_FOUND"}"#)
        let before = client.documentManager.getMetadataIndex().count
        do {
            _ = try await api(client, refused).create(title: "Missing", type: "missing")
            XCTFail("a refused create should throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, "DB3_TYPE_NOT_FOUND")
        }
        XCTAssertEqual(client.documentManager.getMetadataIndex().count, before, "a refusal writes nothing")
        XCTAssertEqual(commits.value, 0)
    }

    func testASyncOffCreateIsNotAdopted() async throws {
        let (client, commits) = try await client()
        let info = try await api(client, RecordingTransport(status: 201, json: Self.answer(sync: false))).create(title: "Orders", sync: false)
        XCTAssertFalse(info.sync)
        XCTAssertNil(client.recordLogBinding(Self.db3Id))
        XCTAssertNil(client.documentManager.getLocalMetadata(Self.db3Id))
        let state = try await client.db3.state(Self.db3Id)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.resident)
        let listed2 = try await storedIds(client)
        XCTAssertEqual(listed2, [])
        XCTAssertEqual(commits.value, 0)
    }

    func testACreatedAliasIsAdoptedAndAReferenceIsNot() async throws {
        let (client, _) = try await client()
        let options = Db3GetOrCreateWithAliasOptions(alias: AliasRef(scope: .user, aliasKey: "home", userId: "user-a"), title: "Orders")
        let reference = try await api(client, RecordingTransport(status: 200, json: """
        {"id": "\(Self.db3Id)", "created": false, "alias": {"aliasKey": "home", "scope": "user", "documentId": "\(Self.db3Id)", "userId": "user-a"}}
        """)).getOrCreateWithAlias(options)
        XCTAssertFalse(reference.created)
        XCTAssertNil(client.recordLogBinding(Self.db3Id), "a reference adopts nothing")

        let created = try await api(client, RecordingTransport(status: 201, json: Self.answer(created: true))).getOrCreateWithAlias(options)
        XCTAssertTrue(created.created)
        let binding = try XCTUnwrap(client.recordLogBinding(Self.db3Id))
        XCTAssertTrue(binding.isResident)
        XCTAssertEqual(client.documentManager.getLocalMetadata(Self.db3Id)?.documentFormat, 3)
    }

    /// Edge case 037: a retry's adoption of a db3 the store already holds resets nothing.
    func testAdoptingAgainKeepsTheCatchUpMarkAndTheRows() async throws {
        let (client, _) = try await client()
        let transport = RecordingTransport(status: 201, json: Self.answer())
        let info = try await api(client, transport).create(title: "Orders")
        let notes = try XCTUnwrap(client.sharedModel("Note")?.member(docId: Self.db3Id))
        _ = try notes.save(id: "n1", values: ["title": .string("kept")])
        let binding = try XCTUnwrap(client.recordLogBinding(Self.db3Id))
        let mark = try binding.refreshMarks().lastCatchUpAt
        try await Task.sleep(nanoseconds: 20_000_000)
        await client.adoptServerCreatedDb3(Self.db3Id, info: info, session: client.metadataSessionToken)
        XCTAssertEqual(try binding.refreshMarks().lastCatchUpAt, mark)
        XCTAssertEqual(notes.find(id: "n1")?["title"], .string("kept"))
        let state = try await client.db3.state(Self.db3Id)
        XCTAssertEqual(state.rows, 1)
        XCTAssertEqual(state.pendingWrites, 1)
    }

    // MARK: - Behavior 22: the account fence

    /// A transport that holds every answer until `gate` opens, and the gate.
    private func holding(_ json: String, status: Int = 201) -> (RecordingTransport, RecordLogReceiptHarness.Gate) {
        let gate = RecordLogReceiptHarness.Gate()
        let transport = RecordingTransport(responder: { _ in
            await gate.wait()
            return TransportResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
        })
        return (transport, gate)
    }

    private func assertNothingAdopted(_ client: JsBaoClient, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertNil(client.recordLogBinding(Self.db3Id), "bound nothing", file: file, line: line)
        XCTAssertNil(client.documentManager.getLocalMetadata(Self.db3Id), "wrote no metadata row", file: file, line: line)
        XCTAssertNil(client.documentManager.getMetadataIndex()[Self.db3Id], "the listing cache does not hold it", file: file, line: line)
        let stored = try await storedIds(client)
        XCTAssertFalse(stored.contains(Self.db3Id), "stored() does not list it", file: file, line: line)
    }

    func testACreateAnsweredAfterAnotherUserSignedInAdoptsNothing() async throws {
        let (client, _) = try await client()
        let (transport, gate) = holding(Self.answer())
        let db3 = api(client, transport)
        let pending = Task { try await db3.create(title: "Orders") }
        try await eventually(description: "the request out") { !transport.calls.isEmpty }
        client.updateToken(makeTestJwt(userId: "user-b"))
        gate.open()
        let info = try await pending.value
        XCTAssertEqual(info.id, Self.db3Id, "the answer is returned")
        try await Task.sleep(nanoseconds: 100_000_000)
        try await assertNothingAdopted(client)
    }

    func testAnAliasCreateAnsweredAfterAnotherUserSignedInAdoptsNothing() async throws {
        let (client, _) = try await client()
        let (transport, gate) = holding(Self.answer(created: true))
        let options = Db3GetOrCreateWithAliasOptions(alias: AliasRef(scope: .user, aliasKey: "home", userId: "user-a"), title: "Orders")
        let db3 = api(client, transport)
        let pending = Task { try await db3.getOrCreateWithAlias(options) }
        try await eventually(description: "the request out") { !transport.calls.isEmpty }
        client.updateToken(makeTestJwt(userId: "user-b"))
        gate.open()
        let result = try await pending.value
        XCTAssertTrue(result.created)
        try await Task.sleep(nanoseconds: 100_000_000)
        try await assertNothingAdopted(client)
    }

    /// 4806-C001: the account changes while the adoption is binding the store
    /// (after the answer and the metadata row, before the store is written):
    /// the new account's record-log store keeps nothing of the db3.
    func testAnAccountChangeWhileTheAdoptionBindsLeavesTheNewAccountsStoreUnchanged() async throws {
        let (client, _) = try await client()
        let reached = RecordLogReceiptHarness.Gate()
        let release = RecordLogReceiptHarness.Gate()
        client.db3BindHoldForTest = { _ in
            reached.open()
            await release.wait()
        }
        let db3 = api(client, RecordingTransport(status: 201, json: Self.answer()))
        let pending = Task { try await db3.create(title: "Orders") }
        await reached.wait()
        client.updateToken(makeTestJwt(userId: "user-b"))
        await client.rebindUserScopedStorage()
        release.open()
        let info = try await pending.value
        client.db3BindHoldForTest = nil
        XCTAssertEqual(info.id, Self.db3Id, "the answer is returned")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(client.recordLogBinding(Self.db3Id), "bound nothing")
        let stored = try await storedIds(client)
        XCTAssertFalse(stored.contains(Self.db3Id), "user-b's store does not hold user-a's db3")
        let state = try await client.db3.state(Self.db3Id)
        XCTAssertFalse(state.resident)
    }

    /// Edge case 035.
    func testACreateAnsweredAfterASignOutAdoptsNothing() async throws {
        let (client, _) = try await client()
        let (transport, gate) = holding(Self.answer())
        let db3 = api(client, transport)
        let pending = Task { try await db3.create(title: "Orders") }
        try await eventually(description: "the request out") { !transport.calls.isEmpty }
        try? await client.logout()
        gate.open()
        let info = try await pending.value
        XCTAssertEqual(info.id, Self.db3Id)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(client.recordLogBinding(Self.db3Id))
        XCTAssertNil(client.documentManager.getLocalMetadata(Self.db3Id))
    }

    /// Edge case 033: offline, a create that needs the server throws before
    /// anything is written. (#4921: a create of your own synced db3 is made
    /// here offline; a sync-off one still needs the server.)
    func testACreateWhileOfflineThrowsAndWritesNothing() async throws {
        let (client, commits) = try await client(offline: true)
        let before = client.documentManager.getMetadataIndex().count
        do {
            _ = try await client.db3.create(title: "Orders", sync: false)
            XCTFail("an offline create should throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .offline)
        }
        XCTAssertEqual(client.documentManager.getMetadataIndex().count, before)
        let listed3 = try await storedIds(client)
        XCTAssertEqual(listed3, [])
        XCTAssertEqual(commits.value, 0)
    }
}
