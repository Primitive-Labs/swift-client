import XCTest
@testable import JsBaoClient

/// #5223 behavior 19 — a device text index on a synced db3, live against the
/// dev server: `register` with `kind: .text, on: .device` and text options
/// resolves with the options filled in and the device's FTS5 table and its
/// three triggers built before it returns; `$search` through the model
/// answers ranked rows with `_score`, and `count`; a prefix search finds
/// `Running notes`; `list` shows the index; `drop` removes the table before
/// it returns, after which a `$search` is refused `.queryIndexNotOnDevice`.
final class Db3DeviceTextIndexLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private typealias L = Db3DeviceIndexLiveFixture

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-device-text-5223")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    func testRegistersADeviceTextIndexSearchesItWithScoreListsItAndDropsIt() async throws {
        let (x, id) = try await L.subscribed(live, "x")
        let registered = try await x.db3.indexes.register(id, Db3IndexRegistration(
            model: "Note", fields: ["title", "body"], kind: .text, on: .device,
            text: Db3TextIndexOptions(tokenizer: .porter, weights: ["title": 3])
        ))
        XCTAssertEqual(registered.name, "idx_text_note")
        XCTAssertEqual(registered.kind, .text)
        XCTAssertEqual(registered.on, .device)
        XCTAssertEqual(registered.fields, ["title", "body"])
        XCTAssertFalse(registered.unique)
        XCTAssertEqual(registered.origins, [Db3IndexOrigin(kind: .named, unique: false)])
        XCTAssertEqual(registered.text, Db3TextIndex(tokenizer: .porter, prefix: [], weights: ["title": 3, "body": 1]))
        // Built before register returned: the table and its three triggers.
        let table = RecordLogIndexes.textTableName(documentId: id, model: "Note")
        XCTAssertEqual(try L.objects(live, x, id, "table", like: table), [table])
        XCTAssertEqual(try L.objects(live, x, id, "trigger", like: "\(table)__%"), ["\(table)__d", "\(table)__i", "\(table)__u"])

        let notes = x.sharedModel(for: L.note)
        let found = try notes.query(["$search": "apple"])
        let titles = found.compactMap { $0["title"]?.stringValue }
        XCTAssertEqual(titles.first, "Apple apple apple")
        XCTAssertEqual(Set(titles), ["Red apple pie", "Green apple", "Apple apple apple", "Pear tart"])
        let scores = found.compactMap { $0["_score"]?.numberValue }
        XCTAssertEqual(scores.count, 4)
        XCTAssertEqual(scores, scores.sorted(by: >))
        XCTAssertEqual(try notes.count(["$search": "apple"]), 4)
        XCTAssertEqual(try notes.query(["$search": ["query": "runn", "prefix": true]]).first?["title"], "Running notes")
        XCTAssertEqual(try notes.query(["$search": "run"]).compactMap { $0["title"]?.stringValue }, ["Running notes"])
        let records = try x.db3.records(id).query("Note", ["$search": ["query": "tart", "fields": ["title"]]])
        XCTAssertEqual(records.data.compactMap { $0["title"]?.stringValue }, ["Pear tart"])
        XCTAssertNotNil(records.data.first?["_score"]?.numberValue)

        let listed = try await x.db3.indexes.list(id)
        XCTAssertEqual(listed.first { $0.kind == .text }, registered)

        try await x.db3.indexes.drop(id, name: registered.name)
        XCTAssertEqual(try L.objects(live, x, id, "table", like: table), [], "dropped before drop returned")
        XCTAssertEqual(try L.objects(live, x, id, "trigger", like: "\(table)__%"), [])
        XCTAssertThrowsError(try notes.query(["$search": "apple"])) {
            XCTAssertEqual(($0 as? JsBaoError)?.code, .queryIndexNotOnDevice, "\($0)")
        }
    }
}
