import XCTest
@testable import JsBaoClient

/// Once this client observes that a session is gone, its queued uploads fail
/// with the not-found error (#4588, plan behaviors 16 to 20 and 46, edges 35
/// to 38): this client's `delete` returning, a session call answered
/// `AGENT_SESSION_NOT_FOUND`, or the queue's own PUT or a session read
/// answered it, each under the identity generation it was made in.
///
/// A real `JsBaoClient` signed in with a test JWT against `LoopbackAPIServer`;
/// the queue is driven through `forAgentSession`, with no view open, so no
/// reconnect `get` observes anything a test did not ask for.
final class AgentSessionGoneHermeticTests: XCTestCase {
    private static let bytes = Data("gone bytes".utf8)
    private static let goneCode = "AGENT_SESSION_NOT_FOUND"

    /// Session routes answer per `gone`; attachment PUTs answer `put`.
    private final class Script: @unchecked Sendable {
        let gone = LockedBox(false)
        let put = LockedBox<@Sendable (SessionUploadServer.Request) -> SessionUploadServer.Response>({ _ in
            .status(503, "busy")
        })
        /// The status a document upload's PUT answers; 201 lands it.
        let documentPut = LockedBox(201)

        func route(_ request: SessionUploadServer.Request) -> SessionUploadServer.Response {
            let path = request.apiPathOnly
            if SessionUploadServer.isAttachmentPut(request) { return put.value(request) }
            if path == "/auth/logout" { return .json("{}") }
            if path.hasPrefix("/documents/") {
                return documentPut.value == 201
                    ? SessionUploadServer.acceptAll(request) : .status(documentPut.value, "scripted")
            }
            guard path.hasPrefix("/agent-sessions") else { return .status(404, "not scripted") }
            if gone.value {
                return SessionUploadServer.refused(404, "AGENT_SESSION_NOT_FOUND", "No such agent session in this app")
            }
            if request.method == "DELETE", path == "/agent-sessions/s1" {
                return .json(#"{"deleted":true,"sessionId":"s1","documentId":"d1"}"#)
            }
            if path == "/agent-sessions/s1" { return .json(sessionInfoJSON("s1", documentId: "d1")) }
            return .status(404, "not scripted")
        }
    }

    private func fixture(
        userId: String = "u-a"
    ) throws -> (SessionUploadServer, JsBaoClient, Script, AgentSessionAttachments) {
        let script = Script()
        let server = try SessionUploadServer { request in script.route(request) }
        let client = makeSessionUploadClient(server, userId: userId)
        return (server, client, script, client.blobManager.forAgentSession(sessionId: "s1", documentId: "d1"))
    }

    /// An upload left queued: answered 503 once, then paused when asked.
    private func queued(_ attachments: AgentSessionAttachments, paused: Bool = false) async throws -> String {
        let blobId = try await within(10, "an upload") { try await attachments.upload(Self.bytes) }.blobId
        if paused { _ = await attachments.pause(blobId: blobId) }
        return blobId
    }

    private func state(_ attachments: AgentSessionAttachments, _ blobId: String) async -> AgentSessionUploadStatus? {
        await attachments.uploads().first { $0.blobId == blobId }
    }

    private func assertGone(
        _ error: Error?, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let http = error as? HttpError else {
            return XCTFail("expected the not-found HttpError, got \(String(describing: error))", file: file, line: line)
        }
        XCTAssertEqual(http.status, 404, file: file, line: line)
        XCTAssertEqual(http.serverCode, Self.goneCode, file: file, line: line)
        XCTAssertEqual(http.serverMessage, "No such agent session in this app", file: file, line: line)
    }

    // MARK: - Behavior 16: this client's delete

