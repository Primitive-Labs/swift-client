import XCTest
@testable import JsBaoClient

/// #5070 behavior 4 and E12 — a grant change on an open db3 reaches the Swift
/// client's state, against the dev server.
///
/// - 4: a member subscribed `live` is downgraded to `reader` by the owner and,
///   with no write of its own, hears a `Db3StateEvent` with `.reader` within
///   5 s; `client.db3.state(id)` answers it. Upgraded again, `.readWrite`. The
///   phase stays `.live` throughout.
/// - E12 (pin): a permission heard for a format-1 document emits its
///   `PermissionEvent` and no `Db3StateEvent`.
final class Db3PermissionStateLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note",
        fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-perm-state-5070")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func until(
        _ what: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for: \(what)", file: file, line: line)
    }

    func testADowngradeAndAnUpgradeReachTheStateWithNoWrite() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let db3Id = try await createdOnServer(owner, title: "Permission state").id
        let bob = try await ctx.createTestUser(appId: live.app.appId)
        _ = try await owner.db3.permissions(db3Id).set(.user(bob.userId, permission: "read-write"))

        let bobClient = try await live.client("bob", models: [Self.note], token: bob.jwt)
        let states = ThreadSafeBox<[Db3State]>([])
        let subscription = bobClient.eventEmitter.subscribe(Db3StateEvent.self) { event in
            if event.state.id == db3Id { states.mutate { $0.append(event.state) } }
        }
        defer { _ = subscription }
        let handle = try bobClient.db3.subscribe(db3Id)
        try await handle.ready()
        let before = try await bobClient.db3.state(db3Id)
        XCTAssertEqual(before.permission, .readWrite)
        try await Task.sleep(nanoseconds: 200_000_000)
        // From here, the states the grant changes cause.
        states.mutate { $0.removeAll() }

        _ = try await owner.db3.permissions(db3Id).set(.user(bob.userId, permission: "reader"))
        try await until("a state with reader", timeout: 5) { states.value.last?.permission == .reader }
        XCTAssertEqual(states.value.last?.phase, .live)
        let downgraded = try await bobClient.db3.state(db3Id)
        XCTAssertEqual(downgraded.permission, .reader)

        _ = try await owner.db3.permissions(db3Id).set(.user(bob.userId, permission: "read-write"))
        try await until("a state with read-write", timeout: 5) { states.value.last?.permission == .readWrite }
        let upgraded = try await bobClient.db3.state(db3Id)
        XCTAssertEqual(upgraded.permission, .readWrite)
        XCTAssertEqual(upgraded.phase, .live)
        XCTAssertEqual(states.value.filter { $0.phase != .live }.count, 0, "live throughout")
        handle.dispose()
    }

    func testAFormat1DocumentsPermissionEmitsNoDb3State() async throws {
        let plain = try await ctx.createDocument(appId: live.app.appId, jwt: live.app.ownerJWT, title: "format-1")
        let bob = try await ctx.createTestUser(appId: live.app.appId)
        _ = try await ctx.appRequest(
            method: "PUT", appId: live.app.appId, path: "/documents/\(plain)/permissions",
            body: ["userId": bob.userId, "permission": "read-write"], jwt: live.app.ownerJWT
        )
        let bobClient = try await live.client("bob", models: [], token: bob.jwt)
        let permissions = ThreadSafeBox<[DocumentPermission]>([])
        let db3States = ThreadSafeBox<Int>(0)
        let heard = bobClient.eventEmitter.subscribe(PermissionEvent.self) { event in
            if event.documentId == plain { permissions.mutate { $0.append(event.permission) } }
        }
        let states = bobClient.eventEmitter.subscribe(Db3StateEvent.self) { _ in db3States.mutate { $0 += 1 } }
        defer { _ = (heard, states) }
        _ = try await bobClient.documents.open(plain)
        _ = try await ctx.appRequest(
            method: "PUT", appId: live.app.appId, path: "/documents/\(plain)/permissions",
            body: ["userId": bob.userId, "permission": "reader"], jwt: live.app.ownerJWT
        )
        try await until("the reader permission event") { permissions.value.contains(.reader) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(db3States.value, 0)
    }
}
