import XCTest
@testable import JsBaoClient

/// A real, non-HTTP-status network failure — what a refresh hits when the
/// device is offline or the host is unreachable. File-scope so the `@Sendable`
/// transport responders below can throw it without capturing the test case.
private func networkFailure() -> Error {
    URLError(.notConnectedToInternet)
}

/// A JSON `TransportResponse`, so a responder reads as one line.
private func jsonResponse(_ json: String, status: Int = 200) -> TransportResponse {
    TransportResponse(
        status: status,
        headers: ["Content-Type": "application/json"],
        body: Data(json.utf8)
    )
}

/// Server-free tests for the refresh-retry backoff scheduler (issue #2022) —
/// the Swift port of the JS client's `handleRefreshDeferred` /
/// `scheduleRefreshRetry` (`src/client/internal/authController.ts`).
///
/// These inject a `RecordingTransport` through `AuthController.setTransport`
/// to induce a network failure and then observe what the controller does with
/// it: whether it emits `authRefreshDeferred`, whether the scheduled retry
/// actually fires, and whether the accumulated backoff reaching the cap
/// flips the client to offline mode. A live dev server can't induce the
/// network failure (or advance the clock) deterministically, so the seam is
/// the only way to assert the timing behavior — the same reasoning as
/// `AuthRefreshCoalescingUnitTests`.
final class AuthRefreshBackoffSchedulerTests: XCTestCase {

