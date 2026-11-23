import XCTest
@testable import JsBaoClient

/// #5150 behaviour 18 (hermetic): a member index through the Swift client.
///
/// - `Db3IndexRegistration(model:field:members:)` encodes `members` beside the
///   model and field, and nothing else.
/// - `Db3Index` decodes `members`, and reads `false` when the row has none.
/// - The room's list entry carries `members`, and `RecordLogIndexes.sync`
///   skips a member entry: no `record_log_indexes` row, no view index, while
///   a scalar entry beside it is cached and built as before.
final class Db3MemberIndex5150HermeticTests: XCTestCase {

    private var fixtures: [RecordLogViewFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures { fixture.remove() }
        fixtures = []
        try await super.tearDown()
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTheRegistrationEncodesMembers() throws {
        let members = try object(JSONEncoder().encode(Db3IndexRegistration(model: "Note", field: "tags", members: true)))
        XCTAssertEqual(members as NSDictionary, ["model": "Note", "field": "tags", "members": true] as NSDictionary)
        let scalar = try object(JSONEncoder().encode(Db3IndexRegistration(model: "Note", field: "email")))
        XCTAssertEqual(scalar as NSDictionary, ["model": "Note", "field": "email"] as NSDictionary)
    }

    func testTheIndexDecodesMembersAndReadsFalseWhenAbsent() throws {
        let member = try JSONDecoder().decode(Db3Index.self, from: Data("""
            {"name":"idx_members_note_tags","model":"Note","fields":["tags"],"unique":false,"members":true,
             "origins":[{"kind":"named","unique":false}]}
            """.utf8))
        XCTAssertTrue(member.members)
        XCTAssertEqual(member.name, "idx_members_note_tags")
        XCTAssertEqual(member.origins, [Db3IndexOrigin(kind: .named, unique: false)])
        let scalar = try JSONDecoder().decode(Db3Index.self, from: Data("""
            {"name":"idx_records_note_email","model":"Note","fields":["email"],"unique":false,
             "origins":[{"kind":"named","unique":false}]}
            """.utf8))
        XCTAssertFalse(scalar.members)
    }

    func testTheStoreSkipsAMemberEntryAndBuildsTheScalarOneBesideIt() async throws {
        let fixture = try await RecordLogViewFixture.make("members")
        fixtures.append(fixture)
        let store = try fixture.open("db3-a").store
        let listed: JSONValue = .array([
            .object(["name": .string("idx_members_note_tags"), "model": .string("Note"), "fields": .array([.string("tags")]),
                     "unique": .bool(false), "members": .bool(true)]),
            .object(["name": .string("idx_records_note_title"), "model": .string("Note"), "fields": .array([.string("title")]),
                     "unique": .bool(false)]),
        ])
        let entries = (listed.arrayValue ?? []).compactMap(RecordLogIndexEntry.init(json:))
        XCTAssertEqual(entries.map(\.members), [true, false])

        let synced = try store.syncIndexes(entries)
        XCTAssertEqual(synced.created, 1)
        XCTAssertEqual(try store.indexTuples(), [RecordLogIndexTuple(model: "Note", fields: ["title"], unique: false)])
        let cached = try fixture.provider.withConnection {
            try $0.query("SELECT room_name FROM record_log_indexes WHERE doc_id = 'db3-a' ORDER BY room_name")
        }
        XCTAssertEqual(cached.map { $0["room_name"].stringValue ?? "" }, ["idx_records_note_title"])

        // A member entry alone leaves no index at all.
        _ = try store.syncIndexes([entries[0]])
        XCTAssertEqual(try store.indexTuples(), [])
    }
}
