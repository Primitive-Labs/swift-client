import XCTest
@testable import JsBaoClient

/// #5220 behaviours 16, 17 and 18 (hermetic): an index's kind and placement
/// through the Swift client.
///
/// - 16: `Db3IndexRegistration` encodes `kind` and `on` only when given (the
///   existing initializers encode what they always encoded); `Db3Index`
///   decodes them, reading an older server's entry as `scalar`/`both` and a
///   `members: true` one as `members`/`server`; `JsBaoErrorCode` names
///   `DB3_INDEX_PLACEMENT_UNSUPPORTED`.
/// - 17: `RecordLogIndexEntry(json:)` reads `kind` and `on`, and
///   `RecordLogIndexes.sync` caches and builds a synced db3's entries placed
///   `device` or `both` and skips one placed `server`.
/// - 18: a local-only db3 lists every index with its kind and `on: .device`,
///   refuses `.server` and `.both` `DB3_LOCAL_ONLY` and a vector index
///   `DB3_INDEX_PLACEMENT_UNSUPPORTED` (a text index is admitted since #5223),
///   and enforces a unique index on the device.
final class Db3IndexPlacementHermeticTests: XCTestCase {

    private var fixtures: [RecordLogViewFixture] = []
    private let world = Db3LocalOnlyWorld()

    override func tearDown() async throws {
        for fixture in fixtures { fixture.remove() }
        fixtures = []
        await world.tearDown()
        try await super.tearDown()
    }

