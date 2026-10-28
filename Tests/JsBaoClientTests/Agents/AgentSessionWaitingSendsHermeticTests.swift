import XCTest
@testable import JsBaoClient

/// A send naming a session upload still in the queue waits for it (#4588,
/// plan behaviors 9 to 14, the waiting send of behavior 16, edges 32 to 34):
/// `.waiting` until the upload lands, then one POST with the same body; the
/// upload's failure fails the message and nothing is sent; a newer send under
/// the id displaces it; the view's close does not end it.
///
/// A real `JsBaoClient` over `LoopbackAPIServer` with a local-only session
/// document; the server answers each POST of a message with a fresh id.
final class AgentSessionWaitingSendsHermeticTests: XCTestCase {
    private static let bytes = Data("waiting bytes".utf8)
    private static let created = "2026-10-20T00:00:00.000Z"

    private final class Script: @unchecked Sendable {
        let put = LockedBox<@Sendable (SessionUploadServer.Request) -> SessionUploadServer.Response>({ _ in
            .status(503, "busy")
        })
        let sent = LockedBox(0)

        func route(_ request: SessionUploadServer.Request) -> SessionUploadServer.Response {
            if SessionUploadServer.isAttachmentPut(request) { return put.value(request) }
            if request.method == "POST", request.apiPathOnly == "/agent-sessions/s1/messages" {
                return .json(Self.sendResult(sent.withValue { $0 += 1; return $0 }))
            }
            if request.method == "DELETE", request.apiPathOnly == "/agent-sessions/s1" {
                return .json(#"{"deleted":true,"sessionId":"s1","documentId":"d1"}"#)
            }
            return SessionUploadServer.acceptAll(request)
        }

        static func sendResult(_ n: Int) -> String {
            #"{"messageId":"m-\#(n)","seq":\#(n),"turnId":"t-\#(n)","queued":false}"#
        }
    }

    private struct Fixture {
        let server: SessionUploadServer
        let client: JsBaoClient
        let script: Script
        let view: AgentSessionView
        let documentId: String

        var posts: [SessionUploadServer.Request] {
            server.requests.filter { $0.method == "POST" && $0.apiPathOnly == "/agent-sessions/s1/messages" }
        }

        func pending(_ clientMessageId: String) -> AgentSessionPendingMessage? {
            view.pendingMessages.first { $0.clientMessageId == clientMessageId }
        }

        func finish() async {
            await view.close()
            await client.destroy()
            server.stop()
        }
    }

    private func fixture() async throws -> Fixture {
        let script = Script()
        let server = try SessionUploadServer()
        let client = makeSessionUploadClient(server)
        let (view, documentId) = try await openLocalSessionView(client, server) { request in script.route(request) }
        return Fixture(server: server, client: client, script: script, view: view, documentId: documentId)
    }

    /// An upload answered 503, then paused when asked: queued until resumed.
    private func queued(_ f: Fixture, paused: Bool = true) async throws -> String {
        let blobId = try await within(10, "an upload") { try await f.view.attachments.upload(Self.bytes) }.blobId
        if paused { _ = await f.view.attachments.pause(blobId: blobId) }
        return blobId
    }

    private func files(_ blobIds: String...) -> [AgentSessionFileRef] {
        blobIds.map(AgentSessionFileRef.init(blobId:))
    }

    // MARK: - Behavior 9 and edge 32: waiting, then one POST

