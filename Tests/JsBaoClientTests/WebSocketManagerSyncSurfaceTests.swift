import XCTest
@testable import JsBaoClient

/// #2171 Phase 2 — the timers, the synchronous surface that survives the actor
/// conversion, and the one deprecation window it opens.
///
/// The sponsor's Fork 2 → Option B resolution is what makes this suite's shape
/// unusual for an actor conversion: the four synchronous **reads**
/// (`isConnected`, `isConnecting`, `connectionStatus`, `isSocketOpen`) stay
/// synchronous **permanently** behind the snapshot box, with undeprecated
/// `…Async` twins beside them. Only one member gets the deprecation ceremony —
/// the still-public `JsBaoClient.forceReconnect()` facade. The three
/// `WebSocketManager` commands went internal in #2363, so a major-release
/// window would protect nobody and they convert outright.
final class WebSocketManagerSyncSurfaceTests: XCTestCase {

    private static let managerFile = "Internal/WebSocketManager.swift"

    private typealias RecordingDelegate = ActorizedWebSocketManagerTests.RecordingDelegate

    private func makeManager(
        url: URL,
        delegate: RecordingDelegate,
        maxReconnectDelayMs: Int = 1000
    ) -> WebSocketManager {
        WebSocketManager(
            logger: Logger(level: .none, scope: "wsm-sync-surface"),
            maxReconnectDelayMs: maxReconnectDelayMs,
            delegate: delegate
        )
    }

    // MARK: - Behavior 10 — the reconnect timer is a cancellable Task.sleep

    /// Structural: both timers are `Task`s in actor state. A surviving
    /// `DispatchWorkItem` would mean a timer whose cancellation is not ordered
    /// against the isolated state it re-reads when it fires.
    func testBothTimersAreCancellableTasks() throws {
        let source = try ClientSourceText.code(Self.managerFile)
        for gone in ["DispatchWorkItem", "asyncAfter", "reconnectWorkItem", "disconnectTimeoutWorkItem"] {
            XCTAssertFalse(source.contains(gone), "\(gone) must not survive the conversion")
        }
        for expected in [
            "private var reconnectTask: Task<Void, Never>?",
            "private var disconnectTimeoutTask: Task<Void, Never>?",
            "try? await Task.sleep(",
        ] {
            XCTAssertTrue(source.contains(expected), "missing: \(expected)")
        }
    }

    /// Behavioral: a `disconnect()` issued while a reconnect is scheduled
    /// cancels the sleeping timer, and no reconnect fires — the manager does
    /// not build a second connection request.
    func testDisconnectCancelsAScheduledReconnect() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let delegate = RecordingDelegate(url: url, shouldReconnect: true)
        let manager = makeManager(url: url, delegate: delegate)

        try await manager.connect()
        XCTAssertEqual(delegate.requestsBuilt, 1)

        // Drop the connection so the manager schedules a reconnect. The first
        // backoff is 1200 ms, so there is ample time to cancel it.
        server.stop()
        let scheduled = await eventuallyTrue { !delegate.reconnectDelays.isEmpty }
        XCTAssertTrue(scheduled, "the manager never scheduled a reconnect")
        let requestsWhenScheduled = delegate.requestsBuilt

        await manager.disconnect()

