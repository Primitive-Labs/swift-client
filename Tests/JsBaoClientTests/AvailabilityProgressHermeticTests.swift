import XCTest
@testable import JsBaoClient
import YSwift

/// `availabilityWait` bounds an open's wait WITHOUT progress (#4609).
///
/// A cold open of a large format-3 document can take longer than the budget
/// while its first catch-up keeps progressing: `building` answers, then
/// catch-up pages or segment chunks. Each is reported as progress, and each
/// starts the budget again; the open throws `NETWORK_TIMEOUT` only once a
/// whole budget passes with none. JS parity:
/// `tests/client/record-log-open-progress-4609.test.ts`.
///
/// Server-free: a loopback WebSocket server the client really connects to,
/// which never answers the handshake, and the progress the record-log session
/// reports, driven through the client's own hook.
final class AvailabilityProgressHermeticTests: XCTestCase {

    private var clients: [JsBaoClient] = []
    private var servers: [LoopbackWebSocketServer] = []

    override func tearDown() async throws {
        for server in servers { server.stop() }
        servers = []
        for client in clients { await client.destroy() }
        clients = []
    }

    private func connected() async throws -> JsBaoClient {
        let server = try LoopbackWebSocketServer()
        servers.append(server)
        let base = try server.start().absoluteString
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: base.hasSuffix("/") ? String(base.dropLast()) : base,
            appId: "availability-progress-app",
            token: makeTestJwt(userId: "availability-progress-user"),
            offline: false,
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        try await client.connect()
        return client
    }

    private func newDocId() -> String { "availability-progress-\(UUID().uuidString.prefix(8))" }

    /// The open's outcome — `"resolved"`, the error code it threw, or
    /// `"hung"` — and the seconds it took to settle.
    private static func outcome(
        of client: JsBaoClient, _ documentId: String, budget: TimeInterval, within seconds: TimeInterval
    ) async -> (result: String, seconds: TimeInterval) {
        let once = LockedBox(false)
        let started = Date()
        return await withCheckedContinuation { (continuation: CheckedContinuation<(result: String, seconds: TimeInterval), Never>) in
            let finish: @Sendable (String) -> Void = { value in
                let first = once.withValue { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: (value, Date().timeIntervalSince(started))) }
            }
            Task {
                do {
                    _ = try await client.openDocument(
                        documentId, options: OpenDocumentOptions(availabilityWait: budget)
                    )
                    finish("resolved")
                } catch let error as JsBaoError {
                    finish(error.code.rawValue)
                } catch {
                    finish("threw: \(error)")
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                finish("hung")
            }
        }
    }

    /// Report progress for `documentId` every `every` seconds for `for` seconds.
    private static func progress(
        _ client: JsBaoClient, _ documentId: String, every: TimeInterval, for duration: TimeInterval
    ) async {
        let until = Date().addingTimeInterval(duration)
        while Date() < until {
            try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
            client.recordLogSyncProgress(documentId)
        }
    }

    /// Progress every 250 ms for 3 s under a 1 s budget, then the room's
    /// answer: the open resolves.
    func testAnOpenWhoseCatchUpKeepsProgressingOutlastsItsBudgetAndResolves() async throws {
        let client = try await connected()
        let documentId = newDocId()
        let opening = Task { await Self.outcome(of: client, documentId, budget: 1, within: 15) }
        await Self.progress(client, documentId, every: 0.25, for: 3)
        // The room's state and its syncComplete.
        let peer = YDocument()
        let map: YMap<JSONValue> = peer.getOrCreateMap(named: "probe")
        peer.transactSync { map.updateValue(.string("x"), forKey: "k", transaction: $0) }
        let update = peer.transactSync { $0.transactionEncodeStateAsUpdate() }
        await client.handleWebSocketMessage("""
        {"type":"syncStep2","documentId":"\(documentId)","update":"\(Data(update).base64EncodedString())"}
        """)
        await client.handleWebSocketMessage(#"{"type":"syncComplete","documentId":"\#(documentId)"}"#)
        let (result, elapsed) = await opening.value
        XCTAssertEqual(
            result, "resolved",
            "an open whose catch-up reported progress every 250 ms did not outlast its 1 s budget "
                + "(settled after \(String(format: "%.1f", elapsed)) s)"
        )
        XCTAssertGreaterThan(elapsed, 2.5, "the open settled before the room answered")
    }

    /// Progress for 2 s under a 1 s budget, then none: the open throws
    /// `NETWORK_TIMEOUT` a budget after the last progress, not before it.
    func testAnOpenWhoseCatchUpStopsProgressingThrowsNetworkTimeoutABudgetLater() async throws {
        let client = try await connected()
        let documentId = newDocId()
        let opening = Task { await Self.outcome(of: client, documentId, budget: 1, within: 15) }
        await Self.progress(client, documentId, every: 0.25, for: 2)
        let (result, elapsed) = await opening.value
        XCTAssertEqual(result, JsBaoErrorCode.networkTimeout.rawValue)
        XCTAssertGreaterThan(elapsed, 2.5, "the open timed out while its catch-up was still progressing")
        XCTAssertLessThan(elapsed, 6, "the open waited well past a budget with no progress")
    }
}
