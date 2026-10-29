import XCTest
@testable import JsBaoClient

/// #4943 behaviors 11 and 14 and edge cases E5, E7 and E8 — the db3 blob
/// family's offline contract, against the dev server.
///
/// - 11 and E5: while the client is offline an upload is stored and queued
///   with no request, answered with `bytesTransferred` 0, and burns no
///   attempt; a paused one waits for `resume` after going online; going
///   online completes the queue to the db3 route. The documents family is
///   unchanged.
/// - 14, E7 and E8: the db3 family's local copies are its own: served
///   offline when this family stored them, refused `.offline` with no
///   request when only the documents family did, and evicted by a db3
///   delete under every disposition without touching the documents copy.
final class Db3BlobOfflineLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-blob-offline-4943")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func isOffline(_ body: () async throws -> Void) async -> Bool {
        do {
            try await body()
            return false
        } catch let error as JsBaoError {
            return error.code == .offline
        } catch {
            return false
        }
    }

    // MARK: - Behavior 11 and E5

    func testAnOfflineUploadIsQueuedWithNoRequestAndCompletesOnceOnline() async throws {
        let owner = try await live.client("owner", models: [])
        let db3Id = try await createdOnServer(owner, title: "Offline").id
        let events = Db3BlobEventLog(owner)
        defer { events.cancel() }
        let blobs = owner.db3.blobs(db3Id)
        let bytes = Data("written offline \(UUID().uuidString)".utf8)

        owner.setNetworkMode(.offline)
        let queued = try await blobs.upload(data: bytes, options: BlobUploadSourceOptions(filename: "offline.txt", contentType: "text/plain"))
        XCTAssertEqual(queued.bytesTransferred, 0)
        XCTAssertEqual(queued.numBytes, bytes.count)
        let notYet = try await live.serverBlobIds("/db3/\(db3Id)/blobs")
        XCTAssertFalse(notYet.contains(queued.blobId), "nothing was sent")

        // Longer than the first backoff (2 s): no attempt is made offline.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let listed = await blobs.uploadsAsync()
        XCTAssertEqual(listed.map(\.blobId), [queued.blobId])
        XCTAssertEqual(listed.first?.status, "pending")
        XCTAssertEqual(listed.first?.attempts, 0)
        XCTAssertEqual(events.kinds(queued.blobId), ["progress:queued", "progress:pending"])
        XCTAssertTrue(events.of(queued.blobId).allSatisfy { $0.documentId == db3Id })

        // The local copy is served offline.
        let local = try await blobs.read(blobId: queued.blobId)
        XCTAssertEqual(local, bytes)

        // E5: a paused upload is not run by going online until it is resumed.
        let paused = await blobs.pauseUploadAsync(blobId: queued.blobId)
        XCTAssertTrue(paused)
        owner.setNetworkMode(.online)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let stillPaused = await blobs.uploadsAsync()
        XCTAssertEqual(stillPaused.first?.status, "paused")
        XCTAssertEqual(stillPaused.first?.attempts, 0)
        let stillNot = try await live.serverBlobIds("/db3/\(db3Id)/blobs")
        XCTAssertFalse(stillNot.contains(queued.blobId))

        let resumed = await blobs.resumeUploadAsync(blobId: queued.blobId)
        XCTAssertTrue(resumed)
        try await eventually(timeout: 20, description: "the queued upload completes") {
            events.kinds(queued.blobId).contains("completed")
        }
        let completed = try XCTUnwrap(events.of(queued.blobId).first { $0.kind == "completed" })
        XCTAssertEqual(completed.documentId, db3Id)
        XCTAssertEqual(completed.queueId, queued.blobId)
        XCTAssertFalse(events.kinds(queued.blobId).contains("failed"))
        let landed = try await live.serverBlobIds("/db3/\(db3Id)/blobs")
        XCTAssertTrue(landed.contains(queued.blobId))
        let remaining = await blobs.uploadsAsync()
        XCTAssertEqual(remaining.count, 0)
        let served = try await blobs.read(blobId: queued.blobId, force: true)
        XCTAssertEqual(served, bytes)
    }

    func testAnOfflineUploadCompletesWhenTheModeFlipsBack() async throws {
        let owner = try await live.client("owner", models: [])
        let db3Id = try await createdOnServer(owner, title: "Flip").id
        let blobs = owner.db3.blobs(db3Id)
        owner.setNetworkMode(.offline)
        let queued = try await blobs.upload(data: Data("flip".utf8))
        XCTAssertEqual(queued.bytesTransferred, 0)
        owner.setNetworkMode(.online)
        try await eventually(timeout: 20, description: "the upload lands once online") {
            try await self.live.serverBlobIds("/db3/\(db3Id)/blobs").contains(queued.blobId)
        }
        try await eventually(timeout: 5, description: "the queue empties") { await blobs.uploadsAsync().isEmpty }
    }

    /// The documents family keeps its own offline behavior: its upload is
    /// not gated on the network mode, and it lands now as it did before.
    func testTheDocumentsFamilyOfflineUploadIsUnchanged() async throws {
        let owner = try await live.client("owner", models: [])
        let plain = try await ctx.createDocument(appId: live.app.appId, jwt: live.app.ownerJWT, title: "format-1")
        owner.setNetworkMode(.offline)
        let uploaded = try await owner.documents.blobs(documentId: plain).upload(data: Data("documents".utf8))
        XCTAssertEqual(uploaded.bytesTransferred, uploaded.numBytes)
        let listed = try await live.serverBlobIds("/documents/\(plain)/blobs")
        XCTAssertTrue(listed.contains(uploaded.blobId))
        let queued = await owner.documents.uploadsAsync()
        XCTAssertEqual(queued.count, 0)
    }

    // MARK: - Behavior 14, E7 and E8

    func testTheDb3FamilysLocalCopiesAreItsOwn() async throws {
        let owner = try await live.client("owner", models: [])
        let other = try await live.client("owner-other", models: [])
        let db3Id = try await createdOnServer(owner, title: "Copies").id
        let plain = try await ctx.createDocument(appId: live.app.appId, jwt: live.app.ownerJWT, title: "format-1")
        let blobs = owner.db3.blobs(db3Id)

        // Uploaded through the db3 context, then read through it: served offline.
        let mine = try await blobs.upload(data: Data("mine".utf8))
        // Read through the documents family of the same id: a copy of its own.
        let viaDocuments = try await owner.documents.blobs(documentId: db3Id).read(blobId: mine.blobId)
        XCTAssertEqual(viaDocuments, Data("mine".utf8))
        let attachment = try await blobs.read(blobId: mine.blobId, disposition: .attachment)
        XCTAssertEqual(attachment, Data("mine".utf8))
        // A format-1 document's blob, read through the documents family only.
        let documentBlob = try await owner.documents.blobs(documentId: plain).upload(data: Data("format-1".utf8))
        _ = try await owner.documents.blobs(documentId: plain).read(blobId: documentBlob.blobId)
        // Two blobs another client uploaded: one prefetched here, one not.
        let prefetched = try await other.db3.blobs(db3Id).upload(data: Data("prefetched".utf8))
        let uncached = try await other.db3.blobs(db3Id).upload(data: Data("uncached".utf8))
        await blobs.prefetch(blobIds: [prefetched.blobId])

        owner.setNetworkMode(.offline)
        let served = try await blobs.read(blobId: mine.blobId)
        XCTAssertEqual(served, Data("mine".utf8))
        let servedPrefetch = try await blobs.read(blobId: prefetched.blobId)
        XCTAssertEqual(servedPrefetch, Data("prefetched".utf8))
        let documentsOnly = await isOffline { _ = try await owner.db3.blobs(plain).read(blobId: documentBlob.blobId) }
        XCTAssertTrue(documentsOnly, "a documents copy is not a db3 copy")

        // E7: an uncached read offline is refused, naming the blob; prefetch swallows it.
        do {
            _ = try await blobs.read(blobId: uncached.blobId)
            XCTFail("an uncached read offline must throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .offline)
            XCTAssertEqual(error.details?["blobId"], .string(uncached.blobId))
            XCTAssertTrue(error.message.contains(uncached.blobId), error.message)
        }
        await blobs.prefetch(blobIds: [uncached.blobId])
        let stillUncached = await isOffline { _ = try await blobs.read(blobId: uncached.blobId) }
        XCTAssertTrue(stillUncached)

        // E8: a db3 delete evicts the db3 copies under every disposition, and
        // not the documents family's copy of the same blob.
        owner.setNetworkMode(.online)
        let deleted = try await blobs.delete(blobId: mine.blobId)
        XCTAssertTrue(deleted.deleted)
        owner.setNetworkMode(.offline)
        let inlineGone = await isOffline { _ = try await blobs.read(blobId: mine.blobId) }
        XCTAssertTrue(inlineGone)
        let attachmentGone = await isOffline { _ = try await blobs.read(blobId: mine.blobId, disposition: .attachment) }
        XCTAssertTrue(attachmentGone)
        let documentsCopy = try await owner.documents.blobs(documentId: db3Id).read(blobId: mine.blobId)
        XCTAssertEqual(documentsCopy, Data("mine".utf8), "the documents family's copy is its own")
        owner.setNetworkMode(.online)
    }
}
