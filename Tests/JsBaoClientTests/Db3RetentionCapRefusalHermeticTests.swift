import XCTest
@testable import JsBaoClient

/// #5112 behaviors 10 to 14 and edge cases E4 to E6 — `maxDocs: 0` (or a
/// negative) is refused at the client's one retention policy, on a client
/// with no server.
///
/// The db3 door `client.db3.setRetentionPolicy(_:)` throws
/// `INVALID_ARGUMENT` and logs nothing; the `retentionPolicy` property, which
/// cannot throw, leaves the policy and the run chain as they were and logs one
/// error line. Either way no format-1 row is evicted, where `0` used to evict
/// every one. `nil` stays no cap.
final class Db3RetentionCapRefusalHermeticTests: XCTestCase {

    private var directories: [String] = []
    private var clients: [JsBaoClient] = []
    private var lines: ThreadSafeBox<[(LogLevel, String, String)]>!

    override func setUp() {
        super.setUp()
        let lines = ThreadSafeBox<[(LogLevel, String, String)]>([])
        self.lines = lines
        Logger.lineForTest = { level, scope, message in lines.mutate { $0.append((level, scope, message)) } }
    }

    override func tearDown() async throws {
        Logger.lineForTest = nil
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    /// A client signed in as `user-a` over its own SQLite store, with no server, logging at debug.
    private func client() async throws -> JsBaoClient {
        let directory = NSTemporaryDirectory() + "/db3-retention-cap-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "db3-retention-cap-5112",
            token: makeTestJwt(userId: "user-a"),
            logLevel: .debug,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        return client
    }

    /// Three local format-1 documents on `client`, by id.
    private func formatOne(_ client: JsBaoClient) async throws -> [String] {
        var ids: [String] = []
        for n in 1...3 {
            let id = "01JD5112F1R0W\(n)XXXXXXXXXXXX"
            _ = try await client.documentManager.createLocalDocument(documentId: id, title: "f\(n)", localOnly: true)
            ids.append(id)
        }
        XCTAssertEqual(Set(client.documentManager.getMetadataIndex().keys).intersection(ids).count, 3)
        return ids
    }

    private func remaining(_ client: JsBaoClient, _ ids: [String]) -> Int {
        Set(client.documentManager.getMetadataIndex().keys).intersection(ids).count
    }

    /// The lines written since `mark` that are about retention or `maxDocs`.
    private func retentionLines(since mark: Int) -> [(LogLevel, String, String)] {
        Array(lines.value.dropFirst(mark)).filter { $0.2.contains("maxDocs") || $0.2.contains("retention") }
    }

    private func refusal(_ body: () throws -> Void) -> JsBaoError? {
        do {
            try body()
            XCTFail("expected the call to throw")
            return nil
        } catch let error as JsBaoError {
            return error
        } catch {
            XCTFail("expected a JsBaoError, got \(error)")
            return nil
        }
    }

    // MARK: - The db3 door

    /// Behavior 10 and E4: `maxDocs: 0` through the db3 door throws
    /// `.invalidArgument`, changes nothing, starts no run and logs nothing.
    func testTheDb3DoorRefusesZeroAndLogsNothing() async throws {
        let client = try await client()
        let mark = lines.value.count
        let error = refusal { try client.db3.setRetentionPolicy(RetentionPolicy(maxDocs: 0)) }
        XCTAssertEqual(error?.code, .invalidArgument)
        XCTAssertTrue(error?.message.contains("client.db3.setRetentionPolicy") == true, error?.message ?? "")
        XCTAssertTrue(error?.message.contains("maxDocs") == true, error?.message ?? "")
        XCTAssertTrue(error?.message.contains("nil") == true, error?.message ?? "")
        XCTAssertEqual(error?.details?["maxDocs"], .number(0))
        XCTAssertNil(client.retentionPolicy.maxDocs)
        XCTAssertNil(client.retentionEnforcement)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(retentionLines(since: mark).isEmpty, "\(retentionLines(since: mark))")
    }

    /// Behavior 11: a negative is refused the same way, the message naming it.
    func testTheDb3DoorRefusesANegative() async throws {
        let client = try await client()
        let error = refusal { try client.db3.setRetentionPolicy(RetentionPolicy(maxDocs: -1)) }
        XCTAssertEqual(error?.code, .invalidArgument)
        XCTAssertTrue(error?.message.contains("-1") == true, error?.message ?? "")
        XCTAssertEqual(error?.details?["maxDocs"], .number(-1))
        XCTAssertNil(client.retentionPolicy.maxDocs)
        XCTAssertNil(client.retentionEnforcement)
    }

    // MARK: - The property

    /// Behavior 12 and E5: the property leaves an earlier cap in place, writes
    /// one error line per refused set and starts no sweep.
    func testThePropertyKeepsTheEarlierCapAndLogsOneErrorLine() async throws {
        let client = try await client()
        client.retentionPolicy = RetentionPolicy(maxDocs: 2)
        await client.retentionEnforcement?.value
        let run = try XCTUnwrap(client.retentionEnforcement)
        let mark = lines.value.count

        client.retentionPolicy = RetentionPolicy(maxDocs: 0)
        XCTAssertEqual(client.retentionPolicy.maxDocs, 2)
        client.retentionPolicy = RetentionPolicy(maxDocs: 0)
        XCTAssertEqual(client.retentionPolicy.maxDocs, 2)
        XCTAssertTrue(client.retentionEnforcement == run, "a refused set starts no retention run")
        try await Task.sleep(nanoseconds: 100_000_000)

        let written = retentionLines(since: mark)
        let errors = written.filter { $0.0 == .error }
        XCTAssertEqual(errors.count, 2, "\(written)")
        for line in errors {
            XCTAssertTrue(line.2.contains("client.retentionPolicy"), line.2)
            XCTAssertTrue(line.2.contains("maxDocs"), line.2)
            XCTAssertTrue(line.2.contains("nil"), line.2)
        }
        XCTAssertTrue(written.filter { $0.2.hasPrefix("[db3] retention:") }.isEmpty, "\(written)")
    }

    /// E6: a `nil` cap after a refused set is accepted with no error line.
    func testANilCapAfterARefusalIsAccepted() async throws {
        let client = try await client()
        client.retentionPolicy = RetentionPolicy(maxDocs: 2)
        await client.retentionEnforcement?.value
        client.retentionPolicy = RetentionPolicy(maxDocs: 0)
        XCTAssertEqual(client.retentionPolicy.maxDocs, 2)
        let mark = lines.value.count
        client.retentionPolicy = RetentionPolicy()
        await client.retentionEnforcement?.value
        XCTAssertNil(client.retentionPolicy.maxDocs)
        XCTAssertTrue(retentionLines(since: mark).filter { $0.0 == .error }.isEmpty)
    }

    // MARK: - Format-1 documents

    /// Behavior 13: `maxDocs: 0` through the property evicts no format-1 row.
    func testZeroThroughThePropertyEvictsNoFormatOneRow() async throws {
        let client = try await client()
        let ids = try await formatOne(client)
        client.retentionPolicy = RetentionPolicy(maxDocs: 0)
        await client.retentionEnforcement?.value
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(remaining(client, ids), 3)
    }

    /// Behavior 14: a `nil` cap keeps every format-1 row and logs no error.
    func testANilCapKeepsEveryFormatOneRow() async throws {
        let client = try await client()
        let ids = try await formatOne(client)
        let mark = lines.value.count
        client.retentionPolicy = RetentionPolicy()
        await client.retentionEnforcement?.value
        XCTAssertEqual(remaining(client, ids), 3)
        XCTAssertTrue(retentionLines(since: mark).filter { $0.0 == .error }.isEmpty)
    }
}
