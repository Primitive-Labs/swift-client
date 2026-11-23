import Foundation
import XCTest
@testable import JsBaoClient
import YSwift

/// #6304 behavior 60, the Swift model's side — `ParityRecord`, the committed
/// model swift-bao-codegen writes for `db3-types/parity.toml`
/// (`ReadDefaultParityCodegenHermeticTests` holds it to the tool), reads each value
/// `tests/fixtures/read-default-parity-6304/parity.json` stores in a db3
/// record as the field's default exactly where that file says, through
/// `init?(record:)` and through `init?(row:)` over the rows `find` and a query
/// answer. The web getter, the room, the `Db3` row and the row projection are
/// held to the same file by `cli/tests/unit/read-default-parity-6304.test.ts`
/// and `tests/unit/workflows/record-room-read-default-parity-6304.test.ts`.
final class ReadDefaultParityHermeticTests: XCTestCase {

    private static let db3Id = "01JD6304PAR1TYSW1FTXXXXXXX"
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

    private struct Fixture: Decodable {
        struct Stored: Decodable {
            let id: String
            let field: String
            let absent: Bool?
            let value: JSONValue?
            let readsDefault: Bool
        }
        let model: String
        let readDefaulted: [String]
        let defaults: [String: JSONValue]
        let stored: [Stored]
    }

    private func fixture() throws -> Fixture {
        var url = URL(fileURLWithPath: #filePath)
        // The file, CodegenReadDefaultParity, Schema, JsBaoClientTests, Tests, swift-client.
        for _ in 0..<6 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appendingPathComponent("tests/fixtures/read-default-parity-6304/parity.json"))
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    private static var schema: PrimitiveSchema { ParityRecord.primitiveSchema }

    /// The fields `parity.toml` declares and does not clear, as the db3's type holds them.
    private static let declared: [String: [String: String]] = ["parity": [
        "title": "string", "label": "string", "blank": "string", "count": "number", "score": "number", "zero": "number",
        "flag": "boolean", "on": "boolean", "off": "boolean", "seen": "date", "due": "date", "owner": "id",
        "rank": "number", "made": "date", "price": "string", "tags": "stringset", "shipping": "string", "embedding": "vector",
    ]]

    /// A client over its own SQLite store with no server, holding the db3
    /// `db3Id` of the `parity` type, with `ParityRecord` registered.
    private func client() async throws -> JsBaoClient {
        let directory = NSTemporaryDirectory() + "/read-default-parity-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "read-default-parity-6304",
            token: makeTestJwt(userId: "user-a"),
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        client.registerModels([Self.schema])
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        JsBaoClient.configureDefault(client)
        let answer = """
        {"id": "\(Self.db3Id)", "title": "Parity", "createdBy": "user-a", "createdAt": "2026-11-22T00:00:00.000Z",
         "modifiedAt": "2026-11-22T00:00:00.000Z", "custodian": "user:user-a", "sync": true, "type": null, "tags": []}
        """
        _ = try await Db3API(lifecycle: client._db3Lifecycle, transport: RecordingTransport(status: 201, json: answer), client: client)
            .create(title: "Parity", custodian: "user:user-a")
        let binding = try XCTUnwrap(client.recordLogBinding(Self.db3Id))
        try binding.setState(type: .typed(name: "parity", hash: "h1", models: Self.declared))
        return client
    }

    /// Record `id` built by `ParityRecord` through each real path, by the path's name.
    private func reads(_ client: JsBaoClient, _ id: String) throws -> [(String, ParityRecord?)] {
        let found = try XCTUnwrap(client.codegen.find(Self.schema, id: id), id)
        let queried = try XCTUnwrap(
            try client.codegen.query(Self.schema, options: QueryOptions(db3: [Self.db3Id])).first { $0["id"]?.stringValue == id }, id
        )
        let record = try XCTUnwrap(client.sharedModel(for: Self.schema).member(docId: Self.db3Id)?.find(id: id), id)
        return [("find", ParityRecord(row: found)), ("query", ParityRecord(row: queried)), ("record", ParityRecord(record: record))]
    }

    /// What `parity` reads for a read-defaulted field, as JSON.
    private func value(_ parity: ParityRecord, _ field: String) -> JSONValue? {
        switch field {
        case "label": return .string(parity.label)
        case "blank": return .string(parity.blank)
        case "score": return .number(parity.score)
        case "zero": return .number(parity.zero)
        case "on": return .bool(parity.on)
        case "off": return .bool(parity.off)
        case "due": return .string(parity.due)
        case "owner": return .string(parity.owner)
        case "rank": return .number(parity.rank)
        default: return nil
        }
    }

    /// Write record `id` holding exactly `fields`, as another client or a workflow could have stored it.
    private func store(_ client: JsBaoClient, _ id: String, _ fields: [String: JSONValue]) throws {
        var values = fields
        values["id"] = .string(id)
        _ = try XCTUnwrap(client.recordLogBinding(Self.db3Id)).commit([RecordLogWrite(mutations: [
            RecordLogMutation(model: Self.schema.name, id: id, kind: .create, fields: values),
        ])])
    }

    func testARecordHoldingNothingIsSuppliedExactlyTheFixturesReadDefaultedFields() async throws {
        let fixture = try fixture()
        XCTAssertEqual(fixture.model, Self.schema.name)
        let client = try await client()
        try store(client, "empty", [:])
        for (path, read) in try reads(client, "empty") {
            let parity = try XCTUnwrap(read, "\(path): the record is built")
            XCTAssertEqual(parity._suppliedDefaults, Set(fixture.readDefaulted), path)
            for field in fixture.readDefaulted {
                XCTAssertEqual(value(parity, field), fixture.defaults[field], "\(path): \(field)")
            }
        }
    }

    func testEachStoredValueReadsTheDefaultExactlyWhereTheFixtureSays() async throws {
        let fixture = try fixture()
        let client = try await client()
        for entry in fixture.stored {
            try store(client, entry.id, entry.absent == true ? [:] : [entry.field: entry.value ?? .null])
        }
        for entry in fixture.stored {
            let expected = try XCTUnwrap(fixture.defaults[entry.field], entry.field)
            for (path, read) in try reads(client, entry.id) {
                let parity = try XCTUnwrap(read, "\(entry.id), \(path): the record is built")
                let read = try XCTUnwrap(value(parity, entry.field), entry.field)
                XCTAssertEqual(read == expected, entry.readsDefault, "\(entry.id), \(path): \(entry.field) stored \(entry.value.map { "\($0)" } ?? "absent") reads \(read)")
            }
        }
    }
}
