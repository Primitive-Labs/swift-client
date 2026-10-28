import XCTest
@testable import JsBaoClient

/// Finding 4701-C05 — the retention policy's `maxDocs` keeps walking past a
/// db3 its lifecycle keeps (subscribed, or holding writes the room has not
/// judged): the limit is met from the next oldest documents, and only a
/// document that went counts toward it.
final class Db3RetentionHermeticTests: XCTestCase {
    private var directory: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = NSTemporaryDirectory() + "db3-retention-\(UUID().uuidString.prefix(8))/"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: directory)
        try await super.tearDown()
    }

    private func manager(_ seed: [LocalMetadataEntry]) async throws -> DocumentManager {
        let storage = SQLiteStorageProvider(path: directory + "retention.sqlite")
        try await storage.initialize(namespace: "retention")
        let offline = OfflineStore()
        await offline.setStorageProvider(storage)
        let manager = DocumentManager(logger: Logger(level: .none, scope: "test"))
        manager.offlineStore = offline
        manager.appId = "db3-retention-app"
        manager.userId = "db3-retention-user"
        try await offline.ensureMetadataDb(appId: "db3-retention-app", userId: "db3-retention-user")
        try await offline.putMetadataBatch(appId: "db3-retention-app", userId: "db3-retention-user", records: seed)
        await manager.loadLocalMetadata()
        return manager
    }

    private func db3(_ id: String, openedSecondsAgo: TimeInterval) -> LocalMetadataEntry {
        var entry = LocalMetadataEntry(
            documentId: id,
            lastOpenedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-openedSecondsAgo)),
            localBytes: 100
        )
        entry.documentFormat = 3
        return entry
    }

    func testMaxDocsEvictsTheNextOldestWhenTheOldestDb3IsKept() async throws {
        let manager = try await manager([
            db3("oldest-kept", openedSecondsAgo: 300),
            db3("middle", openedSecondsAgo: 200),
            db3("newest", openedSecondsAgo: 100),
        ])
        let asked = ThreadSafeBox<[String]>([])
        manager.evictDb3ForRetention = { [weak manager] id in
            asked.mutate { $0.append(id) }
            // The lifecycle keeps a subscribed db3.
            if id == "oldest-kept" { return false }
            await manager?.evictLocalData(documentId: id)
            return true
        }
        await manager.enforceRetentionPolicy(maxDocs: 2)
        let after = manager.getMetadataIndex()
        XCTAssertNotNil(after["oldest-kept"], "the lifecycle kept it")
        XCTAssertNil(after["middle"], "the limit is met from the next oldest")
        XCTAssertNotNil(after["newest"])
        XCTAssertEqual(asked.value, ["oldest-kept", "middle"], "the walk stops once the limit is met")
    }
}
