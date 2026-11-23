import XCTest
@testable import JsBaoClient

/// #5101 behaviour 5 (edge E4) — what counts as a grant heard: a `docMetadata`
/// frame from the server carrying a `permission`, whether or not the level
/// equals the one the client cached (the repro re-grants the same
/// `read-write`). A frame applied locally, and a level recorded through
/// `setPermission` (the open's own fetch, a cached replay), only re-read the
/// state. A frame with the cached level still emits no `PermissionEvent`.
final class Db3PermissionHeardHermeticTests: XCTestCase {
    typealias H = RecordLogReceiptHarness

    private static let db3Id = "01JD5101HEARDGRANTXXXXXXXX"

    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    private func client() async throws -> JsBaoClient {
        let directory = NSTemporaryDirectory() + "/db3-heard-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "db3-heard-5101",
            token: makeTestJwt(userId: "user-a"), logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"), autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        client.registerModels([H.schema])
        return client
    }

    private func frame(_ client: JsBaoClient, _ level: String, source: String) async {
        await client.documentManager.applyDocumentMetadataUpdate(
            documentId: Self.db3Id, metadata: ["permission": .string(level)], changedFields: ["permission"],
            action: "updated", source: source
        )
    }

    func testAServerFrameWithTheCachedLevelIsHeardAndALocalFrameOrARecordedLevelIsNot() async throws {
        let client = try await client()
        try await client.bindStoredDb3(Self.db3Id)
        let binding = try XCTUnwrap(client.recordLogBinding(Self.db3Id))
        // The room refused this user: the store's mark is the room's.
        try binding.setState(permission: .some(RecordLogPermission.refused))
        let events = LockedBox<[DocumentPermission]>([])
        let subscription = client.eventEmitter.subscribe(PermissionEvent.self) { event in
            guard event.documentId == Self.db3Id else { return }
            events.withValue { $0.append(event.permission) }
        }

        // The level the client learns at its own open: recorded, not heard.
        client.documentManager.setPermission(Self.db3Id, permission: .readWrite)
        var state = try await client.db3.state(Self.db3Id)
        XCTAssertEqual(state.phase, .gone)
        XCTAssertEqual(state.permission, .refused)

        // A frame applied locally: not heard.
        await frame(client, "read-write", source: "local")
        state = try await client.db3.state(Self.db3Id)
        XCTAssertEqual(state.phase, .gone)
        XCTAssertEqual(state.permission, .refused)

        // The server's frame, at the level already cached: heard.
        await frame(client, "read-write", source: "server")
        state = try await client.db3.state(Self.db3Id)
        XCTAssertNotEqual(state.phase, .gone, "a grant heard: the room's refusal no longer stands")
        XCTAssertEqual(state.permission, .readWrite)
        XCTAssertEqual(binding.marks.permission, RecordLogPermission.refused, "the mark is the room's to lift")

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(events.value, [.readWrite], "a frame with the cached level emits no PermissionEvent")
        withExtendedLifetime(subscription) {}
    }
}
