import XCTest
@testable import JsBaoClient

/// Unit tests for `DocumentManager.enforceRetentionPolicy` — the
/// engine behind `JsBaoClient.setRetentionPolicy`.
///
/// Seeds the offline store directly with controlled `lastOpenedAt` /
/// `localBytes`, drives a single `loadLocalMetadata()` into a fresh
/// `DocumentManager`, then asserts which entries survive each policy.
/// No live dev server — runs in-process.
final class RetentionPolicyTests: XCTestCase {
    var tempDir: String!

    override func setUp() async throws {
        tempDir = NSTemporaryDirectory() + "jsbao-retention-\(UUID().uuidString.prefix(8))/"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    /// Build a DocumentManager backed by a fresh SQLite store, then
    /// seed it with the given metadata rows. Each row's
    /// `lastOpenedAt` / `localBytes` is loaded into `metadataIndex`
    /// via the normal `loadLocalMetadata()` path.
    private func setupManager(seed: [LocalMetadataEntry]) async throws -> DocumentManager {
        let dbPath = tempDir + "retention-\(UUID().uuidString.prefix(6)).sqlite"
        let storage = SQLiteStorageProvider(path: dbPath)
        try await storage.initialize(namespace: "retention")
        let offline = OfflineStore()
        await offline.setStorageProvider(storage)

        let mgr = DocumentManager(logger: Logger(level: .warn, scope: "test"))
        mgr.offlineStore = offline
        mgr.appId = "test-app"
        mgr.userId = "test-user"

        try await offline.ensureMetadataDb(appId: "test-app", userId: "test-user")
        try await offline.putMetadataBatch(
            appId: "test-app", userId: "test-user", records: seed
        )
        await mgr.loadLocalMetadata()
        return mgr
    }

    private func meta(
        _ id: String,
        openedSecondsAgo: TimeInterval,
        bytes: Int
    ) -> LocalMetadataEntry {
        let ts = Date().addingTimeInterval(-openedSecondsAgo)
        return LocalMetadataEntry(
            documentId: id,
            lastOpenedAt: ISO8601DateFormatter().string(from: ts),
            localBytes: bytes
        )
    }

    // MARK: - ttlMs

    func test_ttlEvictsStaleDocs() async throws {
        let mgr = try await setupManager(seed: [
            meta("fresh", openedSecondsAgo: 10, bytes: 100),
            meta("stale-1", openedSecondsAgo: 3600, bytes: 100),
            meta("stale-2", openedSecondsAgo: 7200, bytes: 100),
        ])

        // 30-minute TTL → both stale docs evicted, fresh remains.
        await mgr.enforceRetentionPolicy(ttlMs: 30 * 60 * 1000)

        let after = mgr.getMetadataIndex()
        XCTAssertNotNil(after["fresh"])
        XCTAssertNil(after["stale-1"])
        XCTAssertNil(after["stale-2"])
    }

    // MARK: - maxDocs

    func test_maxDocsKeepsNewest() async throws {
        let mgr = try await setupManager(seed: [
            meta("oldest", openedSecondsAgo: 300, bytes: 100),
            meta("middle", openedSecondsAgo: 200, bytes: 100),
            meta("newest", openedSecondsAgo: 100, bytes: 100),
        ])

        await mgr.enforceRetentionPolicy(maxDocs: 2)

        let after = mgr.getMetadataIndex()
        XCTAssertNil(after["oldest"], "oldest doc should be evicted")
        XCTAssertNotNil(after["middle"])
        XCTAssertNotNil(after["newest"])
    }

    // MARK: - maxBytes

    func test_maxBytesEvictsOldestUntilUnderBudget() async throws {
        let mgr = try await setupManager(seed: [
            meta("oldest", openedSecondsAgo: 300, bytes: 500),
            meta("middle", openedSecondsAgo: 200, bytes: 500),
            meta("newest", openedSecondsAgo: 100, bytes: 500),
        ])

        // 1000 byte budget; 1500 bytes seeded → must drop one (oldest).
        await mgr.enforceRetentionPolicy(maxBytes: 1000)

        let after = mgr.getMetadataIndex()
        XCTAssertNil(after["oldest"], "oldest doc should be evicted to fit budget")
        XCTAssertNotNil(after["middle"])
        XCTAssertNotNil(after["newest"])
    }

    func test_maxBytesEvictsMultipleWhenNeeded() async throws {
        let mgr = try await setupManager(seed: [
            meta("a", openedSecondsAgo: 400, bytes: 500),
            meta("b", openedSecondsAgo: 300, bytes: 500),
            meta("c", openedSecondsAgo: 200, bytes: 500),
            meta("d", openedSecondsAgo: 100, bytes: 500),
        ])

        // 600 byte budget; 2000 bytes seeded → must drop 3 oldest.
        await mgr.enforceRetentionPolicy(maxBytes: 600)

        let after = mgr.getMetadataIndex()
        XCTAssertNil(after["a"])
        XCTAssertNil(after["b"])
        XCTAssertNil(after["c"])
        XCTAssertNotNil(after["d"], "newest doc should fit and remain")
    }

    // MARK: - Combined

    func test_ttlAndMaxDocsCompose() async throws {
        let mgr = try await setupManager(seed: [
            meta("stale", openedSecondsAgo: 3600, bytes: 100),    // ttl-evicted
            meta("oldest-fresh", openedSecondsAgo: 200, bytes: 100), // maxDocs-evicted
            meta("middle-fresh", openedSecondsAgo: 100, bytes: 100),
            meta("newest-fresh", openedSecondsAgo: 50, bytes: 100),
        ])

        // 30-min TTL then maxDocs=2. After TTL: 3 fresh remain. After
        // maxDocs: drop the oldest-fresh.
        await mgr.enforceRetentionPolicy(
            ttlMs: 30 * 60 * 1000,
            maxDocs: 2
        )

        let after = mgr.getMetadataIndex()
        XCTAssertNil(after["stale"])
        XCTAssertNil(after["oldest-fresh"])
        XCTAssertNotNil(after["middle-fresh"])
        XCTAssertNotNil(after["newest-fresh"])
    }

    // MARK: - Open / pending-create documents

    /// Inverted for #2668: enforcement used to skip open and pending-create
    /// documents. JS `enforceRetentionPolicy` evicts with `force: true`
    /// regardless of open state (`src/client/internal/documentManager.ts`), so a
    /// long-lived open document could hold the local store over budget
    /// indefinitely. This test now pins the JS behavior.
    func test_openDocsAreEvictedByEnforcement() async throws {
        let mgr = try await setupManager(seed: [
            meta("open-doc", openedSecondsAgo: 7200, bytes: 100),
        ])

        // Opening refreshes `lastOpenedAt` to now (as it does in JS), so let the
        // document age past a short TTL rather than relying on the seeded value.
        _ = try await mgr.openDocument(
            documentId: "open-doc",
            options: OpenDocumentOptions(
                waitForLoad: .local, enableNetworkSync: false
            )
        )
        try await Task.sleep(nanoseconds: 1_200_000_000)

        await mgr.enforceRetentionPolicy(ttlMs: 1000)

        XCTAssertNil(
            mgr.getMetadataIndex()["open-doc"],
            "an open document must not be exempt from TTL eviction (#2668 C24)"
        )
    }

    /// The same for a document with an uncommitted local create: JS passes
    /// `force: true` for every retention eviction, so `maxDocs` bounds the
    /// store even when the oldest entries are pending creates (#2668 C24).
    func test_pendingCreateDocsAreEvictedByEnforcement() async throws {
        let mgr = try await setupManager(seed: [])

        _ = try await mgr.createLocalDocument(
            documentId: "pending-create", title: "pending", localOnly: false
        )
        XCTAssertTrue(mgr.isPendingCreate("pending-create"))

        // "keep nothing locally" — the pending create is the only candidate, so
        // the assertion does not depend on timestamp ordering.
        await mgr.enforceRetentionPolicy(maxDocs: 0)

        XCTAssertNil(
            mgr.getMetadataIndex()["pending-create"],
            "a pending-create document must not be exempt from maxDocs eviction (#2668 C24)"
        )
    }
}
