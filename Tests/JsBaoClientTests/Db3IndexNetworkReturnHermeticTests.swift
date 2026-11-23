import XCTest
@testable import JsBaoClient

/// #5101 behaviour 23 (edge E14) — Swift keeps its socket across
/// `setNetworkMode(.offline)`, so no socket-open event follows the return of
/// networking: an index list owed by a read that failed offline is read again
/// when networking is allowed again, once while that read is out.
final class Db3IndexNetworkReturnHermeticTests: XCTestCase {
    typealias H = RecordLogReceiptHarness

    private static let db3Id = "01JD5101NETRETURNXXXXXXXXX"

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
        let directory = NSTemporaryDirectory() + "/db3-net-return-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "db3-net-return-5101",
            token: makeTestJwt(userId: "user-a"), logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"), autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        client.registerModels([H.schema])
        return client
    }

    func testAnOwedListIsReadAgainWhenNetworkingReturnsOnTheSameSocket() async throws {
        let client = try await client()
        let reads = ThreadSafeBox<Int>(0)
        client.db3IndexReadForTest = { id in if id == Self.db3Id { reads.mutate { $0 += 1 } } }
        client.setNetworkMode(.offline)
        try await client.bindStoredDb3(Self.db3Id)
        let handle = try client.db3.subscribe(Self.db3Id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        // The open reads the list; offline, the read fails and is owed, with no retry.
        try await eventually(timeout: 10, description: "the open's read failed and owed") {
            reads.value == 1 && client.db3IndexRefresher.owed(Self.db3Id) && !client.db3IndexRefresher.pending(Self.db3Id)
        }
        XCTAssertFalse(client.db3IndexRefresher.settled(Self.db3Id), "ready() would wait")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(reads.value, 1, "nothing is retried offline")

        // Networking returns on the unchanged socket: the owed list is read at once.
        let hold = RecordLogReceiptHarness.Gate()
        client.db3IndexReadHoldForTest = { _ in await hold.wait() }
        client.setNetworkMode(.online)
        try await eventually(timeout: 5, description: "read again") { reads.value == 2 }
        client.setNetworkMode(.online)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(reads.value, 2, "a list being read is not asked for twice")
        hold.open()
        handle.dispose()
    }
}
