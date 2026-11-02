import XCTest
@testable import JsBaoClient

/// #5150 behaviour 18 (live): `client.db3.indexes.register` with
/// `members: true` against the dev server answers the member index, `list`
/// returns it, and the subscribed copy's indexes are unchanged by it.
final class Db3MemberIndex5150LiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(name: "Note", fields: [
        "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string),
        "email": FieldDescriptor(type: .string), "tags": FieldDescriptor(type: .stringset),
    ])

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-member-index-5150")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    func testAMemberIndexRoundTripsAndTheHeldCopyBuildsNothingForIt() async throws {
        let id = try await live.db3Written(0, model: "Note")
        let file = live.file("members")
        let x = try await live.client("x", models: [Self.note], file: file)
        let handle = try x.db3.subscribe(id)
        try await handle.ready()
        let before = try live.binding(x, id).store.indexTuples()

        let index = try await x.db3.indexes.register(id, Db3IndexRegistration(model: "Note", field: "tags", members: true))
        XCTAssertEqual(index.name, "idx_members_note_tags")
        XCTAssertEqual(index.fields, ["tags"])
        XCTAssertFalse(index.unique)
        XCTAssertTrue(index.members)
        XCTAssertEqual(index.origins, [Db3IndexOrigin(kind: .named, unique: false)])
        let listed = try await x.db3.indexes.list(id)
        XCTAssertTrue(listed.contains(where: { $0.name == index.name && $0.members }))
        XCTAssertEqual(try live.binding(x, id).store.indexTuples(), before)

        // A scalar registration beside it still reaches the copy.
        let email = try await x.db3.indexes.register(id, Db3IndexRegistration(model: "Note", field: "email"))
        XCTAssertFalse(email.members)
        XCTAssertTrue(try live.binding(x, id).store.indexTuples().contains(RecordLogIndexTuple(model: "Note", fields: ["email"], unique: false)))
        XCTAssertFalse(try live.binding(x, id).store.indexTuples().contains(where: { $0.fields == ["tags"] }))
        handle.dispose()
    }
}
