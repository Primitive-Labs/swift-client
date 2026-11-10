import XCTest
@testable import JsBaoClient

/// #5112 behaviors 15 and 16 — on a client holding three stored db3 copies,
/// against the dev server: `maxDocs: 0` through `client.db3.setRetentionPolicy`
/// throws `.invalidArgument` and evicts nothing, where it used to evict every
/// copy; a `nil` cap evicts nothing; `maxDocs: 1` then evicts two.
///
/// `lastOpenedAt` has second precision, so the uses are spaced more than a
/// second apart.
final class Db3RetentionCapRefusalLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-retention-cap-5112")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// A client holding three stored, unsubscribed db3 copies, used in order.
    private func holding() async throws -> (JsBaoClient, [String]) {
        let ids = [
            try await live.db3Written(0, model: "Note"),
            try await live.db3Written(0, model: "Note"),
            try await live.db3Written(0, model: "Note"),
        ]
        let x = try await live.client("x", models: [Self.note])
        for id in ids {
            try await live.residentOn(x, id)
            try await delay(1.1)
        }
        let stored = try await storedIds(x)
        XCTAssertEqual(stored, ids.sorted())
        return (x, ids)
    }

    private func evictions(_ client: JsBaoClient) -> (ThreadSafeBox<[Db3EvictedEvent]>, () -> Void) {
        let seen = ThreadSafeBox<[Db3EvictedEvent]>([])
        let heard = client.eventEmitter.subscribe(Db3EvictedEvent.self) { event in seen.mutate { $0.append(event) } }
        return (seen, { heard.cancel() })
    }

    private func storedIds(_ client: JsBaoClient) async throws -> [String] {
        try await client.db3.stored().map(\.id).sorted()
    }

    // MARK: - Behavior 15

    func testZeroIsRefusedAndEvictsNoCopy() async throws {
        let (x, ids) = try await holding()
        let (evicted, stop) = evictions(x)
        defer { stop() }
        XCTAssertThrowsError(try x.db3.setRetentionPolicy(RetentionPolicy(maxDocs: 0))) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument)
        }
        await x.retentionEnforcement?.value
        try await delay(0.3)
        let left = try await storedIds(x)
        XCTAssertEqual(left, ids.sorted())
        XCTAssertEqual(evicted.value, [])
    }

    // MARK: - Behavior 16

    func testANilCapEvictsNothingAndOneEvictsTwo() async throws {
        let (x, ids) = try await holding()
        let (evicted, stop) = evictions(x)
        defer { stop() }
        try x.db3.setRetentionPolicy(RetentionPolicy())
        await x.retentionEnforcement?.value
        var left = try await storedIds(x)
        XCTAssertEqual(left, ids.sorted())
        XCTAssertEqual(evicted.value, [])

        try x.db3.setRetentionPolicy(RetentionPolicy(maxDocs: 1))
        await x.retentionEnforcement?.value
        left = try await storedIds(x)
        XCTAssertEqual(left, [ids[2]])
        XCTAssertEqual(Set(evicted.value.map(\.id)), Set([ids[0], ids[1]]))
        XCTAssertTrue(evicted.value.allSatisfy { $0.reason == .retention })
    }
}
