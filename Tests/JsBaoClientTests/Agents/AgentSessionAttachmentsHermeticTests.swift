import CryptoKit
import XCTest
@testable import JsBaoClient

/// `view.attachments` over the client's blob queue (#4588, plan behaviors 1
/// to 5, 7 and 8, edges 27 to 31 and 40 to 42): a real `JsBaoClient` signed in
/// with a test JWT against `LoopbackAPIServer`, which records every request
/// with its headers and body.
final class AgentSessionAttachmentsHermeticTests: XCTestCase {
    private static let bytes = Data("hello, session".utf8)

    private static func sha256(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private func status(_ attachments: AgentSessionAttachments, _ blobId: String) async -> AgentSessionUploadStatus? {
        await attachments.uploads().first { $0.blobId == blobId }
    }

    // MARK: - Behavior 1: one PUT on the session route

    func testUploadPutsTheSessionRouteOnceWithTheBlobHeadersAndTheBearer() async throws {
        let server = try SessionUploadServer()
        defer { server.stop() }
        let token = makeTestJwt(userId: "u-a")
        let client = makeSessionUploadClient(server, token: token)
        let events = BlobEventLog(client)
        defer { events.cancel() }
        let (view, documentId) = try await openLocalSessionView(client, server)

        XCTAssertTrue(view.attachments === view.attachments, "one attachments object per view")
        let attachment = try await within(10, "the upload") {
            try await view.attachments.upload(
                Self.bytes,
                options: AgentSessionAttachmentUploadOptions(
                    filename: "note one.txt", contentType: "text/plain", disposition: .inline
                )
            )
        }
        XCTAssertEqual(attachment.filename, "note one.txt")
        XCTAssertEqual(attachment.contentType, "text/plain")
        XCTAssertEqual(attachment.numBytes, Self.bytes.count)
        XCTAssertFalse(attachment.blobId.isEmpty)

        let puts = server.attachmentPuts
        XCTAssertEqual(puts.map(\.apiPathOnly), ["/agent-sessions/s1/attachments/\(attachment.blobId)"])
        let put = try XCTUnwrap(puts.first)
        XCTAssertEqual(put.header("Content-Type"), "text/plain")
        XCTAssertEqual(put.header("X-Blob-Filename"), "note%20one.txt")
        XCTAssertEqual(put.header("X-Blob-Size"), "\(Self.bytes.count)")
        XCTAssertEqual(put.header("X-Blob-Sha256"), Self.sha256(Self.bytes))
        XCTAssertEqual(put.header("X-Blob-Disposition"), "inline")
        XCTAssertEqual(put.header("Authorization"), "Bearer \(token)")
        XCTAssertEqual(put.body, Self.bytes)
        XCTAssertFalse(server.requests.contains { $0.apiPathOnly.contains("/documents/") && $0.method == "PUT" })

        let remaining = await view.attachments.uploads()
        XCTAssertEqual(remaining, [], "a completed upload leaves the list")
        // Edge 41: the events carry the binding's document, as JS's do.
        XCTAssertEqual(events.completed(attachment.blobId).map(\.documentId), [documentId])
        XCTAssertTrue(events.progress(attachment.blobId).allSatisfy { $0.documentId == documentId })
        await view.close()
        await client.destroy()
    }

    /// Edge 28: an empty file is sent as one, with the SHA-256 of nothing.
    func testAnEmptyUploadSendsSizeZeroAndTheHashOfNothing() async throws {
        let server = try SessionUploadServer()
        defer { server.stop() }
        let client = makeSessionUploadClient(server)
        let attachments = client.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")

        let attachment = try await within(10, "the upload") { try await attachments.upload(Data()) }
        XCTAssertEqual(attachment.numBytes, 0)
        XCTAssertTrue(attachment.filename.hasPrefix("blob-"), attachment.filename)
        XCTAssertEqual(attachment.contentType, "application/octet-stream")
        let put = try XCTUnwrap(server.puts(of: attachment.blobId).first)
        XCTAssertEqual(put.header("X-Blob-Size"), "0")
        XCTAssertEqual(put.header("X-Blob-Sha256"), "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=")
        XCTAssertNil(put.header("X-Blob-Disposition"))
        await client.destroy()
    }

    // MARK: - Behavior 2: a retryable failure, or no network, queues

    func testARetryableFailureResolvesQueuedAndRetriesOnTheSessionRoute() async throws {
        let server = try SessionUploadServer { request in
            SessionUploadServer.isAttachmentPut(request) ? .status(503, "busy") : .status(404, "no")
        }
        defer { server.stop() }
        let client = makeSessionUploadClient(server)
        let attachments = client.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")
        let before = Date().timeIntervalSince1970

        let attachment = try await within(10, "the upload") { try await attachments.upload(Self.bytes) }
        let queuedStatus = await status(attachments, attachment.blobId)
        let queued = try XCTUnwrap(queuedStatus)
        XCTAssertEqual(queued.state, .pending)
        XCTAssertEqual(queued.attempts, 1)
        XCTAssertGreaterThan(queued.nextAttemptAt, before)
        XCTAssertGreaterThanOrEqual(queued.updatedAt, before)
        XCTAssertNotNil(queued.lastError)
        XCTAssertNil(queued.error)
        XCTAssertEqual(server.puts(of: attachment.blobId).count, 1)

        server.answer(SessionUploadServer.acceptAll)
        try await eventually(timeout: 10, description: "the retry lands") {
            await attachments.uploads().isEmpty
        }
        XCTAssertEqual(server.puts(of: attachment.blobId).count, 2)
        XCTAssertTrue(server.puts(of: attachment.blobId).allSatisfy {
            $0.apiPathOnly == "/agent-sessions/s1/attachments/\(attachment.blobId)"
        })
        await client.destroy()
    }

    func testAnUploadWhileOfflineQueuesWithNoPutAndAnIdleTimerUntilOnline() async throws {
        let server = try SessionUploadServer()
        defer { server.stop() }
        let client = makeSessionUploadClient(server)
        let manager = client.blobManager
        let attachments = manager.forAgentSession(sessionId: "s1", documentId: "d1")
        client.setNetworkMode(.offline)

        let attachment = try await within(10, "the upload") { try await attachments.upload(Self.bytes) }
        let queuedStatus = await status(attachments, attachment.blobId)
        let queued = try XCTUnwrap(queuedStatus)
        XCTAssertEqual(queued.state, .pending)
        XCTAssertEqual(queued.attempts, 0)
        let starts = await manager.queueTimerStartCount
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(server.attachmentPuts.count, 0, "nothing is sent while offline")
        let pending = await manager.hasPendingQueueTimer
        XCTAssertFalse(pending, "no timer runs for an upload that cannot go out")
        let startsAfter = await manager.queueTimerStartCount
        XCTAssertEqual(startsAfter, starts)

        // A document upload is not held back by the session rule.
        _ = try? await client.documents.blobs(documentId: "doc-1").upload(data: Data("doc".utf8))
        XCTAssertTrue(
            server.requests.contains { $0.method == "PUT" && $0.apiPathOnly.hasPrefix("/documents/doc-1/blobs/") },
            "a document upload made while offline still makes its attempt"
        )

        client.setNetworkMode(.online)
        try await eventually(timeout: 10, description: "the queued upload lands once online") {
            await attachments.uploads().isEmpty
        }
        XCTAssertEqual(server.puts(of: attachment.blobId).count, 1)
        await client.destroy()
    }

    // MARK: - Behavior 3: a refusal keeps the upload, failed

    func testARefusalThrowsAndKeepsTheUploadFailedUntilResumeRetriesIt() async throws {
        let server = try SessionUploadServer { request in
            SessionUploadServer.isAttachmentPut(request)
                ? SessionUploadServer.refused(403, "AGENT_SESSION_PARTICIPANT_ONLY", "Only participants may upload")
                : .status(404, "no")
        }
        defer { server.stop() }
        let client = makeSessionUploadClient(server)
        let events = BlobEventLog(client)
        defer { events.cancel() }
        let attachments = client.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")

        let error = await thrown { _ = try await within(10, "the upload") { try await attachments.upload(Self.bytes) } }
        let http = try XCTUnwrap(error as? HttpError, "a refusal throws the HttpError: \(String(describing: error))")
        XCTAssertEqual(http.status, 403)
        XCTAssertEqual(http.serverCode, "AGENT_SESSION_PARTICIPANT_ONLY")
        let blobId = try XCTUnwrap(server.attachmentPuts.first?.apiPathOnly.split(separator: "/").last.map(String.init))

        let failedStatus = await status(attachments, blobId)
        let failed = try XCTUnwrap(failedStatus)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.error?.code, "AGENT_SESSION_PARTICIPANT_ONLY")
        XCTAssertNil(failed.lastError)
        let local = try await attachments.read(blobId: blobId)
        XCTAssertEqual(local, Self.bytes, "a failed upload keeps its bytes")
        XCTAssertEqual(server.downloads.count, 0, "read locally")
        let waitError = await thrown { _ = try await attachments.waitUntilUploaded(blobId: blobId) }
        XCTAssertEqual((waitError as? HttpError)?.serverCode, "AGENT_SESSION_PARTICIPANT_ONLY")
        let paused = await attachments.pause(blobId: blobId)
        XCTAssertFalse(paused, "a failed upload is not paused (edge 30)")
        XCTAssertEqual(events.failed(blobId).map(\.willRetry), [false])

        server.answer(SessionUploadServer.acceptAll)
        let resumed = await attachments.resume(blobId: blobId)
        XCTAssertTrue(resumed, "resume is the retry of a failed upload")
        let landed = try await within(10, "the retry") { try await attachments.waitUntilUploaded(blobId: blobId) }
        XCTAssertEqual(landed.blobId, blobId)
        let left = await attachments.uploads()
        XCTAssertEqual(left, [])
        XCTAssertEqual(server.puts(of: blobId).count, 2)
        await client.destroy()
    }