    func testDeleteFailsTheSessionsQueuedUploadsWithTheNotFoundErrorAndLeavesOthersAlone() async throws {
        let (server, client, script, attachments) = try fixture()
        defer { server.stop() }
        let events = BlobEventLog(client)
        defer { events.cancel() }
        let manager = client.blobManager
        let pending = try await queued(attachments)
        let paused = try await queued(attachments, paused: true)
        let other = manager.forAgentSession(sessionId: "s2", documentId: "d2")
        let otherId = try await queued(other)
        script.documentPut.value = 503
        _ = try? await client.documents.blobs(documentId: "doc-1").upload(data: Data("doc".utf8))
        let waits = [pending, paused].map { blobId in
            Task { try await attachments.waitUntilUploaded(blobId: blobId) }
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let deleted = try await client.agents.sessions.delete(sessionId: "s1")
        XCTAssertTrue(deleted.deleted)
        for wait in waits {
            assertGone(await thrown { _ = try await within(5, "a wait") { try await wait.value } })
        }
        for blobId in [pending, paused] {
            let listed = await state(attachments, blobId)
            XCTAssertEqual(listed?.state, .failed)
            XCTAssertEqual(listed?.error?.code, Self.goneCode)
            XCTAssertEqual(listed?.error?.message, "No such agent session in this app")
            XCTAssertEqual(events.failed(blobId).filter { !$0.willRetry }.count, 1)
            let local = try await attachments.read(blobId: blobId)
            XCTAssertEqual(local, Self.bytes, "kept locally until cancelled")
        }
        let waitAfter = await thrown { _ = try await attachments.waitUntilUploaded(blobId: pending) }
        assertGone(waitAfter)

        // Another session's upload and a document upload are untouched and land.
        let otherState = await state(other, otherId)
        XCTAssertEqual(otherState?.state, .pending)
        let documentQueued = await client.documents.uploadsAsync()
        XCTAssertEqual(documentQueued.count, 1, "the document upload is still queued")
        script.put.value = { request in SessionUploadServer.created(request) }
        script.documentPut.value = 201
        try await eventually(timeout: 10, description: "the other session's upload lands") {
            await other.uploads().isEmpty
        }
        try await eventually(timeout: 10, description: "the document upload lands") {
            await client.documents.uploadsAsync().isEmpty
        }
        // Only failed uploads are left: no timer.
        try await eventually(timeout: 5, description: "the timer idles") { await !manager.hasPendingQueueTimer }
        let starts = await manager.queueTimerStartCount
        try await Task.sleep(nanoseconds: 300_000_000)
        let startsAfter = await manager.queueTimerStartCount
        XCTAssertEqual(startsAfter, starts)

        // A second delete fails nothing twice.
        _ = try await client.agents.sessions.delete(sessionId: "s1")
        XCTAssertEqual(events.failed(pending).filter { !$0.willRetry }.count, 1)

        // Resume re-arms and retries; the server refuses with the same code.
        script.put.value = { _ in
            SessionUploadServer.refused(404, "AGENT_SESSION_NOT_FOUND", "No such agent session in this app")
        }
        let resumed = await attachments.resume(blobId: pending)
        XCTAssertTrue(resumed)
        try await eventually(timeout: 5, description: "the retry is refused") {
            events.failed(pending).filter { !$0.willRetry }.count == 2
        }
        let again = await state(attachments, pending)
        XCTAssertEqual(again?.error?.code, Self.goneCode)
        XCTAssertEqual(server.puts(of: pending).count, 2)

        let cancelled = await attachments.cancel(blobId: pending)
        XCTAssertTrue(cancelled)
        await client.destroy()
    }

    // MARK: - Behavior 17: a session call answered not found

    func testEverySessionCallAnsweredNotFoundFailsTheQueuedUploadsAndThrowsAsBefore() async throws {
        let (server, client, script, attachments) = try fixture()
        defer { server.stop() }
        let sessions = client.agents.sessions
        let calls: [(String, @Sendable () async throws -> Void)] = [
            ("get", { _ = try await sessions.get(sessionId: "s1") }),
            ("send", { _ = try await sessions.send(sessionId: "s1", body: AgentSessionSendBody(text: "hi")) }),
            ("markRead", { _ = try await sessions.markRead(sessionId: "s1") }),
            ("rename", { _ = try await sessions.rename(sessionId: "s1", title: "t") }),
            ("addMember", { _ = try await sessions.addMember(sessionId: "s1", userId: "u-x", role: .viewer) }),
            ("removeMember", { _ = try await sessions.removeMember(sessionId: "s1", userId: "u-x") }),
            ("answer", { _ = try await sessions.answer(sessionId: "s1", callId: "c1", .approval(approved: true)) }),
            ("cancel", { _ = try await sessions.cancel(sessionId: "s1", turnId: "t1") }),
            ("recordEvent", {
                _ = try await sessions.recordEvent(sessionId: "s1", event: AgentSessionEvent(kind: "viewed", data: .object([:])))
            }),
            ("uploadAttachment", {
                _ = try await sessions.uploadAttachment(
                    sessionId: "s1", blobId: "b-direct", AgentSessionAttachmentUpload(data: Data("x".utf8), filename: "x")
                )
            }),
            ("downloadAttachment", { _ = try await sessions.downloadAttachment(sessionId: "s1", blobId: "b-direct") }),
        ]
        for (name, call) in calls {
            script.gone.value = false
            script.put.value = { _ in .status(503, "busy") }
            let blobId = try await queued(attachments, paused: true)
            let wait = Task { try await attachments.waitUntilUploaded(blobId: blobId) }
            try await Task.sleep(nanoseconds: 50_000_000)
            script.gone.value = true
            script.put.value = { request in
                request.apiPathOnly.hasSuffix("/b-direct")
                    ? SessionUploadServer.refused(404, "AGENT_SESSION_NOT_FOUND", "No such agent session in this app")
                    : .status(503, "busy")
            }
            let error = await thrown { try await call() }
            XCTAssertEqual((error as? HttpError)?.serverCode, Self.goneCode, "\(name) throws as it did")
            let listed = await state(attachments, blobId)
            XCTAssertEqual(listed?.state, .failed, "\(name) observed the session gone")
            XCTAssertEqual(listed?.error?.code, Self.goneCode, name)
            assertGone(await thrown { _ = try await within(5, "the wait") { try await wait.value } })
            _ = await attachments.cancel(blobId: blobId)
        }
        await client.destroy()
    }

    /// `list`, an `attachmentHeaders` 404 and a removal event are not
    /// observations (edge 37).
    func testListAHeadRefusalAndARemovalEventObserveNothing() async throws {
        let (server, client, script, attachments) = try fixture()
        defer { server.stop() }
        let events = BlobEventLog(client)
        defer { events.cancel() }
        let blobId = try await queued(attachments, paused: true)
        script.gone.value = true

        let listError = await thrown { _ = try await client.agents.sessions.list() }
        XCTAssertEqual((listError as? HttpError)?.serverCode, Self.goneCode)
        let headError = await thrown {
            _ = try await client.agents.sessions.attachmentHeaders(sessionId: "s1", blobId: blobId)
        }
        XCTAssertEqual((headError as? HttpError)?.status, 404)
        XCTAssertNil((headError as? HttpError)?.serverCode)
        client.eventEmitter.emit(AgentSessionChangedEvent(
            action: .removed, change: .removed, at: "2026-10-20T00:00:00.000Z", sessionId: "s1", item: nil, members: nil
        ))
        try await Task.sleep(nanoseconds: 200_000_000)

        let listed = await state(attachments, blobId)
        XCTAssertEqual(listed?.state, .paused)
        XCTAssertEqual(events.failed(blobId).filter { !$0.willRetry }.count, 0)
        await client.destroy()
    }

    // MARK: - Behavior 18: observed by the queue

    func testTheUploadsOwnPutAnsweredNotFoundFailsEveryQueuedUploadOfTheSession() async throws {
        let (server, client, script, attachments) = try fixture()
        defer { server.stop() }
        let paused = try await queued(attachments, paused: true)
        let wait = Task { try await attachments.waitUntilUploaded(blobId: paused) }
        try await Task.sleep(nanoseconds: 50_000_000)
        script.put.value = { _ in
            SessionUploadServer.refused(404, "AGENT_SESSION_NOT_FOUND", "No such agent session in this app")
        }

        let uploadError = await thrown { _ = try await within(10, "the upload") { try await attachments.upload(Self.bytes) } }
        assertGone(uploadError)
        assertGone(await thrown { _ = try await within(5, "the wait") { try await wait.value } })
        let all = await attachments.uploads()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.allSatisfy { $0.state == .failed && $0.error?.code == Self.goneCode })
        await client.destroy()
    }

