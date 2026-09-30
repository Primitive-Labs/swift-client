import XCTest
@testable import JsBaoClient

/// Channels and direct messages on the Swift client — #3278 behaviors 16–23
/// and 25, plus the channel and direct-message edge cases. The reference is
/// the JS client's `subscribeToChannel` / `unsubscribeFromChannel` /
/// `channelMessage` / `channelSubscribeFailed` / `directMessage`
/// (`src/client/JsBaoClient.ts`, #3184 and #3183).
///
/// Server-free. Outbound frames are asserted on the wire against the
/// in-process `LoopbackWebSocketServer` (what the client really sent);
/// inbound frames are handed to `handleWebSocketMessage` the way the
/// transport delivers them. Membership bookkeeping is read through the
/// client's internal registry where nothing else can observe it.
final class ChannelSubscribeHermeticTests: XCTestCase {

    /// A bare client on a closed API port: nothing reaches an HTTP server.
    /// `autoNetwork: false` so nothing connects until a test asks.
    private func makeClient(wsUrl: String) -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: wsUrl,
            appId: "channels-hermetic",
            token: makeTestJwt(userId: "user-channels"),
            offline: false,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
    }

    private func wsBase(_ url: URL) -> String {
        let s = url.absoluteString
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    /// A loopback server plus a client connected to it.
    private func connectedClient() async throws -> (LoopbackWebSocketServer, JsBaoClient) {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let client = makeClient(wsUrl: wsBase(url))
        try await client.connect()
        XCTAssertTrue(client.isConnected)
        return (server, client)
    }

    private func deliver(_ frame: [String: Any], to client: JsBaoClient) async {
        let data = try! JSONSerialization.data(withJSONObject: frame)
        await client.handleWebSocketMessage(String(data: data, encoding: .utf8)!)
    }

    /// The frames of one type the client put on the wire, decoded.
    private func frames(_ server: LoopbackWebSocketServer, type: String) -> [[String: Any]] {
        server.receivedFrames.compactMap { text -> [String: Any]? in
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == type
            else { return nil }
            return json
        }
    }

    private func subscribeFrames(_ server: LoopbackWebSocketServer, channel: String) -> [[String: Any]] {
        frames(server, type: "channel.subscribe").filter { $0["channel"] as? String == channel }
    }

    /// A subscribe started in its own task, with its outcome readable.
    private final class Join: @unchecked Sendable {
        let task: Task<ChannelSubscription, Error>
        private let outcome = LockedBox<Result<ChannelSubscription, Error>?>(nil)

        init(_ client: JsBaoClient, _ channel: String, grant: String) {
            let box = outcome
            task = Task {
                do {
                    let sub = try await client.subscribeToChannel(channel, grant: grant)
                    box.value = .success(sub)
                    return sub
                } catch {
                    box.value = .failure(error)
                    throw error
                }
            }
        }

        var isSettled: Bool { outcome.value != nil }
        var result: Result<ChannelSubscription, Error>? { outcome.value }

        func failureCode() -> JsBaoErrorCode? {
            if case let .failure(error)? = outcome.value { return (error as? JsBaoError)?.code }
            return nil
        }

        func failureMessage() -> String? {
            if case let .failure(error)? = outcome.value { return (error as? JsBaoError)?.message }
            return nil
        }
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ check: @escaping () -> Bool
    ) async throws {
        try await eventually(timeout: timeout, interval: 0.02, description: description) { check() }
    }

    // MARK: - Behavior 16: the subscribe frame and its own ack

    func testSubscribeSendsTheSubscribeFrameAndResolvesOnItsOwnChannelsAck() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        let join = Join(client, "orders:1", grant: "grant-1")
        try await waitUntil("the subscribe frame to reach the wire") {
            !self.subscribeFrames(server, channel: "orders:1").isEmpty
        }
        let sent = try XCTUnwrap(subscribeFrames(server, channel: "orders:1").first)
        XCTAssertEqual(sent["grant"] as? String, "grant-1")
        XCTAssertEqual(Set(sent.keys), ["type", "channel", "grant"], "exactly the JS frame")

        // Another channel's ack settles nothing here.
        await deliver(["type": "channel.subscribed", "channel": "orders:2", "expiresAt": 99], to: client)
        try await delay(0.1)
        XCTAssertFalse(join.isSettled, "an ack for a different channel must not resolve this join")

        await deliver(["type": "channel.subscribed", "channel": "orders:1", "expiresAt": 1_700_000_000_000], to: client)
        let subscription = try await join.task.value
        XCTAssertEqual(subscription.channel, "orders:1")
        XCTAssertEqual(subscription.expiresAt, 1_700_000_000_000)
        XCTAssertEqual(client.channelRegistry.heldGrant(for: "orders:1")?.expiresAt, 1_700_000_000_000)
    }

    /// Edge case: an empty channel or grant is refused before any frame is sent.
    func testSubscribeWithAnEmptyChannelOrGrantThrowsInvalidArgumentBeforeAnyFrame() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        for (channel, grant) in [("", "g"), ("orders:1", "")] {
            do {
                _ = try await client.subscribeToChannel(channel, grant: grant)
                XCTFail("must throw for channel '\(channel)' grant '\(grant)'")
            } catch let error as JsBaoError {
                XCTAssertEqual(error.code, .invalidArgument)
            }
        }
        try await delay(0.1)
        XCTAssertTrue(frames(server, type: "channel.subscribe").isEmpty)
        XCTAssertTrue(client.channelRegistry.heldGrants().isEmpty)
    }

    /// Edge case: an ack for a channel with no pending join updates the held
    /// grant's `expiresAt` and nothing else.
    func testAnAckWithNoPendingJoinOnlyUpdatesExpiresAt() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        let join = Join(client, "orders:1", grant: "grant-1")
        try await waitUntil("frame") { !self.subscribeFrames(server, channel: "orders:1").isEmpty }
        await deliver(["type": "channel.subscribed", "channel": "orders:1", "expiresAt": 10], to: client)
        _ = try await join.task.value

        let failed = await collectEvents(from: client.eventEmitter, event: ChannelSubscribeFailedEvent.self) {
            // The renewal's ack, or a duplicate — nobody is waiting.
            await deliver(["type": "channel.subscribed", "channel": "orders:1", "expiresAt": 20], to: client)
            // An ack for a channel this client never joined registers nothing.
            await deliver(["type": "channel.subscribed", "channel": "orders:unknown", "expiresAt": 30], to: client)
        }
        XCTAssertEqual(client.channelRegistry.heldGrant(for: "orders:1")?.expiresAt, 20)
        XCTAssertNil(client.channelRegistry.heldGrant(for: "orders:unknown"))
        XCTAssertTrue(failed.isEmpty)
    }

    /// Edge case: a `channel.unsubscribed` ack settles nothing.
    func testAnUnsubscribedAckSettlesNothing() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        let join = Join(client, "orders:1", grant: "grant-1")
        try await waitUntil("frame") { !self.subscribeFrames(server, channel: "orders:1").isEmpty }
        let errors = try await collectEvents(from: client.eventEmitter, event: ConnectionErrorEvent.self) {
            await deliver(["type": "channel.unsubscribed", "channel": "orders:1"], to: client)
            try await delay(0.1)
        }
        XCTAssertFalse(join.isSettled)
        XCTAssertTrue(errors.isEmpty)
        client.unsubscribeFromChannel("orders:1")
        _ = try? await join.task.value
    }

    // MARK: - Behavior 17: the scoped refusal

    func testASubscribeErrorFrameRejectsOnlyThatChannelAndIsNotAConnectionError() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        let good = Join(client, "orders:good", grant: "grant-good")
        let bad = Join(client, "orders:bad", grant: "grant-bad")
        try await waitUntil("both frames") {
            !self.subscribeFrames(server, channel: "orders:good").isEmpty
                && !self.subscribeFrames(server, channel: "orders:bad").isEmpty
        }

        let errors = try await collectEvents(from: client.eventEmitter, event: ConnectionErrorEvent.self) {
            await deliver([
                "type": "error", "context": "channel.subscribe", "channel": "orders:bad",
                "message": "the grant was not accepted",
            ], to: client)
            _ = try? await bad.task.value
            try await delay(0.1)
        }
        XCTAssertEqual(bad.failureCode(), .channelSubscribeFailed)
        XCTAssertTrue(bad.failureMessage()?.contains("the grant was not accepted") == true, "\(String(describing: bad.failureMessage()))")
        if case let .failure(error)? = bad.result {
            XCTAssertEqual((error as? JsBaoError)?.details?["channel"]?.stringValue, "orders:bad")
        }
        XCTAssertFalse(good.isSettled, "only the named channel's join settles")
        XCTAssertTrue(errors.isEmpty, "a channel refusal is not a connection error")
        XCTAssertNil(client.channelRegistry.heldGrant(for: "orders:bad"), "the refused grant is dropped")
        XCTAssertNotNil(client.channelRegistry.heldGrant(for: "orders:good"))

        // Every other error frame still surfaces as a connection error.
        let plain = await collectEvents(from: client.eventEmitter, event: ConnectionErrorEvent.self) {
            await deliver(["type": "error", "message": "Permission denied", "messageType": "syncStep1"], to: client)
        }
        XCTAssertEqual(plain.count, 1)
        XCTAssertEqual(plain.first?.message, "Permission denied")

        await deliver(["type": "channel.subscribed", "channel": "orders:good", "expiresAt": 1], to: client)
        _ = try await good.task.value
    }

    // MARK: - Behavior 18: channel.message

    func testAChannelMessageFrameEmitsAChannelMessageEvent() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        let join = Join(client, "orders:1", grant: "grant-1")
        try await waitUntil("frame") { !self.subscribeFrames(server, channel: "orders:1").isEmpty }
        await deliver(["type": "channel.subscribed", "channel": "orders:1", "expiresAt": 1], to: client)
        _ = try await join.task.value

        let events = await collectEvents(from: client.eventEmitter, event: ChannelMessageEvent.self) {
            await deliver([
                "type": "channel.message", "channel": "orders:1",
                "payload": ["status": "shipped", "n": 3],
                "functionKey": "order-room", "sentAt": "2026-09-10T00:00:00.000Z",
            ], to: client)
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.channel, "orders:1")
        XCTAssertEqual(events.first?.payload, ["status": "shipped", "n": 3])
        XCTAssertEqual(events.first?.functionKey, "order-room")
        XCTAssertEqual(events.first?.sentAt, "2026-09-10T00:00:00.000Z")
    }

    /// A frame for a channel this client holds no membership in is inert: it
    /// is not an error, does not touch the registry and does not disturb the
    /// socket. As in JS, the frame is still delivered to a listener — the
    /// server is the membership authority, and a message that was in flight
    /// when the client left is not a fault.
    func testAChannelMessageForAChannelNobodyHoldsIsInert() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        let errors = await collectEvents(from: client.eventEmitter, event: ConnectionErrorEvent.self) {
            let messages = await collectEvents(from: client.eventEmitter, event: ChannelMessageEvent.self) {
                await deliver([
                    "type": "channel.message", "channel": "orders:nobody",
                    "payload": "late", "functionKey": "order-room", "sentAt": "2026-09-10T00:00:00.000Z",
                ], to: client)
            }
            XCTAssertEqual(messages.count, 1)
            XCTAssertEqual(messages.first?.payload, "late")
        }
        XCTAssertTrue(errors.isEmpty)
        XCTAssertTrue(client.channelRegistry.heldGrants().isEmpty, "a message registers no membership")
        XCTAssertTrue(client.isConnected)
    }

    // MARK: - Behavior 19: unsubscribe

    func testUnsubscribeSendsTheFrameDropsTheGrantRejectsAnInFlightJoinAndIsIdempotent() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        let join = Join(client, "orders:1", grant: "grant-1")
        try await waitUntil("frame") { !self.subscribeFrames(server, channel: "orders:1").isEmpty }
        await deliver(["type": "channel.subscribed", "channel": "orders:1", "expiresAt": 1], to: client)
        let subscription = try await join.task.value

        subscription.unsubscribe()
        try await waitUntil("the unsubscribe frame") {
            self.frames(server, type: "channel.unsubscribe").contains { $0["channel"] as? String == "orders:1" }
        }
        XCTAssertNil(client.channelRegistry.heldGrant(for: "orders:1"))
        // Idempotent: a second leave neither throws nor announces anything.
        let failed = try await collectEvents(from: client.eventEmitter, event: ChannelSubscribeFailedEvent.self) {
            client.unsubscribeFromChannel("orders:1")
            subscription.unsubscribe()
            try await delay(0.1)
        }
        XCTAssertTrue(failed.isEmpty)

        // A join still waiting for its ack is rejected by the leave.
        let inFlight = Join(client, "orders:2", grant: "grant-2")
        try await waitUntil("frame") { !self.subscribeFrames(server, channel: "orders:2").isEmpty }
        client.unsubscribeFromChannel("orders:2")
        _ = try? await inFlight.task.value
        XCTAssertEqual(inFlight.failureCode(), .channelSubscribeFailed)
        XCTAssertTrue(inFlight.failureMessage()?.contains("was left while joining") == true)
        XCTAssertNil(client.channelRegistry.heldGrant(for: "orders:2"))
    }

    // MARK: - Behavior 20: one join at a time per channel

    func testJoinsToTheSameChannelRunOneAfterTheOtherAndOtherChannelsAreNotBlocked() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        let first = Join(client, "orders:1", grant: "grant-1")
        try await waitUntil("first frame") { self.subscribeFrames(server, channel: "orders:1").count == 1 }
        let renewal = Join(client, "orders:1", grant: "grant-2")
        let other = Join(client, "orders:2", grant: "grant-3")
        try await waitUntil("the other channel's frame") { !self.subscribeFrames(server, channel: "orders:2").isEmpty }
        try await delay(0.1)
        XCTAssertEqual(subscribeFrames(server, channel: "orders:1").count, 1, "the renewal waits for the first join to settle")
        XCTAssertFalse(renewal.isSettled)

        await deliver(["type": "channel.subscribed", "channel": "orders:1", "expiresAt": 1], to: client)
        _ = try await first.task.value
        try await waitUntil("the renewal's frame") { self.subscribeFrames(server, channel: "orders:1").count == 2 }
        XCTAssertEqual(subscribeFrames(server, channel: "orders:1").last?["grant"] as? String, "grant-2")
        XCTAssertFalse(renewal.isSettled, "the first ack was the first join's, not the renewal's")
        await deliver(["type": "channel.subscribed", "channel": "orders:1", "expiresAt": 2], to: client)
        let renewed = try await renewal.task.value
        XCTAssertEqual(renewed.expiresAt, 2)

        await deliver(["type": "channel.subscribed", "channel": "orders:2", "expiresAt": 3], to: client)
        _ = try await other.task.value
    }

    func testAJoinWhoseChannelWasLeftBeforeItRanRejectsAndDoesNotResubscribe() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        let first = Join(client, "orders:1", grant: "grant-1")
        try await waitUntil("first frame") { self.subscribeFrames(server, channel: "orders:1").count == 1 }
        let queued = Join(client, "orders:1", grant: "grant-2")
        try await delay(0.05)

        client.unsubscribeFromChannel("orders:1")
        _ = try? await first.task.value
        _ = try? await queued.task.value
        XCTAssertEqual(first.failureCode(), .channelSubscribeFailed)
        XCTAssertEqual(queued.failureCode(), .channelSubscribeFailed)
        XCTAssertTrue(queued.failureMessage()?.contains("was left before this subscribe ran") == true, "\(String(describing: queued.failureMessage()))")

        try await delay(0.2)
        XCTAssertEqual(subscribeFrames(server, channel: "orders:1").count, 1, "the queued join must not put grant-2 on the wire")
        XCTAssertNil(client.channelRegistry.heldGrant(for: "orders:1"))
    }

    // MARK: - Behavior 21: the ack timeout

    func testAJoinWithNoAnswerRejectsAfterTheAckTimeout() async throws {
        XCTAssertEqual(JsBaoClient.channelSubscribeAckTimeout, 20, "the JS client's 20 s")
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }
        client.channelSubscribeAckTimeoutForTest = 0.2

        let join = Join(client, "orders:1", grant: "grant-1")
        _ = try? await join.task.value
        XCTAssertEqual(join.failureCode(), .channelSubscribeFailed)
        XCTAssertTrue(join.failureMessage()?.contains("no answer") == true, "\(String(describing: join.failureMessage()))")
        XCTAssertNil(client.channelRegistry.heldGrant(for: "orders:1"), "a timed-out join drops its grant, as JS does")
        XCTAssertEqual(subscribeFrames(server, channel: "orders:1").count, 1)
    }

    // MARK: - Behavior 22: a join while the socket is closed

    func testAJoinWhileTheSocketIsClosedConnectsAndSendsItsFrameOnceOnOpen() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let client = makeClient(wsUrl: wsBase(url))
        defer { server.stop(); Task { await client.destroy() } }
        XCTAssertFalse(client.isConnected)

        let join = Join(client, "orders:1", grant: "grant-1")
        try await waitUntil("the grant to be registered") { client.channelRegistry.heldGrant(for: "orders:1") != nil }
        try await waitUntil("the socket to open") { client.isConnected }
        try await waitUntil("the held-back frame") { !self.subscribeFrames(server, channel: "orders:1").isEmpty }
        try await delay(0.3)
        XCTAssertEqual(subscribeFrames(server, channel: "orders:1").count, 1, "sent once: the open flush, not the flush plus a re-issue")
        XCTAssertFalse(join.isSettled)

        await deliver(["type": "channel.subscribed", "channel": "orders:1", "expiresAt": 7], to: client)
        let subscription = try await join.task.value
        XCTAssertEqual(subscription.expiresAt, 7)
    }

    // MARK: - Behavior 23: close and reconnect

    func testOnCloseEveryPendingJoinRejectsGrantsStayAndReconnectRePresentsThem() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        let held = Join(client, "orders:held", grant: "grant-held")
        try await waitUntil("frame") { !self.subscribeFrames(server, channel: "orders:held").isEmpty }
        await deliver(["type": "channel.subscribed", "channel": "orders:held", "expiresAt": 1], to: client)
        _ = try await held.task.value
        let pending = Join(client, "orders:pending", grant: "grant-pending")
        try await waitUntil("frame") { !self.subscribeFrames(server, channel: "orders:pending").isEmpty }

        await client.disconnect()
        _ = try? await pending.task.value
        XCTAssertEqual(pending.failureCode(), .channelSubscribeFailed)
        XCTAssertTrue(pending.failureMessage()?.contains("closed") == true, "\(String(describing: pending.failureMessage()))")
        XCTAssertEqual(
            Set(client.channelRegistry.heldGrants().map(\.channel)), ["orders:held", "orders:pending"],
            "the socket failed, not the credentials: both grants stay for the reconnect pass"
        )

        let framesBefore = server.receivedFrames.count
        await client.setShouldConnect(true)
        try await waitForConnection(client: client, timeout: 10)
        try await waitUntil("both grants re-presented") {
            let after = Array(server.receivedFrames.dropFirst(framesBefore))
            return after.contains { $0.contains("\"orders:held\"") && $0.contains("channel.subscribe") }
                && after.contains { $0.contains("\"orders:pending\"") && $0.contains("channel.subscribe") }
        }
        let reissued = frames(server, type: "channel.subscribe").suffix(2).compactMap { $0["grant"] as? String }
        XCTAssertEqual(Set(reissued), ["grant-held", "grant-pending"], "each held grant is re-presented as stored")

        // A refused re-presentation has nobody waiting on it, so it is
        // announced — and drops only its own channel.
        let failed = try await collectEvents(from: client.eventEmitter, event: ChannelSubscribeFailedEvent.self) {
            await deliver([
                "type": "error", "context": "channel.subscribe", "channel": "orders:pending",
                "message": "the grant was not accepted",
            ], to: client)
            try await waitUntil("the refusal to be announced") {
                client.channelRegistry.heldGrant(for: "orders:pending") == nil
            }
            try await delay(0.1)
        }
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed.first?.channel, "orders:pending")
        XCTAssertTrue(failed.first?.message.contains("the grant was not accepted") == true)
        XCTAssertNotNil(client.channelRegistry.heldGrant(for: "orders:held"), "the other channel keeps its membership")

        // …and the surviving channel keeps delivering.
        await deliver(["type": "channel.subscribed", "channel": "orders:held", "expiresAt": 2], to: client)
        let messages = await collectEvents(from: client.eventEmitter, event: ChannelMessageEvent.self) {
            await deliver([
                "type": "channel.message", "channel": "orders:held", "payload": ["still": "here"],
                "functionKey": "order-room", "sentAt": "2026-09-10T00:00:00.000Z",
            ], to: client)
        }
        XCTAssertEqual(messages.first?.payload, ["still": "here"])
    }

    /// Edge case: `destroy()` rejects pending joins and clears the registry.
    func testDestroyRejectsPendingJoinsAndClearsTheRegistry() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop() }

        let held = Join(client, "orders:held", grant: "grant-held")
        try await waitUntil("frame") { !self.subscribeFrames(server, channel: "orders:held").isEmpty }
        await deliver(["type": "channel.subscribed", "channel": "orders:held", "expiresAt": 1], to: client)
        _ = try await held.task.value
        let pending = Join(client, "orders:pending", grant: "grant-pending")
        try await waitUntil("frame") { !self.subscribeFrames(server, channel: "orders:pending").isEmpty }

        await client.destroy()
        _ = try? await pending.task.value
        XCTAssertEqual(pending.failureCode(), .channelSubscribeFailed)
        XCTAssertTrue(client.channelRegistry.heldGrants().isEmpty)
        XCTAssertFalse(client.channelRegistry.hasPendingJoins)
    }

    // MARK: - Concurrency at the registry boundary (CSO-001..003 on #3278)

    /// CSO-001: joins to the same channel issued at the same moment from
    /// parallel threads — not one after the other's frame has arrived — still
    /// take the wire one at a time, and each is settled by its own answer
    /// only. Reading the chain and installing its replacement in separate
    /// steps let two callers read the same predecessor, both send, and the
    /// first answer settle both.
    func testSimultaneousJoinsToTheSameChannelEachReceiveOnlyTheirOwnOutcome() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        // Launched from parallel threads so the calls really do enter the
        // client together; whichever reserves the chain first goes first and
        // the rest queue behind it in some order.
        let joinCount = 8
        let joins = LockedBox<[String: Join]>([:])
        DispatchQueue.concurrentPerform(iterations: joinCount) { i in
            let grant = "grant-\(i)"
            let join = Join(client, "orders:1", grant: grant)
            joins.withValue { $0[grant] = join }
        }
        try await waitUntil("the first frame") { self.subscribeFrames(server, channel: "orders:1").count >= 1 }
        try await delay(0.3)
        XCTAssertEqual(subscribeFrames(server, channel: "orders:1").count, 1, "one join on the wire at a time")

        // Answer them one by one: each answer settles exactly the join whose
        // grant is on the wire, and only then does the next grant go out.
        // Even-numbered rounds are acked, odd ones refused, so a join settled
        // by somebody else's answer would show as the wrong outcome.
        var settledGrants: [String] = []
        for round in 0..<joinCount {
            let sent = subscribeFrames(server, channel: "orders:1")
            XCTAssertEqual(sent.count, round + 1, "round \(round): exactly one new frame since the last answer")
            let grant = try XCTUnwrap(sent.last?["grant"] as? String)
            XCTAssertFalse(settledGrants.contains(grant), "round \(round): \(grant) was sent twice")
            let join = try XCTUnwrap(joins.value[grant])
            XCTAssertFalse(join.isSettled, "round \(round): \(grant) settled before its own answer")
            XCTAssertEqual(joins.value.values.filter(\.isSettled).count, round, "round \(round): only earlier joins are settled")

            if round.isMultiple(of: 2) {
                await deliver(["type": "channel.subscribed", "channel": "orders:1", "expiresAt": round + 1], to: client)
                let subscription = try await join.task.value
                XCTAssertEqual(subscription.expiresAt, round + 1, "\(grant) resolved with its own ack")
            } else {
                await deliver([
                    "type": "error", "context": "channel.subscribe", "channel": "orders:1", "message": "refused \(grant)",
                ], to: client)
                _ = try? await join.task.value
                XCTAssertEqual(join.failureCode(), .channelSubscribeFailed)
                XCTAssertTrue(join.failureMessage()?.contains("refused \(grant)") == true, "\(grant) rejected with its own refusal")
            }
            settledGrants.append(grant)
            if round + 1 < joinCount {
                try await waitUntil("round \(round): the next frame") {
                    self.subscribeFrames(server, channel: "orders:1").count == round + 2
                }
                try await delay(0.05)
            }
        }
        XCTAssertEqual(Set(settledGrants).count, joinCount, "every join was answered, each by its own frame")
        XCTAssertFalse(client.channelRegistry.hasPendingJoins)
    }

    /// CSO-002: `unsubscribeFromChannel` immediately followed by
    /// `subscribeToChannel` reaches the server as unsubscribe THEN subscribe.
    /// A detached send per frame could reverse them, so the server would
    /// grant the new membership and then remove it. Several rounds, so an
    /// out-of-order send has room to show itself.
    func testAnImmediateLeaveAndRejoinReachesTheWireAsUnsubscribeThenSubscribe() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        var join = Join(client, "orders:1", grant: "grant-0")
        try await waitUntil("frame") { self.subscribeFrames(server, channel: "orders:1").count == 1 }
        await deliver(["type": "channel.subscribed", "channel": "orders:1", "expiresAt": 1], to: client)
        _ = try await join.task.value

        for round in 1...10 {
            client.unsubscribeFromChannel("orders:1")
            join = Join(client, "orders:1", grant: "grant-\(round)")
            try await waitUntil("round \(round): both frames") {
                self.frames(server, type: "channel.unsubscribe").count == round
                    && self.subscribeFrames(server, channel: "orders:1").count == round + 1
            }
            let wire = server.receivedFrames
            let unsubscribeIndex = try XCTUnwrap(wire.lastIndex { $0.contains("channel.unsubscribe") })
            let subscribeIndex = try XCTUnwrap(wire.lastIndex { $0.contains("\"grant-\(round)\"") })
            XCTAssertLessThan(unsubscribeIndex, subscribeIndex, "round \(round): the leave must reach the server before the rejoin")
            await deliver(["type": "channel.subscribed", "channel": "orders:1", "expiresAt": round + 1], to: client)
            _ = try await join.task.value
        }
        XCTAssertEqual(client.channelRegistry.heldGrant(for: "orders:1")?.grant, "grant-10", "the rejoined membership is the one kept")
    }

    /// CSO-003: `destroy()` with a join on the wire AND a renewal queued
    /// behind it. The renewal wakes when the drain rejects its predecessor;
    /// it must reject itself promptly rather than register a grant, park a
    /// continuation nobody will resume, or leave state on a destroyed client.
    func testDestroyWithAnActiveJoinAndAQueuedRenewalRejectsBothPromptlyAndRegistersNothing() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop() }

        let active = Join(client, "orders:1", grant: "grant-1")
        try await waitUntil("frame") { self.subscribeFrames(server, channel: "orders:1").count == 1 }
        let queued = Join(client, "orders:1", grant: "grant-2")
        try await delay(0.1)
        XCTAssertFalse(queued.isSettled)

        await client.destroy()
        // Bounded: a leaked continuation would hang here, not fail.
        try await waitUntil("both joins to settle", timeout: 3) { active.isSettled && queued.isSettled }
        XCTAssertEqual(active.failureCode(), .channelSubscribeFailed)
        XCTAssertTrue(active.failureMessage()?.contains("destroyed") == true, "\(String(describing: active.failureMessage()))")
        XCTAssertEqual(queued.failureCode(), .channelSubscribeFailed)
        XCTAssertTrue(queued.failureMessage()?.contains("destroyed") == true, "\(String(describing: queued.failureMessage()))")

        try await delay(0.2)
        XCTAssertTrue(client.channelRegistry.heldGrants().isEmpty, "the queued renewal must not register on the way down")
        XCTAssertFalse(client.channelRegistry.hasPendingJoins)
        XCTAssertEqual(subscribeFrames(server, channel: "orders:1").count, 1, "grant-2 never reaches the wire")

        // And a subscribe made after destroy rejects at once, for the same reason.
        let late = Join(client, "orders:2", grant: "grant-3")
        try await waitUntil("the late join to settle", timeout: 3) { late.isSettled }
        XCTAssertEqual(late.failureCode(), .channelSubscribeFailed)
        XCTAssertTrue(late.failureMessage()?.contains("destroyed") == true, "\(String(describing: late.failureMessage()))")
        XCTAssertTrue(client.channelRegistry.heldGrants().isEmpty)
    }

    // MARK: - Behavior 25: direct.message

    func testADirectMessageFrameEmitsADirectMessageEventWithNoSubscriptionInvolved() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }
        XCTAssertTrue(client.channelRegistry.heldGrants().isEmpty, "no membership, no grant")

        let events = await collectEvents(from: client.eventEmitter, event: DirectMessageEvent.self) {
            await deliver([
                "type": "direct.message",
                "payload": ["greeting": "hello from a function", "n": 3],
                "functionKey": "notify", "sentAt": "2026-09-10T00:00:00.000Z",
            ], to: client)
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.payload, ["greeting": "hello from a function", "n": 3])
        XCTAssertEqual(events.first?.functionKey, "notify")
        XCTAssertEqual(events.first?.sentAt, "2026-09-10T00:00:00.000Z")
        XCTAssertTrue(frames(server, type: "channel.subscribe").isEmpty, "nothing was sent to receive it")
    }

    /// A frame with nobody listening is inert: no error, no state, the
    /// socket carries on, and a listener attached afterwards hears the next
    /// one. (A Swift handler is `(E) -> Void` and cannot throw, so the JS
    /// "handler threw → debug log" branch has no Swift counterpart to test;
    /// the decode failure branch is covered below.)
    func testADirectMessageWithNoListenerIsInert() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        let errors = await collectEvents(from: client.eventEmitter, event: ConnectionErrorEvent.self) {
            await deliver([
                "type": "direct.message", "payload": ["unheard": true],
                "functionKey": "notify", "sentAt": "2026-09-10T00:00:00.000Z",
            ], to: client)
            let delivered = await collectEvents(from: client.eventEmitter, event: DirectMessageEvent.self) {
                await deliver([
                    "type": "direct.message", "payload": ["heard": true],
                    "functionKey": "notify", "sentAt": "2026-09-10T00:00:00.000Z",
                ], to: client)
            }
            XCTAssertEqual(delivered.count, 1)
            XCTAssertEqual(delivered.first?.payload, ["heard": true])
        }
        XCTAssertTrue(errors.isEmpty)
        XCTAssertTrue(client.isConnected)
        XCTAssertTrue(client.channelRegistry.heldGrants().isEmpty)
    }

    /// Edge case: an absent or JSON-null payload decodes to a nil payload and
    /// still emits; a malformed frame is dropped without tearing down the
    /// socket.
    func testADirectMessageWithAnAbsentOrNullPayloadEmitsAndAMalformedFrameIsDropped() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        let events = await collectEvents(from: client.eventEmitter, event: DirectMessageEvent.self) {
            await deliver(["type": "direct.message", "functionKey": "notify", "sentAt": "t1"], to: client)
            await deliver(["type": "direct.message", "payload": NSNull(), "functionKey": "notify", "sentAt": "t2"], to: client)
            // Malformed: no functionKey, so nothing attributes it.
            await deliver(["type": "direct.message", "payload": ["x": 1], "sentAt": "t3"], to: client)
        }
        XCTAssertEqual(events.map(\.sentAt), ["t1", "t2"])
        XCTAssertNil(events[0].payload)
        XCTAssertNil(events[1].payload)
        XCTAssertTrue(client.isConnected, "a malformed frame must not tear down the socket")
    }

    /// Edge case: `destroy()` stops delivery.
    func testDestroyStopsDirectMessageDelivery() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop() }

        let received = LockedBox<[DirectMessageEvent]>([])
        let sub = client.eventEmitter.subscribe(DirectMessageEvent.self) { event in
            received.withValue { $0.append(event) }
        }
        defer { sub.cancel() }
        await client.destroy()
        await deliver([
            "type": "direct.message", "payload": ["late": true],
            "functionKey": "notify", "sentAt": "2026-09-10T00:00:00.000Z",
        ], to: client)
        XCTAssertTrue(received.value.isEmpty, "a destroyed client delivers nothing")
    }

    // MARK: - The events are declared and paired

    func testTheThreeNewEventsAreDeclaredWithTheirPayloads() {
        XCTAssertEqual(ChannelMessageEvent.eventKey, .channelMessage)
        XCTAssertEqual(ChannelSubscribeFailedEvent.eventKey, .channelSubscribeFailed)
        XCTAssertEqual(DirectMessageEvent.eventKey, .directMessage)
        XCTAssertEqual(JsBaoEvent.channelMessage.rawValue, "channelMessage")
        XCTAssertEqual(JsBaoEvent.channelSubscribeFailed.rawValue, "channelSubscribeFailed")
        XCTAssertEqual(JsBaoEvent.directMessage.rawValue, "directMessage")
        XCTAssertEqual(JsBaoErrorCode.channelSubscribeFailed.rawValue, "CHANNEL_SUBSCRIBE_FAILED")
    }
}
