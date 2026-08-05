import XCTest
@testable import JsBaoClient

/// #2171 — `WebSocketManager` becomes an `actor` behind one ordered
/// delegate-event channel.
///
/// The suite is in two halves, the same split the sibling conversions use:
///
/// * **Structural** (source text) — that the type really is an actor, that no
///   lock survived in its file, that `handleConnectionClosed` really has one
///   caller, and that the three decision regions really contain no suspension
///   point. None of these is observable from a passing functional test: an
///   actor and a lock-guarded class behave identically from the outside, and
///   "this region suspends" is a property the compiler does not check.
/// * **Behavioral** — the ordering the channel exists to provide, the
///   stale-event filtering, concurrent connects, the timers, the synchronous
///   reads, and the teardown.
///
/// Everything here is server-free: the connection behaviors run against the
/// in-process `LoopbackWebSocketServer`, and the ordering behaviors drive the
/// actor's `nonisolated` delegate methods directly.
final class ActorizedWebSocketManagerTests: XCTestCase {

    private static let managerFile = "Internal/WebSocketManager.swift"

    // MARK: - Test doubles

    /// Records every delegate call the manager makes, so the behavioral tests
    /// can assert on the sequence rather than on internal state.
    final class RecordingDelegate: WebSocketManagerDelegate, @unchecked Sendable {
        let url: URL
        let shouldReconnect: Bool

        private let lock = NSLock()
        private var _calls: [String] = []
        private var _errors: [Error] = []
        private var _requestsBuilt = 0
        private var _reconnectDelays: [Int] = []

        init(url: URL, shouldReconnect: Bool = false) {
            self.url = url
            self.shouldReconnect = shouldReconnect
        }

        var calls: [String] { lock.withLock { _calls } }
        var errors: [Error] { lock.withLock { _errors } }
        var requestsBuilt: Int { lock.withLock { _requestsBuilt } }
        var reconnectDelays: [Int] { lock.withLock { _reconnectDelays } }
        func countOf(_ call: String) -> Int { lock.withLock { _calls.filter { $0 == call }.count } }
        private func record(_ call: String) { lock.withLock { _calls.append(call) } }

        func webSocketManagerHasAccessToken() -> Bool { true }
        func webSocketManagerBuildConnectionRequest(connectionId: String) -> (url: URL, headers: [String: String]) {
            lock.withLock { _requestsBuilt += 1 }
            return (url, [:])
        }
        func webSocketManagerOnStatusChange(_ status: ConnectionStatus) { record("status:\(status)") }
        func webSocketManagerOnConnecting() { record("connecting") }
        func webSocketManagerOnConnected() { record("connected") }
        func webSocketManagerOnMessage(_ data: Data) async { record("message:data") }
        func webSocketManagerOnMessage(_ text: String) async { record("message:text") }
        func webSocketManagerOnClose(code: Int?, reason: String?) { record("close") }
        func webSocketManagerOnError(_ error: Error) {
            lock.withLock { _errors.append(error); _calls.append("error") }
        }
        func webSocketManagerOnReconnectScheduled(delayMs: Int) {
            lock.withLock { _reconnectDelays.append(delayMs); _calls.append("reconnectScheduled") }
        }
        func webSocketManagerOnDisconnectInitiated() { record("disconnectInitiated") }
        func webSocketManagerOnDisconnectResolved() { record("disconnectResolved") }
        func webSocketManagerShouldReconnect(code: Int?, reason: String?) -> Bool { shouldReconnect }
    }

