import XCTest
@testable import JsBaoClient

/// #5021 behavior 18 and edge cases E5 and E6 — a refused format lookup
/// settles a db3 subscription at once, over the lifecycle's deps.
///
/// When nothing on the device knows a db3's format, the client asks the
/// documents API. An answer about the document is final: 403 fails the
/// subscription `DB3_ACCESS_REFUSED`, 404 `NOT_FOUND`, any other 4xx but 401
/// and 429 with the server's code. A failure that says nothing about the
/// document (no status, a 5xx, 429, 401) keeps the subscription waiting.
final class Db3FormatRefusalHermeticTests: XCTestCase {

    private static let id = "01JD5021REFVSA1XXXXXXXXXXX"

    /// What the client would answer the lifecycle: a db3 not bound here whose format nothing knows.
    final class World: @unchecked Sendable {
        private let lock = NSLock()
        var bound = false
        var format: Int?
        var refusal: Error?
        var refusalAsks = 0
        var lookups = 0
        /// Run inside each format lookup, after it is counted: what that lookup records.
        var afterLookup: ((World) -> Void)?
        var opens: [String] = []
        var emitted: [any JsBaoEventPayload] = []

        func with<T>(_ body: (World) -> T) -> T { lock.withLock { body(self) } }

        func deps() -> Db3LifecycleDeps {
            Db3LifecycleDeps(
                emit: { [self] payload in with { $0.emitted.append(payload) } },
                socketUp: { true },
                resolveFormat: { [self] _ in
                    with { world -> Int? in
                        world.lookups += 1
                        world.afterLookup?(world)
                        return world.format
                    }
                },
                formatRefusal: { [self] _ in
                    with { world -> Error? in
                        world.refusalAsks += 1
                        return world.refusal
                    }
                },
                open: { [self] id in with { $0.opens.append(id) } },
                knownPermission: { _ in .readWrite },
                isBound: { [self] _ in with { $0.bound } },
                syncMarks: { [self] _ in
                    with { $0.bound } ? Db3SyncMarks(cursor: 1, permission: nil, lastCatchUpAt: 1_000, replacing: false, staged: false) : nil
                },
                storedState: { [self] _ in
                    with { $0.bound } ? RecordLogStoredState(cursor: 1, rows: 0, writers: [], replacing: false, lastCatchUpAt: 1_000) : nil
                }
            )
        }
    }

    private func make(_ configure: (World) -> Void = { _ in }) -> (Db3Lifecycle, World) {
        let world = World()
        world.with(configure)
        return (Db3Lifecycle(deps: world.deps()), world)
    }

    private func failure(_ result: Result<Void, Error>?) -> Error? {
        if case .failure(let error)? = result { return error }
        return nil
    }

    // MARK: - Behavior 18

