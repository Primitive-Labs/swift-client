import XCTest
@testable import JsBaoClient

/// Channels and direct messages against the live dev server — #3278
/// behaviors 24 and 26. The whole chain, end to end: a pushed function mints
/// a grant, the client presents it on the socket it already has, a function
/// publishes, and the frame arrives as a typed event; a function calls
/// `ctx.users.send` and the frame arrives as `directMessage`. Ports of
/// `tests/client/js-bao-client-channels.test.ts` and
/// `js-bao-client-direct-message.test.ts`.
final class ChannelsLiveTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-channels")
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        // A live socket is what a channel membership hangs off and what a
        // direct send has to find. Give the server-side connection mapping a
        // moment to persist before anything sends.
        try await client.connect()
        try await waitForConnection(client: client)
        try await delay(1)
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx.cleanup()
    }

    /// The platform default is 5 s, which a cold sandbox load can exceed when
    /// the whole live scope runs; the budget under test is the function's.
    private let generousTimeout: TimeInterval = 25

    private static let channelBundle = """
    export default async function (input, ctx) {
      if (input.action === "authorize") {
        return ctx.channels.authorize(input.channel, input.options || undefined);
      }
      return ctx.channels.publish(input.channel, input.payload);
    }
    """

    /// #3344 retired the untyped entry points, so this helper's input is a
    /// `JSONValue` (the type a dynamic caller uses either way) rather than a
    /// `[String: Any]`, and the result names its own witness.
    private func invoke(_ functionKey: String, _ input: JSONValue) async throws -> JSONValue {
        let result: FunctionResult<JSONValue> = try await client.functions.invoke(
            functionKey, input: input, timeout: generousTimeout
        )
        XCTAssertEqual(result.status, "completed", "\(String(describing: result.error))")
        return try XCTUnwrap(result.output)
    }

    private func authorize(_ functionKey: String, _ channel: String, options: JSONValue = [:]) async throws -> (grant: String, expiresAt: Int) {
        let output = try await invoke(
            functionKey,
            ["action": "authorize", "channel": .string(channel), "options": options]
        )
        let grant = try XCTUnwrap(output["grant"]?.stringValue)
        let expiresAt = try XCTUnwrap(output["expiresAt"]?.numberValue)
        return (grant, Int(expiresAt))
    }

    private func publish(_ functionKey: String, _ channel: String, _ payload: JSONValue) async throws -> Int {
        let output = try await invoke(functionKey, ["channel": .string(channel), "payload": payload])
        return Int(try XCTUnwrap(output["connections"]?.numberValue))
    }

    // MARK: - Behavior 24: a grant joins, a publish arrives, leaving stops delivery

    func testAGrantJoinsAChannelAPublishArrivesAndLeavingStopsDelivery() async throws {
        let functionKey = "swift-chan-\(Int(Date().timeIntervalSince1970))"
        try await ctx.pushFunction(appId: testApp.appId, functionKey: functionKey, bundle: Self.channelBundle)

        let channel = "orders:swift-\(Int(Date().timeIntervalSince1970))"
        let (grant, expiresAt) = try await authorize(functionKey, channel)

        let events = LockedBox<[ChannelMessageEvent]>([])
        let sub = client.eventEmitter.subscribe(ChannelMessageEvent.self) { event in
            events.withValue { $0.append(event) }
        }
        defer { sub.cancel() }

        let subscription = try await client.subscribeToChannel(channel, grant: grant)
        XCTAssertEqual(subscription.channel, channel)
        XCTAssertEqual(subscription.expiresAt, expiresAt)

        let delivered = try await publish(functionKey, channel, ["hello": "channel"])
        XCTAssertEqual(delivered, 1)
        try await eventually(timeout: 20, description: "the channel message") { !events.value.isEmpty }
        let first = try XCTUnwrap(events.value.first)
        XCTAssertEqual(first.channel, channel)
        XCTAssertEqual(first.payload, ["hello": "channel"])
        XCTAssertEqual(first.functionKey, functionKey)
        XCTAssertFalse(first.sentAt.isEmpty)

        // Leaving stops delivery, and the server confirms by counting nobody.
        subscription.unsubscribe()
        try await delay(0.75)
        let after = try await publish(functionKey, channel, ["hello": "again"])
        XCTAssertEqual(after, 0)
    }

    func testAnExpiredGrantRacingAValidOneRejectsOnlyItsOwnJoin() async throws {
        let functionKey = "swift-chan-race-\(Int(Date().timeIntervalSince1970))"
        try await ctx.pushFunction(appId: testApp.appId, functionKey: functionKey, bundle: Self.channelBundle)

        let stamp = Int(Date().timeIntervalSince1970)
        let goodChannel = "orders:good-\(stamp)"
        let badChannel = "orders:bad-\(stamp)"
        let good = try await authorize(functionKey, goodChannel)
        // A one-second grant, waited out: an expired credential is the
        // cheapest honest refusal, and the TTL is the authoring surface's own
        // field.
        let expired = try await authorize(functionKey, badChannel, options: ["ttlSeconds": 1])
        try await delay(1.5)

        let racing: JsBaoClient = client
        async let goodJoin = racing.subscribeToChannel(goodChannel, grant: good.grant)
        async let badJoin = racing.subscribeToChannel(badChannel, grant: expired.grant)
        let goodResult = try await goodJoin
        XCTAssertEqual(goodResult.channel, goodChannel)
        do {
            _ = try await badJoin
            XCTFail("an expired grant must be refused")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .channelSubscribeFailed)
            XCTAssertEqual(error.details?["channel"]?.stringValue, badChannel)
        }

        // The surviving membership still works…
        let events = LockedBox<[ChannelMessageEvent]>([])
        let sub = client.eventEmitter.subscribe(ChannelMessageEvent.self) { event in
            events.withValue { $0.append(event) }
        }
        defer { sub.cancel() }
        _ = try await publish(functionKey, goodChannel, ["still": "here"])
        try await eventually(timeout: 20, description: "the good channel's message") {
            events.value.contains { $0.channel == goodChannel }
        }

        // …and the failed one left nothing behind.
        let dead = try await publish(functionKey, badChannel, ["should": "not arrive"])
        XCTAssertEqual(dead, 0)
    }

    // MARK: - Behavior 26: a direct message from ctx.users.send

    private static let sendBundle = """
    export default async function (input, ctx) {
      return ctx.users.send(input.userId, input.payload);
    }
    """

    func testADirectMessageArrivesWhileConnectedAndNotForAClientThatConnectsLater() async throws {
        let functionKey = "swift-send-\(Int(Date().timeIntervalSince1970))"
        try await ctx.pushFunction(appId: testApp.appId, functionKey: functionKey, bundle: Self.sendBundle)

        let events = LockedBox<[DirectMessageEvent]>([])
        let sub = client.eventEmitter.subscribe(DirectMessageEvent.self) { event in
            events.withValue { $0.append(event) }
        }
        defer { sub.cancel() }

        let output = try await invoke(functionKey, [
            "userId": .string(testApp.ownerUserId),
            "payload": ["greeting": "hello from a function", "n": 3],
        ])
        XCTAssertEqual(output["connections"]?.numberValue, 1)
        try await eventually(timeout: 20, description: "the direct message") { !events.value.isEmpty }
        let first = try XCTUnwrap(events.value.first)
        XCTAssertEqual(first.payload, ["greeting": "hello from a function", "n": 3])
        XCTAssertEqual(first.functionKey, functionKey)
        XCTAssertFalse(first.sentAt.isEmpty)

        // A live frame with no durable record behind it: a client that was
        // not connected when the function ran does not receive it later.
        await client.disconnect()
        try await delay(0.5)
        let late = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await late.destroy() } }
        let lateEvents = LockedBox<[DirectMessageEvent]>([])
        let lateSub = late.eventEmitter.subscribe(DirectMessageEvent.self) { event in
            lateEvents.withValue { $0.append(event) }
        }
        defer { lateSub.cancel() }

        let unheard = try await invoke(
            functionKey,
            ["userId": .string(testApp.ownerUserId), "payload": ["unheard": true]]
        )
        XCTAssertEqual(unheard["connections"]?.numberValue, 0, "nobody was connected to receive it")

        try await late.connect()
        try await waitForConnection(client: late)
        try await delay(1.5)
        XCTAssertTrue(lateEvents.value.isEmpty, "a client that connects after the send receives nothing")
    }
}
