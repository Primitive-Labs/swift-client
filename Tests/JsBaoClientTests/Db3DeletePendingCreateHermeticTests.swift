import XCTest
@testable import JsBaoClient

/// #6065 — `client.db3.delete(_:)` on a db3 whose create is pending waits for
/// the create, as every other db3 request does: it sends `DELETE db3/:id`
/// only once the server has the db3, and throws `.pendingCreate` offline, or
/// the create's refusal, with nothing sent. JS `client.db3.delete` does the
/// same (`tests/unit/workflows/db3-delete-pending-create-6065.test.ts`).
final class Db3DeletePendingCreateHermeticTests: XCTestCase {

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

    private static func row(_ body: JSONValue) -> Db3Info {
        Db3Info(
            id: body["id"]?.stringValue ?? "", title: body["title"]?.stringValue ?? "", createdBy: "user-a",
            createdAt: "2026-11-16T00:00:00.000Z", modifiedAt: "2026-11-16T00:00:00.000Z", custodian: "user:user-a",
            sync: true, type: nil, tags: [], metadata: nil, permission: nil, accessSource: nil, grantedAt: nil
        )
    }

    /// The create's commit: held until `release()`, then answered by `answer`.
    private final class Commit: @unchecked Sendable {
        private let lock = NSLock()
        private var _released = false
        private var _posts = 0
        let answer: @Sendable (JSONValue) throws -> Db3Info
        init(answer: @escaping @Sendable (JSONValue) throws -> Db3Info) { self.answer = answer }
        func release() { lock.withLock { _released = true } }
        var released: Bool { lock.withLock { _released } }
        func post() { lock.withLock { _posts += 1 } }
        var posts: Int { lock.withLock { _posts } }
    }

    /// A client signed in as `user-a`, networking stopped, whose `POST db3`
    /// commit is `commit`, and a `Db3API` of it over `transport`.
    private func offlineClient(commit: Commit, transport: RecordingTransport) async throws -> (JsBaoClient, Db3API) {
        let directory = NSTemporaryDirectory() + "/db3-delete-pending-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "db3-delete-pending-6065",
            token: makeTestJwt(userId: "user-a"),
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        await client.goOffline()
        client.registerModels([Self.note])
        client.documentManager.commitRetryBackoff = CommitRetryBackoff(base: 0.02, factor: 2, max: 0.1, jitter: false, maxAttempts: 5)
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no documents commit for a db3")
        }
        client.documentManager.createRemoteDb3 = { body in
            commit.post()
            while !commit.released { try await Task.sleep(nanoseconds: 10_000_000) }
            return try commit.answer(body)
        }
        return (client, Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client))
    }

    private func eventually(_ what: String, timeout: TimeInterval = 3, _ check: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await check() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func deletes(_ transport: RecordingTransport) -> [String] {
        transport.calls.filter { $0.method == .delete }.map(\.path)
    }

    func testOfflineItThrowsPendingCreateWithNothingSent() async throws {
        let transport = RecordingTransport(status: 200, json: #"{"success": true}"#)
        let (client, db3) = try await offlineClient(commit: Commit(answer: Self.row), transport: transport)
        let info = try await db3.create(title: "Offline")
        XCTAssertTrue(client.documentManager.isPendingCreate(info.id))

        do {
            _ = try await db3.delete(info.id)
            XCTFail("delete throws .pendingCreate offline")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .pendingCreate)
            XCTAssertEqual(error.details?["db3Id"], .string(info.id))
        }
        XCTAssertEqual(deletes(transport), [])
        XCTAssertTrue(client.documentManager.isPendingCreate(info.id), "the create stays pending")
    }

    func testItSendsTheDeleteOnlyOnceTheCreateCommits() async throws {
        let transport = RecordingTransport(status: 200, json: #"{"success": true}"#)
        let commit = Commit(answer: Self.row)
        let (client, db3) = try await offlineClient(commit: commit, transport: transport)
        let info = try await db3.create(title: "Deleted while pending")
        await client.goOnline()
        try await eventually("the commit to go out") { commit.posts >= 1 }

        let deleting = Task { try await db3.delete(info.id) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(deletes(transport), [], "no DELETE while the create is pending")

        commit.release()
        let result = try await deleting.value
        XCTAssertTrue(result.success)
        XCTAssertEqual(deletes(transport), ["/db3/\(info.id)"])
        XCTAssertFalse(client.documentManager.isPendingCreate(info.id))
    }

    func testItThrowsTheCreatesRefusalWithNothingSent() async throws {
        let transport = RecordingTransport(status: 200, json: #"{"success": true}"#)
        let commit = Commit(answer: { _ in
            throw HttpError(status: 409, message: "taken", serverCode: "DB3_ID_EXISTS", serverMessage: "A document of this app holds this id")
        })
        commit.release()
        let (client, db3) = try await offlineClient(commit: commit, transport: transport)
        let info = try await db3.create(title: "Refused")
        await client.goOnline()
        try await eventually("the refusal") { client.documentManager.getLocalMetadata(info.id)?.commitRefused == true }

        do {
            _ = try await db3.delete(info.id)
            XCTFail("delete throws the create's refusal")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 409)
            XCTAssertEqual(error.serverCode, "DB3_ID_EXISTS")
        }
        XCTAssertEqual(deletes(transport), [])
    }
}