    func testASessionReadAnsweredNotFoundFailsTheQueuedUploads() async throws {
        let (server, client, script, attachments) = try fixture()
        defer { server.stop() }
        let paused = try await queued(attachments, paused: true)
        script.gone.value = true

        let readError = await thrown { _ = try await attachments.read(blobId: "b-somebody-elses") }
        assertGone(readError)
        let listed = await state(attachments, paused)
        XCTAssertEqual(listed?.state, .failed)
        XCTAssertEqual(listed?.error?.code, Self.goneCode)
        await client.destroy()
    }

    // MARK: - Behavior 19: an attempt in flight

    func testAnAttemptInFlightWhenTheSessionIsDeletedChangesNothingWhenItAnswers() async throws {
        let (server, client, script, attachments) = try fixture()
        defer { server.stop() }
        let events = BlobEventLog(client)
        defer { events.cancel() }
        script.put.value = { request in SessionUploadServer.created(request) }
        server.hold(SessionUploadServer.isAttachmentPut)
        let upload = Task { try await attachments.upload(Self.bytes) }
        try await eventually(timeout: 5, description: "the PUT is held") { server.heldRequests.count == 1 }
        let blobId = String(server.heldRequests[0].apiPathOnly.split(separator: "/").last ?? "")

        _ = try await client.agents.sessions.delete(sessionId: "s1")
        assertGone(await thrown { _ = try await within(5, "the upload call") { try await upload.value } })
        server.release(SessionUploadServer.created(server.heldRequests[0]))
        try await Task.sleep(nanoseconds: 300_000_000)
        let listed = await state(attachments, blobId)
        XCTAssertEqual(listed?.state, .failed, "the held 201 completes nothing")
        XCTAssertEqual(events.completed(blobId).count, 0)
        XCTAssertEqual(events.failed(blobId).count, 1)
        await client.destroy()
    }