    /// Thread-safe counter for asserting how many refresh round trips ran.
    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        func increment() { lock.withLock { _value += 1 } }
        var value: Int { lock.withLock { _value } }
    }

    /// Thread-safe recorder for the `authRefreshDeferred` payloads.
    private final class DeferredRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [AuthRefreshDeferredEvent] = []
        func record(_ details: AuthRefreshDeferredEvent) { lock.withLock { _events.append(details) } }
        var events: [AuthRefreshDeferredEvent] { lock.withLock { _events } }
    }

    /// A JWT whose payload decodes so `applyToken` parses a userId and the
    /// controller ends up authenticated (parity with a real refresh).
    private func makeJwt(userId: String) -> String {
        let payload: [String: Any] = ["userId": userId, "sub": userId, "exp": 9_999_999_999]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "h.\(b64).s"
    }

    private func makeController(
        emitter: EventEmitter = EventEmitter(),
        responder: @escaping @Sendable (RecordedRequest) async throws -> TransportResponse
    ) -> AuthController {
        let controller = AuthController(
            appId: "test-app",
            apiUrl: "http://localhost:8787",
            logger: Logger(level: .error),
            offlineStore: OfflineStore(),
            emitter: emitter,
            refreshProxy: nil,
            persistConfig: AuthConfig()
        )
        controller.setTransport(RecordingTransport(responder: responder))
        return controller
    }

    /// Subscribe to `authRefreshDeferred` and keep the subscription alive for
    /// the caller (subscriptions cancel on deinit).
    ///
    /// `.authRefreshDeferred` was one of the nine events converted from a bare
    /// `[String: Any]` to a typed payload (#1994). #2367 removed the untyped
    /// `onAny` shim these tests used to read it through, so the recorder now
    /// holds `AuthRefreshDeferredEvent` values and the assertions read its
    /// fields. `nextAttemptMs` is optional on the payload, so "no next attempt
    /// promised" is still a nil check.
    private func recordDeferred(
        on emitter: EventEmitter,
        into recorder: DeferredRecorder
    ) -> EventSubscription {
        emitter.subscribe(AuthRefreshDeferredEvent.self) { event in
            recorder.record(event)
        }
    }

    /// Poll until `condition` holds or the deadline passes. Returns whether it
    /// held — timing assertions stay robust on a loaded CI machine.
    private func waitUntil(
        timeout: TimeInterval,
        _ condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    // MARK: - Scheduling

    /// The core gap this issue closes: a network-failed refresh must schedule
    /// a background retry that ACTUALLY fires — not just report a
    /// `nextAttemptMs` nothing ever acts on.
    func testNetworkFailedRefreshSchedulesRetryThatFires() async throws {
        let refreshCalls = AtomicCounter()
        let controller = makeController { _ in
            refreshCalls.increment()
            throw networkFailure()
        }
        controller.refreshBackoffBaseMs = 100
        controller.refreshBackoffCapMs = 100_000
        defer { controller.destroy() }

        let outcome = await controller.refreshAccessToken(cause: "test")
        // `.network` carries the underlying failure so the 401 retry path can
        // rethrow it as `JsBaoNetworkError` (#2367 review) — assert both the
        // case and that the payload survived.
        guard case .network(let underlying) = outcome else {
            return XCTFail("expected .network, got \(outcome)")
        }
        XCTAssertEqual(
            underlying?.urlErrorCode, URLError.Code.notConnectedToInternet.rawValue,
            "the transport failure must reach the caller, not be reduced to a bare case"
        )
        XCTAssertEqual(refreshCalls.value, 1, "the initial refresh ran once")

        let retried = await waitUntil(timeout: 5) { refreshCalls.value >= 2 }
        XCTAssertTrue(
            retried,
            "the deferred refresh must be retried by the scheduler (got \(refreshCalls.value) calls)"
        )
    }

    /// The first deferral reports the BASE delay (JS starts `delayMs` at 0 and
    /// reports `nextDelay` before doubling); the next one reports the doubled
    /// delay.
    func testBackoffDelayStartsAtBaseAndDoubles() async throws {
        let emitter = EventEmitter()
        let recorder = DeferredRecorder()
        let subscription = recordDeferred(on: emitter, into: recorder)
        defer { subscription.cancel() }

        let controller = makeController(emitter: emitter) { _ in
            throw networkFailure()
        }
        controller.refreshBackoffBaseMs = 100
        controller.refreshBackoffCapMs = 100_000
        defer { controller.destroy() }

        _ = await controller.refreshAccessToken(cause: "first")
        let sawSecond = await waitUntil(timeout: 5) { recorder.events.count >= 2 }
        XCTAssertTrue(sawSecond, "the scheduled retry must fail again and emit a second deferral")

        let events = recorder.events
        XCTAssertEqual(events[0].status, "scheduled")
        XCTAssertEqual(events[0].nextAttemptMs, 100, "first deferral reports the base delay")
        XCTAssertEqual(events[1].status, "scheduled")
        XCTAssertEqual(events[1].nextAttemptMs, 200, "the delay doubles on the next deferral")
    }

    /// The "already scheduled" fast path: a second deferral while a retry is
    /// pending re-emits `scheduled` with the CURRENT delay and does not stack
    /// a second timer (which would double the retry rate).
    func testSecondDeferralWhileScheduledDoesNotStackATimer() async throws {
        let emitter = EventEmitter()
        let recorder = DeferredRecorder()
        let subscription = recordDeferred(on: emitter, into: recorder)
        defer { subscription.cancel() }

        let refreshCalls = AtomicCounter()
        let controller = makeController(emitter: emitter) { _ in
            refreshCalls.increment()
            throw networkFailure()
        }
        // Long enough that the first scheduled retry can't fire during the test.
        controller.refreshBackoffBaseMs = 30_000
        controller.refreshBackoffCapMs = 300_000
        defer { controller.destroy() }

        _ = await controller.refreshAccessToken(cause: "first")
        _ = await controller.refreshAccessToken(cause: "second")

        let events = recorder.events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].nextAttemptMs, 30_000, "first deferral schedules the base delay")
        XCTAssertEqual(
            events[1].nextAttemptMs, 60_000,
            "the already-scheduled fast path reports the current (doubled) delay"
        )
        XCTAssertEqual(
            refreshCalls.value, 2,
            "only the two explicit refreshes ran — no retry timer stacked or fired early"
        )
    }

    // MARK: - Cap reached

    /// Once the accumulated backoff would reach the cap, the controller stops
    /// retrying: it resets the backoff, flips the client to offline mode, and
    /// emits `status: "offline"` carrying the error.
    func testAccumulatedBackoffReachingCapGoesOffline() async throws {
        let emitter = EventEmitter()
        let recorder = DeferredRecorder()
        let subscription = recordDeferred(on: emitter, into: recorder)
        defer { subscription.cancel() }

        let requestedModes = ThreadSafeBox<[String]>([])

        let controller = makeController(emitter: emitter) { _ in
            throw networkFailure()
        }
        // base 100, cap 300: accum goes 100 (scheduled) -> 100+200=300 >= cap -> offline.
        controller.refreshBackoffBaseMs = 100
        controller.refreshBackoffCapMs = 300
        // Stand in for `JsBaoClient.setNetworkMode`, which records the mode
        // and mirrors it back into the controller.
        controller.setClientNetworkMode = { [weak controller] mode in
            requestedModes.mutate { $0.append(mode.rawValue) }
            controller?.setNetworkMode(mode)
        }
        defer { controller.destroy() }

        _ = await controller.refreshAccessToken(cause: "first")

        let wentOffline = await waitUntil(timeout: 5) {
            recorder.events.contains { $0.status == "offline" }
        }
        XCTAssertTrue(wentOffline, "reaching the backoff cap must emit status: offline")

        let offlineEvent = recorder.events.first { $0.status == "offline" }
        XCTAssertNotNil(offlineEvent?.error, "the offline deferral carries the failure message")
        XCTAssertEqual(
            requestedModes.value.first,
            NetworkMode.offline.rawValue,
            "the controller asks the client to go offline"
        )
        XCTAssertEqual(controller.getNetworkMode(), .offline)

        // The backoff reset on the cap transition: no retry is pending, so
        // nothing else fires after the offline emit.
        let before = recorder.events.count
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(recorder.events.count, before, "no further retries after going offline")
    }

    /// A deferral while ALREADY offline emits `status: "offline"` and schedules
    /// nothing — retrying a refresh in offline mode is pointless.
    func testDeferralWhileOfflineSchedulesNothing() async throws {
        let emitter = EventEmitter()
        let recorder = DeferredRecorder()
        let subscription = recordDeferred(on: emitter, into: recorder)
        defer { subscription.cancel() }

        let refreshCalls = AtomicCounter()
        let controller = makeController(emitter: emitter) { _ in
            refreshCalls.increment()
            throw networkFailure()
        }
        controller.refreshBackoffBaseMs = 100
        controller.refreshBackoffCapMs = 100_000
        controller.setNetworkMode(.offline)
        defer { controller.destroy() }

        _ = await controller.refreshAccessToken(cause: "first")

        XCTAssertEqual(recorder.events.count, 1)
        XCTAssertEqual(recorder.events[0].status, "offline")
        XCTAssertNil(recorder.events[0].nextAttemptMs, "offline deferrals promise no next attempt")

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(refreshCalls.value, 1, "no retry scheduled while offline")
    }

    // MARK: - Reset

    /// A successful refresh clears the pending retry and the accumulated
    /// backoff, so the next failure starts again at the base delay.
    func testSuccessfulRefreshResetsTimerAndBackoff() async throws {
        let emitter = EventEmitter()
        let recorder = DeferredRecorder()
        let subscription = recordDeferred(on: emitter, into: recorder)
        defer { subscription.cancel() }

        let token = makeJwt(userId: "u1")
        let shouldFail = AtomicFlag(true)
        let controller = makeController(emitter: emitter) { _ in
            if shouldFail.value { throw networkFailure() }
            return jsonResponse("{\"token\": \"\(token)\"}")
        }
        controller.refreshBackoffBaseMs = 30_000
        controller.refreshBackoffCapMs = 300_000
        defer { controller.destroy() }

        _ = await controller.refreshAccessToken(cause: "first")
        XCTAssertEqual(recorder.events.first?.nextAttemptMs, 30_000)

        shouldFail.value = false
        let outcome = await controller.refreshAccessToken(cause: "recovered")
        XCTAssertEqual(outcome, .success)

        // Backoff is back to zero: the next failure reports the base delay again.
        shouldFail.value = true
        _ = await controller.refreshAccessToken(cause: "after-success")
        XCTAssertEqual(
            recorder.events.last?.nextAttemptMs, 30_000,
            "a successful refresh resets the backoff to the base delay"
        )
    }

    /// An invalid (401/403) refresh also resets the timer and the backoff —
    /// backing off is only meaningful for connectivity failures.
    func testInvalidRefreshResetsTimerAndBackoff() async throws {
        let emitter = EventEmitter()
        let recorder = DeferredRecorder()
        let subscription = recordDeferred(on: emitter, into: recorder)
        defer { subscription.cancel() }

        let refreshCalls = AtomicCounter()
        let invalid = AtomicFlag(false)
        let controller = makeController(emitter: emitter) { _ in
            refreshCalls.increment()
            if invalid.value {
                return jsonResponse("{\"error\": \"expired\"}", status: 401)
            }
            throw networkFailure()
        }
        controller.refreshBackoffBaseMs = 100
        controller.refreshBackoffCapMs = 100_000
        defer { controller.destroy() }

        _ = await controller.refreshAccessToken(cause: "first")
        invalid.value = true

        let outcome = await controller.refreshAccessToken(cause: "invalid")
        XCTAssertEqual(outcome, .invalid)

        let callsAfterInvalid = refreshCalls.value
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(
            refreshCalls.value, callsAfterInvalid,
            "the pending retry is cancelled once the refresh comes back invalid"
        )

        invalid.value = false
        _ = await controller.refreshAccessToken(cause: "after-invalid")
        XCTAssertEqual(
            recorder.events.last?.nextAttemptMs, 100,
            "the backoff restarts at the base delay after an invalid refresh"
        )
    }

    /// `bootstrapToken` / `updateToken` reset the scheduler — a token arriving
    /// from any path means the deferred refresh is moot.
    func testTokenUpdateResetsTimerAndBackoff() async throws {
        let emitter = EventEmitter()
        let recorder = DeferredRecorder()
        let subscription = recordDeferred(on: emitter, into: recorder)
        defer { subscription.cancel() }

        let refreshCalls = AtomicCounter()
        let controller = makeController(emitter: emitter) { _ in
            refreshCalls.increment()
            throw networkFailure()
        }
        controller.refreshBackoffBaseMs = 100
        controller.refreshBackoffCapMs = 100_000
        defer { controller.destroy() }

        _ = await controller.refreshAccessToken(cause: "first")
        controller.updateToken(makeJwt(userId: "u1"), cause: "magicLinkVerify")

        let callsAfterUpdate = refreshCalls.value
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(
            refreshCalls.value, callsAfterUpdate,
            "the pending retry is cancelled once a fresh token is applied"
        )

        _ = await controller.refreshAccessToken(cause: "after-update")
        XCTAssertEqual(
            recorder.events.last?.nextAttemptMs, 100,
            "the backoff restarts at the base delay after a token update"
        )
    }

    /// `destroy()` cancels the pending retry so no refresh fires after the
    /// client is torn down.
    func testDestroyCancelsPendingRetry() async throws {
        let refreshCalls = AtomicCounter()
        let controller = makeController { _ in
            refreshCalls.increment()
            throw networkFailure()
        }
        controller.refreshBackoffBaseMs = 300
        controller.refreshBackoffCapMs = 100_000

        _ = await controller.refreshAccessToken(cause: "first")
        XCTAssertEqual(refreshCalls.value, 1)

        controller.destroy()

        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(
            refreshCalls.value, 1,
            "no retry may fire after destroy()"
        )
    }

    /// The destroy race: cancelling the retry Task that exists at teardown is
    /// not enough on its own. A refresh that was ALREADY in flight when
    /// `destroy()` ran can fail with a network error afterwards, and must not
    /// schedule a replacement retry against the torn-down client.
    func testDestroyDuringInFlightRefreshDoesNotScheduleARetry() async throws {
        let emitter = EventEmitter()
        let recorder = DeferredRecorder()
        let subscription = recordDeferred(on: emitter, into: recorder)
        defer { subscription.cancel() }

        let refreshCalls = AtomicCounter()
        let requestStarted = AtomicFlag(false)
        let releaseRequest = AtomicFlag(false)

        let controller = makeController(emitter: emitter) { _ in
            refreshCalls.increment()
            requestStarted.value = true
            // Stay in flight until the test has torn the controller down, so
            // the failure lands strictly after destroy().
            while !releaseRequest.value {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            throw networkFailure()
        }
        controller.refreshBackoffBaseMs = 50
        controller.refreshBackoffCapMs = 100_000

        let inFlight = Task { await controller.refreshAccessToken(cause: "in-flight") }

        let started = await waitUntil(timeout: 5) { requestStarted.value }
        XCTAssertTrue(started, "the refresh must be in flight before destroy()")

        controller.destroy()
        releaseRequest.value = true

        let outcome = await inFlight.value
        guard case .network = outcome else {
            return XCTFail("expected .network, got \(outcome)")
        }

        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(
            refreshCalls.value, 1,
            "a refresh that failed after destroy() must not schedule a retry"
        )
        XCTAssertTrue(
            recorder.events.isEmpty,
            "no authRefreshDeferred may be emitted after destroy() (got \(recorder.events))"
        )
    }

    /// A very short delay lets the retry Task finish before the scheduling
    /// call returns. The "already scheduled" bookkeeping must still clear, or
    /// the controller would never schedule another retry.
    func testFastRetryDoesNotLeavePermanentlyScheduledState() async throws {
        let refreshCalls = AtomicCounter()
        let controller = makeController { _ in
            refreshCalls.increment()
            throw networkFailure()
        }
        controller.refreshBackoffBaseMs = 1
        controller.refreshBackoffCapMs = 100_000
        defer { controller.destroy() }

        _ = await controller.refreshAccessToken(cause: "first")

        // Retries chain: 1ms, 2ms, 4ms, ... — several must land quickly.
        let chained = await waitUntil(timeout: 5) { refreshCalls.value >= 4 }
        XCTAssertTrue(
            chained,
            "successive retries must keep scheduling (got \(refreshCalls.value) calls)"
        )
    }
}

/// Minimal thread-safe boolean used by the tests above to flip the injected
/// request behavior mid-test.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    init(_ value: Bool) { _value = value }
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