    func testASendNamingAQueuedUploadWaitsThenPostsOnceWithTheSameBody() async throws {
        let f = try await fixture()
        let blobId = try await queued(f)
        let changes = LockedBox(0)
        f.view.onChange { changes.add(1) }
        let view = f.view
        let send = Task {
            try await view.send(
                text: "look", files: [AgentSessionFileRef(blobId: blobId)], clientMessageId: "c1",
                context: .object(["plan": .string("pro")]), timezone: "Europe/Paris", locale: "fr-FR"
            )
        }
        try await eventually(timeout: 5, description: "the entry waits") { f.pending("c1")?.state == .waiting }
        let waiting = try XCTUnwrap(f.pending("c1"))
        XCTAssertEqual(waiting.text, "look")
        XCTAssertEqual(waiting.files, [AgentSessionFileRef(blobId: blobId)])
        XCTAssertEqual(waiting.context, .object(["plan": .string("pro")]))
        XCTAssertEqual(waiting.timezone, "Europe/Paris")
        XCTAssertEqual(waiting.locale, "fr-FR")
        XCTAssertNil(waiting.messageId)
        XCTAssertGreaterThan(changes.value, 0, "onChange fired")

        // Edge 32: a paused upload keeps the send waiting, with no timeout.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(f.pending("c1")?.state, .waiting)
        XCTAssertEqual(f.posts.count, 0, "nothing is posted while the upload is queued")

        f.script.put.value = { request in SessionUploadServer.created(request) }
        f.server.hold { $0.method == "POST" && $0.apiPathOnly == "/agent-sessions/s1/messages" }
        _ = await f.view.attachments.resume(blobId: blobId)
        try await eventually(timeout: 5, description: "the POST goes out") { f.server.heldRequests.count == 1 }
        XCTAssertEqual(f.pending("c1")?.state, .sending, "sending before the POST answers")
        XCTAssertNil(f.pending("c1")?.messageId)
        let order = f.server.requests.map { $0.method + " " + $0.apiPathOnly }
        let putAt = try XCTUnwrap(order.lastIndex(of: "PUT /agent-sessions/s1/attachments/\(blobId)"))
        let postAt = try XCTUnwrap(order.firstIndex(of: "POST /agent-sessions/s1/messages"))
        XCTAssertLessThan(putAt, postAt, "the upload lands before the message is posted")
        f.server.hold(nil)
        f.server.release(.json(Script.sendResult(1)))

        let result = try await within(5, "the send") { try await send.value }
        XCTAssertEqual(result.messageId, "m-1")
        XCTAssertEqual(f.pending("c1")?.messageId, "m-1")
        XCTAssertEqual(f.posts.count, 1)
        let body = try XCTUnwrap(f.posts.first?.jsonBody)
        XCTAssertEqual(body["text"] as? String, "look")
        XCTAssertEqual((body["files"] as? [[String: Any]])?.map { $0["blobId"] as? String }, [blobId])
        XCTAssertEqual(body["clientMessageId"] as? String, "c1")
        XCTAssertEqual((body["context"] as? [String: Any])?["plan"] as? String, "pro")
        XCTAssertEqual(body["timezone"] as? String, "Europe/Paris")
        XCTAssertEqual(body["locale"] as? String, "fr-FR")
        await f.finish()
    }

    func testASendWaitsForAnUploadPendingUploadingOrPausedAndForEveryOneItNames() async throws {
        let f = try await fixture()
        let paused = try await queued(f)
        let pending = try await queued(f, paused: false)
        let second = try await queued(f)
        f.server.hold(SessionUploadServer.isAttachmentPut)
        _ = await f.view.attachments.resume(blobId: second)
        try await eventually(timeout: 5, description: "an upload in flight") { f.server.heldRequests.count == 1 }
        let states = await f.view.attachments.uploads().reduce(into: [String: AgentSessionUploadStatus.State]()) {
            $0[$1.blobId] = $1.state
        }
        XCTAssertEqual(states, [paused: .paused, pending: .pending, second: .uploading])
        let view = f.view
        let sends = [("c-paused", paused), ("c-pending", pending), ("c-uploading", second)].map { id, blobId in
            Task { try await view.send(text: id, files: [AgentSessionFileRef(blobId: blobId)], clientMessageId: id) }
        }
        try await eventually(timeout: 5, description: "every entry waits") {
            ["c-paused", "c-pending", "c-uploading"].allSatisfy { f.pending($0)?.state == .waiting }
        }
        for send in sends { send.cancel() }
        for id in ["c-paused", "c-pending", "c-uploading"] {
            _ = await f.view.attachments.cancel(blobId: f.pending(id)!.files[0].blobId)
        }
        for send in sends { _ = await thrown { _ = try await within(5, "a send") { try await send.value } } }
        f.server.hold(nil)
        while !f.server.heldRequests.isEmpty { f.server.release(.status(503, "late")) }

        // Two named uploads: nothing is posted until both land.
        f.script.put.value = { _ in .status(503, "busy") }
        let one = try await queued(f)
        let two = try await queued(f)
        let bothFiles = files(one, two)
        let both = Task { try await view.send(text: "both", files: bothFiles, clientMessageId: "c-both") }
        try await eventually(timeout: 5, description: "waiting on both") { f.pending("c-both")?.state == .waiting }
        f.script.put.value = { request in SessionUploadServer.created(request) }
        _ = await f.view.attachments.resume(blobId: one)
        _ = try await within(5, "the first upload") { try await view.attachments.waitUntilUploaded(blobId: one) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.pending("c-both")?.state, .waiting, "one of two landed: still waiting")
        XCTAssertEqual(f.posts.count, 0)
        _ = await f.view.attachments.resume(blobId: two)
        let result = try await within(5, "the send") { try await both.value }
        XCTAssertEqual(result.messageId, "m-1")
        XCTAssertEqual(f.posts.count, 1)
        await f.finish()
    }

