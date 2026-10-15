import XCTest
@testable import JsBaoClient

/// A watched session list and an open view's info against the dev server, from
/// Swift (#4380, behavior 20): another member's activity and a rename reach
/// both within seconds, with no `list` or `get` called by the app.
final class AgentSessionLiveListLiveTests: XCTestCase {
    private static let harnessTask = LockedBox<Task<AgentSessionScenarioHarness, Error>?>(nil)
    private var h: AgentSessionScenarioHarness!

    override func setUp() async throws {
        let task = Self.harnessTask.withValue { slot -> Task<AgentSessionScenarioHarness, Error> in
            if let slot { return slot }
            let created = Task { try await AgentSessionScenarioHarness.make("agent-session-live-list-swift-4380") }
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

    func testAWatchedListAndAnOpenViewFollowAnotherMembersActivityAndARename() async throws {
        let s = try await h.createSession(h.tools, participants: [h.part], title: "Watched")
        let partClient = try await h.client(h.part)
        let ownerClient = try await h.client(h.owner)
        // The user channel is registered just after the socket opens.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let list = try await partClient.agents.sessions.watch(options: WatchAgentSessionsOptions(agent: h.tools))
        defer { list.close() }
        let view = try await h.open(partClient, s)
        let changes = LockedBox(0)
        list.onChange { changes.add(1) }

        let listed = try XCTUnwrap(list.items.first { $0.sessionId == s.sessionId })
        XCTAssertEqual(listed.title, "Watched")
        XCTAssertEqual(listed.status, .idle)

        _ = try await ownerClient.agents.sessions.recordEvent(
            sessionId: s.sessionId, event: AgentSessionEvent(kind: "viewed", data: .object(["item": .string("rent")]))
        )
        let ownerRow = try await ownerClient.agents.sessions.list(options: ListAgentSessionsOptions(agent: h.tools))
            .items.first { $0.sessionId == s.sessionId }
        let activityAt = try XCTUnwrap(ownerRow?.lastActivityAt)
        try await h.poll(timeout: 10, "the watched list and the view hear the event") {
            let item = list.items.first { $0.sessionId == s.sessionId }
            return item?.lastActivityAt == activityAt && item?.hasUnread == true && view.info.lastActivityAt == activityAt
        }
        XCTAssertTrue(view.info.hasUnread)
        XCTAssertEqual(view.info.members, AgentSessionMembers(viewers: [], participants: [h.part.userId]))

        _ = try await ownerClient.agents.sessions.rename(sessionId: s.sessionId, title: "Renamed")
        try await h.poll(timeout: 10, "the watched list and the view hear the rename") {
            list.items.first { $0.sessionId == s.sessionId }?.title == "Renamed" && view.info.title == "Renamed"
        }
        XCTAssertGreaterThan(changes.value, 0)
    }
}
