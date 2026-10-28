import XCTest
@testable import JsBaoClient

/// A document upload queued while a user is signed in belongs to that user
/// (#4592, plan behaviors 13 and 25, edge "a document delete issued by B";
/// spec DEC-4592-001): it is listed, attempted, paused and cancelled only
/// while they are signed in, each queued attempt sends the token taken when
/// it was selected, and an attempt whose user is no longer signed in when it
/// answers changes nothing.
///
/// A real client over `SessionUploadServer`, which records each request's
/// `Authorization`; the queue is driven through the public document members.
final class BlobUploadOwnershipHermeticTests: XCTestCase {
    private static let bytes = Data("document bytes".utf8)

    private static func isDocumentPut(_ request: LoopbackAPIServer.Request) -> Bool {
        request.method == "PUT" && request.apiPathOnly.hasPrefix("/documents/")
    }

    private static func documentPuts(_ server: SessionUploadServer, _ blobId: String) -> [LoopbackAPIServer.Request] {
        server.requests.filter { isDocumentPut($0) && $0.apiPathOnly.hasSuffix("/blobs/\(blobId)") }
    }

    /// Queue a document upload as the signed-in user: the immediate PUT is
    /// answered 503, so it is queued for retry. Returns its blob id.
    private static func queueDocumentUpload(_ client: JsBaoClient, documentId: String = "doc-1") async throws -> String {
        _ = await thrown { _ = try await client.documents.blobs(documentId: documentId).upload(data: bytes) }
        let listed = await client.documents.uploadsAsync()
        return try XCTUnwrap(listed.first?.blobId, "the upload is queued")
    }

    // MARK: - Behavior 13

    func testAnUploadQueuedByAIsInertWhileBIsSignedInAndRunsWithAsTokenWhenABack() async throws {
        let tokenA = makeTestJwt(userId: "u-a")
        let tokenB = makeTestJwt(userId: "u-b")
        let server = try SessionUploadServer { request in
            Self.isDocumentPut(request) ? .status(503, "busy") : SessionUploadServer.acceptAll(request)
        }
        defer { server.stop() }
        let client = makeSessionUploadClient(server, token: tokenA)
        let blobId = try await Self.queueDocumentUpload(client)
        // The queue's first retry follows at once; the next waits the backoff.
        try await eventually(timeout: 5, description: "the first retry") { Self.documentPuts(server, blobId).count == 2 }

        client.updateToken(tokenB)
        let listedForB = await client.documents.uploadsAsync()
        XCTAssertEqual(listedForB.map(\.blobId), [], "B does not see A's upload")
        let pausedByB = await client.documents.pauseUploadAsync(blobId: blobId)
        XCTAssertFalse(pausedByB, "nor pause it")
        await client.documents.pauseAllUploadsAsync()
        await client.blobManager.cancelQueuedUpload(documentId: "doc-1", blobId: blobId)

        server.answer(SessionUploadServer.acceptAll)
        try await Task.sleep(nanoseconds: 2_600_000_000)
        XCTAssertEqual(Self.documentPuts(server, blobId).count, 2, "A's upload is not attempted while B is signed in")

        server.hold(Self.isDocumentPut)
        client.updateToken(tokenA)
        try await eventually(timeout: 10, description: "A's upload is attempted once A is back") {
            server.heldRequests.count == 1
        }
        let listedForA = await client.documents.uploadsAsync()
        XCTAssertEqual(listedForA.map(\.blobId), [blobId], "B's delete and pause-all left A's upload in place")
        XCTAssertEqual(listedForA.first?.status, "uploading")
        server.hold(nil)
        server.release(SessionUploadServer.created(server.heldRequests[0]))
        try await eventually(timeout: 5, description: "and lands") { await client.documents.uploadsAsync().isEmpty }
        XCTAssertEqual(
            Self.documentPuts(server, blobId).map { $0.header("Authorization") },
            Array(repeating: "Bearer \(tokenA)", count: 3),
            "every PUT of A's upload carries A's token"
        )
        await client.destroy()
    }

