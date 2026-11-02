import XCTest
@testable import JsBaoClient

/// #5155 behaviour 35 — a db3 that lives only on this device, through a real
/// authenticated Swift client against the dev server, with networking on.
///
/// Every request the client's API transport sends and every frame its socket
/// sends are logged by a pass-through observer, from each client's
/// construction on. Across a create, saves and a query, a subscribe and its
/// dispose, a new client over the same store reading the rows, and a delete,
/// none of them names the db3; the server has no record of it (`GET db3/:id`
/// by its owner answers 404) and `listMine()` does not list it.
final class Db3LocalOnlyLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string),
            "slug": FieldDescriptor(type: .string, unique: true),
        ]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-local-only-5155")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// What a client sent: each request's method, path and body, and each socket frame.
    private final class Traffic: @unchecked Sendable {
        let requests = LockedBox<[String]>([])
        let frames = LockedBox<[String]>([])

        func naming(_ id: String) -> [String] {
            requests.value.filter { $0.contains(id) } + frames.value.filter { $0.contains(id) }
        }
    }

    /// A connected client over `file`, its traffic logged from its construction on.
    private func observedClient(file: String, traffic: Traffic) async throws -> JsBaoClient {
        let client = createTestClient(
            appId: live.app.appId, token: live.app.ownerJWT, storageConfig: .sqlite(directory: file), autoNetwork: true
        )
        client.observeTrafficForTest(
            requests: { method, path, body in
                traffic.requests.withValue {
                    $0.append("\(method.rawValue) \(path) \(body.map { String(decoding: $0, as: UTF8.self) } ?? "")")
                }
            },
            frames: { frame in traffic.frames.withValue { $0.append(frame) } }
        )
        client.registerModels([Self.note])
        _ = await client.waitForStorageReady()
        try await client.connect()
        try await waitForConnection(client: client, timeout: 10)
        return client
    }

    func testNothingNamingALocalOnlyDb3LeavesARealClient() async throws {
        let traffic = Traffic()
        let file = live.file("local-only")
        let first = try await observedClient(file: file, traffic: traffic)

        let info = try await first.db3.create(title: "Only here", localOnly: true)
        XCTAssertTrue(info.localOnly)
        let notes = try XCTUnwrap(first.sharedModel("Note")?.member(docId: info.id))
        _ = try await notes.save(id: "n1", values: ["title": .string("one"), "slug": .string("a")], confirm: true)
        _ = try notes.save(id: "n2", values: ["title": .string("two"), "slug": .string("b")])
        XCTAssertEqual(try notes.query().compactMap { $0["id"]?.stringValue }.sorted(), ["n1", "n2"])
        let sub = try first.db3.subscribe(info.id)
        try await sub.ready()
        XCTAssertEqual(sub.state.phase, .live)
        sub.dispose()
        // Some traffic did go out over this time (the connection's own).
        try await Task.sleep(nanoseconds: 500_000_000)
        await first.destroy()

        let second = try await observedClient(file: file, traffic: traffic)
        try await eventually(timeout: 10, description: "the stored local-only db3 bound at start-up") {
            try await second.db3.state(info.id).resident
        }
        let stored = try await second.db3.stored()
        XCTAssertEqual(stored.filter { $0.id == info.id }.map(\.localOnly), [true])
        let again = try XCTUnwrap(second.sharedModel("Note")?.member(docId: info.id))
        XCTAssertEqual(try again.query().compactMap { $0["id"]?.stringValue }.sorted(), ["n1", "n2"])

        let listed = try await second.db3.listMine()
        XCTAssertFalse(listed.items.contains { $0.id == info.id }, "listMine() never lists it")
        do {
            _ = try await ctx.appRequest(method: "GET", appId: live.app.appId, path: "/db3/\(info.id)", body: nil, jwt: live.app.ownerJWT)
            XCTFail("the server has no record of a local-only db3")
        } catch {
            XCTAssertTrue(String(describing: error).contains("HTTP 404"), "\(error)")
        }

        _ = try await second.db3.delete(info.id)
        let afterDelete = try await second.db3.stored()
        XCTAssertFalse(afterDelete.contains { $0.id == info.id })
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertFalse(traffic.requests.value.isEmpty, "the observer heard the client's requests")
        XCTAssertFalse(traffic.frames.value.isEmpty, "the observer heard the client's socket frames")
        XCTAssertEqual(traffic.naming(info.id), [], "nothing sent named the local-only db3")
        await second.destroy()
    }
}
