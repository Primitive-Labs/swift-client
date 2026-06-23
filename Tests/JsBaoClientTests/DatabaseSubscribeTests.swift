import XCTest
@testable import JsBaoClient

/// Live integration coverage for `client.databases.subscribe` (#952 / #1058).
///
/// Port of tests/client/js-bao-client-database-subscriptions.test.ts (the JS
/// client is the source of truth for the `db.subscribe` / `db.change` wire
/// contract, including the #737 origin-attribution fields).
final class DatabaseSubscribeTests: XCTestCase {
    /// Minimal TOML schema covering the Task model the tests mutate — the
    /// issue-#666 op-edit gate requires a schema on the type config before
    /// registered ops can be created.
    static let taskSchema = """
    [models.Task.fields]
    id = { type = "string" }
    title = { type = "string" }
    """

    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!
    var databaseId: String!
    let databaseType = "swiftTaskDB"

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-db-subscribe")
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)

        // Type config FIRST (with schema) — implicit auto-create on
        // `POST /databases` would materialize a schemaless type and the op
        // gate would refuse the seed op with 422 (mirrors the JS setup).
        _ = try await client.makeRequest("POST", "/databases/types", [
            "databaseType": databaseType,
            "schema": Self.taskSchema,
        ])

        let db = try await client.databases.create(params: CreateDatabaseParams(
            title: "Swift DB Subs",
            databaseType: databaseType
        ))
        databaseId = db.databaseId

        // Seed mutation op the tests use to trigger changes.
        _ = try await client.makeRequest("POST", "/databases/types/\(databaseType)/operations", [
            "name": "seed_save",
            "type": "mutation",
            "modelName": "$params.modelName",
            "access": "true",
            "definition": [
                "operations": [["op": "save", "id": "$params.id", "data": "$params.data"]],
            ],
            "params": [
                "modelName": ["type": "string", "required": true],
                "id": ["type": "string", "required": true],
                "data": ["type": "object", "required": false],
            ],
        ])

        try await client.connect()
        try await waitForConnection(client: client, timeout: 10)
    }

    override func tearDown() async throws {
        await client?.destroy()
        if let ctx: TestContext = ctx { await ctx.cleanup() }
    }

    // MARK: - Helpers

    private func createSubscription(key: String) async throws {
        _ = try await client.makeRequest("POST", "/databases/types/\(databaseType)/subscriptions", [
            "subscriptionKey": key,
            "displayName": "Swift \(key)",
            "modelName": "Task",
            "filter": "record.modelName == 'Task'",
            "access": "true",
        ])
    }

    private func saveTask(id: String, title: String) async throws {
        _ = try await client.databases.executeOperation(
            databaseId: databaseId,
            name: "seed_save",
            options: ExecuteOperationOptions(params: .object([
                "modelName": .string("Task"),
                "id": .string(id),
                "data": .object(["id": .string(id), "title": .string(title)]),
            ]))
        )
    }

    /// Thread-safe event collector for the `onChange` callback.
    final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [DatabaseChangePayload] = []
        func append(_ e: DatabaseChangePayload) {
            lock.lock(); events.append(e); lock.unlock()
        }
        var all: [DatabaseChangePayload] {
            lock.lock(); defer { lock.unlock() }; return events
        }
    }

    // MARK: - Tests

    /// Happy path: subscribe → mutate through the SAME client → `onChange`
    /// fires with the full JS event shape, including #737 origin attribution
    /// (the write rode this client's `X-JB-Connection-Id`, so `isOrigin` and
    /// `isOriginUser` are both true).
    func testSubscribeReceivesChangeWithOriginAttribution() async throws {
        try await createSubscription(key: "swift-basic-v1")

        let box = EventBox()
        let unsub = try client.databases.subscribe(
            databaseId: databaseId,
            subscriptionKey: "swift-basic-v1",
            options: DatabaseSubscribeOptions { box.append($0) }
        )
        defer { unsub() }

        // Allow db.subscribe to go over the wire.
        try await delay(0.6)

        let taskId = "sw_" + UUID().uuidString.prefix(8)
        try await saveTask(id: String(taskId), title: "hi")

        try await eventually(timeout: 10, description: "db.change frame for \(taskId)") {
            box.all.contains { e in
                e.changes.contains { $0.op == "save" && $0.modelName == "Task" && $0.id == String(taskId) }
            }
        }

        guard let evt = box.all.first(where: { e in
            e.changes.contains { $0.id == String(taskId) }
        }) else {
            XCTFail("change event vanished after eventually() passed")
            return
        }
        XCTAssertEqual(evt.databaseId, databaseId)
        XCTAssertEqual(evt.subscriptionKey, "swift-basic-v1")
        XCTAssertFalse(evt.timestamp.isEmpty)
        // Origin attribution (#737): the write went through this client's
        // HTTP layer, which forwards the WS connection id.
        XCTAssertEqual(evt.originUserId, testApp.ownerUserId)
        XCTAssertTrue(evt.isOriginUser)
        XCTAssertTrue(evt.isOrigin)

        let change = evt.changes.first { $0.id == String(taskId) }
        XCTAssertEqual(change?.op, "save")
        XCTAssertEqual(change?.modelName, "Task")
        XCTAssertNil(change?.previousData, "previousData must be nil for a create")
        let data = change?.data as? [String: Any]
        XCTAssertEqual(data?["title"] as? String, "hi")
    }

    /// Edge: after `unsub()` the callback must stop receiving frames; a
    /// second live subscription on the same connection keeps working
    /// (independent routing by subscriptionKey).
    func testUnsubscribeStopsDeliveryOtherSubsUnaffected() async throws {
        try await createSubscription(key: "swift-unsub-v1")
        try await createSubscription(key: "swift-keep-v1")

        let unsubBox = EventBox()
        let keepBox = EventBox()
        let unsub = try client.databases.subscribe(
            databaseId: databaseId,
            subscriptionKey: "swift-unsub-v1",
            options: DatabaseSubscribeOptions { unsubBox.append($0) }
        )
        let keepUnsub = try client.databases.subscribe(
            databaseId: databaseId,
            subscriptionKey: "swift-keep-v1",
            options: DatabaseSubscribeOptions { keepBox.append($0) }
        )
        defer { keepUnsub() }
        try await delay(0.6)

        // Both subs see the first write.
        let firstId = "su1_" + UUID().uuidString.prefix(8)
        try await saveTask(id: String(firstId), title: "first")
        try await eventually(timeout: 10, description: "both subs see first write") {
            let hit: (EventBox) -> Bool = { box in
                box.all.contains { $0.changes.contains { $0.id == String(firstId) } }
            }
            return hit(unsubBox) && hit(keepBox)
        }

        // Unsubscribe one; the other keeps receiving.
        unsub()
        try await delay(0.4)
        let countAfterUnsub = unsubBox.all.count

        let secondId = "su2_" + UUID().uuidString.prefix(8)
        try await saveTask(id: String(secondId), title: "second")
        try await eventually(timeout: 10, description: "kept sub sees second write") {
            keepBox.all.contains { $0.changes.contains { $0.id == String(secondId) } }
        }

        XCTAssertEqual(
            unsubBox.all.count, countAfterUnsub,
            "unsubscribed callback must not receive frames after unsub()"
        )
    }

    /// Edge: empty databaseId / subscriptionKey throw
    /// `JsBaoError(.invalidArgument)` (matches the JS `_subscribeDatabase`
    /// guards — tightened in the #1057 follow-up).
    func testSubscribeEmptyArgumentsThrow() async throws {
        XCTAssertThrowsError(try client.databases.subscribe(
            databaseId: "",
            subscriptionKey: "k",
            options: DatabaseSubscribeOptions { _ in }
        )) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument)
        }
        XCTAssertThrowsError(try client.databases.subscribe(
            databaseId: databaseId,
            subscriptionKey: "",
            options: DatabaseSubscribeOptions { _ in }
        )) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument)
        }
    }
}
