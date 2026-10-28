import XCTest
@testable import JsBaoClient

/// The attempts of an owned upload and the end of the queue (#4592, code
/// second opinion): the first document PUT sends its user's token and its
/// outcome is applied only while that user is signed in; a 401 answering a
/// token the transport has since refreshed is sent again with the new one;
/// a session upload returns, or sends its first PUT, only once its row is
/// written; `destroy()` ends every wait for an upload; and a bytes read that
/// fails at hydration keeps the stored upload.
///
/// The manager-level checks build a `BlobManager` over an `OfflineStore` and a
/// `RecordingTransport`; the rest run a real client over `SessionUploadServer`,
/// as `BlobUploadPersistenceHermeticTests` does.
final class BlobUploadOwnedAttemptHermeticTests: XCTestCase {
    private typealias P = BlobUploadPersistence
    private static let bytes = Data("owned attempt bytes".utf8)

    private var paths: [String] = []
    private var cleanups: [() async -> Void] = []

    override func tearDown() async throws {
        for cleanup in cleanups.reversed() { await cleanup() }
        cleanups = []
        for path in paths { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        paths = []
    }

    private func databasePath() throws -> String {
        let path = try P.databasePath()
        paths.append(path)
        return path
    }

    private func server(
        _ route: @escaping @Sendable (SessionUploadServer.Request) -> SessionUploadServer.Response = SessionUploadServer.acceptAll
    ) throws -> SessionUploadServer {
        let server = try SessionUploadServer(route)
        cleanups.append { server.stop() }
        return server
    }

    private func client(_ server: SessionUploadServer, path: String?) async -> JsBaoClient {
        let client = P.client(server, path: path)
        cleanups.append { await client.destroy() }
        _ = await client.waitForStorageReady()
        return client
    }

    private static func identity(_ userId: String, epoch: UInt64) -> UploadIdentity {
        UploadIdentity(token: "token-\(userId)", userId: userId, epoch: epoch)
    }

    /// A manager whose every emit is recorded by type name in `events`.
    private func manager(
        _ store: OfflineStore, identity: LockedBox<UploadIdentity>, transport: RecordingTransport,
        networking: Bool = true, events: LockedBox<[String]> = LockedBox([])
    ) -> BlobManager {
        let manager = BlobManager(
            logger: Logger(level: .error, scope: "test"),
            backoffBaseMs: 20,
            backoffMaxMs: 40,
            transport: transport,
            getAppId: { P.appId },
            emit: { payload in events.withValue { $0.append(String(describing: type(of: payload))) } },
            currentIdentity: { identity.value },
            networkingAllowed: { networking },
            offlineStore: store
        )
        cleanups.append {
            await manager.shutdown()
            await manager.awaitPendingPersistence()
            await store.closeStorage()
        }
        return manager
    }

    private static func answering(_ status: Int) -> RecordingTransport {
        RecordingTransport { _ in
            TransportResponse(status: status, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        }
    }

    private static func authorization(_ request: RecordedRequest) -> String? {
        request.options?.customHeaders["Authorization"]
    }

    // MARK: - The first document PUT and a change of user

    func testAUserChangeWhileTheFirstPutsRowIsWrittenSendsTheOwnersTokenAndKeepsTheUploadForThem() async throws {
        let path = try databasePath()
        let gated = GatedStorageProvider(SQLiteStorageProvider(path: path), gatingPuts: true)
        let store = OfflineStore()
        await store.setStorageProvider(gated)
        let identity = LockedBox(Self.identity("u-a", epoch: 1))
        let transport = Self.answering(503)
        let events = LockedBox([String]())
        let manager = manager(store, identity: identity, transport: transport, events: events)
        await manager.storageDidBecomeReady()

        let upload = Task { try await manager.uploadFromSource(documentId: "doc-1", source: Self.bytes) }
        try await eventually(timeout: 5, description: "the row write waits") { gated.gatedPuts.value >= 1 }
        XCTAssertEqual(transport.calls.count, 0, "the PUT waits for the write")
        identity.value = Self.identity("u-b", epoch: 2)
        await manager.syncIdentity()
        gated.release()

        let error = await thrown { _ = try await within(5, "the upload") { try await upload.value } }
        XCTAssertEqual((error as? HttpError)?.status, 503)
        XCTAssertEqual(transport.calls.map(Self.authorization), ["Bearer token-u-a"], "the PUT sends A's token, never B's")
        let listedForB = await manager.listUploads()
        XCTAssertEqual(listedForB.map(\.blobId), [], "B does not see A's upload")
        XCTAssertEqual(events.value, [], "nothing is emitted under B")
        await manager.awaitPendingPersistence()
        let rows = try await UploadRows.read(path)
        XCTAssertEqual(rows.records.map(\.status), ["pending"], "the upload stays stored for A")

        identity.value = Self.identity("u-a", epoch: 3)
        await manager.syncIdentity()
        let listedForA = await manager.listUploads()
        XCTAssertEqual(listedForA.count, 1, "A's sign-in re-adopts it")
        try await eventually(timeout: 5, description: "and it is attempted for A") { transport.calls.count >= 2 }
        XCTAssertEqual(transport.calls.map(Self.authorization).compactMap { $0 }.filter { $0 != "Bearer token-u-a" }, [])
    }

    func testAFirstPutThatLandsAfterAnotherUserSignedInDeletesTheRowsAndEmitsNothing() async throws {
        let path = try databasePath()
        let server = try server()
        server.hold(P.isDocumentPut)
        let client = await client(server, path: path)
        let events = OrderedBlobEvents(client)
        defer { events.cancel() }
        let upload = Task { try await client.documents.blobs(documentId: "doc-1").upload(data: Self.bytes) }
        try await eventually(timeout: 5, description: "the first PUT is held") { server.heldRequests.count == 1 }
        let blobId = P.blobId(of: server.heldRequests[0])

        client.updateToken(P.token("u-b"))
        server.hold(nil)
        server.release(SessionUploadServer.created(server.heldRequests[0]))
        let landed = try await within(5, "the upload") { try await upload.value }
        XCTAssertEqual(landed.blobId, blobId)
        XCTAssertEqual(events.labels(blobId), [], "no upload-completed under B")
        await client.blobManager.awaitPendingPersistence()
        let rows = try await UploadRows.read(path)
        XCTAssertNil(rows.record(blobId), "the upload landed for A: its rows go")
        XCTAssertEqual(rows.byteKeys, [])
    }

    func testAFirstPutRefusedAfterAnotherUserSignedInStaysQueuedForItsUser() async throws {
        let path = try databasePath()
        let server = try server()
        server.hold(P.isDocumentPut)
        let client = await client(server, path: path)
        let events = OrderedBlobEvents(client)
        defer { events.cancel() }
        let upload = Task { try await client.documents.blobs(documentId: "doc-1").upload(data: Self.bytes) }
        try await eventually(timeout: 5, description: "the first PUT is held") { server.heldRequests.count == 1 }
        let blobId = P.blobId(of: server.heldRequests[0])

        client.updateToken(P.token("u-b"))
        server.hold(nil)
        server.release(.status(400, "bad"))
        let error = await thrown { _ = try await within(5, "the upload") { try await upload.value } }
        XCTAssertEqual((error as? HttpError)?.status, 400)
        XCTAssertEqual(events.labels(blobId), [], "nothing is emitted under B")
        let listedForB = await client.documents.uploadsAsync()
        XCTAssertEqual(listedForB.map(\.blobId), [])
        await client.blobManager.awaitPendingPersistence()
        let rows = try await UploadRows.read(path)
        XCTAssertEqual(rows.record(blobId)?.status, "pending", "an outcome under B deletes nothing")
        XCTAssertEqual(rows.bytes["doc-1::\(blobId)"], Self.bytes)
        XCTAssertEqual(P.documentPuts(server, blobId).count, 1, "nothing leaves under B")

        client.updateToken(P.token("u-a"))
        try await eventually(timeout: 10, description: "A's sign-in attempts it and it lands") {
            events.labels(blobId).contains("completed")
        }
        XCTAssertEqual(P.documentPuts(server, blobId).last?.header("Authorization"), "Bearer \(P.token("u-a"))")
        try await eventually(timeout: 5, description: "and its rows go") {
            let rows = try await UploadRows.read(path)
            return rows.records.isEmpty && rows.byteKeys.isEmpty
        }
    }

    // MARK: - A 401 after the transport refreshed the owner's token

    private static func refreshingServerRoute(
        newToken: String, failFirstPut: Bool
    ) -> @Sendable (SessionUploadServer.Request) -> SessionUploadServer.Response {
        let documentPuts = LockedBox(0)
        return { request in
            if request.apiPathOnly == "/auth/refresh" { return .json(#"{"token":"\#(newToken)"}"#) }
            guard P.isDocumentPut(request) else { return SessionUploadServer.acceptAll(request) }
            let first = documentPuts.withValue { (count: inout Int) -> Bool in
                count += 1
                return count == 1
            }
            if failFirstPut, first { return .status(503, "busy") }
            return request.header("Authorization") == "Bearer \(newToken)"
                ? SessionUploadServer.created(request)
                : .status(401, "expired")
        }
    }

    func testAQueuedAttemptAnswered401AfterARefreshIsSentAgainWithTheOwnersNewToken() async throws {
        let tokenA = makeTestJwt(userId: "u-a", exp: 9_999_999_998)
        let tokenA2 = makeTestJwt(userId: "u-a", exp: 9_999_999_999)
        let server = try server(Self.refreshingServerRoute(newToken: tokenA2, failFirstPut: true))
        let client = makeSessionUploadClient(server, token: tokenA)
        cleanups.append { await client.destroy() }
        let events = OrderedBlobEvents(client)
        defer { events.cancel() }

        let error = await thrown { _ = try await client.documents.blobs(documentId: "doc-1").upload(data: Self.bytes) }
        XCTAssertEqual((error as? HttpError)?.status, 503, "the first PUT queues the upload")
        let first = try XCTUnwrap(server.requests.first { P.isDocumentPut($0) })
        let blobId = P.blobId(of: first)
        try await eventually(timeout: 10, description: "the queued attempt lands") {
            events.labels(blobId).contains("completed")
        }
        XCTAssertEqual(events.failed(blobId).map(\.willRetry), [true], "the 401 does not end the upload")
        XCTAssertEqual(
            P.documentPuts(server, blobId).map { $0.header("Authorization") },
            ["Bearer \(tokenA)", "Bearer \(tokenA)", "Bearer \(tokenA)", "Bearer \(tokenA2)"],
            "the transport's retry re-sends the pinned token; the attempt sends the refreshed one"
        )
        let listed = await client.documents.uploadsAsync()
        XCTAssertEqual(listed.map(\.blobId), [])
    }

    func testAFirstPutAnswered401AfterARefreshIsSentAgainWithTheOwnersNewToken() async throws {
        let tokenA = makeTestJwt(userId: "u-a", exp: 9_999_999_998)
        let tokenA2 = makeTestJwt(userId: "u-a", exp: 9_999_999_999)
        let server = try server(Self.refreshingServerRoute(newToken: tokenA2, failFirstPut: false))
        let client = makeSessionUploadClient(server, token: tokenA)
        cleanups.append { await client.destroy() }
        let events = OrderedBlobEvents(client)
        defer { events.cancel() }

        let landed = try await within(10, "the upload") {
            try await client.documents.blobs(documentId: "doc-1").upload(data: Self.bytes)
        }
        XCTAssertEqual(events.labels(landed.blobId), ["completed"], "event order unchanged")
        XCTAssertEqual(
            P.documentPuts(server, landed.blobId).map { $0.header("Authorization") },
            ["Bearer \(tokenA)", "Bearer \(tokenA)", "Bearer \(tokenA2)"]
        )
    }

    // MARK: - A session upload's row before it returns or sends

    func testASessionUploadQueuedOfflineReturnsOnlyOnceItsRowIsWritten() async throws {
        let path = try databasePath()
        let gated = GatedStorageProvider(SQLiteStorageProvider(path: path), gatingPuts: true)
        let store = OfflineStore()
        await store.setStorageProvider(gated)
        let manager = manager(
            store, identity: LockedBox(Self.identity("u-a", epoch: 1)), transport: Self.answering(201), networking: false
        )
        await manager.storageDidBecomeReady()

        let returned = LockedBox(false)
        let attachments = manager.forAgentSession(sessionId: "s1", documentId: "d1")
        let upload = Task {
            let attachment = try await attachments.upload(Self.bytes)
            returned.value = true
            return attachment
        }
        try await eventually(timeout: 5, description: "the row write waits") { gated.gatedPuts.value >= 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(returned.value, "upload does not return before its row is written")
        gated.release()
        let attachment = try await within(5, "the upload") { try await upload.value }

        // No drain: the row is in the file the moment `upload` returned.
        let rows = try await UploadRows.read(path)
        XCTAssertEqual(rows.record(attachment.blobId)?.status, "pending")
        XCTAssertEqual(rows.bytes["d1::\(attachment.blobId)"], Self.bytes)
    }

    func testASessionUploadsFirstPutLeavesOnlyOnceItsRowIsWritten() async throws {
        let path = try databasePath()
        let gated = GatedStorageProvider(SQLiteStorageProvider(path: path), gatingPuts: true)
        let store = OfflineStore()
        await store.setStorageProvider(gated)
        let transport = Self.answering(201)
        let manager = manager(store, identity: LockedBox(Self.identity("u-a", epoch: 1)), transport: transport)
        await manager.storageDidBecomeReady()

        let attachments = manager.forAgentSession(sessionId: "s1", documentId: "d1")
        let upload = Task { try await attachments.upload(Self.bytes) }
        try await eventually(timeout: 5, description: "the row write waits") { gated.gatedPuts.value >= 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.calls.count, 0, "the first PUT waits for the row")
        gated.release()
        _ = try await within(5, "the upload") { try await upload.value }
        XCTAssertEqual(transport.calls.count, 1)
        XCTAssertEqual(transport.calls.first.flatMap(Self.authorization), "Bearer token-u-a")
    }

    // MARK: - destroy() ends the waits

    func testDestroyEndsAWaitForAHeldSessionUploadAndRefusesLaterWaits() async throws {
        let path = try databasePath()
        let server = try server()
        server.hold(SessionUploadServer.isAttachmentPut)
        let client = await client(server, path: path)
        let attachments = client.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")
        let upload = Task { try await attachments.upload(Self.bytes) }
        cleanups.append { upload.cancel() }
        try await eventually(timeout: 5, description: "the session PUT is held") { server.heldRequests.count == 1 }
        let blobId = P.blobId(of: server.heldRequests[0])
        let ended = LockedBox<(any Error)?>(nil)
        let wait = Task {
            do { _ = try await attachments.waitUntilUploaded(blobId: blobId) } catch { ended.value = error }
        }
        cleanups.append { wait.cancel() }
        try await Task.sleep(nanoseconds: 100_000_000)

        await client.destroy()
        try await eventually(timeout: 5, description: "destroy ends the wait") { ended.value != nil }
        let error = ended.value
        XCTAssertEqual((error as? JsBaoError)?.code, .unavailable, "\(String(describing: error))")
        let later = await thrown { _ = try await attachments.waitUntilUploaded(blobId: blobId) }
        XCTAssertEqual((later as? JsBaoError)?.code, .unavailable, "\(String(describing: later))")

        server.hold(nil)
        server.release(SessionUploadServer.created(server.heldRequests[0]))
        _ = try? await within(5, "the upload call") { try await upload.value }
        let rows = try await UploadRows.read(path)
        XCTAssertEqual(rows.record(blobId)?.status, "uploading", "the upload stays stored for the next launch")
    }

    func testDestroyEndsASendWaitingOnAHeldSessionUpload() async throws {
        let path = try databasePath()
        let server = try server()
        let client = await client(server, path: path)
        let (view, _) = try await openLocalSessionView(client, server) { request in
            if request.method == "POST", request.apiPathOnly == "/agent-sessions/s1/messages" {
                return .json(#"{"messageId":"m-1","seq":1,"turnId":"t-1","queued":false}"#)
            }
            return SessionUploadServer.acceptAll(request)
        }
        server.hold(SessionUploadServer.isAttachmentPut)
        let upload = Task { try await view.attachments.upload(Self.bytes) }
        cleanups.append { upload.cancel() }
        try await eventually(timeout: 5, description: "the session PUT is held") { server.heldRequests.count == 1 }
        let blobId = P.blobId(of: server.heldRequests[0])
        let ended = LockedBox<(any Error)?>(nil)
        let send = Task {
            do {
                _ = try await view.send(
                    text: "see attached", files: [AgentSessionFileRef(blobId: blobId)], clientMessageId: "c1"
                )
            } catch { ended.value = error }
        }
        cleanups.append { send.cancel() }
        try await eventually(timeout: 5, description: "the send waits") {
            view.pendingMessages.first { $0.clientMessageId == "c1" }?.state == .waiting
        }

        await client.destroy()
        try await eventually(timeout: 5, description: "destroy ends the waiting send") { ended.value != nil }
        let error = ended.value
        XCTAssertEqual((error as? JsBaoError)?.code, .unavailable, "\(String(describing: error))")
        let posts = server.requests.filter { $0.method == "POST" && $0.apiPathOnly == "/agent-sessions/s1/messages" }
        XCTAssertEqual(posts.count, 0, "nothing is posted")
    }

    // MARK: - A bytes read that fails at hydration

    func testABytesReadThatFailsLeavesTheStoredUploadForTheNextHydration() async throws {
        let path = try databasePath()
        let now = (Date().timeIntervalSince1970 * 1000).rounded()
        let record = PersistedUploadRecord(
            queueId: "B-READ", documentId: "doc-1", blobId: "B-READ", filename: "B-READ.bin",
            contentType: "application/octet-stream", sha256Base64: BlobManager.sha256Base64(Self.bytes),
            disposition: nil, retainLocal: nil, numBytes: Self.bytes.count, status: "pending", attempts: 1,
            nextAttemptAt: now + 3_600_000, createdAt: now, updatedAt: now, lastError: "busy", lastErrorCode: nil,
            destination: nil
        )
        try await UploadRows.seed(path, record, bytes: Self.bytes)
        let flaky = GatedStorageProvider(SQLiteStorageProvider(path: path), failByteReads: 1)
        let store = OfflineStore()
        await store.setStorageProvider(flaky)
        let identity = LockedBox(Self.identity("u-a", epoch: 1))
        let manager = manager(store, identity: identity, transport: Self.answering(503))

        await manager.storageDidBecomeReady()
        XCTAssertEqual(flaky.failByteReads.value, 0, "the bytes read failed")
        let listed = await manager.listUploads()
        XCTAssertEqual(listed.map(\.blobId), [], "not restored this time")
        await manager.awaitPendingPersistence()
        let rows = try await UploadRows.read(path)
        XCTAssertNotNil(rows.record("B-READ"), "the record stays stored")
        XCTAssertEqual(rows.bytes["doc-1::B-READ"], Self.bytes, "and its bytes")

        identity.value = Self.identity("u-a", epoch: 2)
        await manager.syncIdentity()
        try await eventually(timeout: 5, description: "the next hydration restores it") {
            await manager.listUploads().map(\.blobId) == ["B-READ"]
        }
    }
}