    /// Thread-safe collector for the pump's handling order.
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _codes: [Int] = []
        func append(_ code: Int) { lock.withLock { _codes.append(code) } }
        var codes: [Int] { lock.withLock { _codes } }
    }

    private func makeManager(
        url: URL,
        delegate: RecordingDelegate,
        maxReconnectDelayMs: Int = 1000
    ) -> WebSocketManager {
        WebSocketManager(
            logger: Logger(level: .none, scope: "actorized-wsm"),
            maxReconnectDelayMs: maxReconnectDelayMs,
            delegate: delegate
        )
    }

    // MARK: - Behavior 1 — the actor declaration, and no surviving lock

    /// The headline of the conversion, and the one claim no functional test can
    /// make: the type is an `actor`, and it is `internal` (#2363 narrowed it,
    /// and `InternalVisibilityTests` fails on any `public` declaration in the
    /// file — this asserts the conversion did not reintroduce one on the type).
    func testWebSocketManagerIsDeclaredAsAnInternalActor() throws {
        let source = try Self.code(Self.managerFile)
        XCTAssertTrue(
            source.contains("actor WebSocketManager: NSObject, URLSessionWebSocketDelegate {"),
            "WebSocketManager must be an actor conforming to URLSessionWebSocketDelegate"
        )
        XCTAssertFalse(
            source.contains("public actor WebSocketManager"),
            "the actor must stay internal (#2363)"
        )
        XCTAssertFalse(
            source.contains("class WebSocketManager"),
            "WebSocketManager must not still be a lock-guarded class"
        )
    }

    /// The conversion has to *replace* the lock, not sit beside it. The two
    /// surviving `nonisolated` boxes are enumerated in their own file
    /// (`WebSocketTransportBoxes.swift`) precisely so this budget can be zero.
    func testConvertedManagerFileDeclaresNoLocks() throws {
        let source = try Self.code(Self.managerFile)
        for forbidden in ["NSLock()", "withLock", "@unchecked Sendable"] {
            XCTAssertFalse(
                source.contains(forbidden),
                "\(Self.managerFile) still contains `\(forbidden)` — the surviving boxes belong in "
                    + "WebSocketTransportBoxes.swift, where each carries its own safety argument"
            )
        }
    }

    /// The two enumerated exceptions exist, are the *only* `@unchecked`
    /// declarations in their file, and each carries the written safety argument
    /// the architecture doc requires.
    func testTheTwoSurvivingBoxesAreEnumeratedAndArgued() throws {
        let source = try Self.clientSource("Internal/WebSocketTransportBoxes.swift")
        let declarations = ClientSourceText.uncheckedDeclarations(in: source)
        XCTAssertEqual(
            declarations.count, 2,
            "exactly two boxes survive the conversion — found: \(declarations)"
        )
        for declaration in [
            "final class WebSocketTransportSnapshot: @unchecked Sendable {",
            "final class WeakWebSocketManagerDelegateBox: @unchecked Sendable {",
        ] {
            XCTAssertTrue(source.contains(declaration), "missing box declaration: \(declaration)")
            let argument = ClientSourceText.docComment(precedingDeclaration: declaration, in: source)
            XCTAssertNotNil(argument, "\(declaration) must carry a written safety argument")
            XCTAssertTrue(
                (argument ?? "").contains("lock"),
                "\(declaration)'s safety argument must name the lock that confines its fields"
            )
        }
    }

    // MARK: - Behavior 2 — ordering

    /// The property the channel exists to provide. A constructed
    /// `didOpen(taskA)` → `didCloseWith(taskA)` pair must never leave the
    /// manager believing a closed socket is connected, in either arrival order,
    /// and the outcome must be deterministic rather than a race.
    ///
    /// Both orders are exercised because they fail differently:
    ///
    /// * open-then-close — the close is handled second and wins, so the manager
    ///   ends `.disconnected`. Without FIFO ordering the open could be applied
    ///   after the close and strand `connected == true` on a dead socket.
    /// * close-then-open — the close nils the task first, so the open is
    ///   dropped as stale, the in-flight `connect()` throws, and the manager
    ///   ends `.disconnected`. This is the "connected-after-closed" resolution
    ///   the issue names.
    func testConstructedOpenCloseSequenceNeverResolvesConnectedAfterClosed() async throws {
        for closeFirst in [false, true] {
            for _ in 0..<100 {
                let server = try LoopbackWebSocketServer(completesHandshake: false)
                let url = try server.start()
                let delegate = RecordingDelegate(url: url)
                let manager = makeManager(url: url, delegate: delegate)

                // Start a connect and let it park on its continuation — the
                // server never answers the upgrade, so nothing resolves it.
                let connecting = Task { try await manager.connect() }
                let armed = await eventuallyTrue(timeout: 5) { manager.snapshot.task != nil }
                XCTAssertTrue(armed, "the connect attempt never created its task")
                guard let taskA = manager.snapshot.task else {
                    server.stop()
                    connecting.cancel()
                    return
                }

                if closeFirst {
                    manager.urlSession(
                        .shared, webSocketTask: taskA, didCloseWith: .normalClosure, reason: nil
                    )
                    manager.urlSession(.shared, webSocketTask: taskA, didOpenWithProtocol: nil)
                } else {
                    manager.urlSession(.shared, webSocketTask: taskA, didOpenWithProtocol: nil)
                    manager.urlSession(
                        .shared, webSocketTask: taskA, didCloseWith: .normalClosure, reason: nil
                    )
                }

                var threw = false
                do { try await connecting.value } catch { threw = true }

                let settled = await eventuallyTrue(timeout: 5) { manager.connectionStatus == .disconnected }
                XCTAssertTrue(
                    settled,
                    "closeFirst=\(closeFirst): the manager must end .disconnected, "
                        + "not \(manager.connectionStatus)"
                )
                XCTAssertFalse(manager.isConnected, "closeFirst=\(closeFirst): never connected-after-closed")
                if closeFirst {
                    XCTAssertTrue(
                        threw,
                        "closeFirst=true: the close is handled first, so the in-flight connect() must throw"
                    )
                }

                await manager.disconnect()
                server.stop()
            }
        }
    }

    // MARK: - Behavior 3 — one funnel

    /// After the conversion every terminal path reaches `handleConnectionClosed`
    /// through the channel, so the function has exactly one caller: `handle(_:)`.
    /// A second caller would be a path that bypasses the ordering region.
    func testHandleConnectionClosedHasExactlyOneCaller() throws {
        let source = try Self.code(Self.managerFile)
        let callLines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("handleConnectionClosed(") && !$0.hasPrefix("private func") }

        XCTAssertEqual(
            callLines.count, 3,
            "expected the three terminal paths to call handleConnectionClosed — found: \(callLines)"
        )

        let pump = try Self.slice(
            source,
            from: "private func handle(_ event: DelegateEvent) {",
            to: "private func currentTask(matching"
        )
        for call in callLines {
            XCTAssertTrue(
                pump.contains(call),
                "handleConnectionClosed is called from outside the pump: \(call)"
            )
        }
    }

    /// The three producers really do emit rather than call through. Read from
    /// source because the alternative — a direct call — is behaviorally
    /// indistinguishable in the happy path and only diverges under a race.
    func testEveryTerminalPathEmitsIntoTheChannel() throws {
        let source = try Self.code(Self.managerFile)
        for emitCall in [
            "emit(.closed(task: ObjectIdentifier(webSocketTask)",
            "emit(.completed(task: ObjectIdentifier(urlSessionTask)",
            ".receiveLoopFailed(",
        ] {
            XCTAssertTrue(source.contains(emitCall), "missing channel emit: \(emitCall)")
        }
    }

    /// Behavioral half, path 1 — a graceful `didCloseWith` reaches the close
    /// delegate call and emits no error.
    func testGracefulCloseReachesTheCloseDelegateWithoutAnError() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let delegate = RecordingDelegate(url: url)
        let manager = makeManager(url: url, delegate: delegate)
        try await manager.connect()

        await manager.disconnect()

        let sawClose = await eventuallyTrue { delegate.countOf("close") >= 1 }
        XCTAssertTrue(sawClose, "the close path must reach webSocketManagerOnClose")
        XCTAssertEqual(delegate.countOf("error"), 0, "a graceful close emits no error")
        server.stop()
    }

    /// Behavioral half, paths 2 and 3 — a transport failure at connect time
    /// (`didCompleteWithError`) and one on an established connection (the
    /// receive loop's catch) both surface exactly one error. These are the two
    /// cases `WebSocketManagerErrorTests` pins; asserted here on the delegate
    /// sequence so the funnel's ordering (error before close) is covered too.
    func testTransportFailureEmitsErrorBeforeClose() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let delegate = RecordingDelegate(url: url)
        let manager = makeManager(url: url, delegate: delegate)
        try await manager.connect()

        server.stop()

        let sawError = await eventuallyTrue { delegate.countOf("error") >= 1 }
        XCTAssertTrue(sawError, "an established-connection failure must emit an error")
        let calls = delegate.calls
        let errorIndex = try XCTUnwrap(calls.firstIndex(of: "error"))
        let closeIndex = try XCTUnwrap(calls.firstIndex(of: "close"))
        XCTAssertLessThan(errorIndex, closeIndex, "subscribers must see error-then-close")
        XCTAssertEqual(delegate.countOf("error"), 1, "exactly one error per transport failure")
    }

    // MARK: - Behavior 4 — no dropped events

    /// The stream is unbounded on purpose: a bounded policy that discarded an
    /// `open` or a `close` would desynchronize the state machine permanently.
    func testTheChannelIsUnbounded() throws {
        XCTAssertTrue(
            try Self.code(Self.managerFile).contains("bufferingPolicy: .unbounded"),
            "the delegate-event channel must never drop an event"
        )
    }

    /// A synthetic burst is observed by the pump in emit order, with none
    /// missing. The events carry a task identity the manager has never seen, so
    /// each is dropped *after* the pump records it — which is exactly the
    /// region under test.
    func testABurstOfAThousandEventsArrivesInOrderWithNoneMissing() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url)
        let manager = makeManager(url: url, delegate: delegate)

        let log = EventLog()
        await manager.setEventHandledHookForTest { event in
            if case .closed(_, let code, _) = event { log.append(code) }
        }

        let stranger = NSObject()
        let strangerId = ObjectIdentifier(stranger)
        for index in 0..<1000 {
            manager.emit(.closed(task: strangerId, code: index, reason: nil))
        }

        let observed = await eventuallyTrue(timeout: 20) { log.codes.count == 1000 }
        XCTAssertTrue(observed, "the pump observed \(log.codes.count) of 1000 events")
        XCTAssertEqual(log.codes, Array(0..<1000), "the pump must observe events in emit order")
        _ = stranger
    }

    // MARK: - Behavior 5 — stale-task filtering happens inside the actor

    /// Drive a real reconnect so the manager swaps tasks, then deliver a close
    /// for the *old* task. It must be ignored: the connection stays up and no
    /// continuation is resumed.
    func testAnEventFromASupersededTaskIsIgnored() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url)
        let manager = makeManager(url: url, delegate: delegate)

        try await manager.connect()
        let firstTask = try XCTUnwrap(manager.snapshot.task)

        // A fresh connect over a manual reconnect swaps in a second task.
        await manager.forceReconnect()
        let swapped = await eventuallyTrue(timeout: 10) {
            manager.snapshot.task !== firstTask && manager.isConnected
        }
        XCTAssertTrue(swapped, "the reconnect never produced a second live task")
        let closesBefore = delegate.countOf("close")

        // Wait for the pump to have *handled* the stale close rather than
        // sleeping: a pump that has not drained the event yet is indistinguishable
        // from one that correctly dropped it, so a sleep here would let a broken
        // stale filter pass on a loaded machine. The sentinel behind it is what
        // makes the wait ordered — see `HandledEventLog`.
        let handled = HandledEventLog()
        await manager.setEventHandledHookForTest { handled.record($0) }
        let sentinelCode = 4321
        let stranger = NSObject()

        manager.urlSession(.shared, webSocketTask: firstTask, didCloseWith: .normalClosure, reason: nil)
        manager.emit(.closed(task: ObjectIdentifier(stranger), code: sentinelCode, reason: nil))

        let observed = await eventuallyTrue(timeout: 10) { handled.sawSentinel(code: sentinelCode) }
        XCTAssertTrue(observed, "the pump never reached past the injected stale close")
        _ = stranger
        XCTAssertTrue(manager.isConnected, "a stale close must not tear down the live connection")
        XCTAssertEqual(delegate.countOf("close"), closesBefore, "a stale close must reach no delegate")

        await manager.disconnect()
    }

    // MARK: - Behavior 6 — concurrent connects

    /// 50 concurrent `connect()` callers against the loopback server all
    /// resolve, and exactly one socket is built: the decision region's
    /// `_connecting` check-and-commit is still atomic under actor isolation
    /// (it contains no `await`, which behavior 9 pins structurally).
    func testFiftyConcurrentConnectsCreateExactlyOneSocket() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url)
        let manager = makeManager(url: url, delegate: delegate)

        await assertCompletesAsync(within: 15, "50 concurrent connect() callers") {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<50 {
                    group.addTask { try? await manager.connect() }
                }
                await group.waitForAll()
            }
        }

        XCTAssertTrue(manager.isConnected, "every caller resolved and the manager is connected")
        XCTAssertEqual(
            delegate.requestsBuilt, 1,
            "exactly one URLSessionWebSocketTask may be created for 50 concurrent callers"
        )
        await manager.disconnect()
    }

    // MARK: - Behavior 9 — no `await` in a decision region

    /// Under a lock, "read state, decide, commit" was atomic for free. Under an
    /// actor it is not: isolation is reentrant, so a suspension between the
    /// check and the commit lets a second caller take the same decision. The
    /// three regions are sliced out of comment-free source so a doc comment
    /// cannot decide the outcome, and the slice throws if its anchors move.
    func testDecisionRegionsContainNoSuspensionPoint() throws {
        let source = try Self.code(Self.managerFile)

        let regions: [(name: String, from: String, to: String, mustContain: String)] = [
            (
                "connectDecision",
                "private func connectDecision() -> ConnectDecision {",
                "private func waitForInFlightConnect() async throws {",
                "_connecting = true"
            ),
            (
                "disconnectDecision",
                "private func disconnectDecision() -> DisconnectDecision {",
                "private func waitForInFlightDisconnect() async {",
                "isDisconnecting = true"
            ),
            (
                "handle",
                "private func handle(_ event: DelegateEvent) {",
                "private func currentTask(matching",
                "handleConnectionClosed("
            ),
        ]

        for region in regions {
            let body = try Self.slice(source, from: region.from, to: region.to)
            XCTAssertFalse(body.isEmpty, "\(region.name) sliced empty — the anchors moved")
            XCTAssertTrue(
                body.contains(region.mustContain),
                "\(region.name): the slice must be the region under test"
            )
            XCTAssertFalse(
                body.contains("await"),
                "\(region.name) must not suspend between its state read and its commit:\n\(body)"
            )
        }
    }

    /// `handle(_:)` is not merely await-free today — it is **non-`async`**, so
    /// the compiler cannot let a suspension back in.
    func testThePumpsHandlerIsNotAsync() throws {
        let source = try Self.code(Self.managerFile)
        XCTAssertTrue(
            source.contains("private func handle(_ event: DelegateEvent) {"),
            "handle(_:) must stay non-async — that is what makes the ordering region enforceable"
        )
        XCTAssertFalse(
            source.contains("private func handle(_ event: DelegateEvent) async"),
            "an async handle(_:) would let the next event interleave mid-decision"
        )
    }

    /// `ConnectWaiterResolution` is retired (Fork 3): it existed only to close
    /// the gap between the decision's lock hold and the waiter registration's,
    /// and there is no gap inside an actor. `ConnectDecision` and
    /// `DisconnectDecision` — the vocabulary #1993 asked to preserve — stay.
    func testConnectWaiterResolutionIsRetiredAndTheRestOfTheVocabularyStays() throws {
        let source = try Self.code(Self.managerFile)
        XCTAssertFalse(
            source.contains("ConnectWaiterResolution"),
            "the in-gap re-check is unreachable inside an actor — the enum goes with it"
        )
        XCTAssertTrue(source.contains("enum ConnectDecision"), "ConnectDecision stays")
        XCTAssertTrue(source.contains("enum DisconnectDecision"), "DisconnectDecision stays")
    }

    // MARK: - Behavior 22 — no teardown leak

    /// The hazard the conversion introduces: the pump task runs for as long as
    /// the stream is live, so capturing `self` strongly would retain the actor
    /// forever, `deinit` would never run, and the `URLSession` would never be
    /// invalidated — a connection leak on every client teardown.
    func testReleasingTheManagerRunsDeinit() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url)

        // Boxed rather than a bare `weak var`: the poll below reads it from a
        // `@Sendable` closure, and the Swift 6 language mode (#2310) rejects a
        // captured local `var` there. The reference stays weak, so this still
        // measures the leak it is written to catch.
        let weakManager: WeakBox<WebSocketManager>
        do {
            let manager = makeManager(url: url, delegate: delegate)
            weakManager = WeakBox(manager)
            try await manager.connect()
            XCTAssertTrue(manager.isConnected)
            await manager.disconnect()
        }

        let released = await eventuallyTrue(timeout: 10) { weakManager.isReleased }
        XCTAssertTrue(released, "the manager was still alive — the pump is retaining it")
    }

    /// The structural half: the pump and both timers capture `self` weakly.
    /// A behavioral leak test only fails once the capture is wrong *and* the
    /// timing reproduces; this pins the requirement itself.
    func testTheDetachedTasksCaptureSelfWeakly() throws {
        let source = try Self.code(Self.managerFile)
        for factory in [
            "pump = Task { [weak self] in",
            "private nonisolated func makeReceiveLoop",
            "private nonisolated func makeReconnectTimer",
            "private nonisolated func makeDisconnectTimeout",
        ] {
            XCTAssertTrue(source.contains(factory), "missing: \(factory)")
        }
        let strongTasks = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("Task {") && !$0.contains("[weak self]") }
        // The three short-lived `Task { try? await self.connect() }` hops are
        // deliberate strong captures: they finish, so they cannot retain the
        // actor past their own lifetime. Anything else must be weak.
        for line in strongTasks {
            XCTAssertTrue(
                line.contains("self.connect()") || line.contains("self.startPump()"),
                "a long-lived Task must capture self weakly: \(line)"
            )
        }
    }

    // MARK: - Helpers

    private static func code(_ relativePath: String) throws -> String {
        try ClientSourceText.code(relativePath)
    }

    private static func clientSource(_ relativePath: String) throws -> String {
        try ClientSourceText.clientSource(relativePath)
    }

    private static func slice(_ source: String, from: String, to: String) throws -> String {
        try ClientSourceText.slice(source, from: from, to: to)
    }
}
