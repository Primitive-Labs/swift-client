import XCTest
@testable import JsBaoClient

/// The upload queue's two stores in the client's own database (#4592, plan
/// phase 1, behaviors 5 and 6, edge "a record from a later build"): one JSON
/// record per queue id in `blobUploads:<appId>:<userId>`, the bytes in
/// `blobUploadBytes:<appId>:<userId>` keyed `<documentId>::<blobId>`. The
/// record is the JS client's `UploadRecord`, field for field, times in ms.
final class OfflineStoreBlobUploadsHermeticTests: XCTestCase {
    private var directory: String!

    override func setUp() async throws {
        directory = NSTemporaryDirectory() + "jsbao-blob-uploads-\(UUID().uuidString.prefix(8))/"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func makeStore() async throws -> (OfflineStore, SQLiteStorageProvider) {
        let provider = SQLiteStorageProvider(path: directory + "jsbao_storage.sqlite")
        let store = OfflineStore()
        await store.setStorageProvider(provider)
        return (store, provider)
    }

    private static func documentRecord(blobId: String = "B1", status: String = "pending") -> PersistedUploadRecord {
        PersistedUploadRecord(
            queueId: blobId, documentId: "doc-1", blobId: blobId, filename: "a.txt", contentType: "text/plain",
            sha256Base64: "c2hh", disposition: "attachment", retainLocal: true, numBytes: 5, status: status,
            attempts: 2, nextAttemptAt: 1_760_000_000_500, createdAt: 1_760_000_000_000,
            updatedAt: 1_760_000_000_250, lastError: "busy", lastErrorCode: nil, destination: nil
        )
    }

    private static func jsonObject(_ record: PersistedUploadRecord) throws -> [String: Any] {
        let data = try JSONEncoder().encode(record)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - The record is the JS record

    func testADocumentRecordCarriesTheJSFieldSetWithMillisecondTimesAndNoDestination() throws {
        let object = try Self.jsonObject(Self.documentRecord())
        XCTAssertEqual(
            Set(object.keys),
            [
                "queueId", "documentId", "blobId", "filename", "contentType", "sha256Base64", "disposition",
                "retainLocal", "numBytes", "status", "attempts", "nextAttemptAt", "createdAt", "updatedAt",
                "lastError",
            ],
            "absent optionals are left out, as JS leaves them undefined"
        )
        XCTAssertNil(object["destination"], "a document upload has no destination")
        XCTAssertEqual((object["createdAt"] as? NSNumber)?.int64Value, 1_760_000_000_000)
        XCTAssertEqual((object["nextAttemptAt"] as? NSNumber)?.int64Value, 1_760_000_000_500)
        XCTAssertEqual((object["updatedAt"] as? NSNumber)?.int64Value, 1_760_000_000_250)
        XCTAssertEqual(object["status"] as? String, "pending")
    }

    func testASessionRecordNamesItsDestinationAsJSDoes() throws {
        var record = Self.documentRecord(status: "failed")
        record.lastErrorCode = "AGENT_SESSION_PARTICIPANT_ONLY"
        record.destination = .agentSession("s1")
        let object = try Self.jsonObject(record)
        let destination = try XCTUnwrap(object["destination"] as? [String: Any])
        XCTAssertEqual(destination["kind"] as? String, "agent-session")
        XCTAssertEqual(destination["sessionId"] as? String, "s1")
        XCTAssertEqual(object["lastErrorCode"] as? String, "AGENT_SESSION_PARTICIPANT_ONLY")
        XCTAssertEqual(object["status"] as? String, "failed")
    }

    // MARK: - Stores per app and user

    func testARecordAndItsBytesRoundTripUnderTheirAppAndUserOnly() async throws {
        let (store, provider) = try await makeStore()
        let record = Self.documentRecord()
        let bytes = Data([0, 1, 2, 0xFF, 0xFE])
        try await store.putBlobUpload(appId: "app-1", userId: "u-a", record: record, bytes: bytes)

        let loaded = try await store.loadBlobUploads(appId: "app-1", userId: "u-a")
        XCTAssertEqual(loaded, [record])
        let loadedBytes = try await store.loadBlobUploadBytes(
            appId: "app-1", userId: "u-a", documentId: "doc-1", blobId: "B1"
        )
        XCTAssertEqual(loadedBytes, bytes, "non-UTF-8 bytes survive")

        let otherUser = try await store.loadBlobUploads(appId: "app-1", userId: "u-b")
        XCTAssertEqual(otherUser, [], "another user's store is another store")
        let otherApp = try await store.loadBlobUploads(appId: "app-2", userId: "u-a")
        XCTAssertEqual(otherApp, [], "another app's store is another store")

        XCTAssertEqual(OfflineStore.blobUploadsStore(appId: "app-1", userId: "u-a"), "blobUploads:app-1:u-a")
        XCTAssertEqual(OfflineStore.blobUploadBytesStore(appId: "app-1", userId: "u-a"), "blobUploadBytes:app-1:u-a")
        let recordKeys = try await provider.keys(store: "blobUploads:app-1:u-a")
        XCTAssertEqual(recordKeys, ["B1"], "one record per queue id")
        let byteKeys = try await provider.keys(store: "blobUploadBytes:app-1:u-a")
        XCTAssertEqual(byteKeys, ["doc-1::B1"])
        await store.closeStorage()
    }

    func testARecordWriteWithoutBytesKeepsTheBytesAlreadyStored() async throws {
        let (store, _) = try await makeStore()
        try await store.putBlobUpload(appId: "app-1", userId: "u-a", record: Self.documentRecord(), bytes: Data("hello".utf8))
        try await store.putBlobUpload(
            appId: "app-1", userId: "u-a", record: Self.documentRecord(status: "paused"), bytes: nil
        )
        let loaded = try await store.loadBlobUploads(appId: "app-1", userId: "u-a")
        XCTAssertEqual(loaded.map(\.status), ["paused"])
        let bytes = try await store.loadBlobUploadBytes(appId: "app-1", userId: "u-a", documentId: "doc-1", blobId: "B1")
        XCTAssertEqual(bytes, Data("hello".utf8))
        await store.closeStorage()
    }

    func testDeletingAnUploadRemovesItsRecordAndItsBytes() async throws {
        let (store, provider) = try await makeStore()
        try await store.putBlobUpload(appId: "app-1", userId: "u-a", record: Self.documentRecord(), bytes: Data("x".utf8))
        try await store.putBlobUpload(
            appId: "app-1", userId: "u-a", record: Self.documentRecord(blobId: "B2"), bytes: Data("y".utf8)
        )
        try await store.deleteBlobUpload(appId: "app-1", userId: "u-a", queueId: "B1", documentId: "doc-1", blobId: "B1")
        let loaded = try await store.loadBlobUploads(appId: "app-1", userId: "u-a")
        XCTAssertEqual(loaded.map(\.queueId), ["B2"])
        let byteKeys = try await provider.keys(store: "blobUploadBytes:app-1:u-a")
        XCTAssertEqual(byteKeys, ["doc-1::B2"])
        await store.closeStorage()
    }

    // MARK: - Edge: records another build wrote

    func testARecordWithUnknownKeysOrMissingOptionalKeysDecodesWithDefaults() async throws {
        let (store, provider) = try await makeStore()
        try await store.ensureMetadataDb(appId: "app-1", userId: "u-a")
        let later: JSONValue = .object([
            "queueId": .string("B9"), "documentId": .string("doc-1"), "blobId": .string("B9"),
            "filename": .string("f.bin"), "contentType": .string("application/octet-stream"),
            "sha256Base64": .string("c2hh"), "numBytes": .number(3), "status": .string("uploading"),
            "attempts": .number(1), "nextAttemptAt": .number(1_760_000_000_000),
            "createdAt": .number(1_760_000_000_000), "updatedAt": .number(1_760_000_000_000),
            "priority": .string("high"), "chunks": .array([.number(1)]),
        ])
        try await provider.put(store: "blobUploads:app-1:u-a", key: "B9", value: later, metadata: nil)
        let sparse: JSONValue = .object([
            "queueId": .string("B8"), "documentId": .string("doc-1"), "blobId": .string("B8"),
        ])
        try await provider.put(store: "blobUploads:app-1:u-a", key: "B8", value: sparse, metadata: nil)
        try await provider.put(store: "blobUploads:app-1:u-a", key: "junk", value: JSONValue.string("nope"), metadata: nil)

        let before = Date().timeIntervalSince1970 * 1000
        let loaded = try await store.loadBlobUploads(appId: "app-1", userId: "u-a")
        let byId = Dictionary(uniqueKeysWithValues: loaded.map { ($0.queueId, $0) })
        XCTAssertEqual(Set(byId.keys), ["B9", "B8"], "a row that is not a record is skipped, the rest load")
        XCTAssertEqual(byId["B9"]?.status, "uploading")
        XCTAssertEqual(byId["B9"]?.attempts, 1)
        let sparseRecord = try XCTUnwrap(byId["B8"])
        XCTAssertEqual(sparseRecord.status, "pending")
        XCTAssertEqual(sparseRecord.attempts, 0)
        XCTAssertEqual(sparseRecord.filename, "B8")
        XCTAssertEqual(sparseRecord.contentType, "application/octet-stream")
        XCTAssertNil(sparseRecord.destination, "a record without a destination is a document upload")
        XCTAssertGreaterThanOrEqual(sparseRecord.nextAttemptAt, before.rounded(.down))
        XCTAssertGreaterThanOrEqual(sparseRecord.createdAt, before.rounded(.down))
        await store.closeStorage()
    }

    // MARK: - No provider

    func testWithNoProviderBoundEveryCallReturnsWithoutEffect() async throws {
        let store = OfflineStore()
        try await store.putBlobUpload(appId: "app-1", userId: "u-a", record: Self.documentRecord(), bytes: Data("x".utf8))
        let loaded = try await store.loadBlobUploads(appId: "app-1", userId: "u-a")
        XCTAssertEqual(loaded, [])
        let bytes = try await store.loadBlobUploadBytes(appId: "app-1", userId: "u-a", documentId: "doc-1", blobId: "B1")
        XCTAssertNil(bytes)
        try await store.deleteBlobUpload(appId: "app-1", userId: "u-a", queueId: "B1", documentId: "doc-1", blobId: "B1")
    }

    /// A write for another user than the one the store is bound to does not
    /// re-bind it: the in-memory provider wipes every store on a re-bind, so
    /// re-binding would take the signed-in user's rows with it.
    func testAWriteForAnotherUserDoesNotRebindTheStore() async throws {
        let provider = MemoryStorageProvider()
        let store = OfflineStore()
        await store.setStorageProvider(provider)
        try await store.putMetadata(appId: "app-1", userId: "u-b", record: LocalMetadataEntry(documentId: "doc-b"))
        try await store.putBlobUpload(appId: "app-1", userId: "u-a", record: Self.documentRecord(), bytes: Data("x".utf8))
        let metadata = try await store.getMetadata(appId: "app-1", userId: "u-b", documentId: "doc-b")
        XCTAssertNotNil(metadata, "the signed-in user's rows survive another user's upload write")
        let loaded = try await store.loadBlobUploads(appId: "app-1", userId: "u-a")
        XCTAssertEqual(loaded.map(\.queueId), ["B1"])
    }
}
