import XCTest
@testable import JsBaoClient

/// The upload queue survives the process (#4592): a queued or in-flight
/// upload is written to the client's own database before its first attempt
/// and restored by the next client for the same app and user over the same
/// file, where it behaves as an upload queued in that process.
///
/// A "restart" is a second `JsBaoClient` over the same `.sqlite(directory:)`
/// file, after `destroy()` of the first or with the first abandoned and still
/// alive (behavior 27). Each client has its own `SessionUploadServer`, so the
/// first client's attempts can be held while the second's are answered. Rows
/// are read through a second connection to the file (`UploadRows`).
final class BlobUploadPersistenceHermeticTests: XCTestCase {
    private typealias P = BlobUploadPersistence
    private static let bytes = Data("bytes that outlive the process".utf8)
    private static let busy: @Sendable (SessionUploadServer.Request) -> SessionUploadServer.Response = { request in
        if P.isDocumentPut(request) || SessionUploadServer.isAttachmentPut(request) { return .status(503, "busy") }
        return SessionUploadServer.acceptAll(request)
    }

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

    private func client(
        _ server: SessionUploadServer, path: String?, userId: String = "u-a", appId: String = P.appId,
        signedIn: Bool = true
    ) async -> JsBaoClient {
        let client = P.client(server, path: path, userId: userId, appId: appId, signedIn: signedIn)
        cleanups.append { await client.destroy() }
        _ = await client.waitForStorageReady()
        return client
    }

    /// The first client: a document upload queued after a 503, its retries
    /// held in flight. Returns the client and the blob id.
    private func queuedByFirstClient(
        _ path: String, options: BlobUploadSourceOptions = BlobUploadSourceOptions()
    ) async throws -> (client: JsBaoClient, server: SessionUploadServer, blobId: String) {
        let first = try server(Self.busy)
        P.holdDocumentRetries(first)
        let client = await client(first, path: path)
        let blobId = try await P.queueDocumentUpload(client, data: Self.bytes, options: options)
        try await eventually(timeout: 5, description: "the first retry is in flight") { first.heldRequests.count == 1 }
        return (client, first, blobId)
    }

    // MARK: - Behaviors 1, 3, 6 and 11: a document upload across a restart