    // MARK: - Behavior 10: no queued reference, no wait

    func testASendNamingNoQueuedUploadPostsAtOnceAheadOfAWaitingOne() async throws {
        let f = try await fixture()
        let queuedId = try await queued(f)
        let view = f.view
        let waiting = Task {
            try await view.send(text: "later", files: [AgentSessionFileRef(blobId: queuedId)], clientMessageId: "c-wait")
        }
        try await eventually(timeout: 5, description: "the first send waits") { f.pending("c-wait")?.state == .waiting }

        let plain = try await within(5, "a send with no files") { try await view.send(text: "now", clientMessageId: "c-now") }
        XCTAssertEqual(plain.messageId, "m-1")
        f.script.put.value = { request in SessionUploadServer.created(request) }
        let landed = try await within(10, "an upload") { try await view.attachments.upload(Self.bytes) }
        let uploaded = try await within(5, "a send naming an uploaded file") {
            try await view.send(text: "done", files: [AgentSessionFileRef(blobId: landed.blobId)], clientMessageId: "c-up")
        }
        XCTAssertEqual(uploaded.messageId, "m-2")
        let unknown = try await within(5, "a send naming a file no upload lists") {
            try await view.send(text: "other", files: [AgentSessionFileRef(blobId: "b-elsewhere")], clientMessageId: "c-x")
        }
        XCTAssertEqual(unknown.messageId, "m-3")
        XCTAssertEqual(f.pending("c-wait")?.state, .waiting, "the waiting send still waits")
        XCTAssertEqual(f.posts.compactMap { $0.jsonBody?["clientMessageId"] as? String }, ["c-now", "c-up", "c-x"])
        waiting.cancel()
        _ = await f.view.attachments.cancel(blobId: queuedId)
        _ = await thrown { _ = try await within(5, "the waiting send") { try await waiting.value } }
        await f.finish()
    }

    // MARK: - Behavior 11: the upload's failure is the message's