    func testARecordedRefusalFailsEveryHandleAtOnceWithItsCodeAndOpensNothing() async throws {
        let refused = JsBaoError(
            code: .db3AccessRefused, message: "refused",
            details: ["db3Id": .string(Self.id), "status": .number(403), "serverCode": .string("DOC_ACCESS_DENIED")]
        )
        let (lifecycle, world) = make { $0.refusal = refused }
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: 120))
        let second = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: 120))
        try await eventually(timeout: 2, description: "the refusal") { handle.readyResult != nil && second.availableResult != nil }
        for result in [handle.availableResult, handle.readyResult, second.availableResult, second.readyResult] {
            XCTAssertEqual((failure(result) as? JsBaoError)?.code, .db3AccessRefused)
        }
        XCTAssertEqual(world.with { $0.opens }, [])
        let events = world.with { $0.emitted.compactMap { $0 as? Db3ErrorEvent } }
        XCTAssertEqual(events.map(\.code), ["DB3_ACCESS_REFUSED"])
        XCTAssertEqual(events.first?.id, Self.id)
    }

    func testAnotherFinalAnswerFailsWithTheServersCodeAndTheHttpErrorOnTheHandle() async throws {
        let thrown = HttpError(status: 400, message: "HTTP 400", serverCode: "INVALID_DOCUMENT_ID", serverMessage: "bad id")
        let (lifecycle, world) = make { $0.refusal = thrown }
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: 120))
        try await eventually(timeout: 2, description: "the refusal") { handle.readyResult != nil }
        let error = try XCTUnwrap(failure(handle.readyResult) as? HttpError)
        XCTAssertEqual(error.status, 400)
        XCTAssertEqual(error.serverCode, "INVALID_DOCUMENT_ID")
        XCTAssertEqual(world.with { $0.emitted.compactMap { ($0 as? Db3ErrorEvent)?.code } }, ["INVALID_DOCUMENT_ID"])
    }

    /// E5: no refusal recorded keeps the subscription waiting; an answered format readies it.
    func testWithNoRefusalItKeepsWaitingAndReadiesOnceTheFormatIsAnswered() async throws {
        let (lifecycle, world) = make()
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(timeout: 2, description: "the format asked") { world.with { $0.refusalAsks } >= 1 }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(handle.availableResult)
        XCTAssertEqual(world.with { $0.opens }, [])
        world.with {
            $0.format = 3
            $0.bound = true
        }
        try await eventually(timeout: 10, description: "the open") { world.with { $0.opens } == [Self.id] }
        lifecycle.statusChanged(Self.id, RecordLogSessionStatus(phase: .live))
        try await handle.ready()
    }

    /// E6: a db3 bound here never asks.
    func testABoundDb3NeverConsultsTheRefusal() async throws {
        let (lifecycle, world) = make {
            $0.bound = true
            $0.refusal = JsBaoError(code: .db3AccessRefused)
        }
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: 5))
        try await handle.available()
        try await eventually(timeout: 2, description: "the open") { world.with { $0.opens } == [Self.id] }
        XCTAssertEqual(world.with { $0.refusalAsks }, 0)
    }

    /// 5021-C002: the first lookup's refusal is read before a second lookup
    /// is made, so a later lookup that stalls or fails without an answer
    /// cannot lose it.
    func testTheFirstLookupsRefusalFailsTheSubscriptionWithNoSecondLookup() async throws {
        let refused = JsBaoError(code: .db3AccessRefused, message: "refused")
        let (lifecycle, world) = make { world in
            // The first lookup is refused; any later one hears nothing (a transient failure).
            world.afterLookup = { $0.refusal = $0.lookups == 1 ? refused : nil }
        }
        let handle = try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: 120))
        try await eventually(timeout: 2, description: "the refusal") { handle.readyResult != nil }
        XCTAssertEqual((failure(handle.readyResult) as? JsBaoError)?.code, .db3AccessRefused)
        XCTAssertEqual((failure(handle.availableResult) as? JsBaoError)?.code, .db3AccessRefused)
        XCTAssertEqual(world.with { $0.lookups }, 1, "a final answer is never asked again")
        XCTAssertEqual(world.with { $0.opens }, [])
    }

    // MARK: - An earlier refusal does not outlive its lookup (5021-C001)

    private var clients: [JsBaoClient] = []
    private var directories: [String] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    /// A client on SQLite storage (a db3 needs a persistent store), never connecting.
    private func makeClient() async throws -> JsBaoClient {
        let directory = NSTemporaryDirectory() + "format-refusal-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "format-refusal-5021",
            token: makeTestJwt(userId: "u1"), offline: false, logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"), autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        return client
    }

    func testAnOfflineLookupDropsAnEarlierRefusal() async throws {
        let client = try await makeClient()
        client.setNetworkMode(.offline)
        client.recordLogState.noteFormatRefusal(Self.id, JsBaoError(code: .db3AccessRefused, message: "earlier"))
        let format = await client.db3FormatOf(Self.id)
        XCTAssertNil(format)
        XCTAssertNil(client.recordLogState.formatRefusal(Self.id), "the offline lookup heard nothing, so it records nothing")
    }

    func testASubscriptionStartedOfflineAfterARefusalKeepsWaiting() async throws {
        let client = try await makeClient()
        client.setNetworkMode(.offline)
        client.recordLogState.noteFormatRefusal(Self.id, JsBaoError(code: .db3AccessRefused, message: "earlier"))
        let handle = try client.db3.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: 120))
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertNil(handle.availableResult, "offline, the subscription waits for the network")
        XCTAssertNil(handle.readyResult)
        handle.dispose()
    }

    // MARK: - The verdict table (behavior 16's, in Swift)

    func testWhichFailuresAreFinal() {
        XCTAssertEqual(FormatLookupVerdict.of(status: 403), .final(.db3AccessRefused))
        XCTAssertEqual(FormatLookupVerdict.of(status: 404), .final(.notFound))
        XCTAssertEqual(FormatLookupVerdict.of(status: 400), .final(nil))
        XCTAssertEqual(FormatLookupVerdict.of(status: 410), .final(nil))
        for status in [nil, 401, 429, 500, 502, 503] as [Int?] {
            XCTAssertEqual(FormatLookupVerdict.of(status: status), .retry, "\(String(describing: status))")
        }
    }

    func testTheRefusalAFailedLookupRecords() throws {
        let forbidden = try XCTUnwrap(
            FormatLookupVerdict.refusal(of: HttpError(status: 403, message: "HTTP 403", serverCode: "DOC_ACCESS_DENIED"), db3Id: Self.id)
                as? JsBaoError
        )
        XCTAssertEqual(forbidden.code, .db3AccessRefused)
        XCTAssertEqual(forbidden.details?["db3Id"], .string(Self.id))
        XCTAssertEqual(forbidden.details?["status"], .number(403))
        XCTAssertEqual(forbidden.details?["serverCode"], .string("DOC_ACCESS_DENIED"))
        let missing = try XCTUnwrap(FormatLookupVerdict.refusal(of: HttpError(status: 404, message: "HTTP 404"), db3Id: Self.id) as? JsBaoError)
        XCTAssertEqual(missing.code, .notFound)
        XCTAssertEqual(missing.details?["status"], .number(404))
        let gone = FormatLookupVerdict.refusal(of: HttpError(status: 410, message: "HTTP 410", serverCode: "GONE"), db3Id: Self.id)
        XCTAssertEqual((gone as? HttpError)?.serverCode, "GONE")
        for status in [401, 429, 503] {
            XCTAssertNil(FormatLookupVerdict.refusal(of: HttpError(status: status, message: "HTTP \(status)"), db3Id: Self.id))
        }
        XCTAssertNil(FormatLookupVerdict.refusal(of: URLError(.notConnectedToInternet), db3Id: Self.id))
    }
}