    func testAQueuedDocumentUploadIsRestoredByTheNextClientAndCompletesWithItsUsersToken() async throws {
        let path = try databasePath()
        let first = try server(Self.busy)
        P.holdDocumentRetries(first)
        let client1 = await client(first, path: path)
        let options = BlobUploadSourceOptions(filename: "notes.txt", contentType: "text/plain")
        let blobId = try await P.queueDocumentUpload(client1, data: Self.bytes, options: options)

        // Behavior 1: written, with its bytes, before `upload` threw.
        let written = try await UploadRows.read(path)
        let record = try XCTUnwrap(written.record(blobId), "the record is stored before upload throws")
        XCTAssertEqual(record.attempts, 1)
        XCTAssertNotNil(record.lastError)
        XCTAssertTrue(["pending", "uploading"].contains(record.status), record.status)
        XCTAssertEqual(written.bytes["doc-1::\(blobId)"], Self.bytes)

        // Behavior 6: the JS field set, ms times, no destination, never `uploaded`.
        guard case .object(let object)? = written.raw[blobId] else { return XCTFail("the record is a JSON object") }
        let allowed: Set<String> = [
            "queueId", "documentId", "blobId", "filename", "contentType", "sha256Base64", "disposition",
            "retainLocal", "numBytes", "status", "attempts", "nextAttemptAt", "createdAt", "updatedAt",
            "lastError", "lastErrorCode", "destination",
        ]
        let required: Set<String> = [
            "queueId", "documentId", "blobId", "filename", "contentType", "sha256Base64", "numBytes", "status",
            "attempts", "nextAttemptAt", "createdAt", "updatedAt",
        ]
        XCTAssertTrue(Set(object.keys).isSubset(of: allowed), "\(Set(object.keys).subtracting(allowed))")
        XCTAssertTrue(required.isSubset(of: Set(object.keys)), "\(required.subtracting(Set(object.keys)))")
        XCTAssertNil(object["destination"], "a document upload carries no destination")
        XCTAssertEqual(object["queueId"], .string(blobId))
        XCTAssertEqual(object["numBytes"], .number(Double(Self.bytes.count)))
        XCTAssertEqual(object["sha256Base64"], .string(BlobManager.sha256Base64(Self.bytes)))
        if case .number(let createdAt)? = object["createdAt"] {
            XCTAssertEqual(createdAt, createdAt.rounded(), "whole milliseconds")
            XCTAssertEqual(createdAt / 1000, Date().timeIntervalSince1970, accuracy: 60, "ms since the epoch")
        } else {
            XCTFail("createdAt is a number")
        }

        // Behavior 3: destroyed with its retry in flight, the record stays as written.
        try await eventually(timeout: 5, description: "the retry is in flight") { first.heldRequests.count == 1 }
        await client1.destroy()
        let afterDestroy = try await UploadRows.read(path)
        XCTAssertEqual(afterDestroy.record(blobId)?.status, "uploading", "shutdown neither deletes nor re-queues it")
        XCTAssertEqual(afterDestroy.byteKeys, ["doc-1::\(blobId)"])

        // The next client restores it and completes it on the document route.
        let second = try server()
        second.hold(P.isDocumentPut)
        let client2 = P.client(second, path: path)
        cleanups.append { await client2.destroy() }
        let events = OrderedBlobEvents(client2)
        defer { events.cancel() }
        _ = await client2.waitForStorageReady()
        let listedValue = await client2.documents.uploadsAsync().first { $0.blobId == blobId }
        let listed = try XCTUnwrap(listedValue)
        XCTAssertEqual(listed.queueId, blobId)
        XCTAssertEqual(listed.filename, "notes.txt")
        XCTAssertEqual(listed.contentType, "text/plain")
        XCTAssertEqual(listed.numBytes, Self.bytes.count)
        XCTAssertEqual(listed.attempts, record.attempts)
        XCTAssertEqual(listed.lastError, record.lastError)
        XCTAssertTrue(["pending", "uploading"].contains(listed.status), "restored `uploading` reads pending until attempted")
        try await eventually(timeout: 5, description: "the restored upload is attempted") { second.heldRequests.count == 1 }
        let put = second.heldRequests[0]
        XCTAssertEqual(put.apiPathOnly, "/documents/doc-1/blobs/\(blobId)")
        XCTAssertEqual(put.header("Authorization"), "Bearer \(P.token("u-a"))")
        XCTAssertEqual(put.body, Self.bytes)
        second.hold(nil)
        second.release(SessionUploadServer.created(put))
        try await eventually(timeout: 5, description: "it completes") { events.labels(blobId).contains("completed") }
        XCTAssertEqual(events.labels(blobId), ["progress:uploading", "completed"], "hydration emits nothing")
        try await eventually(timeout: 5, description: "queue-drained") { events.drained >= 1 }

        // Behavior 11: completion deletes the rows; the bytes stay in memory.
        try await eventually(timeout: 5, description: "the rows are deleted") {
            let rows = try await UploadRows.read(path)
            return rows.records.isEmpty && rows.byteKeys.isEmpty
        }
        let read = try await client2.documents.blobs(documentId: "doc-1").read(blobId: blobId)
        XCTAssertEqual(read, Self.bytes, "served from the memory cache")
        await client2.destroy()

        let third = try server()
        let client3 = await client(third, path: path)
        let restored = await client3.documents.uploadsAsync()
        XCTAssertEqual(restored.map(\.blobId), [], "a later client restores nothing")
    }

    // MARK: - Behavior 2: a session upload across a restart

    func testASessionUploadQueuedOfflineIsRestoredWithItsDestinationAndLandsOnTheSessionRoute() async throws {
        let path = try databasePath()
        let first = try server()
        let client1 = await client(first, path: path)
        client1.setNetworkMode(.offline)
        let attachment = try await client1.blobManager.forAgentSession(sessionId: "s1", documentId: "d1").upload(Self.bytes)
        await client1.blobManager.awaitPendingPersistence()
        let rows = try await UploadRows.read(path)
        let record = try XCTUnwrap(rows.record(attachment.blobId))
        XCTAssertEqual(record.destination, .agentSession("s1"))
        XCTAssertEqual(record.status, "pending")
        XCTAssertEqual(rows.bytes["d1::\(attachment.blobId)"], Self.bytes)
        XCTAssertEqual(first.attachmentPuts.count, 0)
        await client1.destroy()

        let second = try server()
        second.hold(SessionUploadServer.isAttachmentPut)
        let client2 = await client(second, path: path)
        let attachments = client2.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")
        let listed = await attachments.uploads()
        XCTAssertEqual(listed.map(\.blobId), [attachment.blobId])
        let wait = Task { try await attachments.waitUntilUploaded(blobId: attachment.blobId) }
        try await eventually(timeout: 5, description: "the session PUT leaves") { second.heldRequests.count == 1 }
        let put = second.heldRequests[0]
        XCTAssertEqual(put.apiPathOnly, "/agent-sessions/s1/attachments/\(attachment.blobId)")
        XCTAssertEqual(put.header("Authorization"), "Bearer \(P.token("u-a"))")
        try await Task.sleep(nanoseconds: 100_000_000)
        second.hold(nil)
        second.release(SessionUploadServer.created(put))
        let landed = try await within(10, "the wait") { try await wait.value }
        XCTAssertEqual(landed, attachment)
    }

