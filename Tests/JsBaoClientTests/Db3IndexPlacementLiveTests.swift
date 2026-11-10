import XCTest
@testable import JsBaoClient

/// #5220 behaviours 16 and 17 (live): `client.db3.indexes.register` with
/// `kind` and `on` against the dev server answers them, `list` carries them,
/// a `text` registration throws `HttpError` with `serverCode`
/// `DB3_INDEX_PLACEMENT_UNSUPPORTED`, and the subscribed copy builds a view
/// index for an index placed `both` and none for one placed `server`.
final class Db3IndexPlacementLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(name: "Note", fields: [
        "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string),
        "email": FieldDescriptor(type: .string), "body": FieldDescriptor(type: .string),
    ])

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-index-placement-5220")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    func testKindAndOnRoundTripAndTheHeldCopyBuildsOnlyTheDevicePlacements() async throws {
        let id = try await live.db3Written(0, model: "Note")
        let file = live.file("placement")
        let x = try await live.client("x", models: [Self.note], file: file)
        let handle = try x.db3.subscribe(id)
        try await handle.ready()
        let before = try live.binding(x, id).store.indexTuples()

        let server = try await x.db3.indexes.register(id, Db3IndexRegistration(model: "Note", field: "title", on: .server))
        XCTAssertEqual(server.name, "idx_records_note_title")
        XCTAssertEqual(server.kind, .scalar)
        XCTAssertEqual(server.on, .server)
        XCTAssertEqual(try live.binding(x, id).store.indexTuples(), before)

        let both = try await x.db3.indexes.register(id, Db3IndexRegistration(model: "Note", field: "email", kind: .scalar, on: .both))
        XCTAssertEqual(both.on, .both)
        let tuples = try live.binding(x, id).store.indexTuples()
        XCTAssertTrue(tuples.contains(RecordLogIndexTuple(model: "Note", fields: ["email"], unique: false)))
        XCTAssertFalse(tuples.contains(where: { $0.model == "Note" && $0.fields == ["title"] }))

        let listed = try await x.db3.indexes.list(id)
        XCTAssertEqual(listed.first(where: { $0.name == "idx_records_note_title" })?.on, .server)
        XCTAssertEqual(listed.first(where: { $0.name == "idx_records_note_email" })?.on, .both)

        do {
            // Since #5224 a text index builds on the server; a vector index
            // still builds on the device only (#5225).
            _ = try await x.db3.indexes.register(id, Db3IndexRegistration(model: "Note", field: "body", kind: .vector, on: .server))
            XCTFail("a vector index registered on the server")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 400)
            XCTAssertEqual(error.serverCode, "DB3_INDEX_PLACEMENT_UNSUPPORTED")
            XCTAssertEqual(error.serverCode.flatMap(JsBaoErrorCode.init(rawValue:)), .db3IndexPlacementUnsupported)
        }
        handle.dispose()
    }
}
