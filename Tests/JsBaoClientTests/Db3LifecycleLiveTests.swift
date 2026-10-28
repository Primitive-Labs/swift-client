import XCTest
@testable import JsBaoClient

/// #4701 behaviours 14–16 and edge 40 — `client.db3.subscribe` and its
/// handles against the dev server, the Swift twin of js-bao's
/// `tests/client/db3-lifecycle-4698.test.ts`:
///
/// - 14: two handles in one client are one room subscriber, two clients two;
///   every dispose order leaves the room's count equal to the clients still
///   holding a handle; `dispose` twice is one release; `unsubscribe(id)`
///   disposes every handle; `refresh` catches a resident db3 up and leaves
///   another client's subscription as it was.
/// - 15: the phases of a cold load in order, `reconnecting` with a handle held
///   while offline, one `db3:ready` per subscribe, `idle` after the last
///   dispose, no state event repeating the last, a handle hearing only its id.
/// - 16: `ready` rejects `DB3_READY_TIMEOUT` with every frame dropped, and a
///   page stream slowed past the budget still reaches `live`.
/// - 40: two subscribes while the open is in flight share one `record.open`;
///   disposing one before `record.opened` leaves the other to resolve.
final class Db3LifecycleLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-lifecycle-4701")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private static func ulid() -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        return "01" + String((0..<24).map { _ in alphabet[Int.random(in: 0..<32)] })
    }

    private func subscribers(_ id: String) async throws -> Int {
        (try await live.route(id, "state")["subscribers"] as? [Any])?.count ?? -1
    }

    private func subscribersBecome(_ id: String, _ count: Int) async throws {
        var last = -1
        try await eventually(timeout: 15, description: "\(count) room subscriber(s) of \(id) (last \(last))") {
            last = try await self.subscribers(id)
            return last == count
        }
    }

    /// A db3 created by its own client, with `rows` notes written through the room's `submit` route, paged `pageRows` to a page.
    private func written(_ rows: Int, pageRows: Int = 100) async throws -> String {
        let creator = try await live.client("creator-\(Self.ulid().suffix(4))", models: [Self.note])
        let documentId = try await live.createDocument(creator)
        _ = try await live.route(documentId, "set-limits", ["segmentQuietMs": 3_600_000, "catchUpPageRows": pageRows])
        let writer = Self.ulid()
        var seq = 0
        var at = 1
        while at <= rows {
            let count = min(500, rows - at + 1)
            let mutations: [[String: Any]] = (at..<(at + count)).map { n in
                ["model": "Note", "id": String(format: "p%06d", n), "kind": "create", "fields": ["title": "row \(n)"]]
            }
            let state = try await live.route(documentId, "state")
            let epochs = state["epochs"] as? [String: Any] ?? [:]
            seq += 1
            let answered = try await live.route(documentId, "submit", [
                "writer": writer,
                "entry": [
                    "seq": seq, "e": (epochs["current"] as? NSNumber)?.intValue ?? 1, "k": (state["lsn"] as? NSNumber)?.intValue ?? 0,
                    "m": mutations[0], "also": Array(mutations.dropFirst()),
                ] as [String: Any],
            ])
            XCTAssertEqual((answered["outcome"] as? [String: Any])?["status"] as? String, "accepted")
            at += count
        }
        return documentId
    }

    /// Every `db3:state` and `db3:ready` a client emits.
    final class Heard: @unchecked Sendable {
        let states = ThreadSafeBox<[Db3State]>([])
        let readies = ThreadSafeBox<[String]>([])
        private var subscriptions: [EventSubscription] = []

        init(_ client: JsBaoClient) {
            subscriptions.append(client.eventEmitter.subscribe(Db3StateEvent.self) { [states] event in
                states.mutate { $0.append(event.state) }
            })
            subscriptions.append(client.eventEmitter.subscribe(Db3ReadyEvent.self) { [readies] event in
                readies.mutate { $0.append(event.id) }
            })
        }

        func of(_ id: String) -> [Db3State] { states.value.filter { $0.id == id } }
        func readies(_ id: String) -> Int { readies.value.filter { $0 == id }.count }
    }

    /// Drop every record frame of `id` before the client's session sees it, until the answered stop is called.
    private func drop(_ client: JsBaoClient, _ id: String) -> @Sendable () -> Void {
        let on = ThreadSafeBox(true)
        client.recordLogFrameGateForTest = { frame in
            !(on.value && frame["documentId"]?.stringValue == id)
        }
        return { on.mutate { $0 = false } }
    }

    private func code(_ body: () async throws -> Void) async -> String {
        do {
            try await body()
            return "resolved"
        } catch {
            return (error as? JsBaoError)?.code.rawValue ?? "\(error)"
        }
    }

    // MARK: - Behaviour 14

    func testOneRoomSubscriberPerClientInEveryDisposeOrder() async throws {
        let x = try await live.client("x", models: [Self.note])
        let id = try await live.createDocument(x)
        let y = try await live.client("y", models: [Self.note])
        let a1 = try x.db3.subscribe(id)
        XCTAssertEqual(a1.id, id)
        try await a1.ready()
        XCTAssertEqual(a1.state.phase, .live)
        XCTAssertTrue(a1.state.subscribed)
        let a2 = try x.db3.subscribe(id)
        try await a2.ready()
        try await subscribersBecome(id, 1)
        let b1 = try y.db3.subscribe(id)
        try await b1.ready()
        try await subscribersBecome(id, 2)

        // x's first handle first: x still holds a2.
        a1.dispose()
        a1.dispose()
        try await delay(0.5)
        do {
            let got = try await subscribers(id)
            XCTAssertEqual(got, 2)
        }
        b1.dispose()
        try await subscribersBecome(id, 1)
        a2.dispose()
        a2.dispose()
        try await subscribersBecome(id, 0)
        try await eventually(description: "x to read unsubscribed") { a2.state.subscribed == false && a2.state.phase == .idle }

        // Interleaved with a third handle.
        let c1 = try x.db3.subscribe(id)
        let d1 = try y.db3.subscribe(id)
        let c2 = try x.db3.subscribe(id)
        try await c1.ready()
        try await d1.ready()
        try await c2.ready()
        try await subscribersBecome(id, 2)
        c1.dispose()
        try await delay(0.5)
        do {
            let got = try await subscribers(id)
            XCTAssertEqual(got, 2)
        }
        d1.dispose()
        try await subscribersBecome(id, 1)
        c2.dispose()
        try await subscribersBecome(id, 0)

        // unsubscribe(id) disposes every handle of this client.
        let e1 = try x.db3.subscribe(id)
        let e2 = try x.db3.subscribe(id)
        try await e1.ready()
        try await e2.ready()
        try await subscribersBecome(id, 1)
        x.db3.unsubscribe(id)
        try await subscribersBecome(id, 0)
        try await eventually(description: "the handles to read unsubscribed") {
            e1.state.subscribed == false && e2.state.subscribed == false
        }
        // The store stays bound: the db3 is resident and unsubscribed.
        XCTAssertTrue(x.isRecordLogDocument(id))
        let state = try await x.db3.state(id)
        XCTAssertTrue(state.resident)
        XCTAssertFalse(state.subscribed)
    }

    func testRefreshCatchesAResidentDb3UpAndLeavesTheCountAsItWas() async throws {
        let id = try await written(3)
        let x = try await live.client("x", models: [Self.note])
        let y = try await live.client("y", models: [Self.note])
        let first = try x.db3.subscribe(id)
        try await first.ready()
        first.dispose()
        try await subscribersBecome(id, 0)
        let held = try y.db3.subscribe(id)
        try await held.ready()
        try await subscribersBecome(id, 1)
        // Three more rows while x is unsubscribed.
        let writer = Self.ulid()
        for (seq, title) in ["four", "five", "six"].enumerated() {
            let state = try await live.route(id, "state")
            let epochs = state["epochs"] as? [String: Any] ?? [:]
            _ = try await live.route(id, "submit", [
                "writer": writer,
                "entry": [
                    "seq": seq + 1, "e": (epochs["current"] as? NSNumber)?.intValue ?? 1,
                    "k": (state["lsn"] as? NSNumber)?.intValue ?? 0,
                    "m": ["model": "Note", "id": "q\(seq)", "kind": "create", "fields": ["title": title]] as [String: Any],
                ] as [String: Any],
            ])
        }
        let roomLsn = try await live.roomLsn(id)
        XCTAssertLessThan(try live.marks(x, id).cursor, roomLsn)
        let heard = Heard(x)
        let state = try await x.db3.refresh(id)
        XCTAssertEqual(try live.marks(x, id).cursor, roomLsn)
        XCTAssertEqual(state.id, id)
        XCTAssertTrue(state.resident)
        XCTAssertFalse(state.subscribed)
        XCTAssertEqual(state.cursor, roomLsn)
        XCTAssertEqual(state.rows, 6)
        let phases = heard.of(id).map(\.phase)
        let liveAt = try XCTUnwrap(phases.firstIndex(of: .live), "\(phases)")
        XCTAssertGreaterThan(try XCTUnwrap(phases.lastIndex(of: .idle)), liveAt)
        try await subscribersBecome(id, 1)
        XCTAssertTrue(held.state.subscribed)
    }

    // MARK: - Behaviour 15

    func testThePhasesOfAColdLoadReconnectingAndOneReadyPerSubscribe() async throws {
        let id = try await written(2_000, pageRows: 100)
        let x = try await live.client("x", models: [Self.note])
        let heard = Heard(x)
        let handle = try x.db3.subscribe(id)
        try await handle.ready()
        let cold = heard.of(id)
        XCTAssertEqual(cold.first?.phase, .opening, "\(cold.map(\.phase))")
        let loadingAt = try XCTUnwrap(cold.firstIndex { $0.phase == .loading || $0.phase == .catchingUp }, "\(cold.map(\.phase))")
        XCTAssertGreaterThan(loadingAt, 0)
        XCTAssertNotNil(cold[loadingAt...].first { $0.progress != nil }?.progress, "a progress step while loading")
        XCTAssertGreaterThan(try XCTUnwrap(cold.firstIndex { $0.phase == .live }), loadingAt)
        XCTAssertEqual(heard.readies(id), 1)

        x.setNetworkMode(.offline)
        try await eventually(timeout: 15, description: "reconnecting while offline") { handle.state.phase == .reconnecting }
        x.setNetworkMode(.online)
        try await eventually(timeout: 30, description: "live again") { handle.state.phase == .live }
        XCTAssertEqual(heard.readies(id), 1, "one db3:ready per subscribe, not per reconnect")
        let again = try x.db3.subscribe(id)
        try await again.ready()
        XCTAssertEqual(heard.readies(id), 2)
        handle.dispose()
        again.dispose()
        try await eventually(description: "idle after the last dispose") { heard.of(id).last?.phase == .idle }
        let last = try XCTUnwrap(heard.of(id).last)
        XCTAssertFalse(last.subscribed)
        XCTAssertTrue(last.resident)

        let all = heard.of(id)
        for state in all where state.phase != .loading && state.phase != .catchingUp {
            XCTAssertNil(state.progress, "\(state)")
        }
        for (a, b) in zip(all, all.dropFirst()) { XCTAssertNotEqual(a, b, "a state event repeated the last") }
    }

    func testAHandleHearsOnlyItsOwnDb3() async throws {
        let x = try await live.client("x", models: [Self.note])
        let one = try await live.createDocument(x)
        let two = try await live.createDocument(x)
        let h1 = try x.db3.subscribe(one)
        let seen = ThreadSafeBox<[String]>([])
        let observation = h1.observe { event in
            if case .state(let state) = event { seen.mutate { $0.append(state.id) } }
        }
        let h2 = try x.db3.subscribe(two)
        try await h1.ready()
        try await h2.ready()
        XCTAssertFalse(seen.value.isEmpty)
        XCTAssertEqual(Set(seen.value), [one])
        observation.cancel()
    }

    // MARK: - Behaviour 16

    func testReadyTimesOutWithNoProgressAndASlowedStreamReArmsIt() async throws {
        let id = try await written(2_000, pageRows: 100)
        let x = try await live.client("x", models: [Self.note])
        let stop = drop(x, id)
        let stalled = try x.db3.subscribe(id, options: Db3SubscribeOptions(readyTimeout: 1.5))
        let startedAt = Date()
        do {
            let got = await code { try await stalled.ready() }
            XCTAssertEqual(got, "DB3_READY_TIMEOUT")
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 1.4)
        do {
            let got = await code { try await stalled.available() }
            XCTAssertEqual(got, "DB3_READY_TIMEOUT")
        }
        stalled.dispose()
        stop()

        let y = try await live.client("y", models: [Self.note])
        y.recordLogFrameGateForTest = { frame in
            if frame["documentId"]?.stringValue == id, frame["type"]?.stringValue == "record.catchUpPage" {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            return true
        }
        let slow = try y.db3.subscribe(id, options: Db3SubscribeOptions(readyTimeout: 1))
        let began = Date()
        try await slow.ready()
        XCTAssertGreaterThan(Date().timeIntervalSince(began), 1)
        XCTAssertEqual(slow.state.phase, .live)
    }

    // MARK: - Edge 40

    func testTwoSubscribesInFlightShareOneOpenAndAnEarlyDisposeLeavesTheOther() async throws {
        let x = try await live.client("x", models: [Self.note])
        let id = try await live.createDocument(x)
        let y = try await live.client("y", models: [Self.note])
        let watch = RecordLogClientWatch(y)
        let release = RecordLogReceiptHarness.Gate()
        y.recordLogFrameGateForTest = { frame in
            if frame["documentId"]?.stringValue == id, frame["type"]?.stringValue == "record.opened" { await release.wait() }
            return true
        }
        let first = try y.db3.subscribe(id)
        let second = try y.db3.subscribe(id)
        try await eventually(timeout: 15, description: "the open to go out") {
            !watch.sent("record.open").filter { $0["documentId"]?.stringValue == id }.isEmpty
        }
        first.dispose()
        do {
            let got = await code { try await first.ready() }
            XCTAssertEqual(got, "DB3_DISPOSED")
        }
        release.open()
        try await second.ready()
        XCTAssertEqual(second.state.phase, .live)
        XCTAssertEqual(watch.sent("record.open").filter { $0["documentId"]?.stringValue == id }.count, 1)
        try await subscribersBecome(id, 1)
    }
}
