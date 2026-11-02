import XCTest
@testable import JsBaoClient

/// #5155 behaviours 27 and 32 — a db3 that lives only on this device, in a
/// later session over the same store.
///
/// - 27: a new client over the same directory and user lists it in
///   `stored()` with `localOnly`, reads its rows with no subscribe, continues
///   its cursor, and still refuses a write sharing a composite unique key
///   registered before the restart (the store's constraints list the
///   declared one and the registered one).
/// - 32: another user signing in on the same directory does not see it (not
///   in `stored()`, not resident, a query naming it refused
///   `DB3_NOT_RESIDENT`); its creator signing in again sees it with its rows.
final class Db3LocalOnlyStoredHermeticTests: XCTestCase {

    private let world = Db3LocalOnlyWorld()

    override func tearDown() async throws {
        await world.tearDown()
        try await super.tearDown()
    }

    private static let ownerTitle = Db3IndexRegistration(model: "Note", fields: ["owner", "title"], unique: true, name: "owner_title")

    // MARK: - Behaviour 27

    func testALaterSessionBindsItWithItsRowsCursorAndRegisteredKey() async throws {
        let directory = world.directory()
        let first = try await world.client(directory: directory)
        let transport = RecordingTransport(status: 500, json: "{}")
        let info = try await world.createLocalOnly(first, transport: transport)
        let notes = try world.notes(first, info.id)
        _ = try notes.save(id: "n1", values: ["slug": .string("a"), "owner": .string("u"), "title": .string("t")])
        _ = try notes.save(id: "n2", values: ["slug": .string("b"), "owner": .string("u"), "title": .string("other")])
        _ = try await Db3API(lifecycle: first._db3Lifecycle, transport: transport, client: first).indexes.register(info.id, Self.ownerTitle)
        let cursor = try await first.db3.state(info.id).cursor
        XCTAssertEqual(cursor, 2)
        await world.destroy(first)

        let second = try await world.client(directory: directory)
        try await db3LocalOnlyEventually("the stored db3 bound at start-up") {
            try await second.db3.state(info.id).resident
        }
        let stored = try await second.db3.stored()
        XCTAssertEqual(stored.map(\.id), [info.id])
        XCTAssertEqual(stored.first?.localOnly, true)
        let again = try world.notes(second, info.id)
        XCTAssertEqual(try again.query().compactMap { $0["id"]?.stringValue }.sorted(), ["n1", "n2"], "read with no subscribe")
        XCTAssertFalse(second._db3Lifecycle.isSubscribed(info.id))

        _ = try again.save(id: "n3", values: ["slug": .string("c")])
        let continued = try await second.db3.state(info.id)
        XCTAssertEqual(continued.cursor, cursor + 1, "the cursor continues from the stored value")
        XCTAssertTrue(continued.localOnly)

        let refused = await db3LocalOnlyThrown {
            _ = try again.save(id: "n4", values: ["slug": .string("d"), "owner": .string("u"), "title": .string("t")])
        }
        XCTAssertEqual(refused?.code, .documentConstraintViolated, "the registered key is enforced after the restart")
        let constraints = try XCTUnwrap(second.recordLogBinding(info.id)).store.marks().constraints.map(\.name)
        XCTAssertTrue(constraints.contains("Note_slug_unique"), "\(constraints)")
        XCTAssertTrue(constraints.contains("idx_named_note_owner_title"), "\(constraints)")
        XCTAssertEqual(transport.calls.count, 0)
        XCTAssertEqual(world.remoteCreates, 0)
    }

    // MARK: - Behaviour 32

    func testAnotherUserDoesNotSeeItAndItsCreatorDoesAgain() async throws {
        let directory = world.directory()
        let creator = try await world.client(userId: "user-a", directory: directory)
        let info = try await world.createLocalOnly(creator, transport: RecordingTransport(status: 500, json: "{}"))
        _ = try world.notes(creator, info.id).save(id: "n1", values: ["slug": .string("a")])
        await world.destroy(creator)

        let other = try await world.client(userId: "user-b", directory: directory)
        try await Task.sleep(nanoseconds: 300_000_000)
        let seen = try await other.db3.stored()
        XCTAssertEqual(seen.map(\.id), [], "another user's stored() omits it")
        let state = try await other.db3.state(info.id)
        XCTAssertFalse(state.resident)
        XCTAssertFalse(state.localOnly)
        XCTAssertThrowsError(try other.sharedModel(for: Db3LocalOnlyWorld.note).query(nil, options: QueryOptions(db3: [info.id]))) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .db3NotResident)
        }
        let sub = try other.db3.subscribe(info.id, options: Db3SubscribeOptions(readyTimeout: 0.3))
        _ = await db3LocalOnlyThrown { try await sub.ready() }
        sub.dispose()
        let afterSubscribe = try await other.db3.state(info.id)
        XCTAssertFalse(afterSubscribe.resident, "a subscribe does not reach it either")
        XCTAssertNil(other.recordLogBinding(info.id))
        await world.destroy(other)

        let back = try await world.client(userId: "user-a", directory: directory)
        try await db3LocalOnlyEventually("its creator sees it again") {
            try await back.db3.state(info.id).resident
        }
        let stored = try await back.db3.stored()
        XCTAssertEqual(stored.map(\.id), [info.id])
        XCTAssertEqual(stored.first?.localOnly, true)
        XCTAssertEqual(try world.notes(back, info.id).query().compactMap { $0["id"]?.stringValue }, ["n1"])
    }
}
