import XCTest
@testable import JsBaoClient

/// #5049 behavior 16 — a deleted db3 is gone for `.deleted`, rule for rule
/// from the JS lifecycle.
///
/// The session marks the store refused and reports `DOCUMENT_DELETED`; the
/// lifecycle turns the db3 gone once with `Db3GoneEvent(reason: .deleted,
/// code: "DB3_DELETED")`, its state's error names the code, and a waiting or
/// later `ready()` throws `.db3Deleted`. A deletion stays the reason when an
/// `ACCESS_DENIED` follows; `ACCESS_DENIED` alone is `.permission`; a room
/// that needs a newer client keeps precedence. The client records the reason
/// (`deletedHeard`) when it routes the frame, before the session marks the
/// store refused, so a state read in between already reports `.deleted`, and
/// a live state read between `deletedHeard` and the mark does not clear it
/// (5049-C001); once the session took the refusal, a later live clears it.
final class Db3DeletedLifecycleHermeticTests: XCTestCase {
    typealias World = Db3LifecycleHermeticTests.World

    private static let id = "01JD5049DE1ETEDXXXXXXXXXXX"

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func make(_ configure: (World) -> Void = { _ in }) -> (Db3Lifecycle, World) {
        let world = World()
        world.with(configure)
        return (Db3Lifecycle(deps: world.deps()), world)
    }

    private func code(_ body: () async throws -> Void) async -> String {
        do {
            try await body()
            return "resolved"
        } catch {
            return (error as? JsBaoError)?.code.rawValue ?? "\(error)"
        }
    }

    private func gone(_ world: World) -> [Db3GoneEvent] { world.events(Db3GoneEvent.self) }

    /// The room's `DOCUMENT_DELETED` as the client takes it: the reason heard, the store marked, the session's report.
    private func deletedRefusal(_ lifecycle: Db3Lifecycle, _ world: World) {
        lifecycle.deletedHeard(Self.id)
        world.with { $0.marks?.permission = RecordLogPermission.refused }
        lifecycle.syncFailed(Self.id, "DOCUMENT_DELETED")
    }

    func testADeletionTurnsTheDb3GoneOnceForThatReason() async throws {
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        deletedRefusal(lifecycle, world)
        let got = await code { try await handle.ready() }
        XCTAssertEqual(got, "DB3_DELETED")
        XCTAssertEqual(JsBaoErrorCode.db3Deleted.rawValue, "DB3_DELETED")
        try await eventually(description: "gone") { self.gone(world).count == 1 }
        XCTAssertEqual(gone(world), [Db3GoneEvent(id: Self.id, reason: .deleted)])
        XCTAssertEqual(gone(world).first?.code, "DB3_DELETED")
        let state = try await lifecycle.state(Self.id)
        XCTAssertEqual(state.phase, .gone)
        XCTAssertEqual(state.permission, .refused)
        XCTAssertEqual(state.error?.code, "DB3_DELETED")
        XCTAssertTrue(state.resident, "its rows stay readable")
        XCTAssertTrue(world.events(Db3ErrorEvent.self).isEmpty, "a deletion is not a retried error")

        // A subscribe while gone is answered by the next refusal, with no second gone event.
        let later = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        lifecycle.syncFailed(Self.id, "DOCUMENT_DELETED")
        let again = await code { try await later.ready() }
        XCTAssertEqual(again, "DB3_DELETED")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(gone(world).count, 1)
        handle.dispose()
        later.dispose()
    }

    func testDeletedHeardBeforeTheMarkGivesTheSameReason() async throws {
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        lifecycle.deletedHeard(Self.id)
        world.with { $0.marks?.permission = RecordLogPermission.refused }
        lifecycle.pendingChanged(Self.id)
        try await eventually(description: "gone") { self.gone(world).count == 1 }
        XCTAssertEqual(gone(world), [Db3GoneEvent(id: Self.id, reason: .deleted)])
        lifecycle.syncFailed(Self.id, "DOCUMENT_DELETED")
        let got = await code { try await handle.ready() }
        XCTAssertEqual(got, "DB3_DELETED")
        XCTAssertEqual(gone(world).count, 1)
        handle.dispose()
    }

