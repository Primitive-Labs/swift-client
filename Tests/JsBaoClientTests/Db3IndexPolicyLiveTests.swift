import XCTest
@testable import JsBaoClient

/// #5322 behaviors 26 (live half) and 29, edge case 45 (Swift) — against the
/// dev server.
///
/// - 26: an index the owner registers over HTTP reaches a Swift client that
///   holds the db3 open without a reopen; a drop removes its table; a type
///   replacement that stops indexing a field removes its view index.
/// - 29: a decline outlives a restart over the same file, a registry refresh,
///   a drop and re-registration under another name, an evict and a new
///   subscribe, and the evict of the file's last db3; `accept` rebuilds;
///   `client.db3.delete` clears the policy; with the store's connection
///   limited so a scalar build fails, `ready()` returns and the field's query
///   answers, and the build succeeds once the limit is put back.
final class Db3IndexPolicyLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private typealias F = Db3DeviceIndexLiveFixture

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-index-policy-5322")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    @discardableResult
    private func register(_ id: String, _ body: [String: Any]) async throws -> String {
        let answer = try await ctx.appRequest(method: "POST", appId: live.app.appId, path: "/db3/\(id)/indexes", body: body, jwt: live.app.ownerJWT)
        return try XCTUnwrap((answer["index"] as? [String: Any])?["name"] as? String, "\(answer)")
    }

    private func drop(_ id: String, _ name: String) async throws {
        _ = try await ctx.appRequest(method: "DELETE", appId: live.app.appId, path: "/db3/\(id)/indexes/\(name)", body: nil, jwt: live.app.ownerJWT)
    }

    private func status(_ client: JsBaoClient, _ id: String, _ name: String) async throws -> Db3LocalIndexStatus? {
        try await client.db3.indexes.local(id).first { $0.name == name }?.status
    }

    private func text(_ client: JsBaoClient, _ id: String) throws -> [String] {
        try F.objects(live, client, id, "table", like: #"idx\_record\_log\_text\_%"#)
    }

    private func views(_ client: JsBaoClient, _ id: String, _ model: String) throws -> [String] {
        try live.binding(client, id).store.readView { sql in
            try sql.rows(
                "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE ? ESCAPE '\\' ORDER BY name",
                [.text("idx\\_record\\_log\\_view\\_\(model.utf16.count)\\_\(model.lowercased())\\_%")]
            ).compactMap { $0["name"].stringValue }
        }
    }

    private func policyRows(_ client: JsBaoClient, _ id: String) throws -> Int {
        try live.binding(client, id).store.readView { try $0.first("SELECT COUNT(*) AS n FROM record_log_index_policy")?["n"].intValue ?? 0 }
    }

    // MARK: - Behavior 26 and edge case 45

    func testARegistrationAndADropOverHttpReachAnOpenClientWithoutAReopen() async throws {
        let (client, id) = try await F.subscribed(live, "open")
        let name = try await register(id, ["model": "Note", "fields": ["title", "body"], "kind": "text", "on": "device"])
        try await eventually(timeout: 20, description: "the text index on the open client") { try self.text(client, id).count == 1 }
        let found = try live.member(client, id, "Note").query(["$search": "apple"])
        XCTAssertFalse(found.isEmpty)
        let built = try await status(client, id, name)
        XCTAssertEqual(built, .built)
        try await drop(id, name)
        try await eventually(timeout: 20, description: "the text index to leave the open client") { try self.text(client, id).isEmpty }
        let listed = try await client.db3.indexes.local(id)
        XCTAssertFalse(listed.contains { $0.name == name })
        let state = try await client.db3.state(id)
        XCTAssertEqual(state.phase, .live)
    }

    func testATypeReplacementThatStopsIndexingAFieldRemovesTheDevicesViewIndex() async throws {
        let type = "policy-5322-\(RecordLogLiveApp.ulid().suffix(6).lowercased())"
        let schema = { (indexed: Bool) in "[models.Typed]\n\n[models.Typed.fields.code]\ntype = \"string\"\n\(indexed ? "indexed = true\n" : "")" }
        _ = try await ctx.appRequest(method: "PUT", appId: live.app.appId, path: "/db3-types/\(type)", body: ["schema": schema(true)], jwt: live.app.ownerJWT)
        let id = try await live.db3Written(0, model: "Typed")
        _ = try await ctx.appRequest(method: "PUT", appId: live.app.appId, path: "/db3/\(id)/type", body: ["type": type], jwt: live.app.ownerJWT)
        let typed = PrimitiveSchema(name: "Typed", fields: ["id": FieldDescriptor(type: .id), "code": FieldDescriptor(type: .string)])
        let client = try await live.client("typed", models: [typed])
        try await client.db3.subscribe(id).ready()
        try await eventually(timeout: 20, description: "the declared index on the device") { try !self.views(client, id, "Typed").isEmpty }
        _ = try await ctx.appRequest(method: "PUT", appId: live.app.appId, path: "/db3-types/\(type)", body: ["schema": schema(false)], jwt: live.app.ownerJWT)
        try await eventually(timeout: 20, description: "the declared index to leave the device") { try self.views(client, id, "Typed").isEmpty }
        let listed = try await client.db3.indexes.local(id)
        XCTAssertFalse(listed.contains { $0.model == "Typed" })
    }

    // MARK: - Behavior 29

    func testADeclineOutlivesARestartARefreshARenameAndAnEvictAndDeleteClearsIt() async throws {
        let file = live.file("policy")
        let first = try await F.subscribed(live, "first", file: file)
        let id = first.id
        let textName = try await register(id, ["model": "Note", "fields": ["title", "body"], "kind": "text", "on": "device"])
        let yearName = try await register(id, ["model": "Note", "field": "rank", "on": "device"])
        try await eventually(timeout: 20, description: "both indexes built") {
            let text = try await self.status(first.client, id, textName)
            let year = try await self.status(first.client, id, yearName)
            return text == .built && year == .built
        }
        let declined = try await first.client.db3.indexes.decline(id, name: textName)
        XCTAssertEqual(declined.status, .declined)
        XCTAssertEqual(declined.reason, "declined on this device")
        XCTAssertTrue(try text(first.client, id).isEmpty)
        let refused = await XCTAssertThrowsAsync { _ = try self.live.member(first.client, id, "Note").query(["$search": "apple"]) }
        XCTAssertEqual((refused as? JsBaoError)?.code, .db3IndexDeclinedOnDevice)
        _ = try await first.client.db3.indexes.decline(id, name: yearName)
        await first.client.destroy()

        // Restarted over the same file.
        let restarted = try await live.client("restarted", models: [F.note], file: file)
        try await restarted.db3.subscribe(id).ready()
        let afterRestart = try await status(restarted, id, textName)
        XCTAssertEqual(afterRestart, .declined)
        // A refresh: another index registered, built here; the declined one is not.
        let labels = try await register(id, ["model": "Note", "field": "labels", "kind": "members", "on": "device"])
        try await eventually(timeout: 20, description: "the new index built") { try await self.status(restarted, id, labels) == .built }
        XCTAssertTrue(try text(restarted, id).isEmpty)
        // Dropped and registered again under another name.
        try await drop(id, yearName)
        let renamed = try await register(id, ["model": "Note", "field": "rank", "name": "ranked", "on": "device"])
        try await eventually(timeout: 20, description: "the renamed index listed") { try await self.status(restarted, id, renamed) != nil }
        let renamedStatus = try await status(restarted, id, renamed)
        XCTAssertEqual(renamedStatus, .declined)
        // Evicted, the file's last db3: subscribed again, still declined.
        restarted.db3.unsubscribe(id)
        try await restarted.db3.evict(id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file))
        try await restarted.db3.subscribe(id).ready()
        let afterEvict = try await status(restarted, id, textName)
        XCTAssertEqual(afterEvict, .declined)
        XCTAssertGreaterThan(try policyRows(restarted, id), 0)
        // Accepted: rebuilt, equal to a rebuild from the rows.
        let accepted = try await restarted.db3.indexes.accept(id, name: textName)
        XCTAssertEqual(accepted.status, .built)
        let drift = try await Db3DeviceIndexOracle.driftOnACopy(try live.binding(restarted, id).store)
        XCTAssertEqual(drift, [])
        // Deleted: the policy goes with it.
        _ = try await restarted.db3.indexes.decline(id, name: textName)
        let store = try live.binding(restarted, id).store
        _ = try await restarted.db3.delete(id)
        try await eventually(timeout: 20, description: "the policy cleared") {
            try store.readView { try $0.first("SELECT COUNT(*) AS n FROM record_log_index_policy WHERE doc_id = ?", [.text(id)])?["n"].intValue } == 0
        }
    }

    func testAScalarBuildThatFillsTheDiskHoldsNoReadyAndIsBuiltOnceThereIsRoom() async throws {
        let (client, id) = try await F.subscribed(live, "full", write: false)
        let note = F.note
        for n in 0..<300 {
            try await client.codegen.save(note, id: RecordLogLiveApp.ulid(), values: [
                "title": .string(String(repeating: "a long and wordy title for the full disk ", count: 8) + "\(n)"), "rank": .number(Double(n)),
            ], in: id, confirm: false)
        }
        try await live.settled(client, id)
        let store = try live.binding(client, id).store
        let restore = try limitPages(store, headroom: 3)
        let title = try await register(id, ["model": "Note", "field": "title", "on": "device"])
        try await eventually(timeout: 20, description: "the index listed") { try await self.status(client, id, title) != nil }
        let unbuilt = try await client.db3.indexes.local(id).first { $0.name == title }
        XCTAssertEqual(unbuilt?.status, .unbuilt)
        XCTAssertTrue(unbuilt?.reason?.contains("disk is full") == true, "\(String(describing: unbuilt?.reason))")
        let started = Date()
        try await client.db3.subscribe(id).ready()
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
        let found = try live.member(client, id, "Note").query(["rank": .number(7)])
        XCTAssertEqual(found.count, 1)
        try restore()
        _ = try await register(id, ["model": "Note", "field": "rank", "on": "device"])
        try await eventually(timeout: 20, description: "the title index built once there is room") { try await self.status(client, id, title) == .built }
    }

    /// Lower the store's page limit to `headroom` pages above what it holds, the free list taken first; answers what puts it back.
    private func limitPages(_ store: RecordLogStore, headroom: Int) throws -> () throws -> Void {
        let run = { (sql: String) throws -> Int in
            try self.onConnection(store) { connection in try connection.query(sql, []).first?.columns.values.first?.intValue ?? 0 }
        }
        let saved = try run("PRAGMA max_page_count")
        var rounds = 0
        while try run("PRAGMA freelist_count") > 0, rounds < 50 {
            let free = try run("PRAGMA freelist_count")
            try onConnection(store) { connection in
                try connection.executeScript("CREATE TABLE IF NOT EXISTS pl_disk_filler_5322 (b BLOB)")
                try connection.execute(
                    "INSERT INTO pl_disk_filler_5322 (b) WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?) SELECT zeroblob(3800) FROM n",
                    [.integer(Int64(free))]
                )
            }
            rounds += 1
        }
        let pages = try run("PRAGMA page_count")
        XCTAssertEqual(try run("PRAGMA max_page_count = \(pages + headroom)"), pages + headroom)
        return {
            XCTAssertEqual(try run("PRAGMA max_page_count = \(saved)"), saved)
            try self.onConnection(store) { try $0.executeScript("DROP TABLE IF EXISTS pl_disk_filler_5322") }
        }
    }

    private func onConnection<T>(_ store: RecordLogStore, _ body: @escaping (any Format2SqlConnection) throws -> T) throws -> T {
        try store.flush()
        if let host = store.host as? any RecordLogGroupCommitHost { return try host.withRecordLogConnection(body) }
        return try store.host.withConnection(body)
    }
}

/// The error `body` throws, or a failure when it throws none.
private func XCTAssertThrowsAsync(
    _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
) async -> Error? {
    do {
        try await body()
        XCTFail("expected a throw", file: file, line: line)
        return nil
    } catch {
        return error
    }
}
