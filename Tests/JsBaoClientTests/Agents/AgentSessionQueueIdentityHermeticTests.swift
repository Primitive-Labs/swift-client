import XCTest
@testable import JsBaoClient

/// A session upload belongs to the user who queued it (#4588, plan behaviors
/// 6, 45 and 47, edges 44, 48 and 49): it is listed and attempted only while
/// that user is signed in, every attempt carries that user's token whoever is
/// signed in when the request leaves or is retried, and the queue's timer
/// runs only for work it can attempt.
///
/// The account switches run on a real client over `LoopbackAPIServer`, which
/// records each request's `Authorization`; the queue is driven directly, with
/// no document open, so nothing races the reconnect a token change starts.
/// The timer checks run on a manager built with millisecond backoffs over a
/// recording transport.
final class AgentSessionQueueIdentityHermeticTests: XCTestCase {
    private static let bytes = Data("queued bytes".utf8)

    private static func blobId(of request: LoopbackAPIServer.Request) -> String {
        request.apiPathOnly.split(separator: "/").last.map(String.init) ?? ""
    }

    // MARK: - Behavior 6: another user's token

    func testAnUploadQueuedAsAIsNeitherListedNorSentForBAndResumesWhenASignsInAgain() async throws {
        let tokenA = makeTestJwt(userId: "u-a")
        let tokenB = makeTestJwt(userId: "u-b")
        let server = try SessionUploadServer { request in
            SessionUploadServer.isAttachmentPut(request) ? .status(503, "busy") : SessionUploadServer.acceptAll(request)
        }
        defer { server.stop() }
        let client = makeSessionUploadClient(server, token: tokenA)
        let manager = client.blobManager
        let attachments = manager.forAgentSession(sessionId: "s1", documentId: "d1")
        let queued = try await within(10, "A's upload") { try await attachments.upload(Self.bytes) }
        let wait = Task { try await attachments.waitUntilUploaded(blobId: queued.blobId) }
        try await Task.sleep(nanoseconds: 100_000_000)

        client.updateToken(tokenB)
        let waitError = await thrown { _ = try await within(5, "A's wait") { try await wait.value } }
        XCTAssertEqual((waitError as? JsBaoError)?.code, .agentSessionUploadIdentityChanged)
        XCTAssertEqual((waitError as? JsBaoError)?.details?["blobId"], .string(queued.blobId))
        let listedForB = await attachments.uploads()
        XCTAssertEqual(listedForB, [], "B does not see A's upload")
        let pausedByB = await attachments.pause(blobId: queued.blobId)
        XCTAssertFalse(pausedByB, "nor act on it")

        server.answer(SessionUploadServer.acceptAll)
        try await Task.sleep(nanoseconds: 2_600_000_000)
        XCTAssertEqual(server.puts(of: queued.blobId).count, 1, "A's upload is not attempted while B is signed in")
        let timerArmed = await manager.hasPendingQueueTimer
        XCTAssertFalse(timerArmed, "nothing runnable keeps no timer")

        // B's own upload is B's.
        let mine = try await within(10, "B's upload") { try await attachments.upload(Self.bytes) }
        XCTAssertEqual(server.puts(of: mine.blobId).map { $0.header("Authorization") }, ["Bearer \(tokenB)"])

        client.updateToken(tokenA)
        try await eventually(timeout: 10, description: "A's upload is attempted once A is back") {
            server.puts(of: queued.blobId).count == 2
        }
        try await eventually(timeout: 5, description: "and lands") { await attachments.uploads().isEmpty }
        XCTAssertEqual(
            server.puts(of: queued.blobId).map { $0.header("Authorization") },
            ["Bearer \(tokenA)", "Bearer \(tokenA)"],
            "every PUT of A's upload carries A's token"
        )
        await client.destroy()
    }

    // MARK: - Behavior 45: the attempt's own credentials

