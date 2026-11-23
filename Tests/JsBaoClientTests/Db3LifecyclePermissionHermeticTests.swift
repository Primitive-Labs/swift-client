import XCTest
@testable import JsBaoClient

/// #5070 behavior 5 — the Swift lifecycle hears a permission: after the
/// store took a level, `permissionChanged` reads the db3's state again, so a
/// `Db3StateEvent` carries the new permission with no reopen; a level that
/// changes nothing emits nothing.
final class Db3LifecyclePermissionHermeticTests: XCTestCase {

    private static let id = "01JD5070SW1FTPERM1SS1ONXXX"

    /// What the client would answer the lifecycle.
    final class World: @unchecked Sendable {
        private let lock = NSLock()
        var marks: Db3SyncMarks? = Db3SyncMarks(cursor: 4, permission: nil, lastCatchUpAt: 1_000, replacing: false, staged: false)
        var known: Db3Permission? = .readWrite
        var opens: [String] = []
        var emitted: [any JsBaoEventPayload] = []

        func with<T>(_ body: (World) -> T) -> T { lock.withLock { body(self) } }

        func states() -> [Db3State] {
            with { $0.emitted.compactMap { ($0 as? Db3StateEvent)?.state }.filter { $0.id == Db3LifecyclePermissionHermeticTests.id } }
        }

        func deps() -> Db3LifecycleDeps {
            Db3LifecycleDeps(
                emit: { [self] payload in with { $0.emitted.append(payload) } },
                socketUp: { true },
                resolveFormat: { _ in 3 },
                open: { [self] id in with { $0.opens.append(id) } },
                knownPermission: { [self] _ in with { $0.known } },
                isBound: { [self] _ in with { $0.marks != nil } },
                syncMarks: { [self] _ in with { $0.marks } },
                storedState: { _ in RecordLogStoredState(cursor: 4, rows: 1, writers: [], replacing: false, lastCatchUpAt: 1_000) },
                storedIds: { [Db3LifecyclePermissionHermeticTests.id] }
            )
        }
    }

    func testAPermissionChangeEmitsTheNewLevelAndAnUnchangedOneEmitsNothing() async throws {
        let world = World()
        let lifecycle = Db3Lifecycle(deps: world.deps())
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        try await handle.ready()
        try await eventually(description: "live with read-write") { world.states().last?.permission == .readWrite }

        world.with { $0.marks?.permission = RecordLogPermission.read }
        lifecycle.permissionChanged(Self.id)
        try await eventually(description: "a state with reader") { world.states().last?.permission == .reader }
        XCTAssertEqual(world.states().last?.phase, .live)
        let read = try await lifecycle.state(Self.id)
        XCTAssertEqual(read.permission, .reader)

        world.with { $0.marks?.permission = nil }
        lifecycle.permissionChanged(Self.id)
        try await eventually(description: "a state with read-write") { world.states().last?.permission == .readWrite }
        XCTAssertEqual(world.states().last?.phase, .live)

        let count = world.states().count
        lifecycle.permissionChanged(Self.id)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(world.states().count, count, "a level that changes nothing emits nothing")
        XCTAssertEqual(world.with { $0.opens }, [Self.id], "no reopen")
        handle.dispose()
    }
}
