import XCTest
@testable import JsBaoClient

/// #5356 — `client.db3.records(_:)` is the db3 entry to a db3's local
/// records, the successor of the deprecated `client.documents.records(_:)`:
/// it answers what that member answers, with no server.
///
/// The db3 is adopted from a `POST db3` answer, so it is resident at once and
/// every write stays in this device's store.
final class Db3RecordsEntryHermeticTests: XCTestCase {

    private static let db3Id = "01JD5356DB3REC0RDSXXXXXXXX"
    private static let notHere = "01JD5356DB3REC0RDSN0THEREX"
    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    /// A client over its own SQLite store with no server, holding `db3Id`
    /// adopted from its create answer.
    private func db3Client() async throws -> JsBaoClient {
        let directory = NSTemporaryDirectory() + "/db3-records-entry-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "db3-records-entry-5356",
            token: makeTestJwt(userId: "user-a"),
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        let answer = """
        {"id": "\(Self.db3Id)", "title": "Notes", "createdBy": "user-a", "createdAt": "2026-11-07T00:00:00.000Z",
         "modifiedAt": "2026-11-07T00:00:00.000Z", "custodian": "user:user-a", "sync": true, "type": null, "tags": []}
        """
        _ = try await Db3API(lifecycle: client._db3Lifecycle, transport: RecordingTransport(status: 201, json: answer), client: client)
            .create(title: "Notes", custodian: "user:user-a")
        XCTAssertTrue(try XCTUnwrap(client.recordLogBinding(Self.db3Id)).isResident)
        return client
    }

    private func refusal(_ body: () throws -> Void) -> JsBaoError? {
        do {
            try body()
            return nil
        } catch let error as JsBaoError {
            return error
        } catch {
            XCTFail("not a JsBaoError: \(error)")
            return nil
        }
    }

    func testDb3RecordsWritesAndReadsTheDb3sLocalCopy() async throws {
        let client = try await db3Client()
        let records = client.db3.records(Self.db3Id)
        XCTAssertEqual(records.documentId, Self.db3Id)
        let note = try records.put("Note", ["title": "Groceries", "done": false])
        let id = try XCTUnwrap(note["id"]?.stringValue)
        XCTAssertEqual(try records.get("Note", id: id)?.raw["title"]?.stringValue, "Groceries")
        XCTAssertEqual(try records.count("Note", ["done": false]), 1)
        XCTAssertEqual(try client.db3.records(Self.db3Id).query("Note").data.map { $0.raw["id"]?.stringValue }, [id])
    }

    func testDb3RecordsOnADb3NotOpenHereIsNotFound() async throws {
        let client = try await db3Client()
        let error = refusal { _ = try client.db3.records(Self.notHere).query("Note") }
        XCTAssertEqual(error?.code, .notFound)
        XCTAssertEqual(error?.details?["documentId"], .string(Self.notHere))
    }

    @available(*, deprecated)
    func testTheDeprecatedDocumentsEntryAnswersWhatDb3RecordsAnswers() async throws {
        let client = try await db3Client()
        let note = try client.db3.records(Self.db3Id).put("Note", ["title": "Shared"])
        let id = try XCTUnwrap(note["id"]?.stringValue)
        let viaDocuments = try client.documents.records(Self.db3Id).query("Note").data.map(\.raw)
        let viaDb3 = try client.db3.records(Self.db3Id).query("Note").data.map(\.raw)
        XCTAssertEqual(viaDocuments, viaDb3)
        XCTAssertEqual(viaDb3.first?["id"]?.stringValue, id)
        let fromDocuments = refusal { _ = try client.documents.records(Self.notHere).count("Note") }
        let fromDb3 = refusal { _ = try client.db3.records(Self.notHere).count("Note") }
        XCTAssertEqual(fromDocuments?.code, fromDb3?.code)
        XCTAssertEqual(fromDocuments?.message, fromDb3?.message)
    }
}
