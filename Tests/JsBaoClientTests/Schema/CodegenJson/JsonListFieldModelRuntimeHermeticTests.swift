import XCTest
@testable import JsBaoClient

/// #6307 behavior 16 — a db3 JSON field whose def is a list, through the
/// committed model swift-bao-codegen writes for `db3-types/shop.toml` and the
/// `Generated/` shared file `primitive functions codegen --lang swift` writes,
/// compiled together and run against a real client with no server.
///
/// `tags` refs `ShipTags` (`[String]`) and `stops` refs `ShipStops`
/// (`[ShipAddress]`, the object def named by its items). A saved list is
/// stored as the array's canonical text and reads back equal; a list the def
/// excludes is refused `Db3JSONValueError` and nothing is written; stored text
/// whose root is an object reads `nil` and keeps its text.
final class JsonListFieldModelRuntimeHermeticTests: XCTestCase {

    private static let db3Id = "01JD6307JSONLISTFIELDSXXXX"
    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        JsBaoClient.clearDefault()
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    /// A client over its own SQLite store with no server, holding the db3 `db3Id`, configured as the default client.
    private func client() async throws -> JsBaoClient {
        let directory = NSTemporaryDirectory() + "/json-list-field-model-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "json-list-field-model-6307",
            token: makeTestJwt(userId: "user-a"),
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        client.registerModels([JsonOrderRecord.self, JsonReceiptRecord.self])
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        JsBaoClient.configureDefault(client)
        let answer = """
        {"id": "\(Self.db3Id)", "title": "Shop", "createdBy": "user-a", "createdAt": "2026-11-19T00:00:00.000Z",
         "modifiedAt": "2026-11-19T00:00:00.000Z", "custodian": "user:user-a", "sync": true, "type": null, "tags": []}
        """
        _ = try await Db3API(lifecycle: client._db3Lifecycle, transport: RecordingTransport(status: 201, json: answer), client: client)
            .create(title: "Shop", custodian: "user:user-a")
        return client
    }

    private func stored(_ client: JsBaoClient, _ id: String) -> [String: JSONValue]? {
        client.codegen.find(JsonOrderRecord.primitiveSchema, id: id)
    }

    func testAListIsStoredAsTheArraysCanonicalTextAndReadsBackEqual() async throws {
        let client = try await client()
        let stops = [ShipAddress(city: "Lisbon", zip: "1000-001"), ShipAddress(city: "Porto")]
        let order = JsonOrderRecord(id: "l1", title: "Trip", tags: ["b", "a"], stops: stops)
        let saved = try order.save(in: Self.db3Id)
        let row = try XCTUnwrap(stored(client, "l1"))
        XCTAssertEqual(row["tags"], .string(#"["b","a"]"#))
        XCTAssertEqual(row["stops"], .string(#"[{"city":"Lisbon","zip":"1000-001"},{"city":"Porto"}]"#))
        for (path, read) in [("save", saved), ("find", try XCTUnwrap(try JsonOrderRecord.find("l1"))), ("row", try XCTUnwrap(JsonOrderRecord(row: row)))] {
            XCTAssertEqual(read.tags, ["b", "a"], path)
            XCTAssertEqual(read.stops, stops, path)
            XCTAssertEqual(read.tagsRaw, #"["b","a"]"#, path)
        }
        let empty = try JsonOrderRecord(id: "l2", tags: []).save(in: Self.db3Id)
        XCTAssertEqual(empty.tags, [])
        XCTAssertEqual(stored(client, "l2")?["tags"], .string("[]"))
    }

    func testAListTheDefExcludesThrowsAndWritesNothing() async throws {
        let client = try await client()
        for (tags, path, reason) in [(["a", ""], "value[1]", "value[1] must be at least 1 characters"),
                                     (["a", "b", "c", "d"], "value", "value must have at most 3 items")] {
            do {
                _ = try JsonOrderRecord(id: "bad", tags: tags).save(in: Self.db3Id)
                XCTFail("expected a Db3JSONValueError for \(tags)")
            } catch let error as Db3JSONValueError {
                XCTAssertEqual(error, Db3JSONValueError(model: "json_orders", field: "tags", def: "schemas.common.ShipTags", path: path, reason: reason, kind: .schema))
            }
            XCTAssertNil(stored(client, "bad"))
        }
        do {
            _ = try JsonOrderRecord(id: "bad", stops: [ShipAddress(city: "")]).save(in: Self.db3Id)
            XCTFail("expected a Db3JSONValueError")
        } catch let error as Db3JSONValueError {
            XCTAssertEqual(error.path, "value[0].city")
        }
        XCTAssertNil(stored(client, "bad"))
    }

    func testStoredTextWhoseRootIsAnObjectReadsNilAndKeepsItsText() async throws {
        let client = try await client()
        let record = try client.codegen.save(JsonOrderRecord.primitiveSchema, id: "l3", values: ["tags": .string(#"{"a":"b"}"#)], in: Self.db3Id)
        let order = try XCTUnwrap(JsonOrderRecord(record: record))
        XCTAssertNil(order.tags)
        XCTAssertEqual(order.tagsRaw, #"{"a":"b"}"#)
        XCTAssertTrue(Db3JSONMisreads.wasReported(model: "json_orders", field: "tags"))
    }
}
