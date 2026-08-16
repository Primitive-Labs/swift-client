import XCTest
@testable import JsBaoClient

/// Mirrors the schema half of
/// `tests/client/js-bao-client-docmetadata-ws.test.ts` (parity item C26).
/// JS's `LocalMetadataEntry` carries more than title/permission/modifiedAt:
/// offline listings report last-synced time, the unsynced-changes flag, the
/// cached permission and its age, thumbnails, `grantedAt`, and
/// `createCommittedAt` (the #1953 GSI-lag bridge). The Swift persisted schema
/// must carry the same fields, and old rows written before the widening must
/// still decode.
final class LocalMetadataSchemaTests: XCTestCase {
    var tempDir: String!

    override func setUp() async throws {
        tempDir = NSTemporaryDirectory() + "jsbao-metaschema-\(UUID().uuidString.prefix(8))/"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    private func makeStore() async throws -> OfflineStore {
        let dbPath = tempDir + "schema-\(UUID().uuidString.prefix(6)).sqlite"
        let storage = SQLiteStorageProvider(path: dbPath)
        try await storage.initialize(namespace: "metaschema")
        let offline = OfflineStore()
        await offline.setStorageProvider(storage)
        try await offline.ensureMetadataDb(appId: "test-app", userId: "test-user")
        return offline
    }

    // MARK: - Behavior 6: the wide schema round-trips through persistence

    func test_localMetadataEntry_roundTripsTheJsFieldSet() async throws {
        let offline = try await makeStore()

        var entry = LocalMetadataEntry(documentId: "doc-wide")
        entry.title = "Wide schema"
        entry.lastKnownPermission = "reader"
        entry.permissionCachedAt = "2026-08-13T00:00:01.000Z"
        entry.lastSyncedAt = "2026-08-13T00:00:00.000Z"
        entry.hasUnsyncedLocalChanges = true
        entry.thumbnailBlobId = "blob-123"
        entry.grantedAt = "2026-08-01T00:00:00.000Z"
        entry.createCommittedAt = "2026-08-02T00:00:00.000Z"
        entry.hasIndexedDbSnapshot = true

        try await offline.putMetadata(appId: "test-app", userId: "test-user", record: entry)
        let row = try await offline.getMetadata(
            appId: "test-app", userId: "test-user", documentId: "doc-wide"
        )
        let loaded = try XCTUnwrap(row)

        XCTAssertEqual(loaded.lastKnownPermission, "reader")
        XCTAssertEqual(loaded.permissionCachedAt, "2026-08-13T00:00:01.000Z")
        XCTAssertEqual(loaded.lastSyncedAt, "2026-08-13T00:00:00.000Z")
        XCTAssertEqual(loaded.hasUnsyncedLocalChanges, true)
        XCTAssertEqual(loaded.thumbnailBlobId, "blob-123")
        XCTAssertEqual(loaded.grantedAt, "2026-08-01T00:00:00.000Z")
        XCTAssertEqual(loaded.createCommittedAt, "2026-08-02T00:00:00.000Z")
        XCTAssertEqual(loaded.hasIndexedDbSnapshot, true)
    }

    /// Every new field is optional, so a row written by an older build — JSON
    /// with none of them present — still decodes.
    func test_rowWrittenBeforeTheWideningStillDecodes() throws {
        let legacy = """
        {"documentId":"doc-legacy","title":"Old row","permission":"owner",
         "metadataSyncedAt":"2026-01-01T00:00:00.000Z"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(LocalMetadataEntry.self, from: legacy)
        XCTAssertEqual(decoded.documentId, "doc-legacy")
        XCTAssertEqual(decoded.title, "Old row")
        XCTAssertNil(decoded.lastSyncedAt)
        XCTAssertNil(decoded.hasUnsyncedLocalChanges)
        XCTAssertNil(decoded.thumbnailBlobId)
    }
}