    func testANamedUploadsFailureFailsTheSendWithItsErrorAndPostsNothing() async throws {
        let f = try await fixture()
        let view = f.view

        // A refusal.
        let refused = try await queued(f)
        let refusedSend = Task {
            try await view.send(text: "r", files: [AgentSessionFileRef(blobId: refused)], clientMessageId: "c-refused")
        }
        try await eventually(timeout: 5, description: "waiting") { f.pending("c-refused")?.state == .waiting }
        f.script.put.value = { _ in
            SessionUploadServer.refused(403, "AGENT_SESSION_PARTICIPANT_ONLY", "Only participants may upload")
        }
        _ = await view.attachments.resume(blobId: refused)
        let refusal = await thrown { _ = try await within(5, "the send") { try await refusedSend.value } }
        XCTAssertEqual((refusal as? HttpError)?.serverCode, "AGENT_SESSION_PARTICIPANT_ONLY", "the call throws the upload's error")
        XCTAssertEqual(f.pending("c-refused")?.state, .failed)
        XCTAssertEqual(f.pending("c-refused")?.error?.code, "AGENT_SESSION_PARTICIPANT_ONLY")
        XCTAssertEqual(f.pending("c-refused")?.error?.message, "Only participants may upload")

        // An upload already failed when the send is made fails it at once.
        let atOnce = await thrown {
            _ = try await within(5, "a send naming a failed upload") {
                try await view.send(text: "again", files: [AgentSessionFileRef(blobId: refused)], clientMessageId: "c-failed")
            }
        }
        XCTAssertEqual((atOnce as? HttpError)?.serverCode, "AGENT_SESSION_PARTICIPANT_ONLY")
        XCTAssertEqual(f.pending("c-failed")?.state, .failed)

        // A cancel.
        f.script.put.value = { _ in .status(503, "busy") }
        let cancelled = try await queued(f)
        let cancelledSend = Task {
            try await view.send(text: "c", files: [AgentSessionFileRef(blobId: cancelled)], clientMessageId: "c-cancelled")
        }
        try await eventually(timeout: 5, description: "waiting") { f.pending("c-cancelled")?.state == .waiting }
        _ = await view.attachments.cancel(blobId: cancelled)
        let cancelError = await thrown { _ = try await within(5, "the send") { try await cancelledSend.value } }
        XCTAssertEqual((cancelError as? JsBaoError)?.code, .agentSessionUploadCancelled)
        XCTAssertEqual(f.pending("c-cancelled")?.error?.code, "AGENT_SESSION_UPLOAD_CANCELLED")

        // An error with no code.
        let codeless = try await queued(f)
        let codelessSend = Task {
            try await view.send(text: "n", files: [AgentSessionFileRef(blobId: codeless)], clientMessageId: "c-codeless")
        }
        try await eventually(timeout: 5, description: "waiting") { f.pending("c-codeless")?.state == .waiting }
        f.script.put.value = { _ in SessionUploadServer.Response(status: 400, body: "not json") }
        _ = await view.attachments.resume(blobId: codeless)
        _ = await thrown { _ = try await within(5, "the send") { try await codelessSend.value } }
        XCTAssertEqual(f.pending("c-codeless")?.error?.code, "AGENT_SESSION_SEND_FAILED")

        // Two uploads: the first failure fails the send; the other stays queued.
        f.script.put.value = { _ in .status(503, "busy") }
        let first = try await queued(f)
        let other = try await queued(f)
        let twoFiles = files(first, other)
        let twoSend = Task { try await view.send(text: "2", files: twoFiles, clientMessageId: "c-two") }
        try await eventually(timeout: 5, description: "waiting") { f.pending("c-two")?.state == .waiting }
        _ = await view.attachments.cancel(blobId: first)
        _ = await thrown { _ = try await within(5, "the send") { try await twoSend.value } }
        XCTAssertEqual(f.pending("c-two")?.state, .failed)
        let otherState = await view.attachments.uploads().first { $0.blobId == other }
        XCTAssertEqual(otherState?.state, .paused, "the other upload keeps its place in the queue")

        XCTAssertEqual(f.posts.count, 0, "no failed send posted anything")
        await f.finish()
    }

    // MARK: - Behavior 12: retry

    func testRetryDeliversAgainUnderTheSameIdAndWaitsForTheResumedUpload() async throws {
        let f = try await fixture()
        let view = f.view
        let blobId = try await queued(f)
        let first = Task {
            try await view.send(
                text: "again", files: [AgentSessionFileRef(blobId: blobId)], clientMessageId: "c-retry",
                context: .object(["k": .number(1)]), timezone: "UTC", locale: "en"
            )
        }
        try await eventually(timeout: 5, description: "waiting") { f.pending("c-retry")?.state == .waiting }
        let waitingRetry = await thrown { _ = try await view.retry(clientMessageId: "c-retry") }
        XCTAssertEqual((waitingRetry as? JsBaoError)?.code, .invalidArgument, "a waiting message is not retried")
        f.script.put.value = { _ in SessionUploadServer.refused(403, "AGENT_SESSION_PARTICIPANT_ONLY") }
        _ = await view.attachments.resume(blobId: blobId)
        _ = await thrown { _ = try await within(5, "the first send") { try await first.value } }
        XCTAssertEqual(f.pending("c-retry")?.state, .failed)

        f.script.put.value = { request in SessionUploadServer.created(request) }
        f.server.hold(SessionUploadServer.isAttachmentPut)
        _ = await view.attachments.resume(blobId: blobId)
        try await eventually(timeout: 5, description: "the resumed upload is in flight") { f.server.heldRequests.count == 1 }
        let retried = Task { try await view.retry(clientMessageId: "c-retry") }
        try await eventually(timeout: 5, description: "the retry waits") { f.pending("c-retry")?.state == .waiting }
        XCTAssertNil(f.pending("c-retry")?.error)
        XCTAssertEqual(f.posts.count, 0)
        f.server.hold(nil)
        f.server.release(SessionUploadServer.created(f.server.heldRequests[0]))
        let result = try await within(5, "the retry") { try await retried.value }
        XCTAssertEqual(f.posts.count, 1)
        let body = try XCTUnwrap(f.posts.first?.jsonBody)
        XCTAssertEqual(body["clientMessageId"] as? String, "c-retry")
        XCTAssertEqual(body["text"] as? String, "again")
        XCTAssertEqual((body["files"] as? [[String: Any]])?.first?["blobId"] as? String, blobId)
        XCTAssertEqual((body["context"] as? [String: Any])?["k"] as? Int, 1)
        XCTAssertEqual(body["timezone"] as? String, "UTC")
        XCTAssertEqual(body["locale"] as? String, "en")

        // The entry leaves once its row is in the window.
        try f.client.codegen.save(PrimitiveMessage.primitiveSchema, id: result.messageId, values: [
            "seq": .number(1), "authorKind": .string("user"), "clientMessageId": .string("c-retry"),
            "createdAt": .date(Self.created),
        ], in: f.documentId)
        try await eventually(timeout: 5, description: "the entry leaves") { f.pending("c-retry") == nil }
        let unknown = await thrown { _ = try await view.retry(clientMessageId: "c-nobody") }
        XCTAssertEqual((unknown as? JsBaoError)?.code, .invalidArgument)
        await f.finish()
    }

