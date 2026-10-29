import XCTest
@testable import JsBaoClient

/// #4943 behaviors 10, 15 and 16 — `client.db3.blobs(id)` online, against the
/// dev server.
///
/// - 10: upload, list, get, read (bytes, text, JSON), the download URL and
///   delete over `db3/:id/blobs/*`; a reader lists and reads but cannot
///   upload or delete; deleting the db3 takes its blobs.
/// - 15: on a format-1 document the upload is refused `NOT_A_DB3` and is
///   terminal, and every other blob call is refused the same.
/// - 16: the upload events carry the db3 id; a `retainLocal: false` upload is
///   fetched again by `read`.
final class Db3BlobsLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private struct Payload: Codable, Equatable {
        let kind: String
        let count: Int
    }

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-blobs-4943")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    // MARK: - Behavior 10

    func testUploadListGetReadDownloadAndDeleteOverTheDb3Routes() async throws {
        let owner = try await live.client("owner", models: [])
        let db3Id = try await createdOnServer(owner, title: "Files").id
        let blobs = owner.db3.blobs(db3Id)
        let text = "hello from a db3 \(UUID().uuidString)"
        let uploaded = try await blobs.upload(
            data: Data(text.utf8), options: BlobUploadSourceOptions(filename: "hello.txt", contentType: "text/plain")
        )
        XCTAssertEqual(uploaded.numBytes, text.utf8.count)
        XCTAssertEqual(uploaded.bytesTransferred, uploaded.numBytes)
        XCTAssertEqual(uploaded.contentType, "text/plain")

        let page = try await blobs.list()
        XCTAssertEqual(page.items.map(\.blobId), [uploaded.blobId])
        let serverIds = try await live.serverBlobIds("/db3/\(db3Id)/blobs")
        XCTAssertEqual(serverIds, [uploaded.blobId])
        let info = try await blobs.get(blobId: uploaded.blobId)
        XCTAssertEqual(info.filename, "hello.txt")
        XCTAssertEqual(info.numBytes, text.utf8.count)

        let bytes = try await blobs.read(blobId: uploaded.blobId, force: true)
        XCTAssertEqual(bytes, Data(text.utf8))
        let asText = try await blobs.read(blobId: uploaded.blobId, as: String.self, force: true)
        XCTAssertEqual(asText, text)
        let payload = Payload(kind: "json", count: 3)
        let json = try await blobs.upload(data: try JSONEncoder().encode(payload), options: BlobUploadSourceOptions(contentType: "application/json"))
        let decoded = try await blobs.read(blobId: json.blobId, as: Payload.self, force: true)
        XCTAssertEqual(decoded, payload)

        let url = blobs.downloadUrl(blobId: uploaded.blobId, disposition: .attachment)
        XCTAssertTrue(url.contains("/api/db3/\(db3Id)/blobs/\(uploaded.blobId)/download"), url)
        let fetched = try await live.authenticatedGet(url, jwt: live.app.ownerJWT)
        XCTAssertEqual(fetched.0, 200)
        XCTAssertEqual(fetched.1, Data(text.utf8))

        // A reader lists and reads, and may neither upload nor delete.
        let bob = try await ctx.createTestUser(appId: live.app.appId)
        _ = try await owner.db3.permissions(db3Id).set(.user(bob.userId, permission: "reader"))
        let bobClient = try await live.client("bob", models: [], token: bob.jwt)
        let bobBlobs = bobClient.db3.blobs(db3Id)
        let bobPage = try await bobBlobs.list()
        XCTAssertEqual(Set(bobPage.items.map(\.blobId)), [uploaded.blobId, json.blobId])
        let bobRead = try await bobBlobs.read(blobId: uploaded.blobId)
        XCTAssertEqual(bobRead, Data(text.utf8))
        let bobUpload = await db3BlobRefusal { _ = try await bobBlobs.upload(data: Data("no".utf8)) }
        XCTAssertEqual(bobUpload.0, 403)
        let bobDelete = await db3BlobRefusal { _ = try await bobBlobs.delete(blobId: uploaded.blobId) }
        XCTAssertEqual(bobDelete.0, 403)
        let bobQueued = await bobBlobs.uploadsAsync()
        XCTAssertEqual(bobQueued.count, 0, "a refused upload is not queued")

        let deleted = try await blobs.delete(blobId: uploaded.blobId)
        XCTAssertTrue(deleted.deleted)
        let afterDelete = await db3BlobRefusal { _ = try await blobs.read(blobId: uploaded.blobId, force: true) }
        XCTAssertEqual(afterDelete.0, 404)

        // Deleting the db3 takes its blobs.
        let kept = blobs.downloadUrl(blobId: json.blobId)
        _ = try await owner.db3.delete(db3Id)
        let gone = try await live.authenticatedGet(kept, jwt: live.app.ownerJWT)
        XCTAssertEqual(gone.0, 404)
    }

    // MARK: - Behavior 15

    func testAFormat1DocumentRefusesEveryDb3BlobCallAndTheUploadIsTerminal() async throws {
        let owner = try await live.client("owner", models: [])
        let plain = try await ctx.createDocument(appId: live.app.appId, jwt: live.app.ownerJWT, title: "format-1")
        let events = Db3BlobEventLog(owner)
        defer { events.cancel() }
        let blobs = owner.db3.blobs(plain)

        let refused = await db3BlobRefusal { _ = try await blobs.upload(data: Data("not here".utf8)) }
        XCTAssertEqual(refused.0, 409)
        XCTAssertEqual(refused.1, "NOT_A_DB3")
        let queued = await blobs.uploadsAsync()
        XCTAssertEqual(queued.count, 0, "a NOT_A_DB3 upload is not queued")
        let failed = events.all.filter { $0.kind == "failed" }
        XCTAssertEqual(failed.count, 1, "\(events.all)")
        XCTAssertEqual(failed.first?.willRetry, false)
        XCTAssertEqual(failed.first?.documentId, plain)
        let blobId = try XCTUnwrap(failed.first?.blobId)
        let cached = await owner.blobManager.hasCachedBytes(documentId: plain, blobId: blobId, family: .db3)
        XCTAssertFalse(cached, "no local copy is kept")
        let documentsListed = try await live.serverBlobIds("/documents/\(plain)/blobs")
        XCTAssertFalse(documentsListed.contains(blobId))

        let list = await db3BlobRefusal { _ = try await blobs.list() }
        XCTAssertEqual(list.0, 409)
        XCTAssertEqual(list.1, "NOT_A_DB3")
        let get = await db3BlobRefusal { _ = try await blobs.get(blobId: blobId) }
        XCTAssertEqual(get.0, 409)
        XCTAssertEqual(get.1, "NOT_A_DB3")
        let read = await db3BlobRefusal { _ = try await blobs.read(blobId: blobId, force: true) }
        XCTAssertEqual(read.0, 409)
        XCTAssertEqual(read.1, "NOT_A_DB3")
        let download = try await live.authenticatedGet(blobs.downloadUrl(blobId: blobId), jwt: live.app.ownerJWT)
        XCTAssertEqual(download.0, 409)
        XCTAssertTrue(String(decoding: download.1, as: UTF8.self).contains("NOT_A_DB3"))
        let delete = await db3BlobRefusal { _ = try await blobs.delete(blobId: blobId) }
        XCTAssertEqual(delete.0, 409)
        XCTAssertEqual(delete.1, "NOT_A_DB3")
    }

    // MARK: - Behavior 16

    func testTheUploadEventsCarryTheDb3IdAndAnUnretainedUploadIsFetchedAgain() async throws {
        let owner = try await live.client("owner", models: [])
        let db3Id = try await createdOnServer(owner, title: "Events").id
        let events = Db3BlobEventLog(owner)
        defer { events.cancel() }
        let blobs = owner.db3.blobs(db3Id)

        let uploaded = try await blobs.upload(data: Data("evented".utf8))
        try await eventually(timeout: 5, description: "the completed event") { events.kinds(uploaded.blobId).contains("completed") }
        let entries = events.of(uploaded.blobId)
        XCTAssertFalse(entries.filter { $0.kind == "progress" }.isEmpty, "\(entries)")
        XCTAssertTrue(entries.allSatisfy { $0.documentId == db3Id && $0.queueId == uploaded.blobId }, "\(entries)")
        XCTAssertFalse(entries.contains { $0.kind == "failed" })

        let unretained = try await blobs.upload(data: Data("not kept".utf8), options: BlobUploadSourceOptions(retainLocal: false))
        XCTAssertEqual(unretained.bytesTransferred, unretained.numBytes)
        owner.setNetworkMode(.offline)
        let kept = try await blobs.read(blobId: uploaded.blobId)
        XCTAssertEqual(kept, Data("evented".utf8), "a retained upload is served from its local copy")
        let refetch = await db3BlobRefusal { _ = try await blobs.read(blobId: unretained.blobId) }
        XCTAssertEqual(refetch.1, JsBaoErrorCode.offline.rawValue, "an unretained upload has no local copy: read asks the server")
        owner.setNetworkMode(.online)
        let fetched = try await blobs.read(blobId: unretained.blobId)
        XCTAssertEqual(fetched, Data("not kept".utf8))
    }
}