    func testAHeldAttemptNeverLeavesWithTheNextUsersToken() async throws {
        let tokenA = makeTestJwt(userId: "u-a")
        let tokenB = makeTestJwt(userId: "u-b")
        let server = try SessionUploadServer { request in
            if request.apiPathOnly == "/auth/refresh" { return .json(#"{"token":"\#(tokenB)"}"#) }
            return SessionUploadServer.acceptAll(request)
        }
        defer { server.stop() }
        server.hold { $0.method == "PUT" }
        let client = makeSessionUploadClient(server, token: tokenA)
        let attachments = client.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")
        let upload = Task { try await attachments.upload(Self.bytes) }
        try await eventually(timeout: 5, description: "A's PUT is held") { server.heldRequests.count == 1 }
        let blobId = Self.blobId(of: server.heldRequests[0])
        let wait = Task { try await attachments.waitUntilUploaded(blobId: blobId) }
        try await Task.sleep(nanoseconds: 100_000_000)
        // A document upload in the same state, for comparison.
        let documentUpload = Task {
            try await client.documents.blobs(documentId: "doc-1").upload(data: Data("doc".utf8))
        }
        try await eventually(timeout: 5, description: "the document PUT is held") { server.heldRequests.count == 2 }

        client.updateToken(tokenB)
        let waitError = await thrown { _ = try await within(5, "A's wait") { try await wait.value } }
        XCTAssertEqual((waitError as? JsBaoError)?.code, .agentSessionUploadIdentityChanged)
        server.hold(nil)
        server.release(.status(401, "expired"))
        server.release(.status(401, "expired"))
        _ = try? await within(10, "A's upload call") { try await upload.value }
        _ = try? await within(10, "the document upload") { try await documentUpload.value }
        try await Task.sleep(nanoseconds: 300_000_000)

        let sessionPuts = server.puts(of: blobId)
        XCTAssertFalse(sessionPuts.isEmpty)
        XCTAssertTrue(
            sessionPuts.allSatisfy { $0.header("Authorization") == "Bearer \(tokenA)" },
            "a PUT of A's upload never carries B's token: \(sessionPuts.map { $0.header("Authorization") ?? "-" })"
        )
        let listed = await attachments.uploads()
        XCTAssertEqual(listed, [], "the upload is inert for B")
        // The document upload is A's too since #4592 (DEC-4592-001): its
        // retry after the 401 refresh re-sends A's token, never B's.
        let documentPuts = server.requests.filter { $0.method == "PUT" && $0.apiPathOnly.hasPrefix("/documents/doc-1/") }
        XCTAssertEqual(documentPuts.map { $0.header("Authorization") }, ["Bearer \(tokenA)", "Bearer \(tokenA)"])
        await client.destroy()
    }

    func testA401WhileTheUserStaysSignedInRequeuesAndTheNextAttemptTakesTheirNewToken() async throws {
        let tokenA = makeTestJwt(userId: "u-a", exp: 9_999_999_998)
        let tokenA2 = makeTestJwt(userId: "u-a", exp: 9_999_999_999)
        let server = try SessionUploadServer { request in
            if request.apiPathOnly == "/auth/refresh" { return .json(#"{"token":"\#(tokenA2)"}"#) }
            if SessionUploadServer.isAttachmentPut(request) {
                return request.header("Authorization") == "Bearer \(tokenA2)"
                    ? SessionUploadServer.created(request)
                    : .status(401, "expired")
            }
            return SessionUploadServer.acceptAll(request)
        }
        defer { server.stop() }
        let client = makeSessionUploadClient(server, token: tokenA)
        let events = BlobEventLog(client)
        defer { events.cancel() }
        let attachments = client.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")

        let attachment = try await within(10, "the upload") { try await attachments.upload(Self.bytes) }
        XCTAssertEqual(
            server.puts(of: attachment.blobId).map { $0.header("Authorization") },
            ["Bearer \(tokenA)", "Bearer \(tokenA)"],
            "the transport's retry after its refresh re-sends the attempt's own token"
        )
        XCTAssertEqual(events.failed(attachment.blobId).map(\.willRetry), [true], "a 401 is retried")
        let queuedStatus = await attachments.uploads().first
        XCTAssertEqual(queuedStatus?.state, .pending)

        let landed = try await within(10, "the next attempt") {
            try await attachments.waitUntilUploaded(blobId: attachment.blobId)
        }
        XCTAssertEqual(landed, attachment)
        XCTAssertEqual(server.puts(of: attachment.blobId).last?.header("Authorization"), "Bearer \(tokenA2)")
        await client.destroy()
    }

    // MARK: - Edge 44: logout

    func testLogoutLeavesTheUploadInertAndTheSameUsersSignInReadoptsIt() async throws {
        let tokenA = makeTestJwt(userId: "u-a")
        let server = try SessionUploadServer { request in
            SessionUploadServer.isAttachmentPut(request) ? .status(503, "busy") : SessionUploadServer.acceptAll(request)
        }
        defer { server.stop() }
        let client = makeSessionUploadClient(server, token: tokenA)
        let manager = client.blobManager
        let attachments = manager.forAgentSession(sessionId: "s1", documentId: "d1")
        let queued = try await within(10, "the upload") { try await attachments.upload(Self.bytes) }
        _ = await attachments.pause(blobId: queued.blobId)
        server.hold(SessionUploadServer.isAttachmentPut)
        _ = await attachments.resume(blobId: queued.blobId)
        try await eventually(timeout: 5, description: "the resumed attempt is in flight") {
            server.heldRequests.count == 1
        }
        let wait = Task { try await attachments.waitUntilUploaded(blobId: queued.blobId) }
        try await Task.sleep(nanoseconds: 100_000_000)

        try await client.logout()
        let waitError = await thrown { _ = try await within(5, "the wait") { try await wait.value } }
        XCTAssertEqual((waitError as? JsBaoError)?.code, .agentSessionUploadIdentityChanged)
        let listed = await attachments.uploads()
        XCTAssertEqual(listed, [], "not listed while signed out")
        server.hold(nil)
        server.answer(SessionUploadServer.acceptAll)
        server.release(SessionUploadServer.created(server.heldRequests[0]))
        try await Task.sleep(nanoseconds: 2_600_000_000)
        XCTAssertEqual(server.puts(of: queued.blobId).count, 2, "no further PUT leaves while signed out")
        let timerArmed = await manager.hasPendingQueueTimer
        XCTAssertFalse(timerArmed)

        client.updateToken(tokenA)
        try await eventually(timeout: 10, description: "the upload is attempted for A again") {
            server.puts(of: queued.blobId).count == 3
        }
        try await eventually(timeout: 5, description: "and lands") { await attachments.uploads().isEmpty }
        XCTAssertTrue(server.puts(of: queued.blobId).allSatisfy { $0.header("Authorization") == "Bearer \(tokenA)" })
        await client.destroy()
    }

    // MARK: - A switch is in force for the queue as soon as the token is

    /// CSO-4588-001: nothing waits for the client to tell the queue. A held
    /// attempt of A's answered right after B's token is applied completes
    /// nothing, and work B queues at once is B's, untouched by an
    /// observation made before the switch.
    func testAHeldAttemptAnsweredRightAfterASwitchCompletesNothingAndEndsAsWait() async throws {
        let tokenA = makeTestJwt(userId: "u-a")
        let tokenB = makeTestJwt(userId: "u-b")
        let server = try SessionUploadServer()
        defer { server.stop() }
        server.hold(SessionUploadServer.isAttachmentPut)
        let client = makeSessionUploadClient(server, token: tokenA)
        let events = BlobEventLog(client)
        defer { events.cancel() }
        let attachments = client.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")
        let upload = Task { try await attachments.upload(Self.bytes) }
        try await eventually(timeout: 5, description: "A's PUT is held") { server.heldRequests.count == 1 }
        let blobId = Self.blobId(of: server.heldRequests[0])
        let wait = Task { try await attachments.waitUntilUploaded(blobId: blobId) }
        try await Task.sleep(nanoseconds: 100_000_000)

        client.updateToken(tokenB)
        server.hold(nil)
        server.release(SessionUploadServer.created(server.heldRequests[0]))
        let waitError = await thrown { _ = try await within(5, "A's wait") { try await wait.value } }
        XCTAssertEqual((waitError as? JsBaoError)?.code, .agentSessionUploadIdentityChanged)
        _ = try? await within(5, "A's upload call") { try await upload.value }
        XCTAssertEqual(events.completed(blobId).count, 0, "the answer completes nothing")
        let listedForB = await attachments.uploads()
        XCTAssertEqual(listedForB, [])

        client.updateToken(tokenA)
        try await eventually(timeout: 10, description: "A's upload is attempted again for A") {
            server.puts(of: blobId).count == 2
        }
        try await eventually(timeout: 5, description: "and lands") { await attachments.uploads().isEmpty }
        await client.destroy()
    }

    func testWorkQueuedRightAfterASwitchIsTheNewUsersAndAnEarlierObservationFailsNone() async throws {
        let tokenA = makeTestJwt(userId: "u-a")
        let tokenB = makeTestJwt(userId: "u-b")
        let server = try SessionUploadServer { request in
            SessionUploadServer.isAttachmentPut(request) ? .status(503, "busy") : SessionUploadServer.acceptAll(request)
        }
        defer { server.stop() }
        let client = makeSessionUploadClient(server, token: tokenA)
        let events = BlobEventLog(client)
        defer { events.cancel() }
        let manager = client.blobManager
        let attachments = manager.forAgentSession(sessionId: "s1", documentId: "d1")
        let beforeSwitch = await manager.captureIdentity()

        client.updateToken(tokenB)
        let mine = try await within(10, "B's upload") { try await attachments.upload(Self.bytes) }
        await manager.failAgentSessionUploads(
            sessionId: "s1",
            error: AgentSessionsAPI.sessionGoneError(),
            identity: beforeSwitch
        )
        let listed = await attachments.uploads()
        XCTAssertEqual(listed.map(\.blobId), [mine.blobId])
        XCTAssertEqual(listed.first?.state, .pending, "an observation from before the switch fails nothing of B's")
        XCTAssertEqual(events.failed(mine.blobId).map(\.willRetry), [true])
        XCTAssertEqual(server.puts(of: mine.blobId).map { $0.header("Authorization") }, ["Bearer \(tokenB)"])
        await client.destroy()
    }

    // MARK: - The token cleared without a logout

    /// CSO-4588-002: `updateToken(nil)` and a rejected refresh clear the
    /// token without `logout()`; the waits on the user's uploads end there,
    /// and the uploads stay for that user's next sign-in.
    func testClearingTheTokenEndsTheWaitsAndTheSameUsersSignInReadoptsTheUpload() async throws {
        for clear in ["updateToken(nil)", "rejected refresh"] {
            let tokenA = makeTestJwt(userId: "u-a")
            let server = try SessionUploadServer { request in
                SessionUploadServer.isAttachmentPut(request) ? .status(503, "busy") : SessionUploadServer.acceptAll(request)
            }
            let client = makeSessionUploadClient(server, token: tokenA)
            let attachments = client.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")
            let queued = try await within(10, "the upload") { try await attachments.upload(Self.bytes) }
            let wait = Task { try await attachments.waitUntilUploaded(blobId: queued.blobId) }
            try await Task.sleep(nanoseconds: 100_000_000)

            if clear == "updateToken(nil)" {
                client.updateToken(nil)
            } else {
                client.authController.applyToken(
                    nil, previous: tokenA, cause: "refreshFailed", requiring: .unchangedFrom(tokenA)
                )
            }
            let waitError = await thrown { _ = try await within(5, "the wait (\(clear))") { try await wait.value } }
            XCTAssertEqual((waitError as? JsBaoError)?.code, .agentSessionUploadIdentityChanged, clear)
            let listed = await attachments.uploads()
            XCTAssertEqual(listed, [], "not listed with no user signed in (\(clear))")

            server.answer(SessionUploadServer.acceptAll)
            client.updateToken(tokenA)
            try await eventually(timeout: 10, description: "the upload lands for A again (\(clear))") {
                await attachments.uploads().isEmpty
            }
            XCTAssertEqual(
                server.puts(of: queued.blobId).map { $0.header("Authorization") }, ["Bearer \(tokenA)", "Bearer \(tokenA)"],
                clear
            )
            await client.destroy()
            server.stop()
        }
    }

    // MARK: - An attempt invalidated before its transfer starts

    /// CSO-4588-003: an attempt invalidated between its selection and its
    /// transfer sends nothing. The manager's progress event for the attempt
    /// is emitted in exactly that gap.
    func testAnAttemptInvalidatedBeforeItsTransferStartsSendsNothing() async throws {
        // A pause, from the "uploading" progress event.
        do {
            let transport = RecordingTransport(status: 201, json: "{}")
            let managerBox = LockedBox<BlobManager?>(nil)
            let paused = LockedBox<Bool?>(nil)
            let manager = BlobManager(
                logger: Logger(level: .error, scope: "test"),
                transport: transport,
                emit: { payload in
                    guard let progress = payload as? BlobUploadProgressEvent, progress.status == "uploading",
                          paused.value == nil, let manager = managerBox.value
                    else { return }
                    let done = DispatchSemaphore(value: 0)
                    Task {
                        paused.value = await manager.pauseSessionUpload(blobId: progress.blobId, sessionId: "s1")
                        done.signal()
                    }
                    _ = done.wait(timeout: .now() + 5)
                },
                currentIdentity: { UploadIdentity(token: "t-a", userId: "u-a") },
                networkingAllowed: { true }
            )
            managerBox.value = manager
            let attachments = manager.forAgentSession(sessionId: "s1", documentId: "d1")
            let attachment = try await within(10, "the upload") { try await attachments.upload(Self.bytes) }
            XCTAssertEqual(paused.value, true, "paused while selected")
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(transport.calls.count, 0, "the paused attempt sent nothing")
            let status = await attachments.uploads().first { $0.blobId == attachment.blobId }
            XCTAssertEqual(status?.state, .paused)
        }
        // A change of user, seen through the identity the queue reads.
        do {
            let transport = RecordingTransport(status: 201, json: "{}")
            let identity = LockedBox(UploadIdentity(token: "t-a", userId: "u-a"))
            let switched = LockedBox(false)
            let manager = BlobManager(
                logger: Logger(level: .error, scope: "test"),
                transport: transport,
                emit: { payload in
                    guard let progress = payload as? BlobUploadProgressEvent, progress.status == "uploading",
                          !switched.value
                    else { return }
                    switched.value = true
                    identity.value = UploadIdentity(token: "t-b", userId: "u-b", epoch: 1)
                },
                currentIdentity: { identity.value },
                networkingAllowed: { true }
            )
            let attachments = manager.forAgentSession(sessionId: "s1", documentId: "d1")
            let attachment = try await within(10, "A's upload") { try await attachments.upload(Self.bytes) }
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(transport.calls.count, 0, "nothing of A's leaves once B is signed in")
            let listedForB = await attachments.uploads()
            XCTAssertEqual(listedForB, [])
            // What the client's identity handler does on A's sign-in.
            identity.value = UploadIdentity(token: "t-a2", userId: "u-a", epoch: 2)
            await manager.syncIdentity()
            try await eventually(timeout: 5, description: "A's upload runs for A") { transport.calls.count == 1 }
            XCTAssertEqual(transport.calls.first?.path, "/agent-sessions/s1/attachments/\(attachment.blobId)")
            XCTAssertEqual(transport.calls.first?.options?.customHeaders["Authorization"], "Bearer t-a2")
        }
    }

    // MARK: - Edge 49: a refresh for the same user

    func testANewTokenForTheSameUserKeepsTheUploadAndItsWaitAndIsTheNextAttemptsToken() async throws {
        let tokenA = makeTestJwt(userId: "u-a", exp: 9_999_999_998)
        let tokenA2 = makeTestJwt(userId: "u-a", exp: 9_999_999_999)
        let server = try SessionUploadServer { request in
            SessionUploadServer.isAttachmentPut(request) ? .status(503, "busy") : SessionUploadServer.acceptAll(request)
        }
        defer { server.stop() }
        let client = makeSessionUploadClient(server, token: tokenA)
        let attachments = client.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")
        let queued = try await within(10, "the upload") { try await attachments.upload(Self.bytes) }
        let wait = Task { try await attachments.waitUntilUploaded(blobId: queued.blobId) }

        client.updateToken(tokenA2)
        try await Task.sleep(nanoseconds: 300_000_000)
        let listed = await attachments.uploads()
        XCTAssertEqual(listed.map(\.blobId), [queued.blobId], "still listed for the same user")
        server.answer(SessionUploadServer.acceptAll)
        let landed = try await within(10, "the wait") { try await wait.value }
        XCTAssertEqual(landed, queued, "the wait was not ended by a refresh")
        XCTAssertEqual(server.puts(of: queued.blobId).last?.header("Authorization"), "Bearer \(tokenA2)")
        await client.destroy()
    }

    // MARK: - Behavior 47 and edge 48: the timer runs only for runnable work

    private final class Switches: @unchecked Sendable {
        let identity = LockedBox(UploadIdentity(token: "t-a", userId: "u-a"))
        let networking = LockedBox(true)
    }

    private func manager(
        _ switches: Switches, _ transport: RecordingTransport
    ) -> BlobManager {
        BlobManager(
            logger: Logger(level: .error, scope: "test"),
            uploadConcurrency: 4,
            backoffBaseMs: 20,
            backoffMaxMs: 40,
            transport: transport,
            currentIdentity: { switches.identity.value },
            networkingAllowed: { switches.networking.value }
        )
    }

    /// A transport answering session PUTs and document PUTs each with its
    /// own scripted status.
    private final class Answers: @unchecked Sendable {
        let session = LockedBox(201)
        let document = LockedBox(201)
    }

    private static func recording(_ answers: Answers) -> RecordingTransport {
        RecordingTransport { call in
            let status = call.path.contains("/attachments/") ? answers.session.value : answers.document.value
            return TransportResponse(
                status: status, headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"scripted","code":"SCRIPTED"}"#.utf8)
            )
        }
    }

    func testOnlyUnrunnableSessionUploadsLeaveTheTimerIdleUntilEachIsRunnableAgain() async throws {
        let switches = Switches()
        let answers = Answers()
        let transport = Self.recording(answers)
        let manager = manager(switches, transport)
        let attachments = manager.forAgentSession(sessionId: "s1", documentId: "d1")
        let attempts = { (blobId: String) in transport.calls.filter { $0.path.hasSuffix("/attachments/\(blobId)") } }

        // A's upload, queued; then B signs in, so it is a user's not signed in.
        answers.session.value = 503
        let othersId = try await attachments.upload(Self.bytes).blobId
        switches.identity.value = UploadIdentity(token: "t-b", userId: "u-b")
        await manager.identityChanged()
        // B's upload, refused: failed.
        answers.session.value = 403
        let refusedError = await thrown { _ = try await attachments.upload(Self.bytes) }
        XCTAssertNotNil(refusedError as? HttpError)
        let failedNow = await attachments.uploads().first { $0.state == .failed }
        let refusedId = try XCTUnwrap(failedNow?.blobId)
        // B's upload made while the client may not use the network.
        switches.networking.value = false
        let offlineId = try await attachments.upload(Self.bytes).blobId
        XCTAssertEqual(attempts(offlineId).count, 0)

        try await Task.sleep(nanoseconds: 150_000_000)
        let starts = await manager.queueTimerStartCount
        try await Task.sleep(nanoseconds: 400_000_000)
        let startsAfter = await manager.queueTimerStartCount
        XCTAssertEqual(startsAfter, starts, "no timer starts for unrunnable work, over many backoffs")
        let armed = await manager.hasPendingQueueTimer
        XCTAssertFalse(armed)
        XCTAssertEqual(attempts(othersId).count, 1)
        XCTAssertEqual(attempts(refusedId).count, 1)

        // A document upload alongside keeps its own schedule.
        answers.document.value = 503
        _ = try? await manager.uploadFromSource(documentId: "doc-1", source: Data("doc".utf8))
        let docStarts = await manager.queueTimerStartCount
        try await Task.sleep(nanoseconds: 300_000_000)
        let docStartsAfter = await manager.queueTimerStartCount
        XCTAssertGreaterThan(docStartsAfter, docStarts, "the document upload's retries keep their timer")
        XCTAssertEqual(attempts(othersId).count, 1, "the session uploads are still not attempted")
        XCTAssertEqual(attempts(refusedId).count, 1)
        XCTAssertEqual(attempts(offlineId).count, 0)
        await manager.pauseAll()

        // Each comes back: the network, a resume, and the owner's sign-in.
        answers.session.value = 201
        switches.networking.value = true
        await manager.networkingChanged()
        try await eventually(timeout: 5, description: "the offline upload runs once the network is allowed") {
            attempts(offlineId).count == 1
        }
        let resumed = await attachments.resume(blobId: refusedId)
        XCTAssertTrue(resumed)
        try await eventually(timeout: 5, description: "the resumed upload runs") { attempts(refusedId).count == 2 }
        XCTAssertEqual(attempts(othersId).count, 1)
        switches.identity.value = UploadIdentity(token: "t-a", userId: "u-a")
        await manager.identityChanged()
        try await eventually(timeout: 5, description: "A's upload runs once A signs in") { attempts(othersId).count == 2 }
        XCTAssertEqual(attempts(othersId).last?.options?.customHeaders["Authorization"], "Bearer t-a")
        XCTAssertEqual(attempts(refusedId).last?.options?.customHeaders["Authorization"], "Bearer t-b")
    }

    func testAnIdentityOrNetworkChangeWithNothingRunnableArmsNoTimer() async throws {
        let switches = Switches()
        let transport = RecordingTransport(status: 201, json: "{}")
        let manager = manager(switches, transport)
        let starts = await manager.queueTimerStartCount

        switches.identity.value = UploadIdentity(token: "t-b", userId: "u-b")
        await manager.identityChanged()
        await manager.networkingChanged()
        let startsAfter = await manager.queueTimerStartCount
        XCTAssertEqual(startsAfter, starts)
        let armed = await manager.hasPendingQueueTimer
        XCTAssertFalse(armed)
        XCTAssertEqual(transport.calls.count, 0)
    }
}