    // MARK: - Behavior 4: another user restores nothing

    func testAClientForAnotherUserRestoresNothingAndTheOwnerGetsItBack() async throws {
        let path = try databasePath()
        let (client1, _, blobId) = try await queuedByFirstClient(path)
        client1.setNetworkMode(.offline)
        let session = try await client1.blobManager.forAgentSession(sessionId: "s1", documentId: "d1").upload(Self.bytes)
        await client1.destroy()
        let ownerRows = try await UploadRows.read(path)
        XCTAssertEqual(Set(ownerRows.records.map(\.queueId)), [blobId, session.blobId])

        let other = try server()
        let clientB = await client(other, path: path, userId: "u-b")
        let documentUploads = await clientB.documents.uploadsAsync()
        XCTAssertEqual(documentUploads.map(\.blobId), [])
        let sessionUploads = await clientB.blobManager.forAgentSession(sessionId: "s1", documentId: "d1").uploads()
        XCTAssertEqual(sessionUploads.map(\.blobId), [])
        try await Task.sleep(nanoseconds: 2_600_000_000)
        XCTAssertEqual(other.requests.filter { $0.method == "PUT" }.count, 0, "nothing is attempted for B")
        await clientB.destroy()
        let untouched = try await UploadRows.read(path)
        XCTAssertEqual(untouched.records, ownerRows.records, "the owner's rows are untouched")

        let owner = try server()
        let clientA = await client(owner, path: path)
        let attachments = clientA.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")
        _ = try await within(10, "the session upload") { try await attachments.waitUntilUploaded(blobId: session.blobId) }
        try await eventually(timeout: 10, description: "the owner's next client completes both") {
            await clientA.documents.uploadsAsync().isEmpty && P.documentPuts(owner, blobId).count == 1
        }
    }

    // MARK: - Behavior 5: another app restores nothing

    func testAClientForAnotherAppOverTheSameFileRestoresNothingAndWritesNoOwnerRows() async throws {
        let path = try databasePath()
        let (client1, _, _) = try await queuedByFirstClient(path)
        await client1.destroy()
        let before = try await UploadRows.read(path)

        let other = try server()
        let otherApp = await client(other, path: path, appId: "another-app")
        let listed = await otherApp.documents.uploadsAsync()
        XCTAssertEqual(listed.map(\.blobId), [])
        _ = try? await otherApp.documents.blobs(documentId: "doc-9").upload(data: Data("other".utf8))
        await otherApp.blobManager.awaitPendingPersistence()
        try await Task.sleep(nanoseconds: 300_000_000)
        let ownerBlobId = try XCTUnwrap(before.records.first?.blobId)
        XCTAssertEqual(P.documentPuts(other, ownerBlobId).count, 0)
        let after = try await UploadRows.read(path)
        XCTAssertEqual(after.records, before.records, "no row is written under the owner's stores")
        XCTAssertEqual(after.byteKeys, before.byteKeys)
    }

    // MARK: - Behavior 7: a refused session upload stays failed

    func testARefusedSessionUploadIsRestoredFailedAndLandsOnlyOnResume() async throws {
        let path = try databasePath()
        let code = "AGENT_SESSION_PARTICIPANT_ONLY"
        let first = try server { request in
            SessionUploadServer.isAttachmentPut(request)
                ? SessionUploadServer.refused(403, code, "participants only")
                : SessionUploadServer.acceptAll(request)
        }
        let client1 = await client(first, path: path)
        let refusal = await thrown { _ = try await client1.blobManager.forAgentSession(sessionId: "s1", documentId: "d1").upload(Self.bytes) }
        XCTAssertEqual((refusal as? HttpError)?.serverCode, code)
        let blobId = P.blobId(of: try XCTUnwrap(first.attachmentPuts.first))
        await client1.blobManager.awaitPendingPersistence()
        let rows = try await UploadRows.read(path)
        XCTAssertEqual(rows.record(blobId)?.status, "failed")
        XCTAssertEqual(rows.record(blobId)?.lastErrorCode, code)
        XCTAssertEqual(rows.bytes["d1::\(blobId)"], Self.bytes)
        await client1.destroy()

        let second = try server()
        let client2 = await client(second, path: path)
        let attachments = client2.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")
        let listedValue = await attachments.uploads().first
        let listed = try XCTUnwrap(listedValue)
        XCTAssertEqual(listed.blobId, blobId)
        XCTAssertEqual(listed.state, .failed)
        XCTAssertEqual(listed.error?.code, code)
        try await Task.sleep(nanoseconds: 2_600_000_000)
        XCTAssertEqual(second.attachmentPuts.count, 0, "a failed upload is not attempted until resumed")
        let waitError = await thrown { _ = try await attachments.waitUntilUploaded(blobId: blobId) }
        XCTAssertEqual((waitError as? HttpError)?.serverCode, code)

        let resumed = await attachments.resume(blobId: blobId)
        XCTAssertTrue(resumed)
        let landed = try await within(10, "the resumed upload") { try await attachments.waitUntilUploaded(blobId: blobId) }
        XCTAssertEqual(landed.blobId, blobId)
        XCTAssertEqual(second.puts(of: blobId).count, 1)
    }