    func testABackgroundRefusalIsRecordedFailedOnceAndAgainAfterAResume() async throws {
        let server = try SessionUploadServer { request in
            SessionUploadServer.isAttachmentPut(request) ? .status(503, "busy") : .status(404, "no")
        }
        defer { server.stop() }
        let client = makeSessionUploadClient(server)
        let events = BlobEventLog(client)
        defer { events.cancel() }
        let attachments = client.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")
        let attachment = try await within(10, "the upload") { try await attachments.upload(Self.bytes) }
        let blobId = attachment.blobId
        server.answer { request in
            SessionUploadServer.isAttachmentPut(request)
                ? SessionUploadServer.refused(403, "AGENT_SESSION_PARTICIPANT_ONLY")
                : .status(404, "no")
        }

        try await eventually(timeout: 10, description: "the retry is refused") {
            await self.status(attachments, blobId)?.state == .failed
        }
        XCTAssertEqual(events.failed(blobId).map(\.willRetry), [true, false])
        let resumed = await attachments.resume(blobId: blobId)
        XCTAssertTrue(resumed)
        try await eventually(timeout: 10, description: "the resumed attempt is refused again") {
            events.failed(blobId).count == 3
        }
        XCTAssertEqual(events.failed(blobId).map(\.willRetry), [true, false, false])
        let again = await status(attachments, blobId)
        XCTAssertEqual(again?.state, .failed)
        await client.destroy()
    }