    func testALiveReadBeforeTheMarkKeepsDeleted() async throws {
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        try await handle.ready()
        try await eventually(description: "live") { handle.state.phase == .live }
        lifecycle.deletedHeard(Self.id)
        // Work queued before the frame reads the state while it is still live.
        lifecycle.pendingChanged(Self.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        world.with { $0.marks?.permission = RecordLogPermission.refused }
        lifecycle.pendingChanged(Self.id)
        try await eventually(description: "gone") { self.gone(world).count == 1 }
        lifecycle.syncFailed(Self.id, "DOCUMENT_DELETED")
        XCTAssertEqual(gone(world), [Db3GoneEvent(id: Self.id, reason: .deleted)])
        let state = try await lifecycle.state(Self.id)
        XCTAssertEqual(state.error?.code, "DB3_DELETED")

        // Taken: the db3 live again (a kept id created anew) is no longer deleted.
        world.with { $0.marks?.permission = nil }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        try await eventually(description: "live again") { handle.state.phase == .live }
        world.with { $0.marks?.permission = RecordLogPermission.refused }
        lifecycle.syncFailed(Self.id, "ACCESS_DENIED")
        try await eventually(description: "gone again") { self.gone(world).count == 2 }
        XCTAssertEqual(gone(world).last?.reason, .permission)
        handle.dispose()
    }

    func testAnAccessRefusalAfterTheDeletionKeepsDeleted() async throws {
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        deletedRefusal(lifecycle, world)
        lifecycle.syncFailed(Self.id, "ACCESS_DENIED")
        try await eventually(description: "gone") { self.gone(world).count == 1 }
        XCTAssertEqual(gone(world).first?.reason, .deleted)
        let state = try await lifecycle.state(Self.id)
        XCTAssertEqual(state.error?.code, "DB3_DELETED")
        handle.dispose()
    }

    func testARevokedGrantStillReportsPermission() async throws {
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        world.with { $0.marks?.permission = RecordLogPermission.refused }
        lifecycle.syncFailed(Self.id, "ACCESS_DENIED")
        let got = await code { try await handle.ready() }
        XCTAssertEqual(got, "DB3_ACCESS_REFUSED")
        try await eventually(description: "gone") { self.gone(world).count == 1 }
        XCTAssertEqual(gone(world), [Db3GoneEvent(id: Self.id, reason: .permission)])
        handle.dispose()
    }

    func testAClientOutdatedRoomKeepsPrecedence() async throws {
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(description: "the open") { world.with { $0.opens } == [Self.id] }
        lifecycle.deletedHeard(Self.id)
        lifecycle.syncFailed(Self.id, "DB3_CLIENT_OUTDATED")
        let got = await code { try await handle.ready() }
        XCTAssertEqual(got, "DB3_CLIENT_OUTDATED")
        try await eventually(description: "gone") { self.gone(world).count == 1 }
        XCTAssertEqual(gone(world), [Db3GoneEvent(id: Self.id, reason: .clientOutdated)])
        handle.dispose()
    }

    /// The client's routing records the reason before any session sees the frame.
    func testTheClientRecordsTheReasonWhenItRoutesTheFrame() async throws {
        let directory = NSTemporaryDirectory() + "/db3-deleted-route-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:9",
            wsUrl: "ws://127.0.0.1:1",
            appId: "db3-deleted-route-app",
            token: makeTestJwt(userId: "db3-deleted-route-user"),
            globalAdminAppId: TestConfig.globalAdminAppId,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
        _ = await client.waitForStorageReady()
        XCTAssertNil(client._db3Lifecycle.goneReasonHeard(Self.id))
        await client.routeRecordLogFrame([
            "type": "error", "messageType": "record.open", "code": "DOCUMENT_DELETED",
            "documentId": .string(Self.id), "message": "The document was deleted",
        ])
        XCTAssertEqual(client._db3Lifecycle.goneReasonHeard(Self.id), .deleted)
    }
}
