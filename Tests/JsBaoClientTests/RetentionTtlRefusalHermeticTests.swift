import XCTest
@testable import JsBaoClient

/// #5421 behaviors 9 to 12 — `ttl: 0` (or a negative, or a non-finite
/// number) is refused at the client's one retention policy, on a client with
/// no server, as #5112 refuses `maxDocs: 0`.
///
/// The db3 door `client.db3.setRetentionPolicy(_:)` throws
/// `INVALID_ARGUMENT` and logs nothing; the `retentionPolicy` property, which
/// cannot throw, leaves the policy and the run chain as they were and logs one
/// error line. Either way no format-1 row is evicted, where `0` used to evict
/// every dated one. `nil` stays no TTL, and a positive fraction stays a TTL.
final class RetentionTtlRefusalHermeticTests: XCTestCase {

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
        let directory = NSTemporaryDirectory() + "/retention-ttl-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "retention-ttl-5421",
            token: makeTestJwt(userId: "user-a"),
            logLevel: .debug,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        return client
    }

    /// Three format-1 rows on `client`, last opened a minute ago, by id.
    private func formatOne(_ client: JsBaoClient) async throws -> [String] {
        let manager = client.documentManager
        let store = try XCTUnwrap(manager.offlineStore)
        let opened = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let ids = (1...3).map { "01JD5421F1R0W\($0)XXXXXXXXXXXX" }
        try await store.putMetadataBatch(
            appId: manager.appId,
            userId: manager.userId,
            records: ids.map { LocalMetadataEntry(documentId: $0, lastOpenedAt: opened, localBytes: 100) }
        )
        await manager.loadLocalMetadata()
        XCTAssertEqual(remaining(client, ids), 3)
        return ids
    }

    private func remaining(_ client: JsBaoClient, _ ids: [String]) -> Int {
        Set(client.documentManager.getMetadataIndex().keys).intersection(ids).count
    }

    /// The lines written since `mark` that are about retention or `ttl`.
    private func retentionLines(since mark: Int) -> [(LogLevel, String, String)] {
        Array(lines.value.dropFirst(mark)).filter { $0.2.contains("ttl") || $0.2.contains("retention") }
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

    /// Behavior 9: `ttl: 0` through the db3 door throws `.invalidArgument`,
    /// changes nothing, starts no run and logs nothing.
    func testTheDb3DoorRefusesZeroAndLogsNothing() async throws {
        let client = try await client()
        let mark = lines.value.count
        let error = refusal { try client.db3.setRetentionPolicy(RetentionPolicy(ttl: 0)) }
        XCTAssertEqual(error?.code, .invalidArgument)
        XCTAssertTrue(error?.message.contains("client.db3.setRetentionPolicy") == true, error?.message ?? "")
        XCTAssertTrue(error?.message.contains("ttl") == true, error?.message ?? "")
        XCTAssertTrue(error?.message.contains("pass nil for no TTL") == true, error?.message ?? "")
        XCTAssertEqual(error?.details?["ttl"], .number(0))
        XCTAssertNil(client.retentionPolicy.ttl)
        XCTAssertNil(client.retentionEnforcement)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(retentionLines(since: mark).isEmpty, "\(retentionLines(since: mark))")
    }

    /// Behavior 10: a negative, `NaN` and an infinity are refused the same way.
    func testTheDb3DoorRefusesANegativeAndANonFiniteTtl() async throws {
        let client = try await client()
        for value in [-1.0, -.infinity, .nan, .infinity] {
            let error = refusal { try client.db3.setRetentionPolicy(RetentionPolicy(ttl: value)) }
            XCTAssertEqual(error?.code, .invalidArgument, "\(value)")
            XCTAssertTrue(error?.message.contains("got \(value)") == true, error?.message ?? "")
            XCTAssertNil(client.retentionPolicy.ttl)
            XCTAssertNil(client.retentionEnforcement)
        }
    }

    /// E2: a policy refusing both fields names `maxDocs`, as before #5421.
    func testAPolicyRefusingBothFieldsNamesMaxDocs() async throws {
        let client = try await client()
        let error = refusal { try client.db3.setRetentionPolicy(RetentionPolicy(ttl: 0, maxDocs: 0)) }
        XCTAssertEqual(error?.details?["maxDocs"], .number(0))
        XCTAssertNil(error?.details?["ttl"])
    }

    // MARK: - The property

    /// Behavior 11: the property leaves an earlier TTL in place, writes one
    /// error line per refused set and starts no sweep.
    func testThePropertyKeepsTheEarlierTtlAndLogsOneErrorLine() async throws {
        let client = try await client()
        client.retentionPolicy = RetentionPolicy(ttl: 3600)
        await client.retentionEnforcement?.value
        let run = try XCTUnwrap(client.retentionEnforcement)
        let mark = lines.value.count

        client.retentionPolicy = RetentionPolicy(ttl: 0)
        XCTAssertEqual(client.retentionPolicy.ttl, 3600)
        client.retentionPolicy = RetentionPolicy(ttl: -5)
        XCTAssertEqual(client.retentionPolicy.ttl, 3600)
        XCTAssertTrue(client.retentionEnforcement == run, "a refused set starts no retention run")
        try await Task.sleep(nanoseconds: 100_000_000)

        let written = retentionLines(since: mark)
        let errors = written.filter { $0.0 == .error }
        XCTAssertEqual(errors.count, 2, "\(written)")
        for line in errors {
            XCTAssertTrue(line.2.contains("client.retentionPolicy"), line.2)
            XCTAssertTrue(line.2.contains("ttl"), line.2)
            XCTAssertTrue(line.2.contains("pass nil for no TTL"), line.2)
        }
        XCTAssertTrue(written.filter { $0.2.hasPrefix("[db3] retention:") }.isEmpty, "\(written)")
    }

    // MARK: - Format-1 documents

    /// Behavior 12: `ttl: 0` through either door evicts no format-1 row.
    func testZeroThroughEitherDoorEvictsNoFormatOneRow() async throws {
        let client = try await client()
        let ids = try await formatOne(client)
        client.retentionPolicy = RetentionPolicy(ttl: 0)
        await client.retentionEnforcement?.value
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(remaining(client, ids), 3)
        _ = refusal { try client.db3.setRetentionPolicy(RetentionPolicy(ttl: 0)) }
        await client.retentionEnforcement?.value
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(remaining(client, ids), 3)
    }

    /// Behavior 12, E3: a `nil` TTL keeps every format-1 row and logs no
    /// error; a positive fraction of a second after it is a TTL and evicts them.
    func testANilTtlKeepsEveryRowAndAFractionEvictsThem() async throws {
        let client = try await client()
        let ids = try await formatOne(client)
        let mark = lines.value.count
        client.retentionPolicy = RetentionPolicy()
        await client.retentionEnforcement?.value
        XCTAssertEqual(remaining(client, ids), 3)
        XCTAssertTrue(retentionLines(since: mark).filter { $0.0 == .error }.isEmpty)

        try client.db3.setRetentionPolicy(RetentionPolicy(ttl: 0.5))
        XCTAssertEqual(client.retentionPolicy.ttl, 0.5)
        await client.retentionEnforcement?.value
        XCTAssertEqual(remaining(client, ids), 0)
    }
}
