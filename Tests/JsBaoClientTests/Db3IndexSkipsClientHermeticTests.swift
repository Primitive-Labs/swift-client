import XCTest
@testable import JsBaoClient

/// #5241 behavior 16 and edge case N (Swift) — `client.db3.indexes.skipped(_:)`
/// on a client with no server.
///
/// It answers the bound copy's skipped entries as `[Db3SkippedIndex]`, with
/// nothing sent; `local(_:)` lists none of them and is what it was; a db3 not
/// bound here is refused as `local(_:)` is. `Db3LocalIndexStatus` keeps its
/// four cases, so an exhaustive `switch` with no `default` compiles.
final class Db3IndexSkipsClientHermeticTests: XCTestCase {

    private static let db3Id = "01JD5241SK1PSCL1ENT000000A"
    private static let unbound = "01JD5241SK1PSCL1ENT000000B"

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
        let directory = NSTemporaryDirectory() + "/db3-skips-client-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "db3-skips-5241",
            token: makeTestJwt(userId: "user-a"), logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"), autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        return client
    }

    /// Every case named, no `default`: a fifth case would not compile.
    private func label(_ status: Db3LocalIndexStatus) -> String {
        switch status {
        case .built: return "built"
        case .building: return "building"
        case .unbuilt: return "unbuilt"
        case .declined: return "declined"
        }
    }

    func testSkippedAnswersTheCopysSkippedEntriesWithTheirReasonsAndLocalIsUnchanged() async throws {
        let client = try await client()
        client.setNetworkMode(.offline)
        let sent = LockedBox<[String]>([])
        client.gatedTransportForTest.observeSentForTest { _, path, _ in sent.withValue { $0.append(path) } }
        try await client.bindStoredDb3(Self.db3Id)
        let binding = try XCTUnwrap(client.recordLogBinding(Self.db3Id))
        try binding.store.syncIndexes([
            RecordLogIndexEntry(name: "idx_records_note_year", model: "Note", fields: ["year"], unique: false, on: .device),
            RecordLogIndexEntry(name: "idx_members_note_tags", model: "Note", fields: ["tags"], unique: false, kind: .members, on: .server),
            RecordLogIndexEntry(name: "idx_records_note_id", model: "Note", fields: ["id"], unique: false, on: .both),
        ])

        let skipped = try await client.db3.indexes.skipped(Self.db3Id)
        XCTAssertEqual(skipped, [
            Db3SkippedIndex(
                name: "idx_members_note_tags", model: "Note", fields: ["tags"], kind: .members, on: .server,
                reason: "placed on the server only; this device builds nothing for it"
            ),
            Db3SkippedIndex(
                name: "idx_records_note_id", model: "Note", fields: ["id"], kind: .scalar, on: .both,
                reason: "the primary key serves id; no index of its own is built"
            ),
        ])
        let local = try await client.db3.indexes.local(Self.db3Id)
        XCTAssertEqual(local.map(\.name), ["idx_records_note_year"])
        XCTAssertEqual(local.map { label($0.status) }, ["built"])
        XCTAssertEqual(Db3LocalIndexStatus.allCases.count, 4)
        XCTAssertEqual(sent.value, [])

        do {
            _ = try await client.db3.indexes.skipped(Self.unbound)
            XCTFail("a db3 not bound here is refused")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3NotResident)
        }
    }
}
