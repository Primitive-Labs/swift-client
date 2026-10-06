import XCTest
@testable import JsBaoClient
import YSwift

/// An open that is waiting has to be traceable from the app, and has to settle
/// inside its availability wait whatever is still in flight (#4191).
///
/// The report: an `openDocument` on a never-held large document neither
/// resolved nor threw for five minutes while a server function wrote into it,
/// its availability wait never fired, and `setLogLevel(.debug)` produced
/// nothing — the scoped loggers the open path logs on had copied the level
/// they were built with.
///
/// Server-free: a loopback WebSocket server the client really connects to,
/// frames pushed through it onto the client's own receive loop, and a loopback
/// HTTP server standing in for the R2 download.
final class OpenTraceAndBoundHermeticTests: XCTestCase {

    /// Lines captured off every logger in the process, with their scope.
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [(level: LogLevel, scope: String, message: String)] = []
        func append(_ level: LogLevel, _ scope: String, _ message: String) {
            lock.withLock { lines.append((level, scope, message)) }
        }
        var all: [(level: LogLevel, scope: String, message: String)] {
            lock.withLock { lines }
        }
        func messages(containing needle: String) -> [String] {
            all.map(\.message).filter { $0.contains(needle) }
        }
    }

    private var lines: Lines!
    private var directories: [String] = []

    override func setUp() {
        super.setUp()
        let lines = Lines()
        self.lines = lines
        Logger.lineForTest = { level, scope, message in lines.append(level, scope, message) }
    }

    override func tearDown() {
        Logger.lineForTest = nil
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "/open-trace-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string, required: true),
        ]
    )

    /// A client built at `.warn`, the level an app ships with. The tests turn
    /// debug on at runtime, which is what the report's app did.
    private func makeClient(wsUrl: String, storage: StorageConfig? = nil) async -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: wsUrl,
            appId: "open-trace-test-app",
            token: makeTestJwt(userId: "open-trace-user"),
            offline: false,
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .warn,
            storageConfig: storage ?? .sqlite(directory: newDatabasePath()),
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
        client.registerModels([Self.schema])
        _ = await client.waitForStorageReady()
        return client
    }

    private func connected() async throws -> (JsBaoClient, LoopbackWebSocketServer) {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let base = url.absoluteString
        let client = await makeClient(
            wsUrl: base.hasSuffix("/") ? String(base.dropLast()) : base
        )
        try await client.connect()
        return (client, server)
    }

    private func newDocId() -> String { "open-trace-\(UUID().uuidString.prefix(8))" }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(description)")
    }

    private func sentSyncStep1(_ server: LoopbackWebSocketServer, _ documentId: String) -> Bool {
        server.receivedFrames.contains { frame in
            frame.contains("\"syncStep1\"") && frame.contains(documentId)
        }
    }

    /// Run `body` against a deadline: the result, or `nil` when the deadline
    /// came first. Unstructured on purpose — a task group waits for every
    /// child, so a body that never returns would hold the group, and the test,
    /// with it. A hang fails the test that measures it, not the whole run.
    private func settle<T: Sendable>(
        within seconds: TimeInterval,
        _ body: @escaping @Sendable () async -> T
    ) async -> T? {
        let once = LockedBox(false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let finish: @Sendable (T?) -> Void = { value in
                let first = once.withValue { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            Task { finish(await body()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                finish(nil)
            }
        }
    }

    // MARK: - setLogLevel reaches every scoped logger

    func testSetLogLevelAtRuntimeReachesTheScopedLoggersTheOpenPathLogsOn() async throws {
        let client = await makeClient(wsUrl: "ws://127.0.0.1:1", storage: .memory)
        defer { Task { await client.destroy() } }
        let documentId = newDocId()
        _ = try await client.openDocument(
            documentId, options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )

        client.setLogLevel(.debug)

        // The document manager's scope: a remote apply logs at debug.
        let peer = YDocument()
        let map: YMap<JSONValue> = peer.getOrCreateMap(named: "probe")
        peer.transactSync { map.updateValue(.string("x"), forKey: "k", transaction: $0) }
        let update = peer.transactSync { $0.transactionEncodeStateAsUpdate() }
        client.documentManager.handleRemoteUpdate(documentId: documentId, updateData: Data(update))
        // The HTTP scope: every request logs at debug before it goes out.
        _ = try? await client.documents.get(documentId: documentId)

        let scopes = Set(lines.all.filter { $0.level == .debug }.map(\.scope))
        XCTAssertTrue(
            scopes.contains { $0.hasSuffix("docMgr") },
            "setLogLevel(.debug) did not reach the document manager's logger; "
                + "debug scopes seen: \(scopes.sorted())"
        )
        XCTAssertTrue(
            scopes.contains { $0.hasSuffix("http") },
            "setLogLevel(.debug) did not reach the HTTP logger; debug scopes seen: \(scopes.sorted())"
        )

        // And back down: the scoped loggers follow a lowered level too.
        client.setLogLevel(.warn)
        let before = lines.all.count
        client.documentManager.handleRemoteUpdate(documentId: documentId, updateData: Data(update))
        _ = try? await client.documents.get(documentId: documentId)
        let lateDebug = lines.all.dropFirst(before).filter { $0.level == .debug }
        XCTAssertTrue(
            lateDebug.isEmpty,
            "debug lines after setLogLevel(.warn): \(lateDebug.map(\.message))"
        )
    }

    // MARK: - The trace of one open

    /// A never-held large document, opened with default options against a
    /// room that answers the way the report's did: `epoch.info`, a
    /// `syncStep2` parked in R2, then `syncComplete`. With debug on at runtime
    /// the app can follow every step of the open from its own log.
    func testDebugTracesAnOpenFromItsStartToTheEventThatResolvesIt() async throws {
        let peer = OverlayDocument()
        peer.apply(
            OverlayMutation(id: "r1", kind: .create, fields: ["title": .string("from the room")]),
            model: "Note"
        )
        let payload = Data(peer.encodeStateAsUpdate())
        let r2 = try LoopbackHTTPServer(body: payload)
        let updateUrl = try r2.start()
        defer { r2.stop() }

        let (client, server) = try await connected()
        defer { server.stop(); Task { await client.destroy() } }
        client.setLogLevel(.debug)

        let documentId = newDocId()
        let opening = Task { try await client.openDocument(documentId) }
        try await waitFor("the open's syncStep1") { self.sentSyncStep1(server, documentId) }

        XCTAssertTrue(server.push("""
        {"type":"epoch.info","documentId":"\(documentId)","documentFormat":2,\
        "epoch":1,"sealedEpochs":[],"offlineWindowDays":14}
        """))
        XCTAssertTrue(server.push("""
        {"type":"syncStep2","documentId":"\(documentId)","updateUrl":"\(updateUrl.absoluteString)"}
        """))
        XCTAssertTrue(server.push(#"{"type":"syncComplete","documentId":"\#(documentId)"}"#))

        let outcome = await settle(within: 10) { () -> String in
            do { _ = try await opening.value; return "resolved" } catch { return "threw: \(error)" }
        }
        XCTAssertEqual(outcome, "resolved")

        let model = try XCTUnwrap(client.sharedModel("Note")?.member(docId: documentId))
        try await waitFor("the folded record to be readable") { model.find(id: "r1") != nil }

        let trace = lines.all
            .filter { $0.level == .debug && $0.message.contains(documentId) }
            .map(\.message)
        func traced(_ needle: String, _ what: String) {
            XCTAssertTrue(
                trace.contains { $0.contains(needle) },
                "no trace of \(what) (\"\(needle)\"); the open's debug lines were:\n"
                    + trace.joined(separator: "\n")
            )
        }
        traced("[open] start", "the open starting")
        traced("[open] network wait", "the open deciding to wait on the network")
        traced("plan: join", "the handshake plan")
        traced("[open] download start", "the R2 download starting")
        traced("[open] download end", "the R2 download ending")
        traced("bytes: \(payload.count)", "the downloaded byte count")
        traced("[open] apply", "the downloaded state being applied")
        traced("[format2] folded", "the fold")
        traced("[open] resolved by sync", "the event that resolved the open")
    }

    // MARK: - The open settles inside its availability wait

    /// The handshake's send is still in flight when the budget runs out. The
    /// availability wait bounds the open from the moment it decides to wait
    /// on the network — not from whenever the send returns.
    func testAnOpenWhoseHandshakeIsStillInFlightThrowsInsideItsAvailabilityWait() async throws {
        let (client, server) = try await connected()
        defer { server.stop(); Task { await client.destroy() } }

        let released = LockedBox(false)
        client.onSyncStep1SendForTest = { _ in
            // Held until the test is done with it: a send that does not return.
            while !released.value { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        defer { released.value = true }

        let documentId = newDocId()
        let started = Date()
        let outcome = await settle(within: 8) { () -> String in
            do {
                _ = try await client.openDocument(
                    documentId, options: OpenDocumentOptions(availabilityWait: 1)
                )
                return "resolved"
            } catch let error as JsBaoError {
                return error.code.rawValue
            } catch {
                return "threw: \(error)"
            }
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(
            outcome, JsBaoErrorCode.networkTimeout.rawValue,
            "an open whose handshake send never returned did not settle inside its 1 s "
                + "availability wait (still waiting after \(Int(elapsed)) s)"
        )
        XCTAssertLessThan(elapsed, 4, "the open settled, but not inside its availability wait")
    }

    /// The other half: the room answers while the open is still on its way to
    /// the wait. The `syncComplete` that lands before the wait is armed is
    /// not lost — the open resolves rather than waiting out its budget.
    func testAnOpenWhoseAnswerLandsWhileItsSendIsInFlightResolves() async throws {
        let (client, server) = try await connected()
        defer { server.stop(); Task { await client.destroy() } }

        let documentId = newDocId()
        let released = LockedBox(false)
        let entered = LockedBox(false)
        client.onSyncStep1SendForTest = { id in
            guard id == documentId else { return }
            entered.value = true
            while !released.value { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        defer { released.value = true }

        let opening = Task {
            try await client.openDocument(
                documentId, options: OpenDocumentOptions(availabilityWait: 5)
            )
        }
        try await waitFor("the open to reach its handshake send") { entered.value }
        // The room's state and its syncComplete, delivered while the send is held.
        let peer = YDocument()
        let map: YMap<JSONValue> = peer.getOrCreateMap(named: "probe")
        peer.transactSync { map.updateValue(.string("x"), forKey: "k", transaction: $0) }
        let update = peer.transactSync { $0.transactionEncodeStateAsUpdate() }
        await client.handleWebSocketMessage("""
        {"type":"syncStep2","documentId":"\(documentId)","update":"\(Data(update).base64EncodedString())"}
        """)
        await client.handleWebSocketMessage(#"{"type":"syncComplete","documentId":"\#(documentId)"}"#)

        let started = Date()
        let outcome = await settle(within: 8) { () -> String in
            do { _ = try await opening.value; return "resolved" } catch { return "threw: \(error)" }
        }
        XCTAssertEqual(outcome, "resolved")
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2,
            "the open waited out its budget for a sync that had already completed"
        )
    }
}
