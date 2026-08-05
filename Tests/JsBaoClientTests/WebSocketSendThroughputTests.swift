import XCTest
@testable import JsBaoClient

/// #2171 behavior 23 — the per-message cost of `WebSocketManager.send(_:)`
/// after the actor conversion.
///
/// Its own suite on purpose. `ActorizedWebSocketManagerTests` is in the TSan
/// gate's default filter (the shrink rule: a baseline entry may only be removed
/// if the gate runs the suites that hammer the race it covered), and a
/// 20,000-send throughput loop under a 5-15x sanitizer is pure gate runtime —
/// the ratio between the two arms survives instrumentation, so the measurement
/// says nothing new there. Keeping it out of that suite keeps it out of the
/// filter. Do not add this suite to `DEFAULT_FILTER` in `scripts/tsan-gate.sh`.
final class WebSocketSendThroughputTests: XCTestCase {

    private typealias RecordingDelegate = ActorizedWebSocketManagerTests.RecordingDelegate

    private func makeManager(url: URL, delegate: RecordingDelegate) -> WebSocketManager {
        WebSocketManager(
            logger: Logger(level: .none, scope: "wsm-throughput"),
            maxReconnectDelayMs: 1000,
            delegate: delegate
        )
    }

    /// `send(_:)` gains no actor hop: it reads the live task from the snapshot
    /// box and puts the frame on the wire off the actor, so concurrent sends
    /// stay concurrent. Measured against a raw `URLSessionWebSocketTask.send`
    /// loop over the same loopback server in the same process — a same-machine
    /// baseline, since the pre-conversion wall time is not available at test
    /// time.
    func testSendLoopStaysWithinTwiceTheRawTransportCost() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url)
        let manager = makeManager(url: url, delegate: delegate)
        try await manager.connect()

        let iterations = 10_000
        let payload = String(repeating: "x", count: 64)

        let managerStart = Date()
        for _ in 0..<iterations { try await manager.send(payload) }
        let managerElapsed = Date().timeIntervalSince(managerStart)
        await manager.disconnect()

        let rawSession = URLSession(configuration: .default)
        defer { rawSession.invalidateAndCancel() }
        let rawTask = rawSession.webSocketTask(with: url)
        rawTask.resume()
        let rawStart = Date()
        for _ in 0..<iterations { try await rawTask.send(.string(payload)) }
        let rawElapsed = Date().timeIntervalSince(rawStart)
        rawTask.cancel(with: .normalClosure, reason: nil)

        // The floor keeps a fast, noisy baseline from making the ratio
        // meaningless; the point of the check is that the manager adds no
        // order-of-magnitude cost, not that it matches to the millisecond.
        let budget = max(rawElapsed * 2, 1.0)
        XCTAssertLessThan(
            managerElapsed, budget,
            "\(iterations) sends took \(managerElapsed)s through the manager vs \(rawElapsed)s raw"
        )
    }
}