        // Well past the scheduled delay.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(
            delegate.requestsBuilt, requestsWhenScheduled,
            "a cancelled reconnect timer must not go on to build a connection"
        )
        XCTAssertFalse(manager.isConnected)
    }

    // MARK: - Behavior 11 — the 500 ms disconnect safety timeout

    /// Structural: the timeout and `handleConnectionClosed` are mutually
    /// exclusive through an atomic check-and-nil of `disconnectContinuation`.
    /// Under the class this was atomic only because both paths took the same
    /// lock; the claim now rests on the timeout handler containing no
    /// suspension point, so it is checked in source.
    func testTheDisconnectTimeoutClaimsTheContinuationAtomically() throws {
        let source = try ClientSourceText.code(Self.managerFile)
        let body = try ClientSourceText.slice(
            source,
            from: "private func fireDisconnectTimeout() {",
            to: "func setDesiredConnection("
        )
        XCTAssertTrue(
            body.contains("guard let pendingContinuation = disconnectContinuation else { return }"),
            "the timeout must claim the continuation or bail"
        )
        XCTAssertTrue(body.contains("disconnectContinuation = nil"), "and nil it in the same step")
        XCTAssertFalse(body.contains("await"), "the claim must not suspend:\n\(body)")
    }

    /// Behavioral: disconnect a manager whose socket never completed its
    /// handshake, so the graceful-close callback may never arrive. Whichever
    /// path resolves it — the close or the 500 ms timeout —
    /// `webSocketManagerOnDisconnectResolved` must fire exactly once, which is
    /// the observable form of "the continuation is resumed exactly once".
    func testDisconnectResolvesExactlyOnceWhenNoCloseCallbackArrives() async throws {
        let server = try LoopbackWebSocketServer(completesHandshake: false)
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url)
        let manager = makeManager(url: url, delegate: delegate)

        let connecting = Task { try await manager.connect() }
        let armed = await eventuallyTrue { manager.snapshot.task != nil }
        XCTAssertTrue(armed, "the connect attempt never created its task")
        let pendingTask = try XCTUnwrap(manager.snapshot.task)

        // Tell the manager the socket opened, so `disconnect()` takes the
        // has-a-task path and parks on its continuation.
        manager.urlSession(.shared, webSocketTask: pendingTask, didOpenWithProtocol: nil)
        let connected = await eventuallyTrue { manager.isConnected }
        XCTAssertTrue(connected, "the injected open never landed")
        _ = try? await connecting.value

        await assertCompletesAsync(within: 5, "disconnect with no close callback") {
            await manager.disconnect()
        }
        XCTAssertEqual(delegate.countOf("disconnectResolved"), 1,
                       "the disconnect must resolve exactly once")

        // Give the losing path time to (wrongly) resolve it a second time.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(
            delegate.countOf("disconnectResolved"), 1,
            "the timeout and handleConnectionClosed must be mutually exclusive"
        )
    }

    /// The test above resolves through whichever path wins, and in practice
    /// that is always the close: `disconnect()` cancels the task and
    /// `URLSession` reports the cancellation within milliseconds. This one puts
    /// the manager in the state the timeout exists for — a current task whose
    /// close callback genuinely never arrives — by swapping the live task for
    /// one that belongs to a session the manager is not the delegate of.
    /// Cancelling that task reports to nobody, so only `fireDisconnectTimeout()`
    /// can resolve the disconnect, and its body (the continuation claim, the
    /// state clearing and the waiter drain) is exercised rather than merely
    /// read as source text.
    ///
    /// Stalling the pump cannot produce this state: the pump runs *inside* the
    /// actor, so a stalled pump also blocks `fireDisconnectTimeout()`, and the
    /// close still wins when the stall ends.
    func testTheDisconnectTimeoutResolvesADisconnectWhoseCloseNeverArrives() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url)
        let manager = makeManager(url: url, delegate: delegate)

        try await manager.connect()
        let liveTask = try XCTUnwrap(manager.snapshot.task)

        // A task from a session the manager does not delegate for: cancelling
        // it produces no `didCompleteWithError` and no `didCloseWith` for this
        // manager. The real socket's own eventual callbacks now carry a stale
        // identity and are dropped by the filter.
        let orphanSession = URLSession(configuration: .ephemeral)
        defer { orphanSession.invalidateAndCancel() }
        manager.snapshot.task = orphanSession.webSocketTask(with: url)

        let started = Date()
        await assertCompletesAsync(within: 5, "disconnect whose close callback never arrives") {
            await manager.disconnect()
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertGreaterThan(
            elapsed, 0.35,
            "resolved too fast to have come from the 500 ms timeout — the close path won, "
                + "so this test is no longer covering fireDisconnectTimeout()"
        )
        XCTAssertEqual(delegate.countOf("disconnectResolved"), 1,
                       "the timeout must resolve the disconnect exactly once")
        XCTAssertFalse(manager.isConnected, "the timeout path must clear the transport state")
        XCTAssertNil(manager.snapshot.task, "and drop the task it timed out on")

        // Nothing may resolve it a second time once the real socket's stale
        // callbacks land.
        liveTask.cancel(with: .goingAway, reason: nil)
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(
            delegate.countOf("disconnectResolved"), 1,
            "a stale close arriving after the timeout must not resolve the disconnect again"
        )
    }

    // MARK: - Behavior 12 — the four reads stay synchronous

    /// The load-bearing half: all four are callable from a **non-`async`**
    /// context. If the conversion had let any of them become isolated, this
    /// closure would not compile — which is the check.
    func testTheFourReadsAreCallableFromASynchronousContext() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url)
        let manager = makeManager(url: url, delegate: delegate)
        try await manager.connect()

        let done = expectation(description: "synchronous reads")
        DispatchQueue.global().async {
            // No `await` anywhere in here, on purpose.
            XCTAssertTrue(manager.isConnected)
            XCTAssertFalse(manager.isConnecting)
            XCTAssertEqual(manager.connectionStatus, .connected)
            XCTAssertTrue(manager.isSocketOpen)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)

        // The undeprecated `…Async` twins report the same strictly-current view.
        let asyncStatus = await manager.connectionStatusAsync
        XCTAssertEqual(asyncStatus, .connected)
        let asyncConnected = await manager.isConnectedAsync
        XCTAssertTrue(asyncConnected)

        await manager.disconnect()
    }

    /// `connectionStatus` derives both flags under **one** hold, so a reader can
    /// never catch `connected` and `connecting` half-updated — the property the
    /// class's single-lock-hold accessor had, and the reason the box stores one
    /// pair rather than four independent fields.
    func testConnectionStatusIsDerivedUnderASingleHold() throws {
        let boxes = try ClientSourceText.code("Internal/WebSocketTransportBoxes.swift")
        let status = try ClientSourceText.slice(
            boxes,
            from: "var status: ConnectionStatus {",
            to: "var socketIsOpen: Bool {"
        )
        XCTAssertEqual(
            status.components(separatedBy: "lock.withLock").count - 1, 1,
            "status must read both flags in exactly one lock hold:\n\(status)"
        )
        XCTAssertTrue(status.contains("_connected") && status.contains("_connecting"),
                      "the slice must be the composite read")

        let manager = try ClientSourceText.code(Self.managerFile)
        XCTAssertTrue(
            manager.contains("setTransportState(connected: true, connecting: false)"),
            "the connected transition must write both flags together"
        )
    }

    /// A synchronous reader hammering `connectionStatus` from a non-`async`
    /// context, concurrently with real connect/disconnect cycles, sees only
    /// well-formed values and never stalls. It is the liveness half of the
    /// claim above: the box's lock is uncontended by design, so a reader must
    /// never be blocked behind a transport transition.
    func testSynchronousReadsSurviveConcurrentTransitions() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url)
        let manager = makeManager(url: url, delegate: delegate)

        let observed = ObservedStatuses()
        let stop = StopFlag()
        DispatchQueue.global().async {
            while !stop.isSet {
                observed.record(manager.connectionStatus)
            }
        }

        await assertCompletesAsync(within: 20, "connect/disconnect cycles under a synchronous reader") {
            for _ in 0..<10 {
                try? await manager.connect()
                await manager.disconnect()
            }
        }
        stop.set()

        let statuses = observed.values
        XCTAssertGreaterThan(statuses.count, 0, "the reader never ran")
        XCTAssertTrue(
            statuses.contains(.connected) && statuses.contains(.disconnected),
            "the reader must have seen the transport move: \(Set(statuses))"
        )
    }

    // MARK: - Behavior 13 — isSocketOpen is live, not cached

    /// The box holds the task **reference**, not a cached `Bool`. Cancelling
    /// the socket out from under the manager must make `isSocketOpen` read
    /// `false` while `isConnected` — which *is* a flag — still reads `true`,
    /// because no delegate callback has been applied yet.
    ///
    /// The pump is deliberately stalled for the duration so that window is
    /// deterministic rather than a race: `URLSessionWebSocketTask.cancel()`
    /// updates `state` asynchronously and then delivers a completion callback,
    /// and without the stall the manager's own teardown can win and make both
    /// reads `false` for the uninteresting reason.
    func testIsSocketOpenReflectsTheLiveTaskState() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url)
        let manager = makeManager(url: url, delegate: delegate)
        try await manager.connect()
        XCTAssertTrue(manager.isSocketOpen)

        let stall = StopFlag()
        await manager.setEventHandledHookForTest { _ in
            guard !stall.isSet else { return }
            stall.set()
            Thread.sleep(forTimeInterval: 2)
        }

        manager.snapshot.task?.cancel()

        let wentDown = await eventuallyTrue(timeout: 5) { manager.snapshot.task?.state != .running }
        XCTAssertTrue(wentDown, "the socket's live state never left .running")
        XCTAssertFalse(
            manager.isSocketOpen,
            "isSocketOpen must read the socket's live state, not a cached boolean"
        )
        XCTAssertTrue(
            manager.isConnected,
            "the connected flag has not been updated yet — that is the difference being pinned"
        )

        await manager.setEventHandledHookForTest(nil)
        await manager.disconnect()
    }

    // MARK: - Behavior 14 — facade-only deprecation

    /// The one member with a deprecation window: `JsBaoClient.forceReconnect()`
    /// is still public, so app source compatibility is still at stake. It keeps
    /// the shipped shape exactly — a distinctly-named `…Async` twin and an
    /// `@available(*, deprecated, message:)` ending "Removed in the next major
    /// release."
    func testTheFacadeForceReconnectCarriesTheDeprecationWindow() throws {
        let source = try ClientSourceText.clientSource("JsBaoClient.swift")
        XCTAssertTrue(source.contains("public func forceReconnectAsync() async"),
                      "the async twin must exist")
        XCTAssertTrue(source.contains("public func forceReconnect() {"),
                      "the synchronous spelling must survive the window")

        let attributes = ClientSourceText.attributes(before: "public func forceReconnect() {", in: source)
        let deprecation = try XCTUnwrap(
            attributes.first { $0.hasPrefix("@available(*, deprecated") },
            "forceReconnect() must be deprecated — attributes: \(attributes)"
        )
        XCTAssertTrue(
            deprecation.contains("forceReconnectAsync()"),
            "the message must name the twin: \(deprecation)"
        )
        XCTAssertTrue(
            deprecation.contains("Removed in the next major release."),
            "the message must end with the shipped removal wording: \(deprecation)"
        )
    }

    /// The three now-internal commands convert outright: no `@available`, no
    /// twin, no ceremony. A deprecation window exists for app source
    /// compatibility, and internal members no longer have any.
    func testTheInternalCommandsConvertWithoutDeprecationCeremony() throws {
        let source = try ClientSourceText.clientSource(Self.managerFile)
        for declaration in [
            "func forceReconnect() {",
            "func setMaxReconnectDelay(_ ms: Int) {",
            "func closeSocket(initiator: String) {",
        ] {
            XCTAssertTrue(source.contains(declaration), "missing: \(declaration)")
            XCTAssertEqual(
                ClientSourceText.attributes(before: declaration, in: source), [],
                "\(declaration) is internal — it takes no availability ceremony (#2363/#2171)"
            )
        }
        for twin in ["forceReconnectAsync", "setMaxReconnectDelayAsync", "closeSocketAsync"] {
            XCTAssertFalse(
                source.contains(twin),
                "\(twin): an internal command converts outright rather than growing a twin"
            )
        }
    }

    /// Fork 2 Option B: the four reads stay synchronous permanently, so nothing
    /// on any `WebSocketManager` surface is removed-with-rename. #2172 shipped
    /// that second shape (`@available(*, unavailable, renamed:)` compile-error
    /// stubs) for `BlobManager`'s removed reads; it must not appear here.
    func testTheUnavailableRenamedShapeAppearsOnNoWebSocketManagerSurface() throws {
        for file in [Self.managerFile, "Internal/WebSocketTransportBoxes.swift"] {
            XCTAssertFalse(
                try ClientSourceText.clientSource(file).contains("unavailable, renamed:"),
                "\(file): Fork 2 Option B keeps every read synchronous — nothing is removed here"
            )
        }

        let client = try ClientSourceText.clientSource("JsBaoClient.swift")
        for read in ["public var isConnected: Bool", "public func forceReconnectAsync"] {
            XCTAssertFalse(
                ClientSourceText.attributes(before: read, in: client)
                    .contains { $0.contains("unavailable") },
                "\(read) must not be an unavailable stub"
            )
        }
        XCTAssertTrue(
            client.contains("public var isConnected: Bool"),
            "the client's synchronous isConnected read stays — DebugInspector and SwiftUI call it"
        )
        XCTAssertEqual(
            ClientSourceText.attributes(before: "public var isConnected: Bool", in: client), [],
            "isConnected is not deprecated: its semantics are unchanged behind the snapshot box"
        )
    }

    // MARK: - Behavior 15 — the deprecated member still works

    /// The deprecated member is `JsBaoClient.forceReconnect()`, so this drives
    /// **that** — the real public facade an app on the old spelling calls, not
    /// the manager command underneath it. The facade's body is new code in this
    /// PR (a `Task { await wsManager.forceReconnect() }` hand-off), and the
    /// whole point of the one-release window is that the old spelling keeps
    /// producing a reconnect; nothing else in the suite would notice if that
    /// fire-and-forget `Task` stopped being spawned.
    ///
    /// A fresh socket is observed from the **server** side (`acceptedCount`)
    /// because the client's `wsManager` is `private` — the server accepting a
    /// second connection is the observable form of "the reconnect happened".
    /// The enclosing method is marked deprecated so the reference sits in a
    /// deprecated context and the build stays warning-free (the convention
    /// `DeprecationWindowInternalUseTests` set).
    @available(*, deprecated, message: "Deprecated context: exercises the deprecated forceReconnect() on purpose (#2171).")
    func testTheDeprecatedClientFacadeForceReconnectStillReconnects() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = JsBaoClient(
            options: JsBaoClientOptions(
                apiUrl: "http://127.0.0.1:1",
                wsUrl: String(url.absoluteString.dropLast()),
                appId: "test-app",
                token: "test-token",
                offline: false,
                logLevel: .error,
                storageConfig: .memory,
                autoNetwork: false
            )
        )
        defer { Task { await client.destroy() } }

        try await client.connect()
        XCTAssertTrue(client.isConnected)
        let acceptedBefore = server.acceptedCount

        // The deprecated spelling: synchronous, fire-and-forget.
        client.forceReconnect()

        let reconnected = await eventuallyTrue(timeout: 10) {
            server.acceptedCount > acceptedBefore && client.isConnected
        }
        XCTAssertTrue(
            reconnected,
            "the deprecated facade must still produce a fresh live socket "
                + "(accepted \(server.acceptedCount), was \(acceptedBefore))"
        )
    }

    /// The manager command the facade dispatches to, driven directly — the
    /// facade test above cannot see the task swap, only the new socket.
    func testTheManagerForceReconnectStillReconnects() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url)
        let manager = makeManager(url: url, delegate: delegate)
        try await manager.connect()
        let firstTask = try XCTUnwrap(manager.snapshot.task)

        // The manager-level command, which the facade's deprecated spelling
        // dispatches to from its detached Task.
        await manager.forceReconnect()

        let reconnected = await eventuallyTrue(timeout: 10) {
            manager.isConnected && manager.snapshot.task !== firstTask
        }
        XCTAssertTrue(reconnected, "forceReconnect must still produce a fresh live socket")
        await manager.disconnect()
    }

    // MARK: - Behavior 16 — the reduced failure keeps the message verbatim

    /// `webSocketManagerOnError` receives a `Sendable` `WebSocketError`, not the
    /// original `URLError` — but its `localizedDescription` must be byte-equal
    /// to the original's, because `JsBaoClient` puts it straight into
    /// `ConnectionErrorEvent.message` for app code to read.
    func testTheReducedTransportFailureKeepsTheMessageVerbatim() async throws {
        // A refused port produces a deterministic URLError.
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        server.stop()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let delegate = RecordingDelegate(url: url)
        let manager = makeManager(url: url, delegate: delegate)
        do {
            try await manager.connect()
            XCTFail("connect() to a refused port should throw")
        } catch {
            // Expected.
        }

        let fired = await eventuallyTrue { !delegate.errors.isEmpty }
        XCTAssertTrue(fired, "the transport failure never reached the delegate")

        let received = try XCTUnwrap(delegate.errors.first)
        let webSocketError = try XCTUnwrap(
            received as? WebSocketError,
            "the delegate must receive the Sendable reduction, not the raw URLError"
        )
        guard case .transportFailure(let message, let code) = webSocketError else {
            return XCTFail("expected .transportFailure, got \(webSocketError)")
        }
        XCTAssertEqual(
            webSocketError.localizedDescription, message,
            "errorDescription must return the original message verbatim — a prefix here "
                + "would change ConnectionErrorEvent.message for every transport failure"
        )
        XCTAssertFalse(
            webSocketError.localizedDescription.hasPrefix("WebSocket connection failed:"),
            "the .connectionFailed prefix must not creep back in"
        )
        XCTAssertNotNil(code, "the URLError code must survive the reduction")
    }

    // MARK: - Test support

    /// Thread-safe recorder for the synchronous reader loop.
    private final class ObservedStatuses: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [ConnectionStatus] = []
        func record(_ status: ConnectionStatus) { lock.withLock { _values.append(status) } }
        var values: [ConnectionStatus] { lock.withLock { _values } }
    }

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _set = false
        func set() { lock.withLock { _set = true } }
        var isSet: Bool { lock.withLock { _set } }
    }
}