    // MARK: - Behavior 8: paused stays paused

    func testAPausedDocumentUploadIsRestoredPausedAndAttemptedOnlyOnResume() async throws {
        let path = try databasePath()
        let (client1, _, blobId) = try await queuedByFirstClient(path)
        let paused = await client1.documents.pauseUploadAsync(blobId: blobId)
        XCTAssertTrue(paused)
        await client1.blobManager.awaitPendingPersistence()
        let pausedRows = try await UploadRows.read(path)
        XCTAssertEqual(pausedRows.record(blobId)?.status, "paused")
        await client1.destroy()

        let second = try server()
        let client2 = P.client(second, path: path)
        cleanups.append { await client2.destroy() }
        let events = OrderedBlobEvents(client2)
        defer { events.cancel() }
        _ = await client2.waitForStorageReady()
        let listed = await client2.documents.uploadsAsync()
        XCTAssertEqual(listed.map(\.status), ["paused"])
        try await Task.sleep(nanoseconds: 2_600_000_000)
        XCTAssertEqual(P.documentPuts(second, blobId).count, 0, "not attempted while paused")

        let resumed = await client2.documents.resumeUploadAsync(blobId: blobId)
        XCTAssertTrue(resumed)
        try await eventually(timeout: 1, description: "attempted at once") { P.documentPuts(second, blobId).count == 1 }
        try await eventually(timeout: 5, description: "and lands") { events.labels(blobId).contains("completed") }
        XCTAssertEqual(Array(events.labels(blobId).prefix(3)), ["resumed", "progress:pending", "progress:uploading"])
    }

    // MARK: - Behavior 9: pause and resume on a restored upload

    func testPauseAndResumeActOnARestoredUploadAndTheRowFollows() async throws {
        let path = try databasePath()
        let (client1, _, blobId) = try await queuedByFirstClient(path)
        await client1.destroy()

        let second = try server(Self.busy)
        let client2 = P.client(second, path: path)
        cleanups.append { await client2.destroy() }
        let events = OrderedBlobEvents(client2)
        defer { events.cancel() }
        _ = await client2.waitForStorageReady()
        try await eventually(timeout: 5, description: "the restored attempt fails") { !events.failed(blobId).isEmpty }

        let paused = await client2.documents.pauseUploadAsync(blobId: blobId)
        XCTAssertTrue(paused)
        XCTAssertEqual(Array(events.labels(blobId).suffix(2)), ["paused", "progress:paused"])
        await client2.blobManager.awaitPendingPersistence()
        var rows = try await UploadRows.read(path)
        XCTAssertEqual(rows.record(blobId)?.status, "paused")

        let resumed = await client2.documents.resumeUploadAsync(blobId: blobId)
        XCTAssertTrue(resumed)
        await client2.blobManager.awaitPendingPersistence()
        rows = try await UploadRows.read(path)
        XCTAssertNotEqual(rows.record(blobId)?.status, "paused")

        let context = client2.documents.blobs(documentId: "doc-1")
        await context.pauseAllAsync()
        let listed = await context.uploadsAsync()
        XCTAssertEqual(listed.map(\.status), ["paused"])
        await client2.blobManager.awaitPendingPersistence()
        rows = try await UploadRows.read(path)
        XCTAssertEqual(rows.record(blobId)?.status, "paused")

        await context.resumeAllAsync()
        await client2.blobManager.awaitPendingPersistence()
        rows = try await UploadRows.read(path)
        XCTAssertNotEqual(rows.record(blobId)?.status, "paused")
    }

    // MARK: - Behavior 10: cancel