    func testANotFoundReleasedAfterAnObservationChangesNothingMore() async throws {
        let (server, client, script, attachments) = try fixture()
        defer { server.stop() }
        let events = BlobEventLog(client)
        defer { events.cancel() }
        let paused = try await queued(attachments, paused: true)
        server.hold(SessionUploadServer.isAttachmentPut)
        _ = await attachments.resume(blobId: paused)
        try await eventually(timeout: 5, description: "the resumed PUT is held") { server.heldRequests.count == 1 }

        script.gone.value = true
        _ = await thrown { _ = try await client.agents.sessions.get(sessionId: "s1") }
        XCTAssertEqual(events.failed(paused).filter { !$0.willRetry }.count, 1)
        server.release(SessionUploadServer.refused(404, "AGENT_SESSION_NOT_FOUND", "No such agent session in this app"))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(events.failed(paused).filter { !$0.willRetry }.count, 1, "no second failure")
        await client.destroy()
    }

    func testAResumeBeforeTheHeldAttemptSettlesRecordsOnlyTheNewAttempt() async throws {
        let (server, client, script, attachments) = try fixture()
        defer { server.stop() }
        let events = BlobEventLog(client)
        defer { events.cancel() }
        server.hold(SessionUploadServer.isAttachmentPut)
        let upload = Task { try await attachments.upload(Self.bytes) }
        try await eventually(timeout: 5, description: "the first PUT is held") { server.heldRequests.count == 1 }
        let blobId = String(server.heldRequests[0].apiPathOnly.split(separator: "/").last ?? "")
        _ = try await client.agents.sessions.delete(sessionId: "s1")
        _ = await thrown { _ = try await within(5, "the upload call") { try await upload.value } }

        script.put.value = { request in SessionUploadServer.created(request) }
        let resumed = await attachments.resume(blobId: blobId)
        XCTAssertTrue(resumed)
        try await eventually(timeout: 5, description: "the new attempt is held") { server.heldRequests.count == 2 }
        server.release(SessionUploadServer.refused(404, "AGENT_SESSION_NOT_FOUND", "No such agent session in this app"))
        try await Task.sleep(nanoseconds: 200_000_000)
        let stillUploading = await state(attachments, blobId)
        XCTAssertEqual(stillUploading?.state, .uploading, "the first attempt's answer is ignored")
        server.hold(nil)
        server.release(SessionUploadServer.created(server.heldRequests[0]))
        let landed = try await within(5, "the new attempt") { try await attachments.waitUntilUploaded(blobId: blobId) }
        XCTAssertEqual(landed.blobId, blobId)
        XCTAssertEqual(events.completed(blobId).count, 1)
        XCTAssertEqual(events.failed(blobId).filter { !$0.willRetry }.count, 1)
        await client.destroy()
    }

    // MARK: - Behaviors 20 and 46: identity generations