    // MARK: - Behavior 4: pause, resume, cancel and wait

    func testPauseAndResumeAnswerByState() async throws {
        let server = try SessionUploadServer { request in
            SessionUploadServer.isAttachmentPut(request) ? .status(503, "busy") : .status(404, "no")
        }
        defer { server.stop() }
        let client = makeSessionUploadClient(server)
        let attachments = client.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")
        let first = try await within(10, "first") { try await attachments.upload(Self.bytes) }
        let second = try await within(10, "second") { try await attachments.upload(Self.bytes) }

        let pausedFirst = await attachments.pause(blobId: first.blobId)
        XCTAssertTrue(pausedFirst)
        let pausedAgain = await attachments.pause(blobId: first.blobId)
        XCTAssertFalse(pausedAgain, "already paused")
        let pausedUnknown = await attachments.pause(blobId: "no-such-upload")
        XCTAssertFalse(pausedUnknown)
        let resumedPending = await attachments.resume(blobId: second.blobId)
        XCTAssertFalse(resumedPending, "a pending upload is not resumed")
        let resumedUnknown = await attachments.resume(blobId: "no-such-upload")
        XCTAssertFalse(resumedUnknown)
        let listed = await status(attachments, first.blobId)
        XCTAssertEqual(listed?.state, .paused)

        // Nothing goes out for a paused upload past the first backoff.
        let putsBefore = server.puts(of: first.blobId).count
        try await Task.sleep(nanoseconds: 2_600_000_000)
        XCTAssertEqual(server.puts(of: first.blobId).count, putsBefore, "a paused upload sends nothing")

        server.answer(SessionUploadServer.acceptAll)
        let resumed = await attachments.resume(blobId: first.blobId)
        XCTAssertTrue(resumed)
        let landed = try await within(5, "the resumed attempt runs at once") {
            try await attachments.waitUntilUploaded(blobId: first.blobId)
        }
        XCTAssertEqual(landed, first)
        let doneAtOnce = try await within(1, "a completed upload answers at once") {
            try await attachments.waitUntilUploaded(blobId: first.blobId)
        }
        XCTAssertEqual(doneAtOnce, first)
        await client.destroy()
    }

