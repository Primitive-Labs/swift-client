import XCTest
@testable import JsBaoClient

/// #5155 behaviour 28 — `client.db3.indexes` on a db3 that lives only on
/// this device, with no server.
///
/// `register`, `list` and `drop` work on the device by the room's rules and
/// names, sending nothing: a field registration builds a view index at once;
/// declared `indexed` and `unique` fields have theirs from the bind; a
/// composite unique registration is refused `DB3_INDEX_NOT_UNIQUE` while
/// records share its key, and otherwise is enforced until it is dropped;
/// `drop` of an index a declaration keeps is refused `DB3_INDEX_IN_USE` (a
/// member index is #5156's).
final class Db3LocalOnlyIndexesHermeticTests: XCTestCase {

    private let world = Db3LocalOnlyWorld()

    override func tearDown() async throws {
        await world.tearDown()
        try await super.tearDown()
    }

    private func tuples(_ client: JsBaoClient, _ db3Id: String) throws -> [[String]] {
        let binding = try XCTUnwrap(client.recordLogBinding(db3Id))
        return try binding.store.indexTuples().filter { $0.model == "Note" }.map { $0.fields }
    }

    func testIndexesAreRegisteredListedEnforcedAndDroppedOnTheDevice() async throws {
        let client = try await world.client(directory: world.directory())
        let transport = RecordingTransport(status: 500, json: "{}")
        let info = try await world.createLocalOnly(client, transport: transport)
        let db3 = Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
        let notes = try world.notes(client, info.id)

        // Declared `unique` and `indexed` fields have their index from the bind.
        let declared = try await db3.indexes.list(info.id)
        XCTAssertTrue(declared.contains { $0.name == "idx_records_note_slug" && $0.unique && $0.origins.map(\.kind) == [.declaration] })
        XCTAssertTrue(declared.contains { $0.name == "idx_records_note_status" && !$0.unique })
        XCTAssertTrue(declared.contains { $0.name == "idx_uc_note_owner_day" && $0.fields == ["owner", "day"] })
        XCTAssertTrue(try tuples(client, info.id).contains(["slug"]))
        XCTAssertTrue(try tuples(client, info.id).contains(["status"]))

        // A field registration builds the view index at once.
        let title = try await db3.indexes.register(info.id, Db3IndexRegistration(model: "Note", field: "title"))
        XCTAssertEqual(title.name, "idx_records_note_title")
        XCTAssertEqual(title.origins, [Db3IndexOrigin(kind: .named, unique: false)])
        XCTAssertTrue(try tuples(client, info.id).contains(["title"]))
        let listed = try await db3.indexes.list(info.id)
        XCTAssertTrue(listed.contains { $0.name == "idx_records_note_title" })

        // A composite unique registration over records sharing its key is refused.
        _ = try notes.save(id: "n1", values: ["slug": .string("a"), "owner": .string("u"), "title": .string("t")])
        _ = try notes.save(id: "n2", values: ["slug": .string("b"), "owner": .string("u"), "title": .string("t")])
        let composite = Db3IndexRegistration(model: "Note", fields: ["owner", "title"], unique: true, name: "owner_title")
        let shared = await db3LocalOnlyThrown { _ = try await db3.indexes.register(info.id, composite) }
        XCTAssertEqual(shared?.code, .db3IndexNotUnique)
        XCTAssertEqual(shared?.details?["db3Id"], .string(info.id))
        XCTAssertEqual(shared?.details?["duplicates"]?.arrayValue?.first?["values"], ["u", "t"])
        let unregistered = try await db3.indexes.list(info.id)
        XCTAssertFalse(unregistered.contains { $0.name == "idx_named_note_owner_title" })

        // Resolved, it registers and is enforced.
        try notes.update(id: "n2", values: ["title": .string("other")])
        let registered = try await db3.indexes.register(info.id, composite)
        XCTAssertEqual(registered.name, "idx_named_note_owner_title")
        XCTAssertTrue(registered.unique)
        XCTAssertTrue(try tuples(client, info.id).contains(["owner", "title"]))
        let refused = await db3LocalOnlyThrown {
            _ = try notes.save(id: "n3", values: ["slug": .string("c"), "owner": .string("u"), "title": .string("t")])
        }
        XCTAssertEqual(refused?.code, .documentConstraintViolated)
        XCTAssertNil(notes.find(id: "n3"))

        // An index a declaration keeps cannot be dropped; a registered one can,
        // and its key is no longer enforced.
        let inUse = await db3LocalOnlyThrown { try await db3.indexes.drop(info.id, name: "idx_records_note_slug") }
        XCTAssertEqual(inUse?.code, .db3IndexInUse)
        try await db3.indexes.drop(info.id, name: "idx_named_note_owner_title")
        let dropped = try await db3.indexes.list(info.id)
        XCTAssertFalse(dropped.contains { $0.name == "idx_named_note_owner_title" })
        _ = try notes.save(id: "n3", values: ["slug": .string("c"), "owner": .string("u"), "title": .string("t")])
        XCTAssertEqual(notes.find(id: "n3")?.id, "n3")
        // The declared constraints stay in force.
        let slug = await db3LocalOnlyThrown { _ = try notes.save(id: "n4", values: ["slug": .string("a")]) }
        XCTAssertEqual(slug?.code, .documentConstraintViolated)

        // A member index is built on the device too (#5156: Db3LocalOnlyMemberIndexSurfaceHermeticTests).

        // An invalid registration is the room's DB3_INDEX_INVALID.
        let invalid = await db3LocalOnlyThrown {
            _ = try await db3.indexes.register(info.id, Db3IndexRegistration(model: "Note", fields: [], unique: true, name: "none"))
        }
        XCTAssertEqual(invalid?.code, .db3IndexInvalid)
        XCTAssertEqual(transport.calls.count, 0, "nothing is sent")
        XCTAssertEqual(world.remoteCreates, 0)
    }
}