    func testAnObservationFromBeforeAUserChangeFailsNothingOfTheNextUsers() async throws {
        let (server, client, script, attachments) = try fixture()
        defer { server.stop() }
        let events = BlobEventLog(client)
        defer { events.cancel() }
        server.hold { $0.method == "GET" && $0.apiPathOnly == "/agent-sessions/s1" }
        script.gone.value = true
        let get = Task { try await client.agents.sessions.get(sessionId: "s1") }
        try await eventually(timeout: 5, description: "A's get is held") { server.heldRequests.count == 1 }

        client.updateToken(makeTestJwt(userId: "u-b"))
        let generationForB = await client.blobManager.captureIdentity()
        XCTAssertGreaterThan(generationForB, 0, "the queue sees B as soon as B's token is applied")
        let mine = try await queued(attachments, paused: true)
        let wait = Task { try await attachments.waitUntilUploaded(blobId: mine) }
        server.hold(nil)
        server.release(SessionUploadServer.refused(404, "AGENT_SESSION_NOT_FOUND", "No such agent session in this app"))
        _ = await thrown { _ = try await within(5, "A's get") { try await get.value } }
        try await Task.sleep(nanoseconds: 200_000_000)

        let listed = await state(attachments, mine)
        XCTAssertEqual(listed?.state, .paused, "A's observation fails nothing of B's")
        XCTAssertEqual(events.failed(mine).filter { !$0.willRetry }.count, 0)
        wait.cancel()
        await client.destroy()
    }

    func testAnObservationFromBeforeAToBToAFailsNothingReadopted() async throws {
        let tokenA = makeTestJwt(userId: "u-a")
        let (server, client, script, attachments) = try fixture()
        defer { server.stop() }
        let events = BlobEventLog(client)
        defer { events.cancel() }
        let manager = client.blobManager
        let first = await manager.captureIdentity()
        let blobId = try await queued(attachments, paused: true)
        server.hold { $0.method == "GET" && $0.apiPathOnly == "/agent-sessions/s1" }
        script.gone.value = true
        let get = Task { try await client.agents.sessions.get(sessionId: "s1") }
        try await eventually(timeout: 5, description: "A's get is held") { server.heldRequests.count == 1 }

        client.updateToken(makeTestJwt(userId: "u-b"))
        let generationForB = await manager.captureIdentity()
        XCTAssertEqual(generationForB, first + 1, "B's generation, as soon as B's token is applied")
        client.updateToken(tokenA)
        let generationForA = await manager.captureIdentity()
        XCTAssertEqual(generationForA, first + 2, "A's again")
        let readopted = await state(attachments, blobId)
        XCTAssertEqual(readopted?.state, .paused, "A's upload is A's again")
        let wait = Task { try await attachments.waitUntilUploaded(blobId: blobId) }
        server.hold(nil)
        server.release(SessionUploadServer.refused(404, "AGENT_SESSION_NOT_FOUND", "No such agent session in this app"))
        _ = await thrown { _ = try await within(5, "the get") { try await get.value } }
        try await Task.sleep(nanoseconds: 200_000_000)
        let after = await state(attachments, blobId)
        XCTAssertEqual(after?.state, .paused, "the stale observation fails nothing")
        XCTAssertEqual(events.failed(blobId).filter { !$0.willRetry }.count, 0)

        // Behavior 46: the first generation is a no-op; the current one fails it.
        await manager.failAgentSessionUploads(
            sessionId: "s1", error: AgentSessionsAPI.sessionGoneError(), identity: first
        )
        let untouched = await state(attachments, blobId)
        XCTAssertEqual(untouched?.state, .paused)
        XCTAssertEqual(events.failed(blobId).filter { !$0.willRetry }.count, 0)
        let current = await manager.captureIdentity()
        await manager.failAgentSessionUploads(
            sessionId: "s1", error: AgentSessionsAPI.sessionGoneError(), identity: current
        )
        assertGone(await thrown { _ = try await within(5, "the wait") { try await wait.value } })
        let failed = await state(attachments, blobId)
        XCTAssertEqual(failed?.state, .failed)
        await client.destroy()
    }

