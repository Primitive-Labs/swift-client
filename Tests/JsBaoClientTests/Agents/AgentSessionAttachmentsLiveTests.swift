import XCTest
@testable import JsBaoClient

/// A session driven from Swift with `sessionId` alone, files included,
/// against the dev server (#4588, plan behaviors 25, 1, 3, 4, 5, 7, 9, 12, 14
/// and 21, their live halves; intent criteria 1, 3, 4 and 5).
///
/// Every call goes through `client.agents.sessions` and the view; the test
/// reads a document only to check what the server stored. Two model turns in
/// all: one paused on client tools and answered, one plain reply.
final class AgentSessionAttachmentsLiveTests: XCTestCase {
    private static let harnessTask = LockedBox<Task<AgentSessionScenarioHarness, Error>?>(nil)
    private var h: AgentSessionScenarioHarness!
    private static let png = AgentSessionScenarioHarness.png

    override func setUp() async throws {
        let task = Self.harnessTask.withValue { slot -> Task<AgentSessionScenarioHarness, Error> in
            if let slot { return slot }
            let created = Task { try await AgentSessionScenarioHarness.make("agent-session-attachments-swift-4588") }
            slot = created
            return created
        }
        h = try await task.value
    }

    override class func tearDown() {
        guard let task = harnessTask.value else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            if let harness = try? await task.value { await harness.cleanup() }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 120)
        super.tearDown()
    }

    private func expectServerCode(
        _ code: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, code, error.body ?? "", file: file, line: line)
        } catch {
            XCTFail("expected HttpError \(code), got \(error)", file: file, line: line)
        }
    }

    private func png(_ name: String = "dot.png") -> AgentSessionAttachmentUploadOptions {
        AgentSessionAttachmentUploadOptions(filename: name, contentType: "image/png")
    }

    // MARK: - Behavior 25: the whole flow from the session surface

    func testASessionRunsFromTheSessionSurfaceWithAFileAndNoDocumentId() async throws {
        let s = try await h.createSession(h.tools, participants: [h.part], viewers: [h.viewer], title: "Files")
        let ownerC = try await h.client(h.owner)
        let partC = try await h.client(h.part)
        let viewerC = try await h.client(h.viewer)
        let strangerC = try await h.client(h.stranger)
        let view = try await h.open(partC, s)
        let changes = LockedBox(0)
        view.onChange { changes.add(1) }

        // Upload and wait, then read it back three ways.
        let options = png()
        let attachment = try await within(60, "the upload") {
            try await view.attachments.upload(Self.png, options: options)
        }
        let waited = try await within(60, "the wait") { try await view.attachments.waitUntilUploaded(blobId: attachment.blobId) }
        XCTAssertEqual(waited, attachment)
        XCTAssertEqual(attachment.contentType, "image/png")
        XCTAssertEqual(attachment.numBytes, Self.png.count)
        let uploadsLeft = await view.attachments.uploads()
        XCTAssertEqual(uploadsLeft, [])
        let downloaded = try await partC.agents.sessions.downloadAttachment(sessionId: s.sessionId, blobId: attachment.blobId)
        XCTAssertEqual(downloaded, Self.png)
        let viewerView = try await h.open(viewerC, s)
        let viewerRead = try await viewerView.attachments.read(blobId: attachment.blobId)
        XCTAssertEqual(viewerRead, Self.png, "another member reads the file through the session")
        let heads = try await viewerC.agents.sessions.attachmentHeaders(sessionId: s.sessionId, blobId: attachment.blobId)
        XCTAssertEqual(heads.status, 200)
        XCTAssertEqual(heads.headers["content-type"], "image/png")
        await expectServerCode("AGENT_SESSION_ATTACHMENT_NOT_FOUND") {
            _ = try await viewerView.attachments.read(blobId: "01J0000000000000000000NONE")
        }
        await viewerView.close()

        // inspect.storage answers get's document; it grants nothing.
        let storage = try await partC.agents.sessions.inspect.storage(s.sessionId)
        XCTAssertEqual(storage.documentId, s.documentId)
        await expectServerCode("AGENT_SESSION_NOT_FOUND") {
            _ = try await strangerC.agents.sessions.inspect.storage(s.sessionId)
        }
        // The file is a blob of the session's document.
        let listed = try await h.ctx.appRequest(
            method: "GET", appId: h.appId, path: "/documents/\(s.documentId)/blobs", body: nil, jwt: h.owner.jwt
        )
        let items = (listed["items"] as? [[String: Any]]) ?? []
        XCTAssertTrue(items.contains { $0["blobId"] as? String == attachment.blobId }, "\(listed)")

        // Send it: one turn that pauses on the two client tools.
        var turnId: String?
        var callIds: [String] = []
        for attempt in 0..<2 {
            let sent = try await view.send(
                text: "Go.", files: attempt == 0 ? [AgentSessionFileRef(blobId: attachment.blobId)] : []
            )
            try await h.poll(timeout: 120, interval: 0.5, "the turn pauses or ends") {
                let info = try await partC.agents.sessions.get(sessionId: s.sessionId)
                if info.turn?.phase == .paused { callIds = info.turn?.pause?.callIds ?? [] }
                return info.turn == nil || info.turn?.phase == .paused
            }
            if callIds.count == 2 {
                turnId = sent.turnId
                break
            }
            try await h.settled(s)
        }
        let paused = try XCTUnwrap(turnId, "the model paused on both tools")
        try await h.poll(timeout: 30, "the message carries the file") {
            view.syncedMessages.contains { message in
                message.parts.contains { $0.kind == .file && $0.blobId == attachment.blobId }
            }
        }
        try await h.poll(timeout: 30, "the calls are in the window") { callIds.allSatisfy { view.toolCall($0) != nil } }
        for callId in callIds {
            let call = try XCTUnwrap(view.toolCall(callId))
            if call.toolName == "sign" {
                _ = try await view.answer(callId: callId, .approval(approved: true))
                _ = try await view.answer(callId: callId, try .output(encoding: ["signed": true]))
            } else {
                _ = try await view.answer(callId: callId, .output(["count": 2]))
            }
        }
        try await h.settled(s)
        XCTAssertGreaterThan(changes.value, 0)
        XCTAssertNil(view.activeTurnId)
        XCTAssertFalse(paused.isEmpty)

        // Events, read markers, paging.
        let recorded = try await view.recordEvent(AgentSessionEvent(kind: "viewed", data: ["item": "lease"]))
        XCTAssertFalse(recorded.messageId.isEmpty)
        _ = try await view.markRead()
        XCTAssertFalse(view.info.hasUnread)
        // Its own client: two views on one client share one document, and
        // closing either closes it for both.
        let pager = try await h.open(try await h.client(h.part), s, pageSize: 2)
        XCTAssertTrue(pager.hasOlder, "the turn left more than one page")
        let older = try await pager.loadOlder()
        XCTAssertGreaterThan(older.loaded, 0)
        await pager.close()

        // Cancel a running turn, held in its first round.
        try await h.slowRound(s, ms: 20_000)
        let running = try await view.send(text: "Hello.")
        let runningTurn = try XCTUnwrap(running.turnId)
        try await h.poll(timeout: 20, "the row names the running turn") { view.activeTurnId == runningTurn }
        let cancelled = try await view.cancel()
        XCTAssertEqual(cancelled.turnId, runningTurn)
        XCTAssertTrue(cancelled.cancelled)
        try await h.settled(s)

        // Rename and members, as the owner.
        let renamed = try await ownerC.agents.sessions.rename(sessionId: s.sessionId, title: "Files, renamed")
        XCTAssertEqual(renamed.title, "Files, renamed")
        let added = try await ownerC.agents.sessions.addMember(sessionId: s.sessionId, userId: h.part2.userId, role: .viewer)
        XCTAssertTrue(added.members.viewers.contains(h.part2.userId))
        let removed = try await ownerC.agents.sessions.removeMember(sessionId: s.sessionId, userId: h.part2.userId)
        XCTAssertFalse(removed.members.viewers.contains(h.part2.userId))

        await view.close()
        let deleted = try await ownerC.agents.sessions.delete(sessionId: s.sessionId)
        XCTAssertTrue(deleted.deleted)
    }

    // MARK: - Behaviors 3 and 4: a refusal kept, a promotion, a cancel

    func testAViewersRefusedUploadIsKeptUntilAPromotionAndResumeLandIt() async throws {
        let s = try await h.createSession(h.plain, participants: [h.part], viewers: [h.viewer])
        let ownerC = try await h.client(h.owner)
        let viewerC = try await h.client(h.viewer)
        let view = try await h.open(viewerC, s)

        await expectServerCode("AGENT_SESSION_PARTICIPANT_ONLY") {
            _ = try await view.attachments.upload(Self.png, options: self.png())
        }
        let listedFailed = await view.attachments.uploads().first
        let failed = try XCTUnwrap(listedFailed)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.error?.code, "AGENT_SESSION_PARTICIPANT_ONLY")
        let local = try await view.attachments.read(blobId: failed.blobId)
        XCTAssertEqual(local, Self.png, "the refused upload keeps its bytes")
        let paused = await view.attachments.pause(blobId: failed.blobId)
        XCTAssertFalse(paused)

        _ = try await ownerC.agents.sessions.addMember(sessionId: s.sessionId, userId: h.viewer.userId, role: .participant)
        let resumed = await view.attachments.resume(blobId: failed.blobId)
        XCTAssertTrue(resumed)
        let landed = try await within(60, "the resumed upload") {
            try await view.attachments.waitUntilUploaded(blobId: failed.blobId)
        }
        XCTAssertEqual(landed.blobId, failed.blobId)
        let served = try await ownerC.agents.sessions.downloadAttachment(sessionId: s.sessionId, blobId: failed.blobId)
        XCTAssertEqual(served, Self.png)
        let cancelledLanded = await view.attachments.cancel(blobId: failed.blobId)
        XCTAssertFalse(cancelledLanded, "a completed upload is not cancelled")

        // A queued upload cancelled never reaches the server.
        viewerC.setNetworkMode(.offline)
        let queued = try await view.attachments.upload(Self.png, options: png("never.png"))
        let cancelled = await view.attachments.cancel(blobId: queued.blobId)
        XCTAssertTrue(cancelled)
        viewerC.setNetworkMode(.online)
        try await waitForConnection(client: viewerC, timeout: 30)
        await expectServerCode("AGENT_SESSION_ATTACHMENT_NOT_FOUND") {
            _ = try await ownerC.agents.sessions.downloadAttachment(sessionId: s.sessionId, blobId: queued.blobId)
        }
        let stillServed = try await ownerC.agents.sessions.downloadAttachment(sessionId: s.sessionId, blobId: failed.blobId)
        XCTAssertEqual(stillServed, Self.png, "cancel deletes nothing on the server")
        await view.close()
    }

    // MARK: - Behaviors 5, 9, 12 and 14: queued offline, sent after close, once

    func testAnUploadQueuedOfflineAndTheMessageWaitingOnItLandOnceAfterTheViewCloses() async throws {
        let s = try await h.createSession(h.plain, participants: [h.part])
        let partC = try await h.client(h.part)
        let view = try await h.open(partC, s)
        let clientMessageId = "c-\(h.stamp)-close"

        partC.setNetworkMode(.offline)
        let attachment = try await view.attachments.upload(Self.png, options: png())
        let queued = await view.attachments.uploads()
        XCTAssertEqual(queued.map(\.state), [.pending])
        let send = Task {
            try await view.send(text: "With a file.", files: [AgentSessionFileRef(blobId: attachment.blobId)],
                                clientMessageId: clientMessageId)
        }
        try await h.poll(timeout: 10, "the message waits") {
            view.pendingMessages.first { $0.clientMessageId == clientMessageId }?.state == .waiting
        }
        await view.close()

        partC.setNetworkMode(.online)
        let sent = try await within(90, "the waiting send") { try await send.value }
        XCTAssertNil(sent.duplicate)
        let left = await view.attachments.uploads()
        XCTAssertEqual(left, [], "the upload completed through the session after the close")
        try await h.settled(s)

        // A repeat under the id is a duplicate, and the session holds one message.
        let repeated = try await partC.agents.sessions.send(sessionId: s.sessionId, body: AgentSessionSendBody(
            text: "With a file.", files: [AgentSessionFileRef(blobId: attachment.blobId)], clientMessageId: clientMessageId
        ))
        XCTAssertEqual(repeated.duplicate, true)
        XCTAssertEqual(repeated.messageId, sent.messageId)
        let fresh = try await h.client(h.part)
        let reader = try await h.open(fresh, s)
        try await h.poll(timeout: 30, "the message syncs") {
            reader.syncedMessages.contains { $0.clientMessageId == clientMessageId }
        }
        let mine = reader.syncedMessages.filter { $0.clientMessageId == clientMessageId }
        XCTAssertEqual(mine.count, 1)
        XCTAssertTrue(mine[0].parts.contains { $0.kind == .file && $0.blobId == attachment.blobId })
        await reader.close()
    }

    // MARK: - Behavior 21: a document deleted directly

    func testInspectStorageAnswersDocumentMissingOnceTheDocumentIsDeletedDirectly() async throws {
        let s = try await h.createSession(h.plain, participants: [h.part])
        let partC = try await h.client(h.part)
        _ = try await h.ctx.appRequest(
            method: "DELETE", appId: h.appId, path: "/documents/\(s.documentId)", body: nil, jwt: h.owner.jwt
        )
        do {
            _ = try await partC.agents.sessions.inspect.storage(s.sessionId)
            XCTFail("a missing document is refused")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 410)
            XCTAssertEqual(error.serverCode, "AGENT_SESSION_DOCUMENT_MISSING")
        }
        do {
            _ = try await h.ctx.appRequest(
                method: "GET", appId: h.appId, path: "/documents/\(s.documentId)", body: nil, jwt: h.owner.jwt
            )
            XCTFail("the document stays absent")
        } catch {}
    }
}