    // MARK: - Behavior 13: a newer send under the id

    func testANewerSendUnderTheSameIdDisplacesAWaitingOneAtOnce() async throws {
        let f = try await fixture()
        let view = f.view
        let blobId = try await queued(f)
        let older = Task {
            try await view.send(text: "old", files: [AgentSessionFileRef(blobId: blobId)], clientMessageId: "c-same")
        }
        try await eventually(timeout: 5, description: "waiting") { f.pending("c-same")?.state == .waiting }
        XCTAssertFalse(view.dismiss(clientMessageId: "c-same"), "a waiting entry is not dismissed")

        let newer = try await within(5, "the newer send") { try await view.send(text: "new", clientMessageId: "c-same") }
        let displaced = await thrown { _ = try await within(2, "the displaced send ends at once") { try await older.value } }
        let error = try XCTUnwrap(displaced as? JsBaoError)
        XCTAssertEqual(error.code, .invalidArgument)
        XCTAssertTrue(error.message.contains("c-same"), error.message)
        XCTAssertEqual(error.details?["clientMessageId"], .string("c-same"))
        XCTAssertEqual(f.posts.compactMap { $0.jsonBody?["text"] as? String }, ["new"], "the displaced send posts nothing")
        XCTAssertEqual(view.pendingMessages.filter { $0.clientMessageId == "c-same" }.count, 1)
        XCTAssertEqual(f.pending("c-same")?.messageId, newer.messageId)
        let stillPaused = await view.attachments.uploads().first { $0.blobId == blobId }
        XCTAssertEqual(stillPaused?.state, .paused, "the upload stays as it was")

        // A failed entry that had waited is dismissed.
        let failing = Task {
            try await view.send(text: "f", files: [AgentSessionFileRef(blobId: blobId)], clientMessageId: "c-dismiss")
        }
        try await eventually(timeout: 5, description: "waiting") { f.pending("c-dismiss")?.state == .waiting }
        _ = await view.attachments.cancel(blobId: blobId)
        _ = await thrown { _ = try await within(5, "the send") { try await failing.value } }
        XCTAssertTrue(view.dismiss(clientMessageId: "c-dismiss"))
        XCTAssertNil(f.pending("c-dismiss"))
        await f.finish()
    }

