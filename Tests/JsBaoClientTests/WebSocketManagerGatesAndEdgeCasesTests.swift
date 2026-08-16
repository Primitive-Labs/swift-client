import XCTest
@testable import JsBaoClient

/// #2171 Phase 3 — the gate work the conversion is responsible for, the
/// documentation of its two exceptions, and the edge cases the actor
/// conversion introduces or changes.
///
/// The TSan work is part of the deliverable, not a side effect. Emptying
/// `BASELINE_RACE_SIGNATURES` is the whole point of converting this type, and
/// the script had two ways to turn an empty baseline into a gate that reports
/// a permanent pass. `testTheGateStillFailsOnANewRaceWithAnEmptyBaseline` runs
/// the real classifier over a synthetic TSan log and is the regression test for
/// both.
final class WebSocketManagerGatesAndEdgeCasesTests: XCTestCase {

    private typealias RecordingDelegate = ActorizedWebSocketManagerTests.RecordingDelegate

    private func makeManager(
        url: URL,
        delegate: RecordingDelegate?,
        maxReconnectDelayMs: Int = 1000
    ) -> WebSocketManager {
        WebSocketManager(
            logger: Logger(level: .none, scope: "wsm-gates"),
            maxReconnectDelayMs: maxReconnectDelayMs,
            delegate: delegate
        )
    }

    // MARK: - Behavior 18 — the baseline is empty

    /// Both `WebSocketManager` signatures are gone, leaving the baseline empty:
    /// the race they documented was `disconnect()` versus `receiveLoopTask`, and
    /// `receiveLoopTask` is actor-isolated state now.
    func testTheRaceBaselineIsEmpty() throws {
        let gate = try ClientSourceText.packageFile("scripts/tsan-gate.sh")
        let baseline = try ClientSourceText.slice(
            gate, from: "BASELINE_RACE_SIGNATURES=(", to: ")"
        )
        let entries = baseline
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        XCTAssertEqual(entries, [], "the baseline must be empty after this conversion: \(entries)")
    }

    /// A baseline entry may only be removed once the gate actually runs the
    /// suites that hammer the race it covered — the rule `docs/testing.md`
    /// records and the reason `EventStreamTests` and
    /// `AnalyticsQueueFlushTimerRaceTests` were added before their removals.
    func testTheSuitesCoveringTheRemovedEntriesAreInTheDefaultFilter() throws {
        let gate = try ClientSourceText.packageFile("scripts/tsan-gate.sh")
        for suite in [
            "WebSocketManagerDisconnectTests",
            "WebSocketManagerErrorTests",
            "ActorizedWebSocketManagerTests",
        ] {
            XCTAssertTrue(
                gate.contains(suite),
                "\(suite) must be in the TSan gate's default filter — it exercises the "
                    + "state the removed baseline entries covered"
            )
        }
    }

    // MARK: - Behavior 19 — an empty baseline does not disable the gate