    func testAQueuedAttemptSendsTheTokenTakenAtSelectionWhenTheUserChangesBeforeItLeaves() async throws {
        let tokenA = makeTestJwt(userId: "u-a")
        let tokenB = makeTestJwt(userId: "u-b")
        let server = try SessionUploadServer { request in
            Self.isDocumentPut(request) ? .status(503, "busy") : SessionUploadServer.acceptAll(request)
        }
        defer { server.stop() }
        let client = makeSessionUploadClient(server, token: tokenA)
        let blobId = try await Self.queueDocumentUpload(client)
        try await eventually(timeout: 5, description: "the first retry") { Self.documentPuts(server, blobId).count == 2 }

        // The next attempt is selected for A; B signs in while its
        // `uploading` frame is delivered, before the request leaves.
        let switched = LockedBox(false)
        let subscription = client.eventEmitter.subscribe(BlobUploadProgressEvent.self) { event in
            guard event.blobId == blobId, event.status == "uploading" else { return }
            let first = switched.withValue { (done: inout Bool) -> Bool in
                defer { done = true }
                return !done
            }
            if first { client.updateToken(tokenB) }
        }
        defer { subscription.cancel() }
        server.answer(SessionUploadServer.acceptAll)
        try await eventually(timeout: 10, description: "the selected attempt leaves") {
            Self.documentPuts(server, blobId).count == 3
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let authorizations = Self.documentPuts(server, blobId).map { $0.header("Authorization") }
        XCTAssertFalse(authorizations.contains("Bearer \(tokenB)"), "no PUT of A's upload carries B's token: \(authorizations)")
        XCTAssertEqual(authorizations.last, "Bearer \(tokenA)")
        await client.destroy()
    }

    // MARK: - Behavior 25

    func testAnAttemptThatAnswersAfterItsUserSignedOutChangesNothingAndRunsAgainForThem() async throws {
        let tokenA = makeTestJwt(userId: "u-a")
        let tokenB = makeTestJwt(userId: "u-b")
        let server = try SessionUploadServer { request in
            Self.isDocumentPut(request) ? .status(503, "busy") : SessionUploadServer.acceptAll(request)
        }
        defer { server.stop() }
        let client = makeSessionUploadClient(server, token: tokenA)
        let events = BlobEventLog(client)
        defer { events.cancel() }
        let blobId = try await Self.queueDocumentUpload(client)
        try await eventually(timeout: 5, description: "the first retry") { Self.documentPuts(server, blobId).count == 2 }
        let failedBefore = events.failed(blobId).count

        server.hold(Self.isDocumentPut)
        try await eventually(timeout: 10, description: "the next attempt is in flight") { server.heldRequests.count == 1 }
        client.updateToken(tokenB)
        server.hold(nil)
        server.answer(SessionUploadServer.acceptAll)
        server.release(SessionUploadServer.created(server.heldRequests[0]))
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(events.completed(blobId).count, 0, "no upload-completed under B")
        XCTAssertEqual(events.failed(blobId).count, failedBefore, "nor a failure")
        XCTAssertEqual(Self.documentPuts(server, blobId).count, 3, "nothing else leaves under B")

        client.updateToken(tokenA)
        try await eventually(timeout: 10, description: "the upload completes once A is back") {
            events.completed(blobId).count == 1
        }
        XCTAssertEqual(Self.documentPuts(server, blobId).count, 4, "attempted again for A")
        XCTAssertEqual(Self.documentPuts(server, blobId).last?.header("Authorization"), "Bearer \(tokenA)")
        let listed = await client.documents.uploadsAsync()
        XCTAssertEqual(listed.map(\.blobId), [])
        await client.destroy()
    }

    // MARK: - An upload queued with no user stays unbound

    func testAnUploadQueuedWithNoUserSignedInRunsWhoeverIsSignedIn() async throws {
        let tokenB = makeTestJwt(userId: "u-b")
        let server = try SessionUploadServer { request in
            Self.isDocumentPut(request) ? .status(503, "busy") : SessionUploadServer.acceptAll(request)
        }
        defer { server.stop() }
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: server.baseUrl, wsUrl: "ws://127.0.0.1:1", appId: "agent-session-uploads",
            token: nil, offline: false, logLevel: .none, storageConfig: .memory, autoNetwork: false
        ))
        let blobId = try await Self.queueDocumentUpload(client)
        try await eventually(timeout: 5, description: "the first retry") { Self.documentPuts(server, blobId).count == 2 }
        client.updateToken(tokenB)
        let listed = await client.documents.uploadsAsync()
        XCTAssertEqual(listed.map(\.blobId), [blobId], "an unbound upload is listed for whoever is signed in")
        server.answer(SessionUploadServer.acceptAll)
        try await eventually(timeout: 10, description: "and lands") { await client.documents.uploadsAsync().isEmpty }
        await client.destroy()
    }
}
