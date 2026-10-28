import XCTest
@testable import JsBaoClient

/// #4701 behaviour 32 — `client.db3.indexes` against the dev server, and when
/// the client reads a db3's index list:
///
/// - `list`, `register` and `drop` answer the route's shapes (a registration,
///   a unique composite with a name, a drop), and refuse as the route does
///   (`DB3_INDEX_NOT_UNIQUE` over duplicates, `NOT_A_DB3` on a format-1
///   document), each refusal an `HttpError` carrying the route's code;
/// - after a subscribe the store's view indexes equal the room's list, and a
///   registration made while unsubscribed reaches the store at the next
///   subscribe;
/// - binding a stored db3 at start-up reads no list; the first read is the
///   subscribe's.
final class Db3IndexesLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(name: "Note", fields: [
        "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string),
        "a": FieldDescriptor(type: .string), "b": FieldDescriptor(type: .string),
        "email": FieldDescriptor(type: .string),
    ])

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-indexes-4701")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func tuples(_ indexes: [Db3Index]) -> [RecordLogIndexTuple] {
        indexes.map { RecordLogIndexTuple(model: $0.model, fields: $0.fields, unique: $0.unique) }
            .sorted { ($0.model, $0.fields.joined(separator: "\u{1}")) < ($1.model, $1.fields.joined(separator: "\u{1}")) }
    }

    private func refusal(_ body: () async throws -> Void) async -> (status: Int, code: String?) {
        do {
            try await body()
            return (0, nil)
        } catch let error as HttpError {
            return (error.status, error.serverCode)
        } catch {
            return (-1, "\(error)")
        }
    }

    func testListRegisterAndDropAnswerAndRefuseAsTheRoutesDo() async throws {
        let id = try await live.db3Written(0, model: "Note")
        let x = try await live.client("x", models: [Self.note])

        let email = try await x.db3.indexes.register(id, Db3IndexRegistration(model: "Note", field: "email"))
        XCTAssertEqual(email.model, "Note")
        XCTAssertEqual(email.fields, ["email"])
        XCTAssertFalse(email.unique)
        XCTAssertEqual(email.origins, [Db3IndexOrigin(kind: .named, unique: false)])
        let composite = try await x.db3.indexes.register(
            id, Db3IndexRegistration(model: "Note", fields: ["a", "b"], unique: true, name: "by_ab")
        )
        XCTAssertEqual(composite.fields, ["a", "b"])
        XCTAssertTrue(composite.unique)
        XCTAssertEqual(composite.name.lowercased(), "idx_named_note_by_ab")
        var listed = try await x.db3.indexes.list(id)
        XCTAssertEqual(listed.map(\.name), listed.map(\.name).sorted(), "sorted by name")
        XCTAssertTrue(listed.contains { $0.name == email.name })
        XCTAssertTrue(listed.contains { $0.name == composite.name })
        try await x.db3.indexes.drop(id, name: email.name)
        listed = try await x.db3.indexes.list(id)
        XCTAssertFalse(listed.contains { $0.name == email.name })

        // Refused as the routes refuse: two records share an email.
        let state = try await live.route(id, "state")
        let epochs = state["epochs"] as? [String: Any] ?? [:]
        _ = try await live.route(id, "submit", [
            "writer": RecordLogLiveApp.ulid(),
            "entry": [
                "seq": 1, "e": (epochs["current"] as? NSNumber)?.intValue ?? 1, "k": (state["lsn"] as? NSNumber)?.intValue ?? 0,
                "m": ["model": "Note", "id": "d1", "kind": "create", "fields": ["email": "dup@x"]] as [String: Any],
                "also": [["model": "Note", "id": "d2", "kind": "create", "fields": ["email": "dup@x"]] as [String: Any]],
            ] as [String: Any],
        ])
        let duplicates = await refusal {
            _ = try await x.db3.indexes.register(id, Db3IndexRegistration(model: "Note", field: "email", unique: true))
        }
        XCTAssertEqual(duplicates.code, "DB3_INDEX_NOT_UNIQUE", "\(duplicates)")
        let formatOne = try await ctx.createDocument(appId: live.app.appId, jwt: live.app.ownerJWT, title: "format-1")
        let notADb3 = await refusal { _ = try await x.db3.indexes.list(formatOne) }
        XCTAssertEqual(notADb3.status, 409)
        XCTAssertEqual(notADb3.code, "NOT_A_DB3")
    }

    func testTheStoreFollowsTheRoomsListFromTheSubscribeAndAStartUpBindingReadsNone() async throws {
        let id = try await live.db3Written(0, model: "Note")
        let file = live.file("indexes")
        let x = try await live.client("x", models: [Self.note], file: file)
        _ = try await x.db3.indexes.register(id, Db3IndexRegistration(model: "Note", field: "email"))
        let handle = try x.db3.subscribe(id)
        try await handle.ready()
        let room = tuples(try await x.db3.indexes.list(id))
        try await eventually(timeout: 20, description: "the store to hold the room's list after the subscribe") {
            try self.live.binding(x, id).store.indexTuples() == room
        }
        handle.dispose()
        try await eventually(description: "unsubscribed") { try await !x.db3.state(id).subscribed }

        // Registered while unsubscribed: in the store at the next subscribe.
        _ = try await x.db3.indexes.register(id, Db3IndexRegistration(model: "Note", field: "a"))
        let withA = tuples(try await x.db3.indexes.list(id))
        XCTAssertNotEqual(try live.binding(x, id).store.indexTuples(), withA)
        await x.destroy()

        // A new client over the same file binds the db3 at start-up and reads no list until it subscribes.
        let reads = ThreadSafeBox<[String]>([])
        let x2 = createTestClient(
            appId: live.app.appId, token: live.app.ownerJWT, storageConfig: .sqlite(directory: file), autoNetwork: true
        )
        x2.db3IndexReadForTest = { documentId in reads.mutate { $0.append(documentId) } }
        x2.registerModels([Self.note])
        _ = await x2.waitForStorageReady()
        try await x2.connect()
        try await waitForConnection(client: x2, timeout: 10)
        XCTAssertTrue(x2.isRecordLogDocument(id))
        try await delay(0.5)
        XCTAssertEqual(reads.value, [], "binding a stored db3 reads no index list")
        let again = try x2.db3.subscribe(id)
        try await again.ready()
        try await eventually(timeout: 20, description: "the store to hold the registration after the next subscribe") {
            try self.live.binding(x2, id).store.indexTuples() == withA
        }
        XCTAssertEqual(reads.value.first, id)
        again.dispose()
        await x2.destroy()
    }
}
