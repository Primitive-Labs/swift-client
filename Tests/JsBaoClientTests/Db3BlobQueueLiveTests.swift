import XCTest
@testable import JsBaoClient

/// #4943 behaviors 12, 13 and 17 and edge case E4 — a db3 upload that cannot
/// reach the server, against the dev server (the `BlobUploadRestartLiveTests`
/// pattern: a first client pointed at an unreachable port, the next one over
/// the same SQLite file).
///
/// - 12: the db3 upload is queued and answered with `bytesTransferred` 0
///   after one `willRetry: true` failure; the documents upload of the same id
///   still throws; each bound context lists and controls its own family only.
/// - 17: the app-wide `client.documents` verbs reach both, by id alone.
/// - 13: the db3 upload is stored with its destination and the next client
///   sends it to the db3 route; the documents one is stored as before.
/// - E4: with nobody signed in a db3 upload is queued unbound and not stored.
final class Db3BlobQueueLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-blob-queue-4943")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        for client in clients.reversed() { await client.destroy() }
        clients = []
        await live?.destroy()
        await ctx?.cleanup()
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
    }

    private func databasePath() throws -> String {
        let directory = NSTemporaryDirectory() + "jsbao-db3-queue-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory + "/jsbao_storage.sqlite"
    }

    /// A client over the SQLite file at `path`; `apiUrl` defaults to the dev server.
    private func client(
        token: String?, path: String, apiUrl: String = TestConfig.httpUrl, beforeStorage: (JsBaoClient) -> Void = { _ in }
    ) async -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: apiUrl,
            wsUrl: TestConfig.wsUrl,
            appId: live.app.appId,
            token: token,
            offline: false,
            globalAdminAppId: TestConfig.globalAdminAppId,
            wsHeaders: ["X-Global-Admin-App-Id": TestConfig.globalAdminAppId],
            logLevel: .warn,
            storageConfig: .sqlite(directory: path),
            autoNetwork: false
        ))
        clients.append(client)
        beforeStorage(client)
        _ = await client.waitForStorageReady()
        return client
    }

    private static let unreachable = "http://127.0.0.1:9"

    // MARK: - Behaviors 12, 17 and 13

    func testAQueuedDb3UploadIsScopedToItsFamilyStoredWithItsDestinationAndSentToTheDb3RouteByTheNextClient() async throws {
        let owner = try await live.client("owner", models: [])
        let db3Id = try await createdOnServer(owner, title: "Queued").id
        let plain = try await ctx.createDocument(appId: live.app.appId, jwt: live.app.ownerJWT, title: "format-1")
        let path = try databasePath()

        let first = await client(token: live.app.ownerJWT, path: path, apiUrl: Self.unreachable)
        let events = Db3BlobEventLog(first)
        defer { events.cancel() }
        let db3Blobs = first.db3.blobs(db3Id)
        let documentBlobs = first.documents.blobs(documentId: db3Id)

        // Behavior 12: the db3 upload is queued and answered, not thrown.
        let db3Bytes = Data("db3 bytes \(UUID().uuidString)".utf8)
        let queued = try await db3Blobs.upload(data: db3Bytes, options: BlobUploadSourceOptions(filename: "db3.txt", contentType: "text/plain"))
        XCTAssertEqual(queued.bytesTransferred, 0)
        // The immediate attempt: one retryable failure, then queued. (The
        // queue's own retries follow on its backoff.)
        let attempt = Array(events.of(queued.blobId).prefix(4))
        XCTAssertEqual(attempt.map { $0.status.map { "progress:\($0)" } ?? $0.kind }, ["progress:queued", "progress:uploading", "failed", "progress:pending"])
        XCTAssertEqual(attempt.first { $0.kind == "failed" }?.willRetry, true)
        XCTAssertTrue(attempt.allSatisfy { $0.documentId == db3Id && $0.queueId == queued.blobId })

        // The documents upload of the same id throws, as it always has.
        let before = Set(await first.documents.uploadsAsync().map(\.blobId))
        let documentFailure = await thrown { _ = try await documentBlobs.upload(data: Data("documents bytes".utf8)) }
        XCTAssertNotNil(documentFailure)
        let afterDocument = await first.documents.uploadsAsync().map(\.blobId)
        let documentBlobId = try XCTUnwrap(afterDocument.first { !before.contains($0) })

        // A db3 upload aimed at a format-1 document: the next client's db3
        // route refuses it, where the documents route would take it.
        let misaimed = try await first.db3.blobs(plain).upload(data: Data("misaimed".utf8))
        XCTAssertEqual(misaimed.bytesTransferred, 0)

        // Each bound context lists its own family only.
        let db3Listed = await db3Blobs.uploadsAsync()
        XCTAssertEqual(db3Listed.map(\.blobId), [queued.blobId])
        XCTAssertEqual(db3Listed.first?.documentId, db3Id)
        let documentListed = await documentBlobs.uploadsAsync()
        XCTAssertEqual(documentListed.map(\.blobId), [documentBlobId])

        // And controls its own family only.
        let pausedOther = await db3Blobs.pauseUploadAsync(blobId: documentBlobId)
        XCTAssertFalse(pausedOther, "the db3 context does not reach a documents upload")
        let paused = await db3Blobs.pauseUploadAsync(blobId: queued.blobId)
        XCTAssertTrue(paused)
        let status = { (blobId: String) async -> String? in
            await first.documents.uploadsAsync().first { $0.blobId == blobId }?.status
        }
        let pausedStatus = await status(queued.blobId)
        XCTAssertEqual(pausedStatus, "paused")
        let documentUntouched = await status(documentBlobId)
        XCTAssertNotEqual(documentUntouched, "paused")
        let resumedOther = await db3Blobs.resumeUploadAsync(blobId: documentBlobId)
        XCTAssertFalse(resumedOther)
        let resumed = await db3Blobs.resumeUploadAsync(blobId: queued.blobId)
        XCTAssertTrue(resumed)
        await db3Blobs.pauseAllAsync()
        let afterPauseAll = await status(queued.blobId)
        XCTAssertEqual(afterPauseAll, "paused")
        let documentAfterPauseAll = await status(documentBlobId)
        XCTAssertNotEqual(documentAfterPauseAll, "paused")
        await db3Blobs.resumeAllAsync()
        let afterResumeAll = await status(queued.blobId)
        XCTAssertNotEqual(afterResumeAll, "paused")

        // Behavior 17: the app-wide verbs match by id alone.
        let appWide = await first.documents.uploadsAsync(documentId: db3Id)
        XCTAssertEqual(Set(appWide.map(\.blobId)), [queued.blobId, documentBlobId])
        await first.documents.pauseAllUploadsAsync(documentId: db3Id)
        let bothPaused = await first.documents.uploadsAsync(documentId: db3Id)
        XCTAssertEqual(bothPaused.map(\.status), ["paused", "paused"])
        await first.documents.resumeAllUploadsAsync(documentId: db3Id)

        // Behavior 13: each upload is stored, the db3 ones with their destination.
        await first.blobManager.awaitPendingPersistence()
        let rows = try await UploadRows.read(path, appId: live.app.appId, userId: live.app.ownerUserId)
        XCTAssertEqual(Set(rows.records.map(\.blobId)), [queued.blobId, documentBlobId, misaimed.blobId])
        let db3Raw = try XCTUnwrap(rows.raw.first { $0.value["blobId"] == .string(queued.blobId) }?.value)
        XCTAssertEqual(db3Raw["destination"], ["kind": "db3", "documentId": .string(db3Id)])
        let documentRaw = try XCTUnwrap(rows.raw.first { $0.value["blobId"] == .string(documentBlobId) }?.value)
        XCTAssertNil(documentRaw["destination"], "a documents upload is stored as before")
        let misaimedRaw = try XCTUnwrap(rows.raw.first { $0.value["blobId"] == .string(misaimed.blobId) }?.value)
        XCTAssertEqual(misaimedRaw["destination"], ["kind": "db3", "documentId": .string(plain)])
        await first.destroy()

        // The next client, over the same file and against the dev server.
        var heard: Db3BlobEventLog?
        let next = await client(token: live.app.ownerJWT, path: path) { heard = Db3BlobEventLog($0) }
        let nextEvents = try XCTUnwrap(heard)
        defer { nextEvents.cancel() }
        try await eventually(timeout: 30, description: "the restored uploads settle") {
            await next.documents.uploadsAsync().isEmpty
        }
        let db3Listed2 = try await live.serverBlobIds("/db3/\(db3Id)/blobs")
        XCTAssertTrue(db3Listed2.contains(queued.blobId), "the db3 upload landed on the db3")
        XCTAssertTrue(db3Listed2.contains(documentBlobId), "the documents upload of the same id landed too")
        let served = try await next.db3.blobs(db3Id).read(blobId: queued.blobId, force: true)
        XCTAssertEqual(served, db3Bytes)
        // The misaimed one went to the db3 route: refused NOT_A_DB3, terminal,
        // and never listed under the format-1 document.
        let misaimedEvents = nextEvents.of(misaimed.blobId)
        XCTAssertEqual(misaimedEvents.filter { $0.kind == "failed" }.map(\.willRetry), [false], "\(misaimedEvents)")
        let plainListed = try await live.serverBlobIds("/documents/\(plain)/blobs")
        XCTAssertFalse(plainListed.contains(misaimed.blobId), "a db3 upload never replays to the documents route")
        let rowsAfter = try await UploadRows.read(path, appId: live.app.appId, userId: live.app.ownerUserId)
        XCTAssertEqual(rowsAfter.records.count, 0)
    }

    // MARK: - E4

    func testADb3UploadWithNobodySignedInIsQueuedUnboundAndNotStored() async throws {
        let owner = try await live.client("owner", models: [])
        let db3Id = try await createdOnServer(owner, title: "Unbound").id
        let path = try databasePath()
        let anonymous = await client(token: nil, path: path, apiUrl: Self.unreachable)
        let blobs = anonymous.db3.blobs(db3Id)
        let queued = try await blobs.upload(data: Data("nobody".utf8))
        XCTAssertEqual(queued.bytesTransferred, 0)
        let listed = await blobs.uploadsAsync()
        XCTAssertEqual(listed.map(\.blobId), [queued.blobId])
        await anonymous.blobManager.awaitPendingPersistence()
        let stored = try await UploadRows.countAll(path)
        XCTAssertEqual(stored, 0, "an unbound upload is never stored")
    }
}