    /// CSO-4588-004: a newer send racing the upload's landing either finds
    /// the earlier one waiting, and it posts nothing, or finds it already
    /// sending, and it posts as a request in flight would. A displaced send
    /// never posts.
    func testANewerSendRacingTheUploadsLandingNeverLetsTheDisplacedOnePost() async throws {
        let f = try await fixture()
        let view = f.view
        for round in 0..<12 {
            f.script.put.value = { _ in .status(503, "busy") }
            let blobId = try await queued(f)
            let id = "c-race-\(round)"
            let older = Task {
                try await view.send(text: "old-\(round)", files: [AgentSessionFileRef(blobId: blobId)], clientMessageId: id)
            }
            try await eventually(timeout: 5, description: "waiting") { f.pending(id)?.state == .waiting }
            f.script.put.value = { request in SessionUploadServer.created(request) }
            _ = await view.attachments.resume(blobId: blobId)
            try await Task.sleep(nanoseconds: UInt64(round % 6) * 2_000_000)
            _ = try await within(5, "the newer send") { try await view.send(text: "new-\(round)", clientMessageId: id) }
            let outcome = await thrown { _ = try await within(5, "the older send") { try await older.value } }
            let olderPosts = f.posts.filter { $0.jsonBody?["text"] as? String == "old-\(round)" }.count
            if let error = outcome {
                XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument, "round \(round): \(error)")
                XCTAssertEqual(olderPosts, 0, "round \(round): the displaced send posted")
            } else {
                XCTAssertEqual(olderPosts, 1, "round \(round)")
            }
        }
        await f.finish()
    }

    // MARK: - Behavior 14: close

    func testAWaitingSendSurvivesTheViewsCloseAndPostsWhenItsUploadLands() async throws {
        let f = try await fixture()
        let view = f.view
        let blobId = try await queued(f)
        let send = Task {
            try await view.send(text: "after close", files: [AgentSessionFileRef(blobId: blobId)], clientMessageId: "c-close")
        }
        try await eventually(timeout: 5, description: "waiting") { f.pending("c-close")?.state == .waiting }
        let attachments = view.attachments
        await view.close()

        f.script.put.value = { request in SessionUploadServer.created(request) }
        _ = await attachments.resume(blobId: blobId)
        let result = try await within(10, "the send") { try await send.value }
        XCTAssertEqual(result.messageId, "m-1")
        XCTAssertEqual(f.posts.count, 1)
        await f.client.destroy()
        f.server.stop()
    }

    // MARK: - Edges 33 and 34

    func testTwoSendsNamingOneUploadBothWaitAndBothPost() async throws {
        let f = try await fixture()
        let view = f.view
        let blobId = try await queued(f)
        let sends = ["c-a", "c-b"].map { id in
            Task { try await view.send(text: id, files: [AgentSessionFileRef(blobId: blobId)], clientMessageId: id) }
        }
        try await eventually(timeout: 5, description: "both wait") {
            f.pending("c-a")?.state == .waiting && f.pending("c-b")?.state == .waiting
        }
        f.script.put.value = { request in SessionUploadServer.created(request) }
        _ = await view.attachments.resume(blobId: blobId)
        for send in sends { _ = try await within(5, "a send") { try await send.value } }
        XCTAssertEqual(Set(f.posts.compactMap { $0.jsonBody?["clientMessageId"] as? String }), ["c-a", "c-b"])
        XCTAssertEqual(f.posts.count, 2)
        await f.finish()
    }

    func testAContextThatIsNotAnObjectThrowsBeforeAnyWait() async throws {
        let f = try await fixture()
        let blobId = try await queued(f)
        let error = await thrown {
            _ = try await f.view.send(
                text: "x", files: [AgentSessionFileRef(blobId: blobId)], clientMessageId: "c-ctx", context: .string("no")
            )
        }
        XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument)
        XCTAssertNil(f.pending("c-ctx"), "no entry, no wait")
        await f.finish()
    }

    // MARK: - Behavior 16: a waiting send and the session's deletion

    func testDeletingTheSessionFailsAWaitingSendWithTheNotFoundError() async throws {
        let f = try await fixture()
        let view = f.view
        let blobId = try await queued(f)
        let send = Task {
            try await view.send(text: "gone", files: [AgentSessionFileRef(blobId: blobId)], clientMessageId: "c-gone")
        }
        try await eventually(timeout: 5, description: "waiting") { f.pending("c-gone")?.state == .waiting }

        _ = try await f.client.agents.sessions.delete(sessionId: "s1")
        let error = await thrown { _ = try await within(5, "the send") { try await send.value } }
        XCTAssertEqual((error as? HttpError)?.serverCode, "AGENT_SESSION_NOT_FOUND")
        XCTAssertEqual(f.pending("c-gone")?.state, .failed)
        XCTAssertEqual(f.pending("c-gone")?.error?.code, "AGENT_SESSION_NOT_FOUND")
        XCTAssertEqual(f.pending("c-gone")?.error?.message, "No such agent session in this app")
        XCTAssertEqual(f.posts.count, 0)
        await f.finish()
    }
}
