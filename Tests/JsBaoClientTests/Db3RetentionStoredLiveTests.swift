import XCTest
@testable import JsBaoClient

/// #5085 — the Swift retention policy over the db3 copies stored on this
/// device, against the dev server (#5071's rules):
///
/// - 1: with N stored copies and `maxDocs: M`, exactly `min(N, M)` remain, the
///   least recently used evicted first; a subscribed copy counts and stays.
/// - 2, 3 (intent repro A): only copies `client.db3.stored()` lists are counted
///   or evicted: a db3 row with no stored copy and a format-1 document take no
///   keep slot, and no `Db3EvictedEvent` fires for a copy that was not stored.
/// - 4a: an older subscribed db3 and a newer format-1 document under
///   `maxDocs: 1`: the format-1 document goes and the db3 stays, as before.
/// - 4b: older unheld stored db3s and a newer format-1 document under
///   `maxDocs: 1`: the format-1 document stays, as before, and the sweep
///   evicts the older copy (one event); `maxBytes` removes no db3 copy.
/// - 5085-C002: `ttl` with `maxDocs`: a db3 copy past the TTL goes before the
///   format-1 pass counts, as it did, so an undated format-1 row stays.
///
/// `lastOpenedAt` has second precision, so the uses are spaced more than a
/// second apart.
final class Db3RetentionStoredLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-retention-5085")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// Subscribe, wait for live, dispose; the next use is more than a second later.
    private func used(_ client: JsBaoClient, _ id: String) async throws {
        try await live.residentOn(client, id)
        try await delay(1.1)
    }

    /// Subscribe until live and keep it; the next use is more than a second later.
    private func held(_ client: JsBaoClient, _ id: String) async throws -> Db3Subscription {
        let handle = try client.db3.subscribe(id)
        try await handle.ready()
        try await delay(1.1)
        return handle
    }

    /// A format-1 document opened and closed on `client`; the next use is more than a second later.
    private func formatOne(_ client: JsBaoClient) async throws -> String {
        let created = try await client.createDocument(options: CreateDocumentOptions(title: "format 1"))
        let id = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        _ = try await client.openDocument(id, options: OpenDocumentOptions(waitForLoad: .local))
        _ = await client.closeDocument(id)
        try await delay(1.1)
        return id
    }

    private func evictions(_ client: JsBaoClient) -> (ThreadSafeBox<[Db3EvictedEvent]>, () -> Void) {
        let seen = ThreadSafeBox<[Db3EvictedEvent]>([])
        let heard = client.eventEmitter.subscribe(Db3EvictedEvent.self) { event in seen.mutate { $0.append(event) } }
        return (seen, { heard.cancel() })
    }

    /// Apply `policy` and wait for every retention run it started.
    private func apply(_ client: JsBaoClient, _ policy: RetentionPolicy) async {
        try! client.db3.setRetentionPolicy(policy)
        await client.retentionEnforcement?.value
    }

    private func storedIds(_ client: JsBaoClient) async throws -> [String] {
        try await client.db3.stored().map(\.id)
    }

    // MARK: - Behaviour 1

    func testMaxDocsLeavesMinOfNAndMTheSubscribedCopyCounted() async throws {
        let a = try await live.db3Written(0, model: "Note")
        let b = try await live.db3Written(0, model: "Note")
        let c = try await live.db3Written(0, model: "Note")
        let x = try await live.client("x", models: [Self.note])
        // A, the least recently used, is the subscribed one.
        let sub = try await held(x, a)
        try await used(x, b)
        try await used(x, c)
        let (evicted, stop) = evictions(x)
        defer { stop() }
        await apply(x, RetentionPolicy(maxDocs: 2))
        XCTAssertEqual(evicted.value, [Db3EvictedEvent(id: b, reason: .retention)])
        let left = try await storedIds(x)
        XCTAssertEqual(left, [a, c].sorted())
        XCTAssertTrue(sub.state.subscribed)
        await apply(x, RetentionPolicy(maxDocs: 3))
        XCTAssertEqual(evicted.value.count, 1, "two copies under a cap of three: nothing goes")
    }

    // MARK: - Behaviours 2 and 3 (intent repro A)

    func testOnlyStoredCopiesAreCountedOrEvicted() async throws {
        let a = try await live.db3Written(0, model: "Note")
        let b = try await live.db3Written(0, model: "Note")
        let c = try await live.db3Written(0, model: "Note")
        let ghost = try await live.db3Written(0, model: "Note")
        let x = try await live.client("x", models: [Self.note])
        // A db3 row with no stored copy, dated before everything, and a format-1 document.
        await x.documentManager.handleServerDocuments([["documentId": ghost, "title": "no copy here"]])
        x.noteDb3(ghost)
        XCTAssertEqual(x.documentManager.getMetadataIndex()[ghost]?.documentFormat, 3)
        _ = try await formatOne(x)
        try await used(x, a)
        try await used(x, b)
        // The last one stays subscribed.
        let sub = try await held(x, c)
        let before = try await storedIds(x)
        XCTAssertEqual(before, [a, b, c].sorted())
        let (evicted, stop) = evictions(x)
        defer { stop() }
        await apply(x, RetentionPolicy(maxDocs: 2))
        try await delay(0.3)
        XCTAssertEqual(evicted.value, [Db3EvictedEvent(id: a, reason: .retention)], "no event for the row with no copy")
        let after = try await storedIds(x)
        XCTAssertEqual(after, [b, c].sorted(), "exactly min(3, 2) copies remain")
        XCTAssertTrue(sub.state.subscribed)
    }

    // MARK: - Behaviour 4

    func testAnOlderSubscribedDb3LetsTheFormatOnePassGoOnToANewerDocument() async throws {
        let d = try await live.db3Written(0, model: "Note")
        let x = try await live.client("x", models: [Self.note])
        let sub = try await held(x, d)
        let f = try await formatOne(x)
        let (evicted, stop) = evictions(x)
        defer { stop() }
        await apply(x, RetentionPolicy(maxDocs: 1))
        XCTAssertNil(x.documentManager.getMetadataIndex()[f], "the format-1 document went, as before")
        XCTAssertEqual(evicted.value, [])
        let left = try await storedIds(x)
        XCTAssertEqual(left, [d])
        XCTAssertTrue(sub.state.subscribed)
    }

    func testOlderUnheldDb3sTakeTheFormatOneSlotsAndTheSweepEvictsTheOlderCopy() async throws {
        let d1 = try await live.db3Written(0, model: "Note")
        let d2 = try await live.db3Written(0, model: "Note")
        let x = try await live.client("x", models: [Self.note])
        try await used(x, d1)
        try await used(x, d2)
        let f = try await formatOne(x)
        let (evicted, stop) = evictions(x)
        defer { stop() }
        await apply(x, RetentionPolicy(maxDocs: 1))
        XCTAssertNotNil(x.documentManager.getMetadataIndex()[f], "the db3 rows took the format-1 pass's slots, as before")
        XCTAssertEqual(evicted.value, [Db3EvictedEvent(id: d1, reason: .retention)], "the sweep removed the older copy, once")
        let left = try await storedIds(x)
        XCTAssertEqual(left, [d2])

        await apply(x, RetentionPolicy(maxBytes: 1))
        XCTAssertEqual(evicted.value.count, 1, "maxBytes removes no db3 copy")
        let still = try await storedIds(x)
        XCTAssertEqual(still, [d2])
    }

    // MARK: - ttl with maxDocs (5085-C002)

    func testAnExpiredCopyLeavesTheFormatOneCountAsBeforeUnderTtlAndMaxDocs() async throws {
        let d = try await live.db3Written(0, model: "Note")
        let x = try await live.client("x", models: [Self.note])
        try await used(x, d)
        try await delay(1.0)
        // A format-1 row no open has dated: the oldest in the format-1 pass's order.
        let f = UUID().uuidString
        await x.documentManager.handleServerDocuments([["documentId": f, "title": "undated"]])
        let row = try XCTUnwrap(x.documentManager.getMetadataIndex()[f])
        XCTAssertNil(row.lastOpenedAt)
        XCTAssertNotEqual(row.documentFormat, 3)
        let (evicted, stop) = evictions(x)
        defer { stop() }
        await apply(x, RetentionPolicy(ttl: 1, maxDocs: 1))
        XCTAssertNotNil(x.documentManager.getMetadataIndex()[f], "the expired copy went before the count: one row under maxDocs 1, as before")
        XCTAssertEqual(evicted.value, [Db3EvictedEvent(id: d, reason: .retention)], "evicted once")
        let left = try await storedIds(x)
        XCTAssertEqual(left, [])
    }
}
