import XCTest
@testable import JsBaoClient

/// Swift clients for the local-only db3 tests (#5155): each signed in, with
/// networking stopped and both create hooks counting what they are asked,
/// over a sqlite directory (one directory serves a restart and another user's
/// sign-in) or in memory. `tearDown()` destroys them and removes the
/// directories.
final class Db3LocalOnlyWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var directories: [String] = []
    private var clients: [JsBaoClient] = []
    private var remote = 0

    /// The model every client registers: a unique `slug`, an indexed
    /// `status`, a compound unique `(owner, day)`, and a string set `tags`.
    static let note = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string),
            "slug": FieldDescriptor(type: .string, unique: true), "status": FieldDescriptor(type: .string, indexed: true),
            "views": FieldDescriptor(type: .number), "owner": FieldDescriptor(type: .string), "day": FieldDescriptor(type: .number),
            "tags": FieldDescriptor(type: .stringset),
        ],
        constraints: ["owner_day": ConstraintDescriptor(name: "owner_day", fields: ["owner", "day"])]
    )

    /// How many times a create hook was asked, every client's.
    var remoteCreates: Int { lock.withLock { remote } }

    /// A new directory, removed at `tearDown()`.
    func directory() -> String {
        let made = NSTemporaryDirectory() + "/db3-local-only-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
        lock.withLock { directories.append(made) }
        return made
    }

    /// A client signed in as `userId` over `directory`'s store, networking stopped.
    func client(userId: String = "user-a", directory: String) async throws -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "db3-local-only-5155",
            token: makeTestJwt(userId: userId),
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        lock.withLock { clients.append(client) }
        _ = await client.waitForStorageReady()
        await client.goOffline()
        client.registerModels([Self.note])
        client.documentManager.createRemoteDocument = { [weak self] _ in
            self?.lock.withLock { self?.remote += 1 }
            throw JsBaoError(code: .unavailable, message: "no documents commit for a local-only db3")
        }
        client.documentManager.createRemoteDb3 = { [weak self] _ in
            self?.lock.withLock { self?.remote += 1 }
            throw JsBaoError(code: .unavailable, message: "no db3 commit for a local-only db3")
        }
        return client
    }

    /// Destroy `client` now, so another can open its store.
    func destroy(_ client: JsBaoClient) async {
        await client.destroy()
        lock.withLock { clients.removeAll { $0 === client } }
    }

    func tearDown() async {
        for client in lock.withLock({ clients }) { await client.destroy() }
        let removing = lock.withLock { () -> [String] in
            defer { directories = []; clients = [] }
            return directories
        }
        for directory in removing { try? FileManager.default.removeItem(atPath: directory) }
    }

    /// A local-only db3 of `client`'s, created through a `Db3API` over `transport`.
    func createLocalOnly(_ client: JsBaoClient, transport: RecordingTransport, title: String = "Mine") async throws -> Db3Info {
        try await Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
            .create(title: title, tags: ["t"], localOnly: true)
    }

    /// The `Note` model of `db3Id` on `client`.
    func notes(_ client: JsBaoClient, _ db3Id: String) throws -> DynamicModel {
        try XCTUnwrap(client.sharedModel("Note")?.member(docId: db3Id))
    }
}

/// Wait until `check` holds, failing after `timeout` seconds.
func db3LocalOnlyEventually(
    _ description: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
    _ check: () async throws -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await check() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("timed out waiting for \(description)", file: file, line: line)
}

/// The `JsBaoError` `body` throws; a failure when it throws nothing or something else.
func db3LocalOnlyThrown(
    file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void
) async -> JsBaoError? {
    do {
        try await body()
        XCTFail("nothing was thrown", file: file, line: line)
        return nil
    } catch let error as JsBaoError {
        return error
    } catch {
        XCTFail("threw \(error), not a JsBaoError", file: file, line: line)
        return nil
    }
}
