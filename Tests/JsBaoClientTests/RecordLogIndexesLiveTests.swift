import XCTest
@testable import JsBaoClient

/// #4700 behaviours 18–19 (criterion 3 on Swift): a Swift client's store
/// builds its view indexes from the room's list (`GET db3/:id/indexes`), read
/// when a db3 is opened and again when the room acknowledges a declaration
/// (`record.declared`). A read that fails keeps the cached list and logs one
/// warning naming the document; the open never waits for it.
final class RecordLogIndexesLiveTests: XCTestCase {

    private static let note = PrimitiveSchema(name: "db3_ix4700_note", fields: [
        "id": FieldDescriptor(type: .id),
        "slug": FieldDescriptor(type: .string, indexed: true),
        "title": FieldDescriptor(type: .string),
        "a": FieldDescriptor(type: .string),
        "b": FieldDescriptor(type: .string),
        "temp": FieldDescriptor(type: .string),
    ])
    private static let later = PrimitiveSchema(name: "db3_ix4700_later", fields: [
        "id": FieldDescriptor(type: .id), "label": FieldDescriptor(type: .string),
    ])

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private let warnings = LockedBox<[String]>([])

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-indexes-4700")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
        let warnings = warnings
        Logger.lineForTest = { level, _, message in
            if level == .warn, message.contains("index list") { warnings.withValue { $0.append(message) } }
        }
    }

    override func tearDown() async throws {
        Logger.lineForTest = nil
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// The room's list as tuples, in the store's order.
    private func roomTuples(_ documentId: String) async throws -> [RecordLogIndexTuple] {
        let answer = try await ctx.appRequest(
            method: "GET", appId: live.app.appId, path: "/db3/\(documentId)/indexes", body: nil, jwt: live.app.ownerJWT
        )
        let tuples = ((answer["indexes"] as? [[String: Any]]) ?? []).map { index in
            RecordLogIndexTuple(
                model: index["model"] as? String ?? "", fields: index["fields"] as? [String] ?? [],
                unique: index["unique"] as? Bool ?? false
            )
        }
        return tuples.sorted { ($0.model, $0.fields.joined(separator: "\u{1}")) < ($1.model, $1.fields.joined(separator: "\u{1}")) }
    }

    private func register(_ documentId: String, _ body: [String: Any]) async throws {
        _ = try await ctx.appRequest(
            method: "POST", appId: live.app.appId, path: "/db3/\(documentId)/indexes", body: body, jwt: live.app.ownerJWT
        )
    }

    private func storeTuples(_ client: JsBaoClient, _ documentId: String) throws -> [RecordLogIndexTuple] {
        try live.binding(client, documentId).store.indexTuples()
    }

    private func cached(_ client: JsBaoClient, _ documentId: String) throws -> [String] {
        try live.binding(client, documentId).store.host.withConnection {
            try $0.query("SELECT model, fields, is_unique FROM record_log_indexes WHERE doc_id = ? ORDER BY model, fields", [.text(documentId)])
        }.map { "\($0["model"].stringValue ?? "") \($0["fields"].stringValue ?? "") \($0["is_unique"].intValue ?? -1)" }
    }

    // MARK: - Behaviour 18

    func testTheStoreHoldsTheRoomsListAfterAnOpenAfterADeclarationAndAfterAReopen() async throws {
        let swift = try await live.client("swift", models: [Self.note])
        let documentId = try await live.createDocument(swift)
        let model = Self.note.name
        try await register(documentId, ["model": model, "field": "title"])
        try await register(documentId, ["model": model, "fields": ["a", "b"], "unique": true, "name": "by_ab"])

        try await live.open(swift, documentId)
        try await eventually(timeout: 20, description: "the room to hold the declaration's index") {
            try await self.roomTuples(documentId).count == 3
        }
        let room = try await roomTuples(documentId)
        XCTAssertEqual(room.map { $0.fields.joined(separator: "+") }, ["a+b", "slug", "title"])
        try await eventually(timeout: 20, description: "the store to hold the room's list after the open") {
            try self.storeTuples(swift, documentId) == room
        }

        // Registered while the document is open: in the store once the
        // client's next declaration is acknowledged.
        try await register(documentId, ["model": model, "field": "temp"])
        let withTemp = try await roomTuples(documentId)
        XCTAssertEqual(withTemp.count, 4)
        swift.registerModels([Self.later])
        try await eventually(timeout: 20, description: "the store to hold the registration after a declaration") {
            try self.storeTuples(swift, documentId) == withTemp
        }

        // Registered while the document is closed: in the store after the reopen.
        _ = await swift.closeDocument(documentId)
        try await register(documentId, ["model": model, "field": "b"])
        let reopened = try await roomTuples(documentId)
        XCTAssertEqual(reopened.count, 5)
        try await live.open(swift, documentId)
        try await eventually(timeout: 20, description: "the store to hold the room's list after the reopen") {
            try self.storeTuples(swift, documentId) == reopened
        }
        XCTAssertTrue(warnings.value.isEmpty, "\(warnings.value)")
    }

    // MARK: - Behaviour 19

    func testAReadThatFailsKeepsTheCachedListAndLogsOneWarningNamingTheDocument() async throws {
        let swift = try await live.client("swift", models: [Self.note])
        let documentId = try await live.createDocument(swift)
        try await register(documentId, ["model": Self.note.name, "field": "title"])
        try await live.open(swift, documentId)
        try await eventually(timeout: 20, description: "the store to cache the room's list") {
            try self.storeTuples(swift, documentId).count == 2
        }
        let tuples = try storeTuples(swift, documentId)
        let cache = try cached(swift, documentId)
        _ = await swift.closeDocument(documentId)

        // Networking off: the read fails, the open answers from the store.
        swift.setNetworkMode(.offline)
        warnings.value = []
        _ = try await swift.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .local))
        try await eventually(timeout: 15, description: "the index read's warning") { !self.warnings.value.isEmpty }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(warnings.value.count, 1, "\(warnings.value)")
        XCTAssertTrue(warnings.value.first?.contains(documentId) ?? false, "\(warnings.value)")
        XCTAssertEqual(try storeTuples(swift, documentId), tuples, "the cached indexes stand")
        XCTAssertEqual(try cached(swift, documentId), cache, "the cached list stands")
    }
}
