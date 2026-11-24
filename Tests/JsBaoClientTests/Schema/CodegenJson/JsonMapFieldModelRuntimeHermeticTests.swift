import XCTest
@testable import JsBaoClient

/// #6307 behaviors 27 and 29 — a db3 JSON field whose def is a map with typed
/// values, through the committed model swift-bao-codegen writes for
/// `db3-types/shop.toml` and the `Generated/` shared file `primitive functions
/// codegen --lang swift` writes, compiled together and run against a real
/// client with no server.
///
/// `weights` refs `ShipWeights` (`[String: Double]`, each value at least 0);
/// `keyed` refs `ShipKeyed`, whose required key `id` is not declared in
/// `properties` and so is a `Double` property beside a `[String: Double]`
/// catch-all. A saved map is stored as its canonical text and reads back
/// equal; a value the value schema excludes is refused `Db3JSONValueError` and
/// nothing is written; text without `id` does not decode as `ShipKeyed`.
final class JsonMapFieldModelRuntimeHermeticTests: XCTestCase {

    private static let db3Id = "01JD6307JSONMAPFIELDSXXXXX"
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
        let directory = NSTemporaryDirectory() + "/json-map-field-model-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "json-map-field-model-6307",
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

    func testAMapIsStoredAsItsCanonicalTextAndReadsBackEqual() async throws {
        let client = try await client()
        let keyed = ShipKeyed(id: 1, extra: ["x": 2])
        let order = JsonOrderRecord(id: "m1", title: "Weighted", weights: ["b": 2, "a": 1.5], keyed: keyed)
        let saved = try order.save(in: Self.db3Id)
        let row = try XCTUnwrap(stored(client, "m1"))
        XCTAssertEqual(row["weights"], .string(#"{"a":1.5,"b":2}"#))
        XCTAssertEqual(row["keyed"], .string(#"{"id":1,"x":2}"#))
        for (path, read) in [("save", saved), ("find", try XCTUnwrap(try JsonOrderRecord.find("m1"))), ("row", try XCTUnwrap(JsonOrderRecord(row: row)))] {
            XCTAssertEqual(read.weights, ["a": 1.5, "b": 2], path)
            XCTAssertEqual(read.keyed, keyed, path)
            XCTAssertEqual(read.keyed?.extra["id"], nil, path)
        }
        let empty = try JsonOrderRecord(id: "m2", weights: [:]).save(in: Self.db3Id)
        XCTAssertEqual(empty.weights, [:])
        XCTAssertEqual(stored(client, "m2")?["weights"], .string("{}"))
    }

    func testAMapValueTheDefExcludesThrowsAndWritesNothing() async throws {
        let client = try await client()
        do {
            _ = try JsonOrderRecord(id: "bad", weights: ["a": 1, "b": -1]).save(in: Self.db3Id)
            XCTFail("expected a Db3JSONValueError")
        } catch let error as Db3JSONValueError {
            XCTAssertEqual(error, Db3JSONValueError(model: "json_orders", field: "weights", def: "schemas.common.ShipWeights",
                                                    path: "value.b", reason: "value.b must be >= 0", kind: .schema))
        }
        XCTAssertNil(stored(client, "bad"))
    }

    func testARequiredUndeclaredKeyIsTypedAndTextWithoutItDoesNotDecode() async throws {
        let client = try await client()
        XCTAssertEqual(Db3JSONDef_common_ShipKeyed.value(fromStored: #"{"id":1,"x":2}"#, model: "json_orders6307", field: "keyed"),
                       ShipKeyed(id: 1, extra: ["x": 2]))
        XCTAssertNil(Db3JSONDef_common_ShipKeyed.value(fromStored: #"{"x":2}"#, model: "json_orders6307", field: "keyed"))
        let record = try client.codegen.save(JsonOrderRecord.primitiveSchema, id: "m3", values: ["keyed": .string(#"{"x":2}"#)], in: Self.db3Id)
        let order = try XCTUnwrap(JsonOrderRecord(record: record))
        XCTAssertNil(order.keyed)
        XCTAssertEqual(order.keyedRaw, #"{"x":2}"#)
    }
}