    private func object(_ registration: Db3IndexRegistration) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(registration)) as? NSDictionary)
    }

    private func index(_ json: String) throws -> Db3Index {
        try JSONDecoder().decode(Db3Index.self, from: Data(json.utf8))
    }

    // MARK: - Behaviour 16

    func testTheRegistrationEncodesKindAndOnOnlyWhenGiven() throws {
        XCTAssertEqual(
            try object(Db3IndexRegistration(model: "Note", field: "title", kind: .scalar, on: .server)),
            ["model": "Note", "field": "title", "kind": "scalar", "on": "server"] as NSDictionary
        )
        XCTAssertEqual(try object(Db3IndexRegistration(model: "Note", field: "title", on: .device)), ["model": "Note", "field": "title", "on": "device"] as NSDictionary)
        XCTAssertEqual(
            try object(Db3IndexRegistration(model: "Note", fields: ["a", "b"], unique: true, name: "ab", on: .both)),
            ["model": "Note", "fields": ["a", "b"], "unique": true, "name": "ab", "on": "both"] as NSDictionary
        )
        XCTAssertEqual(
            try object(Db3IndexRegistration(model: "Note", field: "tags", members: true, kind: .members, on: .server)),
            ["model": "Note", "field": "tags", "members": true, "kind": "members", "on": "server"] as NSDictionary
        )
        XCTAssertEqual(try object(Db3IndexRegistration(model: "Note", field: "tags", kind: .members)), ["model": "Note", "field": "tags", "kind": "members"] as NSDictionary)
        // The existing initializers encode what they always encoded.
        XCTAssertEqual(try object(Db3IndexRegistration(model: "Note", field: "email")), ["model": "Note", "field": "email"] as NSDictionary)
        XCTAssertEqual(
            try object(Db3IndexRegistration(model: "Note", fields: ["a", "b"], unique: true, name: "ab")),
            ["model": "Note", "fields": ["a", "b"], "unique": true, "name": "ab"] as NSDictionary
        )
        XCTAssertEqual(try object(Db3IndexRegistration(model: "Note", field: "tags", members: true)), ["model": "Note", "field": "tags", "members": true] as NSDictionary)
    }

    func testTheIndexDecodesKindAndOnWithAnOlderServersDefaults() throws {
        let placed = try index("""
            {"name":"idx_records_note_title","model":"Note","fields":["title"],"unique":false,
             "origins":[{"kind":"named","unique":false}],"kind":"scalar","on":"device"}
            """)
        XCTAssertEqual(placed.kind, .scalar)
        XCTAssertEqual(placed.on, .device)
        XCTAssertFalse(placed.members)
        let older = try index("""
            {"name":"idx_records_note_title","model":"Note","fields":["title"],"unique":false,
             "origins":[{"kind":"named","unique":false}]}
            """)
        XCTAssertEqual(older.kind, .scalar)
        XCTAssertEqual(older.on, .both)
        // Edge case: a member entry carrying members: true and no kind.
        let member = try index("""
            {"name":"idx_members_note_tags","model":"Note","fields":["tags"],"unique":false,"members":true,
             "origins":[{"kind":"named","unique":false}]}
            """)
        XCTAssertEqual(member.kind, .members)
        XCTAssertEqual(member.on, .server)
        XCTAssertEqual(Db3IndexKind.allCases.map(\.rawValue), ["scalar", "members", "text", "vector"])
        XCTAssertEqual(Db3IndexPlacement.allCases.map(\.rawValue), ["server", "device", "both"])
        XCTAssertEqual(JsBaoErrorCode(rawValue: "DB3_INDEX_PLACEMENT_UNSUPPORTED"), .db3IndexPlacementUnsupported)
    }

    // MARK: - Behaviour 17

    func testTheStoreBuildsDeviceAndBothEntriesAndSkipsServerOnes() async throws {
        let fixture = try await RecordLogViewFixture.make("placement")
        fixtures.append(fixture)
        let store = try fixture.open("db3-a").store
        func entry(_ field: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
            var object: [String: JSONValue] = [
                "name": .string("idx_records_note_\(field)"), "model": .string("Note"), "fields": .array([.string(field)]), "unique": .bool(false),
            ]
            for (key, value) in extra { object[key] = value }
            return .object(object)
        }
        let listed: [JSONValue] = [
            entry("body", ["kind": .string("scalar"), "on": .string("device")]),
            entry("rank", ["kind": .string("scalar"), "on": .string("both")]),
            entry("title", ["kind": .string("scalar"), "on": .string("server")]),
            entry("slug", ["kind": .string("scalar"), "on": .string("server"), "unique": .bool(true)]),
            entry("legacy"),
            entry("summary", ["kind": .string("text"), "on": .string("device")]),
        ]
        let entries = listed.compactMap(RecordLogIndexEntry.init(json:))
        XCTAssertEqual(entries.map(\.on), [.device, .both, .server, .server, .both, .device])
        XCTAssertEqual(entries.map(\.kind), [.scalar, .scalar, .scalar, .scalar, .scalar, .text])

        _ = try store.syncIndexes(entries)
        XCTAssertEqual(try store.indexTuples(), [
            RecordLogIndexTuple(model: "Note", fields: ["body"], unique: false),
            RecordLogIndexTuple(model: "Note", fields: ["legacy"], unique: false),
            RecordLogIndexTuple(model: "Note", fields: ["rank"], unique: false),
        ])
        let cached = try fixture.provider.withConnection {
            try $0.query("SELECT room_name FROM record_log_indexes WHERE doc_id = 'db3-a' ORDER BY room_name")
        }
        // A text entry placed on the device is cached as a text index (#5223), never a view index.
        XCTAssertEqual(cached.map { $0["room_name"].stringValue ?? "" },
                       ["idx_records_note_body", "idx_records_note_legacy", "idx_records_note_rank", "idx_records_note_summary"])
        XCTAssertEqual(try fixture.provider.withConnection {
            try $0.query("SELECT kind FROM record_log_indexes WHERE room_name = 'idx_records_note_summary'")
        }.first?["kind"].stringValue, "text")

        // An entry moved to the server loses its view index.
        _ = try store.syncIndexes([try XCTUnwrap(RecordLogIndexEntry(json: entry("body", ["on": .string("server")])))])
        XCTAssertEqual(try store.indexTuples(), [])
    }

    // MARK: - Behaviour 18

    func testALocalOnlyDb3KeepsEveryIndexOnTheDevice() async throws {
        let client = try await world.client(directory: world.directory())
        let transport = RecordingTransport(status: 500, json: "{}")
        let info = try await world.createLocalOnly(client, transport: transport)
        let db3 = Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
        let notes = try world.notes(client, info.id)

        let declared = try await db3.indexes.list(info.id)
        XCTAssertFalse(declared.isEmpty)
        XCTAssertTrue(declared.allSatisfy { $0.on == .device && $0.kind == .scalar })

        let title = try await db3.indexes.register(info.id, Db3IndexRegistration(model: "Note", field: "title", on: .device))
        XCTAssertEqual(title.kind, .scalar)
        XCTAssertEqual(title.on, .device)
        let unplaced = try await db3.indexes.register(info.id, Db3IndexRegistration(model: "Note", field: "owner"))
        XCTAssertEqual(unplaced.on, .device)
        let members = try await db3.indexes.register(info.id, Db3IndexRegistration(model: "Note", field: "tags", kind: .members))
        XCTAssertTrue(members.members)
        XCTAssertEqual(members.kind, .members)
        XCTAssertEqual(members.on, .device)
        let listed = try await db3.indexes.list(info.id)

        for on in [Db3IndexPlacement.server, .both] {
            let refused = await db3LocalOnlyThrown {
                _ = try await db3.indexes.register(info.id, Db3IndexRegistration(model: "Note", field: "day", on: on))
            }
            XCTAssertEqual(refused?.code, .db3LocalOnly)
            XCTAssertEqual(refused?.details?["on"], .string(on.rawValue))
            XCTAssertEqual(refused?.details?["db3Id"], .string(info.id))
        }
        // A text index is admitted on the device since #5223 (Db3LocalOnlyTextIndexHermeticTests), a vector index since
        // #5230 (Db3LocalOnlyVectorIndexLiveTests): one on a field that is not a vector field is refused.
        for kind in [Db3IndexKind.vector] {
            let refused = await db3LocalOnlyThrown {
                _ = try await db3.indexes.register(info.id, Db3IndexRegistration(model: "Note", field: "day", kind: kind))
            }
            XCTAssertEqual(refused?.code, .db3IndexInvalid)
            XCTAssertEqual(
                refused?.message,
                "Note.day is not a vector field: a vector index covers a field the model's declaration gives type \"vector\", dims and element"
            )
        }
        let refusedList = try await db3.indexes.list(info.id)
        XCTAssertEqual(refusedList, listed)

        // A unique index on the device is enforced there.
        _ = try notes.save(id: "n1", values: ["slug": .string("a"), "day": .number(1)])
        let unique = try await db3.indexes.register(info.id, Db3IndexRegistration(model: "Note", field: "day", unique: true, on: .device))
        XCTAssertTrue(unique.unique)
        XCTAssertEqual(unique.on, .device)
        let duplicate = await db3LocalOnlyThrown {
            _ = try notes.save(id: "n2", values: ["slug": .string("b"), "day": .number(1)])
        }
        XCTAssertEqual(duplicate?.code, .documentConstraintViolated)

        // The store is asked for device entries only.
        XCTAssertTrue(RecordLogLocalOnly.entries(listed).allSatisfy { $0.on == .device })
    }
}