    func testCancellingRestoredUploadsDeletesTheirRowsAndDrainsTheQueue() async throws {
        let path = try databasePath()
        let (client1, _, blobId) = try await queuedByFirstClient(path)
        client1.setNetworkMode(.offline)
        let session = try await client1.blobManager.forAgentSession(sessionId: "s1", documentId: "d1").upload(Self.bytes)
        await client1.destroy()

        let second = try server { request in
            if request.method == "DELETE", request.apiPathOnly.hasPrefix("/documents/doc-1/blobs/") {
                return .json(#"{"deleted":true}"#)
            }
            return Self.busy(request)
        }
        let client2 = P.client(second, path: path)
        cleanups.append { await client2.destroy() }
        let events = OrderedBlobEvents(client2)
        defer { events.cancel() }
        _ = await client2.waitForStorageReady()
        let queued = await client2.documents.uploadsAsync()
        XCTAssertEqual(queued.map(\.blobId), [blobId])

        _ = try await client2.documents.blobs(documentId: "doc-1").delete(blobId: blobId)
        let afterDelete = await client2.documents.uploadsAsync()
        XCTAssertEqual(afterDelete.map(\.blobId), [])
        XCTAssertEqual(events.drained, 0, "the session upload is still queued")
        let cancelled = await client2.blobManager.forAgentSession(sessionId: "s1", documentId: "d1").cancel(blobId: session.blobId)
        XCTAssertTrue(cancelled)
        XCTAssertEqual(events.drained, 1, "queue-drained once the queue is empty")
        await client2.blobManager.awaitPendingPersistence()
        let rows = try await UploadRows.read(path)
        XCTAssertEqual(rows.records, [])
        XCTAssertEqual(rows.byteKeys, [])
        await client2.destroy()

        let third = try server()
        let client3 = await client(third, path: path)
        let restored = await client3.documents.uploadsAsync()
        XCTAssertEqual(restored.map(\.blobId), [])
    }

    // MARK: - Behavior 12: a terminal failure

    func testATerminalFailureOfARestoredUploadDeletesItsRowsAndEmitsOneFailure() async throws {
        let path = try databasePath()
        let (client1, _, blobId) = try await queuedByFirstClient(path)
        await client1.destroy()

        let second = try server { request in
            P.isDocumentPut(request) ? .status(400, "bad") : SessionUploadServer.acceptAll(request)
        }
        let client2 = P.client(second, path: path)
        cleanups.append { await client2.destroy() }
        let events = OrderedBlobEvents(client2)
        defer { events.cancel() }
        _ = await client2.waitForStorageReady()
        try await eventually(timeout: 5, description: "the rows are deleted") {
            let rows = try await UploadRows.read(path)
            return rows.records.isEmpty && rows.byteKeys.isEmpty
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(events.failed(blobId).map(\.willRetry), [false])
    }

    // MARK: - Behavior 14: a send waits on a restored upload

    func testASendNamingARestoredSessionUploadWaitsForItAndLands() async throws {
        let path = try databasePath()
        let first = try server()
        let client1 = await client(first, path: path)
        client1.setNetworkMode(.offline)
        let queued = try await client1.blobManager.forAgentSession(sessionId: "s1", documentId: "d-old").upload(Self.bytes)
        await client1.destroy()

        let second = try server()
        second.hold(SessionUploadServer.isAttachmentPut)
        let client2 = await client(second, path: path)
        let (view, _) = try await openLocalSessionView(client2, second) { request in
            if request.method == "POST", request.apiPathOnly == "/agent-sessions/s1/messages" {
                return .json(#"{"messageId":"m-1","seq":1,"turnId":"t-1","queued":false}"#)
            }
            return SessionUploadServer.acceptAll(request)
        }
        cleanups.append { await view.close() }
        let send = Task {
            try await view.send(text: "see attached", files: [AgentSessionFileRef(blobId: queued.blobId)], clientMessageId: "c1")
        }
        try await eventually(timeout: 5, description: "the send waits") {
            view.pendingMessages.first { $0.clientMessageId == "c1" }?.state == .waiting
        }
        let posts = { second.requests.filter { $0.method == "POST" && $0.apiPathOnly == "/agent-sessions/s1/messages" } }
        XCTAssertEqual(posts().count, 0)
        try await eventually(timeout: 5, description: "the restored upload is in flight") { second.heldRequests.count == 1 }
        second.hold(nil)
        second.release(SessionUploadServer.created(second.heldRequests[0]))
        _ = try await within(10, "the send") { try await send.value }
        XCTAssertEqual(posts().count, 1, "the message is posted once the upload lands")
    }

    // MARK: - Behavior 15: retries continue from the persisted attempts

    func testRetriesOfARestoredUploadContinueFromThePersistedAttempts() async throws {
        let path = try databasePath()
        let (client1, _, blobId) = try await queuedByFirstClient(path)
        await client1.destroy()
        let persistedValue = try await UploadRows.read(path).record(blobId)
        let persisted = try XCTUnwrap(persistedValue)

        let second = try server(Self.busy)
        let client2 = P.client(second, path: path)
        cleanups.append { await client2.destroy() }
        let events = OrderedBlobEvents(client2)
        defer { events.cancel() }
        _ = await client2.waitForStorageReady()
        try await eventually(timeout: 5, description: "the restored attempt fails") { !events.failed(blobId).isEmpty }
        let failed = events.failed(blobId)[0]
        XCTAssertEqual(failed.attempts, persisted.attempts + 1)
        let backoff = Double(BlobManager.uploadBackoffMs(attempts: persisted.attempts + 1, baseMs: 2000, maxMs: 60000)) / 1000
        XCTAssertEqual(failed.nextAttemptAt - failed.updatedAt, backoff, accuracy: 0.05)
        XCTAssertTrue(failed.willRetry)
    }

    // MARK: - Behavior 16: `.memory` keeps nothing

    func testWithMemoryStorageANewClientRestoresNothing() async throws {
        let first = try server(Self.busy)
        let client1 = await client(first, path: nil)
        _ = try await P.queueDocumentUpload(client1, data: Self.bytes)
        await client1.destroy()

        let second = try server()
        let client2 = await client(second, path: nil)
        let listed = await client2.documents.uploadsAsync()
        XCTAssertEqual(listed.map(\.blobId), [])
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(second.requests.filter { $0.method == "PUT" }.count, 0)
    }

    // MARK: - Behavior 20: destroy waits for the writes

    func testDestroyRightAfterQueueingLeavesACompleteRowAndTheNextClientOpensTheFile() async throws {
        let path = try databasePath()
        let first = try server()
        let client1 = P.client(first, path: path)
        _ = await client1.waitForStorageReady()
        client1.setNetworkMode(.offline)
        let queued = try await client1.blobManager.forAgentSession(sessionId: "s1", documentId: "d1").upload(Self.bytes)
        await client1.destroy()

        let rows = try await UploadRows.read(path)
        XCTAssertEqual(rows.record(queued.blobId)?.status, "pending")
        XCTAssertEqual(rows.bytes["d1::\(queued.blobId)"], Self.bytes)

        let second = try server()
        second.hold(SessionUploadServer.isAttachmentPut)
        let client2 = await client(second, path: path)
        let listed = await client2.blobManager.forAgentSession(sessionId: "s1", documentId: "d1").uploads()
        XCTAssertEqual(listed.map(\.blobId), [queued.blobId], "the next client opens the file and restores it")
    }

    // MARK: - Behavior 21: a record without its bytes

    func testARecordWhoseBytesAreMissingIsDroppedAndTheRestRestore() async throws {
        let path = try databasePath()
        let now = (Date().timeIntervalSince1970 * 1000).rounded()
        func record(_ blobId: String) -> PersistedUploadRecord {
            PersistedUploadRecord(
                queueId: blobId, documentId: "doc-1", blobId: blobId, filename: "\(blobId).bin",
                contentType: "application/octet-stream", sha256Base64: BlobManager.sha256Base64(Self.bytes),
                disposition: nil, retainLocal: nil, numBytes: Self.bytes.count, status: "pending", attempts: 1,
                nextAttemptAt: now, createdAt: now, updatedAt: now, lastError: "busy", lastErrorCode: nil,
                destination: nil
            )
        }
        try await UploadRows.seed(path, record("B-KEPT"), bytes: Self.bytes)
        try await UploadRows.seed(path, record("B-LOST"), bytes: nil)

        let second = try server()
        second.hold(P.isDocumentPut)
        let client2 = await client(second, path: path)
        let listed = await client2.documents.uploadsAsync()
        XCTAssertEqual(listed.map(\.blobId), ["B-KEPT"])
        let rows = try await UploadRows.read(path)
        XCTAssertNil(rows.record("B-LOST"), "the record without bytes is deleted")
        XCTAssertNotNil(rows.record("B-KEPT"))
    }

    /// Storage ready means the restore is done, and dropping a record without
    /// its bytes is part of the restore: by the time `waitForStorageReady()`
    /// returns, every such record is already gone from the file. Several, so
    /// a drop still being written when storage reports ready cannot hide.
    func testEveryRecordWithoutItsBytesIsDeletedByTheTimeStorageIsReady() async throws {
        let path = try databasePath()
        let now = (Date().timeIntervalSince1970 * 1000).rounded()
        let lost = (1...10).map { "B-LOST-\($0)" }
        for blobId in lost {
            try await UploadRows.seed(path, PersistedUploadRecord(
                queueId: blobId, documentId: "doc-1", blobId: blobId, filename: "\(blobId).bin",
                contentType: "application/octet-stream", sha256Base64: BlobManager.sha256Base64(Self.bytes),
                disposition: nil, retainLocal: nil, numBytes: Self.bytes.count, status: "pending", attempts: 1,
                nextAttemptAt: now, createdAt: now, updatedAt: now, lastError: "busy", lastErrorCode: nil,
                destination: nil
            ), bytes: nil)
        }

        _ = await client(try server(), path: path)
        let rows = try await UploadRows.read(path)
        XCTAssertEqual(rows.records.map(\.queueId), [], "every record without bytes is deleted before storage is ready")
    }

    // MARK: - Behavior 24: the first attempt

    func testTheRowIsWrittenBeforeTheFirstPutAndFollowsEachOutcome() async throws {
        // 201: the rows are gone before `upload` returns.
        let path = try databasePath()
        let created = try server()
        let client1 = P.client(created, path: path)
        cleanups.append { await client1.destroy() }
        let events = OrderedBlobEvents(client1)
        defer { events.cancel() }
        _ = await client1.waitForStorageReady()
        let landed = try await client1.documents.blobs(documentId: "doc-1").upload(data: Self.bytes)
        var rows = try await UploadRows.read(path)
        XCTAssertEqual(rows.records, [])
        XCTAssertEqual(rows.byteKeys, [])
        XCTAssertEqual(events.labels(landed.blobId), ["completed"], "event order unchanged")

        // 400: gone before `upload` throws.
        created.answer { request in P.isDocumentPut(request) ? .status(400, "bad") : SessionUploadServer.acceptAll(request) }
        let refused = await thrown { _ = try await client1.documents.blobs(documentId: "doc-1").upload(data: Self.bytes) }
        XCTAssertEqual((refused as? HttpError)?.status, 400)
        rows = try await UploadRows.read(path)
        XCTAssertEqual(rows.records, [])
        XCTAssertEqual(rows.byteKeys, [])
        let refusedId = P.blobId(of: try XCTUnwrap(created.requests.last { P.isDocumentPut($0) }))
        XCTAssertEqual(events.labels(refusedId), ["failed:false"], "event order unchanged")

        // 503: pending, one attempt, the error. One upload holds the only
        // slot, so the queue cannot select this one before it is read.
        await client1.documents.setUploadConcurrencyAsync(1)
        created.answer(Self.busy)
        P.holdDocumentRetries(created)
        let slot = try await P.queueDocumentUpload(client1, data: Data("slot".utf8))
        try await eventually(timeout: 5, description: "the slot is taken") { created.heldRequests.count == 1 }
        let blobId = try await P.queueDocumentUpload(client1, data: Self.bytes)
        XCTAssertNotEqual(blobId, slot)
        rows = try await UploadRows.read(path)
        let record = try XCTUnwrap(rows.record(blobId))
        XCTAssertEqual(record.status, "pending")
        XCTAssertEqual(record.attempts, 1)
        XCTAssertNotNil(record.lastError)
        XCTAssertEqual(rows.bytes["doc-1::\(blobId)"], Self.bytes)
        XCTAssertEqual(events.labels(blobId), ["failed:true", "progress:pending"], "event order unchanged")
    }

    // MARK: - Behaviors 24 and 27: restart without destroy

    func testAnAbandonedFirstClientsHeldFirstPutIsRestoredByASecondClientWhileItLives() async throws {
        let path = try databasePath()
        let first = try server()
        first.hold(P.isDocumentPut)
        let client1 = await client(first, path: path)
        let upload = Task { try await client1.documents.blobs(documentId: "doc-1").upload(data: Self.bytes) }
        cleanups.append { upload.cancel() }
        try await eventually(timeout: 5, description: "the first PUT is held") { first.heldRequests.count == 1 }
        let blobId = P.blobId(of: first.heldRequests[0])

        // Written before the first PUT left, while `upload` still awaits it.
        let rows = try await UploadRows.read(path)
        let record = try XCTUnwrap(rows.record(blobId))
        XCTAssertEqual(record.status, "uploading")
        XCTAssertEqual(record.attempts, 0)
        XCTAssertEqual(record.queueId, blobId)
        XCTAssertEqual(rows.bytes["doc-1::\(blobId)"], Self.bytes)

        let second = try server()
        let client2 = P.client(second, path: path)
        cleanups.append { await client2.destroy() }
        let events = OrderedBlobEvents(client2)
        defer { events.cancel() }
        _ = await client2.waitForStorageReady()
        try await eventually(timeout: 10, description: "the second client completes it") {
            events.labels(blobId).contains("completed")
        }
        XCTAssertEqual(P.documentPuts(second, blobId).count, 1)
    }

    func testAnAbandonedFirstClientsQueuedUploadIsReadByAFreshConnectionAndCompletedByASecondClient() async throws {
        let path = try databasePath()
        let (_, _, blobId) = try await queuedByFirstClient(path)
        // Never destroyed: a fresh connection reads the row as it is.
        let rows = try await UploadRows.read(path)
        XCTAssertNotNil(rows.record(blobId))
        XCTAssertEqual(rows.bytes["doc-1::\(blobId)"], Self.bytes)

        let second = try server()
        let client2 = P.client(second, path: path)
        cleanups.append { await client2.destroy() }
        let events = OrderedBlobEvents(client2)
        defer { events.cancel() }
        _ = await client2.waitForStorageReady()
        try await eventually(timeout: 10, description: "the second client completes it") {
            events.labels(blobId).contains("completed")
        }
        XCTAssertEqual(P.documentPuts(second, blobId).count, 1)
        XCTAssertEqual(P.documentPuts(second, blobId).first?.header("Authorization"), "Bearer \(P.token("u-a"))")
    }

    // MARK: - Behavior 25: the rows of a dropped outcome

    func testAnOutcomeDroppedAfterASignOutLeavesTheRowsUntilTheOwnersAttemptCompletes() async throws {
        let path = try databasePath()
        let (client1, first, blobId) = try await queuedByFirstClient(path)
        client1.updateToken(P.token("u-b"))
        first.hold(nil)
        first.answer(SessionUploadServer.acceptAll)
        first.release(SessionUploadServer.created(first.heldRequests[0]))
        try await Task.sleep(nanoseconds: 300_000_000)
        await client1.blobManager.awaitPendingPersistence()
        let kept = try await UploadRows.read(path)
        XCTAssertNotNil(kept.record(blobId), "an outcome under B deletes nothing")

        client1.updateToken(P.token("u-a"))
        try await eventually(timeout: 10, description: "A's attempt completes and the rows go") {
            let rows = try await UploadRows.read(path)
            return rows.records.isEmpty && rows.byteKeys.isEmpty
        }
    }

    // MARK: - Behavior 26: an attempt answering after shutdown

    func testAnAttemptThatAnswersAfterDestroyChangesNeitherTheQueueNorTheStore() async throws {
        let path = try databasePath()
        let (client1, first, blobId) = try await queuedByFirstClient(path)
        let events = OrderedBlobEvents(client1)
        defer { events.cancel() }
        await client1.destroy()
        first.hold(nil)
        first.release(SessionUploadServer.created(first.heldRequests[0]))
        try await Task.sleep(nanoseconds: 500_000_000)

        let rows = try await UploadRows.read(path)
        XCTAssertEqual(rows.record(blobId)?.status, "uploading")
        XCTAssertEqual(rows.bytes["doc-1::\(blobId)"], Self.bytes)
        XCTAssertEqual(events.labels(blobId), [], "nothing is emitted")
        let reopened = await client1.offlineStore.getStorageProvider()?.isReady()
        XCTAssertEqual(reopened, false, "no write reopened the closed database")
        let queued = await client1.blobManager.hasQueuedUpload(blobId)
        XCTAssertTrue(queued, "the queue is unchanged")
    }

    func testAFirstPutThatAnswersAfterDestroyLeavesItsRowAsWritten() async throws {
        let path = try databasePath()
        let first = try server()
        first.hold(P.isDocumentPut)
        let client1 = await client(first, path: path)
        let upload = Task { try await client1.documents.blobs(documentId: "doc-1").upload(data: Self.bytes) }
        try await eventually(timeout: 5, description: "the first PUT is held") { first.heldRequests.count == 1 }
        let blobId = P.blobId(of: first.heldRequests[0])
        await client1.destroy()
        first.hold(nil)
        first.release(SessionUploadServer.created(first.heldRequests[0]))
        _ = try? await within(5, "the upload call") { try await upload.value }
        let rows = try await UploadRows.read(path)
        XCTAssertEqual(rows.record(blobId)?.status, "uploading", "restores pending next launch")
        let reopened = await client1.offlineStore.getStorageProvider()?.isReady()
        XCTAssertEqual(reopened, false)
    }
}