    /// The sharp one. With `BASELINE_RACE_SIGNATURES` empty the script has to
    /// (a) run at all under macOS bash 3.2 + `set -u`, where `"${arr[@]}"` on an
    /// empty array aborts with `unbound variable`, and (b) still classify a race
    /// as NEW — an empty `KNOWN_RE` is an empty awk regex, which matches every
    /// block, so the unguarded classifier would file every future race as KNOWN
    /// and report OK forever.
    ///
    /// Both halves are exercised against the **real** script text: the two
    /// fragments are extracted from `tsan-gate.sh` and run in a bash 3.2-strict
    /// harness, so a future edit that reintroduces either hazard fails here.
    func testTheGateStillFailsOnANewRaceWithAnEmptyBaseline() throws {
        let gate = try ClientSourceText.packageFile("scripts/tsan-gate.sh")

        let knownReBlock = try ClientSourceText.slice(
            gate,
            from: "if [ \"${#BASELINE_RACE_SIGNATURES[@]}\" -gt 0 ]; then",
            to: "\n# Collect every race"
        )
        let classifier = try ClientSourceText.slice(
            gate, from: "CLASSIFY=\"$(", to: "\nread -r KNOWN_RACES"
        )

        let log = """
            WARNING: ThreadSanitizer: data race (pid=1)
              Write of size 8 at 0x000102030405 by thread T7:
                #0 SomeBrandNewType.mutate() SomeBrandNewType.swift:42
            SUMMARY: ThreadSanitizer: data race SomeBrandNewType.swift:42

            """

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsan-empty-baseline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let logURL = temporary.appendingPathComponent("tsan.log")
        try log.write(to: logURL, atomically: true, encoding: .utf8)

        let script = """
            set -euo pipefail
            BASELINE_RACE_SIGNATURES=()
            TSAN_LOG="\(logURL.path)"
            if [ "${#BASELINE_RACE_SIGNATURES[@]}" -gt 0 ]; then
            \(knownReBlock)
            CLASSIFY="$(\(classifier)
            echo "$CLASSIFY"
            """
        let scriptURL = temporary.appendingPathComponent("harness.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        // /bin/bash on macOS is 3.2 — the shell the gate actually runs under,
        // and the one whose empty-array behaviour is the hazard.
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let stdout = String(
            data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        process.waitUntilExit()

        XCTAssertEqual(
            process.terminationStatus, 0,
            "the gate must run to completion with an empty baseline under `set -u`: \(stderr)"
        )
        XCTAssertFalse(
            stderr.contains("unbound variable"),
            "the empty-array expansion aborted the script: \(stderr)"
        )

        let counts = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").compactMap { Int($0) }
        XCTAssertEqual(counts.count, 3, "expected `known new other`, got: \(stdout)")
        XCTAssertEqual(counts[0], 0, "an empty baseline can classify nothing as KNOWN")
        XCTAssertEqual(
            counts[1], 1,
            "an injected race must classify as NEW with an empty baseline — an empty "
                + "regex matching every block is what silently disables the race verdict"
        )
    }

    // MARK: - Behavior 20 — the .v6 gate holds the converted file at zero

    func testTheV6GateHoldsTheConvertedFileAtZero() throws {
        let runner = try ClientSourceText.packageFile("run-tests.sh")
        XCTAssertTrue(
            runner.contains("\"Internal/WebSocketManager.swift\""),
            "run-tests.sh must hold Internal/WebSocketManager.swift at zero .v6 Sendable sites — "
                + "actorizing a type creates Sendable requirements at every new boundary"
        )
    }

    // MARK: - Behavior 24 — the architecture doc

    /// The doc has to name the new actor, carry a written safety argument for
    /// each surviving `nonisolated` box, record the channel-ordering invariant,
    /// and — because the two paragraphs now sit next to each other — say why the
    /// snapshot box is not the "second source of truth" the `BlobManager`
    /// rationale rejects.
    func testArchitectureDocCoversTheConversion() throws {
        let doc = try ClientSourceText.packageFile("docs/architecture.md")

        XCTAssertTrue(
            doc.contains("| `WebSocketManager` |"),
            "architecture.md's actor table must list WebSocketManager"
        )
        XCTAssertFalse(
            doc.contains("`WebSocketManager` (#2171) and `AuthController` (#2173) are queued"),
            "the doc still says WebSocketManager is queued for actorization — it is done"
        )
        XCTAssertFalse(
            doc.contains("**WebSocketManager**: `NSLock` guards the state machine"),
            "the sync-domain patterns list must no longer describe WebSocketManager as lock-guarded"
        )

        // The two boxes, named as the enumerated exceptions rather than left
        // to contradict the "no lock" sentence above them.
        XCTAssertTrue(
            doc.contains("two** enumerated exceptions"),
            "the actor-domain paragraph must name how many locks survive"
        )
        for box in ["transport snapshot", "weak delegate box"] {
            XCTAssertTrue(doc.contains(box), "architecture.md must name the \(box)")
        }

        // The channel-ordering invariant, beside the existing no-`await` one.
        XCTAssertTrue(
            doc.contains("every lifecycle signal that originates outside isolation enters through the channel"),
            "architecture.md must record the channel-ordering invariant"
        )
        XCTAssertTrue(
            doc.contains("`.unbounded`"),
            "the invariant only holds with the never-drop buffering policy — say so"
        )

        // The reconciliation with #2340's BlobManager rationale.
        XCTAssertTrue(
            doc.contains("second source of truth"),
            "architecture.md must address the rationale the BlobManager section states"
        )
        XCTAssertTrue(
            doc.contains("there is no second copy to drift")
                || doc.contains("no second copy to drift"),
            "the snapshot box's argument must say why it is not a second copy of actor state"
        )
    }

    // MARK: - Edge case 1 — the delegate is deallocated mid-flight

    /// The weak box goes nil while a connection is live. Nothing may crash, and
    /// no pending continuation may be stranded — the manager still resolves its
    /// own `disconnect()`.
    func testADeallocatedDelegateStrandsNoContinuation() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let manager: WebSocketManager
        do {
            let delegate = RecordingDelegate(url: url)
            manager = makeManager(url: url, delegate: delegate)
            try await manager.connect()
            XCTAssertTrue(manager.isConnected)
        }
        // The delegate is gone; the box holds it weakly.
        XCTAssertNil(manager.delegate, "the delegate box must not keep the delegate alive")

        await assertCompletesAsync(within: 8, "disconnect with a deallocated delegate") {
            await manager.disconnect()
        }
        XCTAssertFalse(manager.isConnected)
    }

    // MARK: - Edge case 2 — the delegate is set after construction

    /// `JsBaoClient.setupDependencies()` wires the delegate synchronously from
    /// `init`, so the setter must leave no window: a `connect()` issued
    /// immediately afterwards must see it.
    func testTheDelegateSetterLeavesNoWindowBeforeConnect() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url)