    func testAnObservationFromBeforeALogoutAndSignInFailsNothing() async throws {
        let tokenA = makeTestJwt(userId: "u-a")
        let (server, client, script, attachments) = try fixture()
        defer { server.stop() }
        let events = BlobEventLog(client)
        defer { events.cancel() }
        let manager = client.blobManager
        let blobId = try await queued(attachments, paused: true)
        server.hold { $0.method == "GET" && $0.apiPathOnly == "/agent-sessions/s1" }
        script.gone.value = true
        let before = await manager.captureIdentity()
        let get = Task { try await client.agents.sessions.get(sessionId: "s1") }
        try await eventually(timeout: 5, description: "the get is held") { server.heldRequests.count == 1 }

        try await client.logout()
        client.updateToken(tokenA)
        let signedInAgain = await manager.captureIdentity()
        XCTAssertGreaterThan(signedInAgain, before + 1, "a generation for the logout and one for the sign-in")
        let readopted = await state(attachments, blobId)
        XCTAssertEqual(readopted?.state, .paused)
        server.hold(nil)
        server.release(SessionUploadServer.refused(404, "AGENT_SESSION_NOT_FOUND", "No such agent session in this app"))
        _ = await thrown { _ = try await within(5, "the get") { try await get.value } }
        try await Task.sleep(nanoseconds: 200_000_000)
        let after = await state(attachments, blobId)
        XCTAssertEqual(after?.state, .paused)
        XCTAssertEqual(events.failed(blobId).filter { !$0.willRetry }.count, 0)
        await manager.failAgentSessionUploads(
            sessionId: "s1", error: AgentSessionsAPI.sessionGoneError(), identity: before
        )
        let stillPaused = await state(attachments, blobId)
        XCTAssertEqual(stillPaused?.state, .paused, "the pre-logout generation is a no-op")
        await client.destroy()
    }

    // MARK: - Edges 35 and 36

    func testFailingASessionFailsPendingUploadingAndPausedOnceAndNeverRefailsAFailedOne() async throws {
        let (server, client, script, attachments) = try fixture()
        defer { server.stop() }
        let events = BlobEventLog(client)
        defer { events.cancel() }
        let manager = client.blobManager
        script.put.value = { _ in SessionUploadServer.refused(403, "AGENT_SESSION_PARTICIPANT_ONLY") }
        _ = await thrown { _ = try await attachments.upload(Self.bytes) }
        let refused = try XCTUnwrap(server.attachmentPuts.last?.apiPathOnly.split(separator: "/").last.map(String.init))
        script.put.value = { _ in .status(503, "busy") }
        let pending = try await queued(attachments)
        let paused = try await queued(attachments, paused: true)
        server.hold(SessionUploadServer.isAttachmentPut)
        let uploadingCall = Task { try await attachments.upload(Self.bytes) }
        try await eventually(timeout: 5, description: "an upload in flight") { server.heldRequests.count == 1 }
        let uploading = String(server.heldRequests[0].apiPathOnly.split(separator: "/").last ?? "")
        let uploadingState = await state(attachments, uploading)
        XCTAssertEqual(uploadingState?.state, .uploading)

        let identity = await manager.captureIdentity()
        await manager.failAgentSessionUploads(sessionId: "s1", error: AgentSessionsAPI.sessionGoneError(), identity: identity)
        _ = await thrown { _ = try await within(5, "the call in flight") { try await uploadingCall.value } }
        for blobId in [pending, paused, uploading] {
            let listed = await state(attachments, blobId)
            XCTAssertEqual(listed?.error?.code, Self.goneCode, blobId)
            XCTAssertEqual(events.failed(blobId).filter { !$0.willRetry }.count, 1, blobId)
        }
        let first = await state(attachments, refused)
        XCTAssertEqual(first?.error?.code, "AGENT_SESSION_PARTICIPANT_ONLY", "a failed upload keeps its first error")
        XCTAssertEqual(events.failed(refused).filter { !$0.willRetry }.count, 1)

        // Edge 35: again, and for a session with nothing queued: nothing.
        await manager.failAgentSessionUploads(sessionId: "s1", error: AgentSessionsAPI.sessionGoneError(), identity: identity)
        await manager.failAgentSessionUploads(sessionId: "s9", error: AgentSessionsAPI.sessionGoneError(), identity: identity)
        for blobId in [pending, paused, uploading, refused] {
            XCTAssertEqual(events.failed(blobId).filter { !$0.willRetry }.count, 1, blobId)
        }
        server.hold(nil)
        await client.destroy()
    }
}
