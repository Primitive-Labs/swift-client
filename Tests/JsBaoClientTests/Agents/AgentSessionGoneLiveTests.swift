import XCTest
@testable import JsBaoClient

/// Once a Swift client observes a session is gone, its queued uploads and
/// the messages waiting on them fail with `AGENT_SESSION_NOT_FOUND`, against
/// the dev server (#4588, plan behaviors 16, 17 and 18, their live halves;
/// intent criterion 9). No model turn: every message here waits on an upload
/// that never lands.
final class AgentSessionGoneLiveTests: XCTestCase {
    private static let harnessTask = LockedBox<Task<AgentSessionScenarioHarness, Error>?>(nil)
    private var h: AgentSessionScenarioHarness!
    private static let png = AgentSessionScenarioHarness.png

    override func setUp() async throws {
        let task = Self.harnessTask.withValue { slot -> Task<AgentSessionScenarioHarness, Error> in
            if let slot { return slot }
            let created = Task { try await AgentSessionScenarioHarness.make("agent-session-gone-swift-4588") }
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

    private func assertGone(_ error: Error?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual((error as? HttpError)?.serverCode, "AGENT_SESSION_NOT_FOUND", "\(String(describing: error))",
                       file: file, line: line)
    }

    /// An upload queued while offline, then paused, so it stays queued once
    /// the client is online again.
    private func pausedUpload(_ client: JsBaoClient, _ attachments: AgentSessionAttachments) async throws -> String {
        client.setNetworkMode(.offline)
        let blobId = try await attachments.upload(
            Self.png, options: AgentSessionAttachmentUploadOptions(filename: "dot.png", contentType: "image/png")
        ).blobId
        _ = await attachments.pause(blobId: blobId)
        client.setNetworkMode(.online)
        try await waitForConnection(client: client, timeout: 30)
        return blobId
    }

    // MARK: - Behavior 16: this client's delete

    func testDeletingASessionFailsItsQueuedUploadAndTheMessageWaitingOnIt() async throws {
        let s = try await h.createSession(h.plain, participants: [h.part])
        let ownerC = try await h.client(h.owner)
        let view = try await h.open(ownerC, s)
        let blobId = try await pausedUpload(ownerC, view.attachments)
        let send = Task {
            try await view.send(text: "Never sent.", files: [AgentSessionFileRef(blobId: blobId)], clientMessageId: "c-gone")
        }
        try await h.poll(timeout: 10, "the message waits") {
            view.pendingMessages.first { $0.clientMessageId == "c-gone" }?.state == .waiting
        }
        let attachments = view.attachments
        await view.close()

        _ = try await ownerC.agents.sessions.delete(sessionId: s.sessionId)
        assertGone(await thrown { _ = try await within(20, "the send") { try await send.value } })
        let failed = await attachments.uploads().first { $0.blobId == blobId }
        XCTAssertEqual(failed?.state, .failed)
        XCTAssertEqual(failed?.error?.code, "AGENT_SESSION_NOT_FOUND")
        let local = try? await attachments.waitUntilUploaded(blobId: blobId)
        XCTAssertNil(local)

        // A retry is refused by the server with the same code.
        _ = await attachments.resume(blobId: blobId)
        assertGone(await thrown { _ = try await within(30, "the retry") { try await attachments.waitUntilUploaded(blobId: blobId) } })
    }

    // MARK: - Behavior 17: observed through the participant's own call

    func testAParticipantSeesNothingFailUntilTheirOwnCallAnswersNotFound() async throws {
        let s = try await h.createSession(h.plain, participants: [h.part])
        let ownerC = try await h.client(h.owner)
        let partC = try await h.client(h.part)
        let view = try await h.open(partC, s)
        let blobId = try await pausedUpload(partC, view.attachments)
        let attachments = view.attachments
        await view.close()

        _ = try await ownerC.agents.sessions.delete(sessionId: s.sessionId)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let before = await attachments.uploads().first { $0.blobId == blobId }
        XCTAssertEqual(before?.state, .paused, "nothing fails before this client observes it")

        assertGone(await thrown { _ = try await partC.agents.sessions.get(sessionId: s.sessionId) })
        let after = await attachments.uploads().first { $0.blobId == blobId }
        XCTAssertEqual(after?.state, .failed)
        XCTAssertEqual(after?.error?.code, "AGENT_SESSION_NOT_FOUND")
    }

    // MARK: - Behavior 18: observed by the upload's own PUT

    func testAMemberRemovedWhileAnUploadIsQueuedSeesItsOwnPutFailEveryQueuedUpload() async throws {
        let s = try await h.createSession(h.plain, participants: [h.part])
        let ownerC = try await h.client(h.owner)
        let partC = try await h.client(h.part)
        let view = try await h.open(partC, s)
        let first = try await pausedUpload(partC, view.attachments)
        let second = try await pausedUpload(partC, view.attachments)
        let attachments = view.attachments
        await view.close()

        _ = try await ownerC.agents.sessions.removeMember(sessionId: s.sessionId, userId: h.part.userId)
        _ = await attachments.resume(blobId: first)
        assertGone(await thrown { _ = try await within(30, "the PUT") { try await attachments.waitUntilUploaded(blobId: first) } })
        let both = await attachments.uploads()
        XCTAssertEqual(Set(both.map(\.blobId)), [first, second])
        XCTAssertTrue(both.allSatisfy { $0.state == .failed && $0.error?.code == "AGENT_SESSION_NOT_FOUND" }, "\(both)")
    }
}
