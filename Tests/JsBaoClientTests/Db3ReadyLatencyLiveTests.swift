import XCTest
@testable import JsBaoClient

/// #5101 behaviour 19 (measurement, principle 9) — warm
/// `subscribe(_:).ready()` on the Swift client, against the dev server: the
/// p50 over 50 subscriptions of a db3 this client already holds, each
/// disposed and closed on the room before the next. `ready()` waits for the
/// open's index list (and its declaration's acknowledgment) since #5101; the
/// figure is printed, not bounded.
final class Db3ReadyLatencyLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string, indexed: true)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-ready-latency-5101")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    func testWarmSubscribeToReadyP50IsPrinted() async throws {
        let id = try await live.db3Written(3, model: "Note")
        let c = try await live.client("latency", models: [Self.note])
        let warm = try c.db3.subscribe(id)
        try await warm.ready()
        warm.dispose()
        try await live.subscribersBecome(id, 0)

        var samples: [Double] = []
        for _ in 0..<50 {
            let started = Date()
            let handle = try c.db3.subscribe(id)
            try await handle.ready()
            samples.append(Date().timeIntervalSince(started) * 1000)
            handle.dispose()
            try await eventually(description: "unsubscribed") { try await !c.db3.state(id).subscribed }
            try await live.subscribersBecome(id, 0)
        }
        let sorted = samples.sorted()
        let p50 = sorted[sorted.count / 2]
        print(String(format: "[db3-ready-latency-5101] warm subscribe→ready p50 %.1f ms (n=%d, min %.1f, max %.1f)",
                     p50, sorted.count, sorted.first ?? 0, sorted.last ?? 0))
        XCTAssertEqual(samples.count, 50)
    }
}