    func testCancelDropsTheUploadAndItsBytesAndEndsItsWaits() async throws {
        let server = try SessionUploadServer { request in
            SessionUploadServer.isAttachmentPut(request) ? .status(503, "busy") : SessionUploadServer.acceptAll(request)
        }
        defer { server.stop() }
        let client = makeSessionUploadClient(server)
        let attachments = client.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")
        let attachment = try await within(10, "the upload") { try await attachments.upload(Self.bytes) }
        let blobId = attachment.blobId
        let waits = (0..<2).map { _ in
            Task { try await attachments.waitUntilUploaded(blobId: blobId) }
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let cancelled = await attachments.cancel(blobId: blobId)
        XCTAssertTrue(cancelled)
        for wait in waits {
            let error = await thrown { _ = try await within(5, "the wait") { try await wait.value } }
            let code = try XCTUnwrap(error as? JsBaoError)
            XCTAssertEqual(code.code, .agentSessionUploadCancelled)
            XCTAssertEqual(code.details?["blobId"], .string(blobId))
        }
        let listed = await attachments.uploads()
        XCTAssertEqual(listed, [])
        let cancelledAgain = await attachments.cancel(blobId: blobId)
        XCTAssertFalse(cancelledAgain, "not queued any more")
        let cancelledUnknown = await attachments.cancel(blobId: "no-such-upload")
        XCTAssertFalse(cancelledUnknown)

        // The bytes went with it: a read goes to the server.
        let readError = await thrown { _ = try await attachments.read(blobId: blobId) }
        XCTAssertEqual((readError as? HttpError)?.serverCode, "AGENT_SESSION_ATTACHMENT_NOT_FOUND")
        XCTAssertEqual(server.downloads.count, 1)
        XCTAssertFalse(server.requests.contains { $0.method == "DELETE" }, "cancel never deletes on the server")

        let unknown = await thrown { _ = try await attachments.waitUntilUploaded(blobId: "no-such-upload") }
        XCTAssertEqual((unknown as? JsBaoError)?.code, .agentSessionUploadUnknown)
        XCTAssertEqual((unknown as? JsBaoError)?.details?["blobId"], .string("no-such-upload"))

        // A completed upload is not cancelled.
        server.answer(SessionUploadServer.acceptAll)
        let landed = try await within(10, "a second upload") { try await attachments.upload(Self.bytes) }
        let cancelledLanded = await attachments.cancel(blobId: landed.blobId)
        XCTAssertFalse(cancelledLanded)
        await client.destroy()
    }

    /// Edges 29 and 30: an upload cancelled mid-transfer leaves the queue, its
    /// held answer changes nothing, and a resume during a transfer answers
    /// false.
    func testCancelMidTransferIgnoresTheTransfersOutcome() async throws {
        let server = try SessionUploadServer()
        defer { server.stop() }
        server.hold(SessionUploadServer.isAttachmentPut)
        let client = makeSessionUploadClient(server)
        let events = BlobEventLog(client)
        defer { events.cancel() }
        let attachments = client.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")
        let upload = Task { try await attachments.upload(Self.bytes) }
        try await eventually(timeout: 5, description: "the PUT is held") { server.heldRequests.count == 1 }
        let blobId = try XCTUnwrap(server.heldRequests.first?.apiPathOnly.split(separator: "/").last.map(String.init))
        let uploading = await status(attachments, blobId)
        XCTAssertEqual(uploading?.state, .uploading)
        let resumedWhileUploading = await attachments.resume(blobId: blobId)
        XCTAssertFalse(resumedWhileUploading, "edge 30: an uploading upload is not resumed")

        let cancelled = await attachments.cancel(blobId: blobId)
        XCTAssertTrue(cancelled)
        _ = try await within(5, "the upload call returns once its transfer is cancelled") { try await upload.value }
        server.release(SessionUploadServer.created(server.heldRequests.first!))
        try await Task.sleep(nanoseconds: 300_000_000)
        let listed = await attachments.uploads()
        XCTAssertEqual(listed, [])
        XCTAssertEqual(events.completed(blobId).count, 0, "the cancelled transfer's answer completes nothing")
        let unknown = await thrown { _ = try await attachments.waitUntilUploaded(blobId: blobId) }
        XCTAssertEqual((unknown as? JsBaoError)?.code, .agentSessionUploadUnknown)
        await client.destroy()
    }

    /// Edge 31: two waits on one upload both resolve, and both throw the one
    /// failure.
    func testTwoWaitsOnOneUploadShareItsOutcome() async throws {
        let server = try SessionUploadServer { request in
            SessionUploadServer.isAttachmentPut(request) ? .status(503, "busy") : .status(404, "no")
        }
        defer { server.stop() }
        let client = makeSessionUploadClient(server)
        let attachments = client.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")
        let good = try await within(10, "upload") { try await attachments.upload(Self.bytes) }
        let bad = try await within(10, "upload") { try await attachments.upload(Self.bytes) }
        _ = await attachments.pause(blobId: good.blobId)
        _ = await attachments.pause(blobId: bad.blobId)
        let goodWaits = (0..<2).map { _ in Task { try await attachments.waitUntilUploaded(blobId: good.blobId) } }
        let badWaits = (0..<2).map { _ in Task { try await attachments.waitUntilUploaded(blobId: bad.blobId) } }
        try await Task.sleep(nanoseconds: 100_000_000)

        server.answer { request in
            guard SessionUploadServer.isAttachmentPut(request) else { return .status(404, "no") }
            return request.apiPathOnly.hasSuffix(bad.blobId)
                ? SessionUploadServer.refused(413, "BLOB_TOO_LARGE", "too large")
                : SessionUploadServer.created(request)
        }
        _ = await attachments.resume(blobId: good.blobId)
        _ = await attachments.resume(blobId: bad.blobId)
        for wait in goodWaits {
            let landed = try await within(5, "a wait") { try await wait.value }
            XCTAssertEqual(landed, good)
        }
        var codes: [String?] = []
        for wait in badWaits {
            let error = await thrown { _ = try await within(5, "a wait") { try await wait.value } }
            codes.append((error as? HttpError)?.serverCode)
        }
        XCTAssertEqual(codes, ["BLOB_TOO_LARGE", "BLOB_TOO_LARGE"])
        await client.destroy()
    }

    // MARK: - Behavior 5 and edge 27: the view's close

    func testAQueuedUploadAndItsWaitOutliveTheViewsClose() async throws {
        let server = try SessionUploadServer()
        defer { server.stop() }
        let client = makeSessionUploadClient(server)
        let (view, _) = try await openLocalSessionView(client, server)
        let attachments = view.attachments
        client.setNetworkMode(.offline)
        let attachment = try await within(10, "the upload") { try await attachments.upload(Self.bytes) }
        let wait = Task { try await attachments.waitUntilUploaded(blobId: attachment.blobId) }
        try await Task.sleep(nanoseconds: 100_000_000)

        await view.close()
        let uploadError = await thrown { _ = try await attachments.upload(Self.bytes) }
        XCTAssertEqual((uploadError as? JsBaoError)?.code, .invalidArgument)
        XCTAssertEqual((uploadError as? JsBaoError)?.message, "The session view is closed")
        let readError = await thrown { _ = try await attachments.read(blobId: attachment.blobId) }
        XCTAssertEqual((readError as? JsBaoError)?.message, "The session view is closed")
        let listed = await attachments.uploads()
        XCTAssertEqual(listed.map(\.blobId), [attachment.blobId], "edge 27: nothing new was stored")
        let paused = await attachments.pause(blobId: attachment.blobId)
        XCTAssertTrue(paused)
        let resumed = await attachments.resume(blobId: attachment.blobId)
        XCTAssertTrue(resumed)
        XCTAssertEqual(server.attachmentPuts.count, 0, "edge 27: nothing was sent")

        client.setNetworkMode(.online)
        let landed = try await within(10, "the wait") { try await wait.value }
        XCTAssertEqual(landed, attachment)
        XCTAssertEqual(server.puts(of: attachment.blobId).map(\.apiPathOnly), [
            "/agent-sessions/s1/attachments/\(attachment.blobId)",
        ])
        let left = await attachments.uploads()
        XCTAssertEqual(left, [])
        let cancelled = await attachments.cancel(blobId: attachment.blobId)
        XCTAssertFalse(cancelled, "the queue members keep answering after close")
        await client.destroy()
    }

    // MARK: - Behavior 7 and edge 42: read

    func testReadDownloadsThroughTheSessionOnceThenReadsTheLocalCopy() async throws {
        let server = try SessionUploadServer { request in
            switch request.apiPathOnly {
            case "/agent-sessions/s1/attachments/b-text/download": return .json(#""hello""#)
            case "/agent-sessions/s1/attachments/b-json/download": return .json(#"{"a":1}"#)
            default: return SessionUploadServer.acceptAll(request)
            }
        }
        defer { server.stop() }
        let client = makeSessionUploadClient(server)
        let attachments = client.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")

        let first = try await attachments.read(blobId: "b-text")
        XCTAssertEqual(String(decoding: first, as: UTF8.self), #""hello""#)
        XCTAssertEqual(server.downloads.map(\.apiPathOnly), ["/agent-sessions/s1/attachments/b-text/download"])
        let download = try XCTUnwrap(server.downloads.first)
        XCTAssertNotNil(download.header("Authorization"))
        let again = try await attachments.read(blobId: "b-text")
        XCTAssertEqual(again, first)
        XCTAssertEqual(server.downloads.count, 1, "the second read is the local copy")

        client.setNetworkMode(.offline)
        let offline = try await attachments.read(blobId: "b-text")
        XCTAssertEqual(offline, first, "the local copy reads offline")
        let missing = await thrown { _ = try await attachments.read(blobId: "b-json") }
        XCTAssertEqual((missing as? JsBaoError)?.code, .offline, "edge 42: no local copy offline")
        XCTAssertEqual(server.downloads.count, 1, "nothing is attempted offline")
        client.setNetworkMode(.online)

        let absent = await thrown { _ = try await attachments.read(blobId: "b-absent") }
        let http = try XCTUnwrap(absent as? HttpError)
        XCTAssertEqual(http.status, 404)
        XCTAssertEqual(http.serverCode, "AGENT_SESSION_ATTACHMENT_NOT_FOUND")

        struct Shape: Decodable, Equatable { let a: Int }
        let decoded = try await attachments.read(blobId: "b-json", as: Shape.self)
        XCTAssertEqual(decoded, Shape(a: 1))
        let text = try await attachments.read(blobId: "b-text", as: String.self)
        XCTAssertEqual(text, #""hello""#)
        let forced = try await attachments.read(blobId: "b-text", force: true)
        XCTAssertEqual(forced, first)
        XCTAssertEqual(
            server.downloads.filter { $0.apiPathOnly.hasSuffix("b-text/download") }.count, 2,
            "force downloads again"
        )
        await client.destroy()
    }

    /// CSO-4588-005: an upload's retained bytes answer a read whatever
    /// disposition the upload was made with and the read asks for.
    func testAnUploadsRetainedBytesReadLocallyUnderAnyDisposition() async throws {
        let options = AgentSessionAttachmentUploadOptions(disposition: .attachment)
        // Queued while offline.
        do {
            let server = try SessionUploadServer()
            defer { server.stop() }
            let client = makeSessionUploadClient(server)
            let attachments = client.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")
            client.setNetworkMode(.offline)
            let queued = try await within(10, "the upload") { try await attachments.upload(Self.bytes, options: options) }
            let local = try await attachments.read(blobId: queued.blobId)
            XCTAssertEqual(local, Self.bytes, "a queued upload reads offline")
            let inline = try await attachments.read(blobId: queued.blobId, disposition: .inline)
            XCTAssertEqual(inline, Self.bytes)
            XCTAssertEqual(server.downloads.count, 0)
            await client.destroy()
        }
        // Refused, and kept failed.
        do {
            let server = try SessionUploadServer { request in
                SessionUploadServer.isAttachmentPut(request)
                    ? SessionUploadServer.refused(403, "AGENT_SESSION_PARTICIPANT_ONLY")
                    : SessionUploadServer.acceptAll(request)
            }
            defer { server.stop() }
            let client = makeSessionUploadClient(server)
            let attachments = client.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")
            _ = await thrown { _ = try await within(10, "the upload") { try await attachments.upload(Self.bytes, options: options) } }
            let failed = await attachments.uploads().first { $0.state == .failed }
            let blobId = try XCTUnwrap(failed?.blobId)
            let local = try await attachments.read(blobId: blobId)
            XCTAssertEqual(local, Self.bytes, "a refused upload's bytes read locally")
            XCTAssertEqual(server.downloads.count, 0, "with no download")
            let forced = await thrown { _ = try await attachments.read(blobId: blobId, force: true) }
            XCTAssertEqual((forced as? HttpError)?.serverCode, "AGENT_SESSION_ATTACHMENT_NOT_FOUND", "force still downloads")
            await client.destroy()
        }
    }

    // MARK: - Behavior 8: the document context never sees a session upload

    func testTheDocumentContextNeitherListsNorActsOnASessionUpload() async throws {
        let server = try SessionUploadServer { request in
            if SessionUploadServer.isAttachmentPut(request) { return .status(503, "busy") }
            if request.method == "DELETE" { return .json(#"{"deleted":true}"#) }
            return SessionUploadServer.acceptAll(request)
        }
        defer { server.stop() }
        let client = makeSessionUploadClient(server)
        let attachments = client.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")
        let attachment = try await within(10, "the upload") { try await attachments.upload(Self.bytes) }
        let blobId = attachment.blobId
        let documents = client.documents
        let blobs = documents.blobs(documentId: "d1")

        let docUploads = await blobs.uploadsAsync()
        XCTAssertEqual(docUploads.map(\.blobId), [])
        let appUploads = await documents.uploadsAsync()
        XCTAssertEqual(appUploads.map(\.blobId), [])
        let scopedUploads = await documents.uploadsAsync(documentId: "d1")
        XCTAssertEqual(scopedUploads.map(\.blobId), [])
        let pausedByDocument = await blobs.pauseUploadAsync(blobId: blobId)
        XCTAssertFalse(pausedByDocument)
        let pausedByApp = await documents.pauseUploadAsync(blobId: blobId)
        XCTAssertFalse(pausedByApp)
        await blobs.pauseAllAsync()
        await documents.pauseAllUploadsAsync()
        let afterPauseAll = await status(attachments, blobId)
        XCTAssertEqual(afterPauseAll?.state, .pending, "pause-all leaves it as it was")

        _ = await attachments.pause(blobId: blobId)
        let resumedByDocument = await blobs.resumeUploadAsync(blobId: blobId)
        XCTAssertFalse(resumedByDocument)
        let resumedByApp = await documents.resumeUploadAsync(blobId: blobId)
        XCTAssertFalse(resumedByApp)
        await blobs.resumeAllAsync()
        await documents.resumeAllUploadsAsync()
        let afterResumeAll = await status(attachments, blobId)
        XCTAssertEqual(afterResumeAll?.state, .paused, "resume-all leaves it as it was")

        _ = try await blobs.delete(blobId: blobId)
        let afterDelete = await status(attachments, blobId)
        XCTAssertEqual(afterDelete?.state, .paused, "a document delete leaves the session upload")
        let local = try await attachments.read(blobId: blobId)
        XCTAssertEqual(local, Self.bytes, "and its bytes")
        await client.destroy()
    }
}
