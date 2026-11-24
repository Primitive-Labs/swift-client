import XCTest
@testable import JsBaoClient

/// #6025 behavior 58 (live) — for one pushed db3 type that allows local-only
/// db3s, a typed local-only db3 on the Swift client and a synced db3 the
/// room installed the type on list the same declared indexes: the same
/// names, fields and uniqueness.
final class Db3LocalOnlyTypedLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    /// An indexed `label`, a unique `slug`, a compound unique `(title,
    /// weight)` and an indexed string set `tags`.
    private static let schema = """
    [models.Entry]
    [models.Entry.fields.title]
    type = "string"
    [models.Entry.fields.weight]
    type = "number"
    [models.Entry.fields.slug]
    type = "string"
    unique = true
    [models.Entry.fields.label]
    type = "string"
    indexed = true
    [models.Entry.fields.tags]
    type = "stringset"
    indexed = true
    [[models.Entry.unique_constraints]]
    name = "title_weight"
    fields = ["title", "weight"]
    """

    /// The same declarations in install shape, as `swift-bao-codegen` embeds them.
    private static let modelsJSON = """
    {"Entry":{"constraints":{"title_weight":{"fields":["title","weight"],"type":"unique"}},"fields":{\
    "label":{"indexed":true,"type":"string"},"slug":{"type":"string","unique":true},"tags":{"indexed":true,"type":"stringset"},\
    "title":{"type":"string"},"weight":{"type":"number"}}}}
    """

    private static let entry = PrimitiveSchema(
        name: "Entry",
        fields: [
            "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string), "weight": FieldDescriptor(type: .number),
            "slug": FieldDescriptor(type: .string), "label": FieldDescriptor(type: .string), "tags": FieldDescriptor(type: .stringset),
        ]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-local-only-typed-6025")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// The declared indexes of a list, as `name fields unique` lines, sorted.
    private static func declared(_ list: [Db3Index]) -> [String] {
        list.filter { $0.origins.contains { $0.kind == .declaration } }
            .map { "\($0.name) \($0.fields.joined(separator: ",")) \($0.unique)" }
            .sorted()
    }

    func testATypedLocalOnlyDb3AndASyncedDb3OfOneTypeListTheSameDeclaredIndexes() async throws {
        let type = "swift-local-only-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try await ctx.appRequest(
            method: "PUT", appId: live.app.appId, path: "/db3-types/\(type)",
            body: ["schema": Self.schema, "allowLocalOnly": true], jwt: live.app.ownerJWT
        )
        let read = try await ctx.appRequest(method: "GET", appId: live.app.appId, path: "/db3-types/\(type)", body: nil, jwt: live.app.ownerJWT)
        XCTAssertEqual(read["allowLocalOnly"] as? Bool, true)

        let owner = try await live.client("owner", models: [Self.entry])
        owner.registerDb3Types(PrimitiveDb3Types(knownTypesOnly: false, types: [
            PrimitiveDb3Types.DeclaredType(name: type, localOnly: PrimitiveDb3Types.LocalOnlyDeclarations(hash: "live-6025", modelsJSON: Self.modelsJSON)),
        ]))

        let synced = try await owner.db3.create(title: "Synced", type: type)
        let opened = try owner.db3.subscribe(synced.id)
        try await opened.ready()
        let room = try await owner.db3.indexes.list(synced.id)
        opened.dispose()

        let local = try await owner.db3.create(title: "Local", type: type, localOnly: true)
        XCTAssertTrue(local.localOnly)
        XCTAssertEqual(local.type, type)
        let device = try await owner.db3.indexes.list(local.id)

        XCTAssertFalse(Self.declared(room).isEmpty, "the room lists the type's declared indexes")
        XCTAssertEqual(Self.declared(device), Self.declared(room))
    }
}
