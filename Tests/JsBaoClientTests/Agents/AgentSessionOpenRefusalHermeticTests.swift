import XCTest
@testable import JsBaoClient

/// `open` when the session's db3 cannot go live (#4884 edges E4 and E12,
/// DSO-4884-001): `ready()`'s error is `open`'s, with the subscription
/// disposed; `NOT_A_DB3`, `DB3_READY_TIMEOUT` and `DB3_DISPOSED` leave the
/// local copy as it was, and `DB3_ACCESS_REFUSED` (the room's refusal landing
/// after `get`, before `ready()`) also evicts the session's copy, so a copy
/// kept from an earlier `close()` does not outlive the membership. A `get`
/// answered `AGENT_SESSION_DB3_MISSING` throws before anything is subscribed.
///
/// Over the real lifecycle (`SessionDb3`): the refusal reaches it as the
/// client's session reports the room's `ACCESS_DENIED` frame.
final class AgentSessionOpenRefusalHermeticTests: XCTestCase {
    private var clients: [JsBaoClient] = []
    private var db3s: [SessionDb3] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for db3 in db3s { db3.cleanup() }
        db3s = []
    }

    private func sessions(get status: Int = 200, _ body: String = agentSessionInfoJSON("s1")) -> AgentSessionsAPI {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "agent-session-open-refusal",
            token: makeTestJwt(userId: "u1"), offline: false, logLevel: .none,
            storageConfig: .memory, autoNetwork: false
        ))
        clients.append(client)
        return AgentSessionsAPI(transport: RecordingTransport(status: status, json: body), client: client)
    }

    private func db3(resident: Bool = true, format: Int = RecordLogTransport.documentFormat, bound: Bool = true) async throws -> SessionDb3 {
        let made = try await SessionDb3.make(id: "s1", resident: resident, format: format, bound: bound)
        db3s.append(made)
        return made
    }

    private func code(_ body: () async throws -> Void) async -> String {
        do {
            try await body()
            return "resolved"
        } catch let error as JsBaoError {
            return error.code.rawValue
        } catch let error as HttpError {
            return error.serverCode ?? "\(error.status)"
        } catch {
            return "\(error)"
        }
    }

    /// `open` running while the db3 does not go live; `act` runs once the
    /// subscribe has asked the lifecycle to open it.
    private func openWhile(
        _ sessions: AgentSessionsAPI, _ db3: SessionDb3, act: @escaping @Sendable () async throws -> Void
    ) async -> String {
        db3.setGoesLive(false)
        let opening = Task { () -> String in
            do {
                _ = try await sessions.open(sessionId: "s1", db3: db3)
                return "resolved"
            } catch let error as JsBaoError {
                return error.code.rawValue
            } catch {
                return "\(error)"
            }
        }
        do {
            try await eventually(description: "the subscribe opens the db3") { db3.opens == ["s1"] }
            try await act()
        } catch {
            XCTFail("\(error)")
        }
        return await opening.value
    }

    private func rows(_ db3: SessionDb3) async throws -> (resident: Bool, rows: Int, subscribed: Bool) {
        let state = try await db3.state()
        return (state.resident, state.rows, state.subscribed)
    }

    // MARK: - Edge E4

    func testAnAccessRefusalDuringOpenThrowsDisposesAndEvictsTheCopy() async throws {
        let db3 = try await db3()
        try db3.write("Message", SessionRows.message("m1", seq: 1))
        let thrown = await openWhile(sessions(), db3) { try db3.refuse() }
        XCTAssertEqual(thrown, "DB3_ACCESS_REFUSED")
        try await eventually(description: "the copy is evicted") {
            guard let state = try? await self.rows(db3) else { return false }
            return !state.resident && state.rows == 0 && !state.subscribed
        }
        XCTAssertEqual(db3.evictionCount, 1)
    }

    func testAReadyTimeoutThrowsDisposesAndKeepsTheCopy() async throws {
        let db3 = try await db3()
        try db3.write("Message", SessionRows.message("m1", seq: 1))
        db3.setReadyTimeout(0.3)
        let thrown = await openWhile(sessions(), db3) {}
        XCTAssertEqual(thrown, "DB3_READY_TIMEOUT")
        try await eventually(description: "nothing is subscribed") { (try? await self.rows(db3).subscribed) == false }
        let state = try await rows(db3)
        XCTAssertTrue(state.resident, "the copy stays")
        XCTAssertEqual(state.rows, 1)
        XCTAssertEqual(db3.evictionCount, 0)
    }

    func testADisposedSubscriptionThrowsAndKeepsTheCopy() async throws {
        let db3 = try await db3()
        try db3.write("Message", SessionRows.message("m1", seq: 1))
        let thrown = await openWhile(sessions(), db3) { await db3.endSubscriptions() }
        XCTAssertEqual(thrown, "DB3_DISPOSED")
        let state = try await rows(db3)
        XCTAssertTrue(state.resident)
        XCTAssertEqual(state.rows, 1)
        XCTAssertFalse(state.subscribed)
        XCTAssertEqual(db3.evictionCount, 0)
    }

    func testAnIdThatIsNoDb3ThrowsNotADb3WithNothingSubscribed() async throws {
        let db3 = try await db3(resident: false, format: 1, bound: false)
        let thrown = await code { _ = try await self.sessions().open(sessionId: "s1", db3: db3) }
        XCTAssertEqual(thrown, "NOT_A_DB3")
        let state = try await rows(db3)
        XCTAssertFalse(state.subscribed)
        XCTAssertEqual(db3.evictionCount, 0)
    }

    func testAGetAnsweredDb3MissingThrowsBeforeAnySubscribe() async throws {
        let db3 = try await db3()
        let thrown = await code {
            _ = try await self.sessions(get: 410, #"{"code":"AGENT_SESSION_DB3_MISSING","error":"gone"}"#)
                .open(sessionId: "s1", db3: db3)
        }
        XCTAssertEqual(thrown, "AGENT_SESSION_DB3_MISSING")
        XCTAssertEqual(db3.opens, [], "nothing is subscribed")
    }

    // MARK: - Edge E12: a copy kept from an earlier close

    func testARefusalDuringTheNextOpenEvictsACopyKeptFromAnEarlierClose() async throws {
        let db3 = try await db3()
        let sessions = sessions()
        try db3.write([
            ("Session", SessionRows.session()),
            ("Message", SessionRows.message("m1", seq: 1)),
        ])
        let first = try await sessions.open(sessionId: "s1", db3: db3)
        XCTAssertEqual(first.syncedMessages.count, 1)
        await first.close()
        let kept = try await rows(db3)
        XCTAssertTrue(kept.resident, "close() keeps the copy")
        XCTAssertEqual(kept.rows, 2)

        // Removed meanwhile: the room refuses the next open after get answered.
        let thrown = await openWhile(sessions, db3) { try db3.refuse() }
        XCTAssertEqual(thrown, "DB3_ACCESS_REFUSED")
        try await eventually(description: "the kept copy is evicted") {
            guard let state = try? await self.rows(db3) else { return false }
            return !state.resident && state.rows == 0 && !state.subscribed
        }
    }

    func testTheSameRefusalWithNoCopyThrowsTheSameWithNothingToEvict() async throws {
        let db3 = try await db3(resident: false)
        let thrown = await openWhile(sessions(), db3) { try db3.refuse() }
        XCTAssertEqual(thrown, "DB3_ACCESS_REFUSED")
        try await eventually(description: "nothing is left") {
            guard let state = try? await self.rows(db3) else { return false }
            return !state.resident && state.rows == 0 && !state.subscribed
        }
    }
}