        let manager = makeManager(url: url, delegate: nil)
        // Synchronous, from a non-async context — the shape the client needs.
        manager.delegate = delegate
        XCTAssertTrue(manager.delegate === delegate)

        try await manager.connect()
        XCTAssertTrue(manager.isConnected, "a delegate wired after init must still be seen by connect()")
        await manager.disconnect()
    }

    // MARK: - Edge case 3 — a callback after invalidateAndCancel

    /// Covered structurally by the stale filter and behaviorally by
    /// `ActorizedWebSocketManagerTests.testAnEventFromASupersededTaskIsIgnored`;
    /// this pins the harder instance — a callback arriving after the manager
    /// has torn everything down, when `task` is nil rather than merely
    /// different.
    func testACallbackAfterTeardownIsDropped() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url)
        let manager = makeManager(url: url, delegate: delegate)

        try await manager.connect()
        let liveTask = try XCTUnwrap(manager.snapshot.task)
        await manager.disconnect()
        XCTAssertNil(manager.snapshot.task, "teardown must clear the task")
        let closesAfterTeardown = delegate.countOf("close")

        // Same reason as `testAnEventFromASupersededTaskIsIgnored`: a sentinel
        // behind the two injected callbacks turns "nothing happened" into an
        // ordered observation, instead of one a sleep could make before the
        // pump had even drained them.
        let handled = HandledEventLog()
        await manager.setEventHandledHookForTest { handled.record($0) }
        let sentinelCode = 4321
        let stranger = NSObject()

        manager.urlSession(.shared, webSocketTask: liveTask, didCloseWith: .normalClosure, reason: nil)
        manager.urlSession(.shared, webSocketTask: liveTask, didOpenWithProtocol: nil)
        manager.emit(.closed(task: ObjectIdentifier(stranger), code: sentinelCode, reason: nil))

        let observed = await eventuallyTrue(timeout: 10) { handled.sawSentinel(code: sentinelCode) }
        XCTAssertTrue(observed, "the pump never reached past the injected post-teardown callbacks")
        _ = stranger
        XCTAssertEqual(
            delegate.countOf("close"), closesAfterTeardown,
            "a callback that arrives after teardown must reach no delegate"
        )
        XCTAssertFalse(manager.isConnected, "and must not resurrect the connection")
    }

    // MARK: - Edge case 5 — an idle close

    /// `didCloseWith` with no connect in flight: no continuation is resumed and
    /// the reconnect decision still runs normally.
    func testAnIdleCloseResumesNothingAndStillDecidesOnReconnect() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url, shouldReconnect: true)
        let manager = makeManager(url: url, delegate: delegate)

        try await manager.connect()
        // connect() has returned, so nothing is parked on a continuation.
        let liveTask = try XCTUnwrap(manager.snapshot.task)

        manager.urlSession(.shared, webSocketTask: liveTask, didCloseWith: .normalClosure, reason: nil)

        let decided = await eventuallyTrue { !delegate.reconnectDelays.isEmpty }
        XCTAssertTrue(decided, "an idle close must still run the reconnect decision")
        XCTAssertEqual(delegate.countOf("close"), 1)

        await manager.disconnect()
    }

    // MARK: - Edge case 6 — the reconnect sleep is cancelled

    /// The cancelled `Task.sleep` throws `CancellationError`; it must be
    /// absorbed and spawn no connect. Structural, because the absorbing is a
    /// `try?` plus a cancellation guard that a behavioral test can only observe
    /// as "nothing happened" — which is also what a broken timer looks like.
    func testTheCancelledReconnectSleepIsAbsorbed() throws {
        let source = try ClientSourceText.code("Internal/WebSocketManager.swift")
        let timer = try ClientSourceText.slice(
            source,
            from: "private nonisolated func makeReconnectTimer(delayMs: Int) -> Task<Void, Never> {",
            to: "private func fireReconnect() {"
        )
        XCTAssertTrue(
            timer.contains("try? await Task.sleep("),
            "the cancellation error must be absorbed, not propagated:\n\(timer)"
        )
        XCTAssertTrue(
            timer.contains("guard !Task.isCancelled"),
            "a cancelled sleep must not go on to fire the reconnect:\n\(timer)"
        )
    }

    // MARK: - Edge case 7 — forceReconnect twice in quick succession

    /// The guarantee is **at most one extra attempt, never a reconnect storm**
    /// — not "always exactly one reconnect" (edge case 7, amended during review
    /// of PR #2425).
    ///
    /// `forceReconnect()`'s decision logic is unchanged by the conversion:
    /// `manualReconnectPending` is set, and a live task takes the
    /// close-and-return branch, exactly as the locked class did. What the
    /// conversion changes is the *window*: `await manager.forceReconnect()`
    /// suspends between the two calls, so the pump can run
    /// `handleConnectionClosed` in between — it consumes the flag and spawns
    /// its own connect, and the second call then finds `task == nil` and takes
    /// the connect branch itself. The class had the same interleaving (its
    /// `handleConnectionClosed` ran on `URLSession`'s delegate queue and
    /// contended for the same lock), just through a narrower window.
    ///
    /// The blast radius is bounded by `connect()`'s own dedup — a second caller
    /// takes `.waitOnExisting` rather than building a socket — so the observable
    /// ceiling is one extra connection request, which is what this asserts.
    /// Closing the window properly would mean tracking a manual reconnect as
    /// in-flight state across the close, which is new state and new failure
    /// modes for a bounded, non-user-visible overlap.
    func testTwoRapidForceReconnectsDoNotFanOut() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url)
        let manager = makeManager(url: url, delegate: delegate)

        try await manager.connect()
        let firstTask = try XCTUnwrap(manager.snapshot.task)
        let requestsBefore = delegate.requestsBuilt

        await manager.forceReconnect()
        await manager.forceReconnect()

        let reconnected = await eventuallyTrue(timeout: 10) {
            manager.isConnected && manager.snapshot.task !== firstTask
        }
        XCTAssertTrue(reconnected, "the manual reconnect never produced a fresh socket")

        // Let any second reconnect land before counting.
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertLessThanOrEqual(
            delegate.requestsBuilt - requestsBefore, 2,
            "two rapid forceReconnects must not fan out into a reconnect storm"
        )
        XCTAssertTrue(manager.isConnected)
        await manager.disconnect()
    }

    // MARK: - Edge case 8 — deinit with buffered, unconsumed events

    /// Teardown completes rather than hanging when the channel still holds
    /// events the pump has not reached. The pump is stalled on its first event
    /// while a burst is queued behind it, then the manager is released.
    func testTeardownCompletesWithBufferedEvents() async throws {
        let stranger = NSObject()
        let strangerId = ObjectIdentifier(stranger)

        // Boxed rather than a bare `weak var`: the poll below reads it from a
        // `@Sendable` closure, and the Swift 6 language mode (#2310) rejects a
        // captured local `var` there. The reference stays weak.
        let weakManager: WeakBox<WebSocketManager>
        do {
            let url = URL(string: "ws://127.0.0.1:1/")!
            let manager = makeManager(url: url, delegate: nil)
            weakManager = WeakBox(manager)

            let stall = StallFlag()
            await manager.setEventHandledHookForTest { _ in
                guard !stall.isSet else { return }
                stall.set()
                Thread.sleep(forTimeInterval: 0.5)
            }
            for index in 0..<200 {
                manager.emit(.closed(task: strangerId, code: index, reason: nil))
            }
        }

        let released = await eventuallyTrue(timeout: 10) { weakManager.isReleased }
        XCTAssertTrue(released, "teardown hung with buffered events still on the channel")
        _ = stranger
    }

    // MARK: - Edge case 9 — connect while a disconnect is in flight

    /// `setDesiredConnection(true)` parks on the in-flight disconnect and only
    /// then connects, rather than racing it.
    ///
    /// The connect is issued from **inside** the disconnect, out of the
    /// `disconnectInitiated` delegate callback. `disconnect()` makes that call
    /// from the same non-suspending isolated region that set
    /// `isDisconnecting = true`, and before it has issued the socket close at
    /// all, so the disconnect is provably still in flight at the moment the
    /// connect is enqueued on the actor. That is the precondition the test
    /// claims to exercise, and there is no other seam that establishes it:
    /// `URLSessionWebSocketTask.cancel(with:)` reports `didCloseWith` locally
    /// within a fraction of a millisecond on the loopback server, so *any*
    /// wait-then-act shape — including polling for `disconnectInitiated`, the
    /// shape PR #2624 first used — issues its connect against a disconnect
    /// that has already fully resolved. Measured, with
    /// `waitForInFlightDisconnect()` stubbed out to return immediately: the
    /// polling shape still passed 5 of 10 runs; this shape failed 20 of 20.
    ///
    /// The settle check below is a plain assertion rather than a poll, because
    /// `setDesiredConnection` awaits `connect()`, and `connect()` publishes the
    /// transport snapshot before it resumes its caller. The 10 s poll it
    /// replaces was not a timeout worth keeping: waiting longer for a
    /// condition that is already decided is what made the original test burn
    /// its full window.
    ///
    /// Fired as two unordered `async let` children instead — the shape this
    /// test had until #2568 — the connect reaches the actor first often enough
    /// to matter under CPU load, finds no disconnect in flight, short-circuits
    /// on `.alreadyConnected`, and lets the disconnect land last and settle
    /// the manager disconnected. That is correct last-writer-wins behavior, so
    /// the 10 s settle poll could never succeed and the test burned its full
    /// window. The unordered case is covered by
    /// `testConcurrentDisconnectAndSetDesiredConnectionSettleOnTheLastCommand`,
    /// which asserts only invariants that hold in both interleavings.
    func testSetDesiredConnectionWaitsOutAnInFlightDisconnect() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let managerBox = LockedBox<WebSocketManager?>(nil)
        let reconnecting = LockedBox<Task<Void, Never>?>(nil)
        let delegate = RecordingDelegate(url: url, onDisconnectInitiated: {
            // Cleared before the teardown disconnect below, so this fires for
            // exactly the one disconnect the test is ordering against.
            guard let manager = managerBox.value else { return }
            reconnecting.value = Task { await manager.setDesiredConnection(shouldConnect: true) }
        })
        let manager = makeManager(url: url, delegate: delegate)
        managerBox.value = manager

        try await manager.connect()
        XCTAssertEqual(delegate.requestsBuilt, 1, "the opening connect builds exactly one request")

        await assertCompletesAsync(within: 15, "setDesiredConnection(true) behind an in-flight disconnect") {
            await manager.disconnect()
            await reconnecting.value?.value
        }

        let calls = delegate.calls
        XCTAssertEqual(
            delegate.countOf("disconnectInitiated"), 1,
            "disconnect() must report disconnectInitiated — the callback this test issues the connect from: \(calls)"
        )

        // The parking is what these two assert. Without it the connect runs
        // while the socket is still open and `_connected` still true, takes
        // `connectDecision()`'s `.alreadyConnected` branch, builds no second
        // request, and leaves the disconnect to land last and settle the
        // manager disconnected.
        XCTAssertEqual(
            delegate.requestsBuilt, 2,
            "the connect must park on the close and then build a fresh request, not short-circuit on the open socket: \(calls)"
        )
        if let resolved = calls.firstIndex(of: "disconnectResolved"),
           let reconnected = calls.lastIndex(of: "connecting") {
            XCTAssertGreaterThan(
                reconnected, resolved,
                "the connect must start after the disconnect resolved, not alongside it: \(calls)"
            )
        } else {
            XCTFail("expected both a resolved disconnect and a second connect: \(calls)")
        }
        XCTAssertTrue(
            manager.isConnected,
            "the connect must win the ordering and leave the manager connected: \(calls)"
        )

        managerBox.value = nil
        await manager.disconnect()
    }

    /// The unordered variant: `disconnect()` and `setDesiredConnection(true)`
    /// are fired with no ordering between them, and only the invariants that
    /// hold in *both* interleavings are asserted (#2568).
    ///
    /// Which command reaches the actor last is the scheduler's choice, so the
    /// terminal state is too — `setDesiredConnection` documents the rule as
    /// last writer wins. The delegate call sequence names the interleaving: a
    /// `connecting` after `disconnectInitiated` means the connect parked on
    /// the in-flight disconnect and then re-drove a real connect, so it landed
    /// last; no such call means the connect arrived first, short-circuited on
    /// an already-open socket, and the disconnect landed last.
    func testConcurrentDisconnectAndSetDesiredConnectionSettleOnTheLastCommand() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url)
        let manager = makeManager(url: url, delegate: delegate)

        try await manager.connect()
        XCTAssertEqual(delegate.requestsBuilt, 1, "the opening connect builds exactly one request")

        await assertCompletesAsync(within: 15, "concurrent disconnect and setDesiredConnection(true)") {
            async let disconnecting: Void = manager.disconnect()
            async let reconnecting: Void = manager.setDesiredConnection(shouldConnect: true)
            _ = await (disconnecting, reconnecting)
        }

        let calls = delegate.calls
        XCTAssertEqual(
            delegate.countOf("disconnectInitiated"), 1,
            "exactly one disconnect runs whichever order the pair lands in: \(calls)"
        )
        guard let initiated = calls.firstIndex(of: "disconnectInitiated") else { return }

        if calls[initiated...].contains("connecting") {
            XCTAssertEqual(
                delegate.requestsBuilt, 2,
                "the connect landed last, so it built exactly one further request: \(calls)"
            )
            let settled = await eventuallyTrue(timeout: 5) { manager.isConnected }
            XCTAssertTrue(settled, "the connect landed last, so the manager must end connected: \(calls)")
        } else {
            XCTAssertEqual(
                delegate.requestsBuilt, 1,
                "the connect short-circuited on the open socket, so no second socket was opened: \(calls)"
            )
            XCTAssertFalse(
                manager.isConnected,
                "the disconnect landed last, so the manager must end disconnected: \(calls)"
            )
        }

        await manager.disconnect()
    }

    // MARK: - Edge case 11 — reentrancy at each await inside connect()

    /// Actor isolation is reentrant, so `connect()` suspends several times after
    /// setting `_connecting = true`. A second caller arriving at any of those
    /// points must take `.waitOnExisting` and never create a second socket.
    /// Exercised as staggered arrivals rather than one simultaneous burst — the
    /// burst (behavior 6) mostly lands before the first suspension.
    func testStaggeredConnectCallersNeverCreateASecondSocket() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let delegate = RecordingDelegate(url: url)
        let manager = makeManager(url: url, delegate: delegate)

        await assertCompletesAsync(within: 15, "staggered connect() callers") {
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<20 {
                    group.addTask {
                        try? await Task.sleep(nanoseconds: UInt64(index) * 200_000)
                        try? await manager.connect()
                    }
                }
                await group.waitForAll()
            }
        }

        XCTAssertTrue(manager.isConnected)
        XCTAssertEqual(
            delegate.requestsBuilt, 1,
            "a caller arriving at any suspension point inside connect() must wait, not re-connect"
        )
        await manager.disconnect()
    }

    // MARK: - Edge case 12 — the lock-order edge, written down

    /// `webSocketManagerShouldReconnect` → `JsBaoClient.networkingAllowed()` →
    /// `JsBaoClient.lock` is called from actor isolation. The reverse edge would
    /// need some path to `await` the actor while holding that lock, which is
    /// impossible: you cannot `await` inside `lock.withLock`. The written
    /// argument is the deliverable here; the runtime check is the deadlock
    /// watchdog in `WebSocketManagerDisconnectTests`.
    func testTheLockOrderArgumentIsWrittenDown() throws {
        let doc = try ClientSourceText.packageFile("docs/architecture.md")
        XCTAssertTrue(
            doc.contains("AuthController") && doc.contains("#2173"),
            "architecture.md must record that WebSocketManager depends on AuthController "
                + "staying synchronously readable"
        )
        let source = try ClientSourceText.clientSource("Internal/WebSocketManager.swift")
        XCTAssertTrue(
            source.contains("would reopen the double-connect race"),
            "the delegate protocol must say why its methods stay synchronous"
        )
    }

    // MARK: - Test support

    private final class StallFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _set = false
        func set() { lock.withLock { _set = true } }
        var isSet: Bool { lock.withLock { _set } }
    }
}
