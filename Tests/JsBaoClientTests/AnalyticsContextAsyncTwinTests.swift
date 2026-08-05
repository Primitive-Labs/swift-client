import XCTest
@testable import JsBaoClient

/// #2244 Phase 3 — the analytics surface's remaining deprecation gaps
/// (consolidated from #2272).
///
/// Phase D3 of #1993 gave nine analytics members an `Async` twin and a
/// deprecation, but three entry points were rewired to the actor as
/// fire-and-forget with neither: `AnalyticsContext.logEvent` and the
/// `logAnalytics` closures handed to `LlmAPI` / `GeminiAPI`. This suite covers
/// the twin, the fallback, and the closures' call-site timestamp.
///
/// Server-free: the client is built with `autoNetwork: false` against an
/// unreachable URL, and nothing here connects.
final class AnalyticsContextAsyncTwinTests: XCTestCase {

    private func makeClient() -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "test-app",
            token: "test-token",
            offline: false,
            logLevel: .error,
            storageConfig: .memory,
            autoNetwork: false
        ))
    }

    /// Thread-safe capture box for `setOnEventLogged`.
    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [[String: JSONValue]] = []
        func append(_ e: [String: JSONValue]) { lock.withLock { events.append(e) } }
        var all: [[String: JSONValue]] { lock.withLock { events } }
        var count: Int { lock.withLock { events.count } }
    }

    // MARK: - Behavior 10: the twin returns only after the event is buffered

    /// `await ctx.logEventAsync(...)` returns with the event already through
    /// `ingest` — the property the synchronous member cannot offer, and the
    /// reason the deprecation window exists.
    func testLogEventAsyncReturnsOnlyAfterTheEventIsBuffered() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }
        let box = EventBox()
        await client.analyticsQueue.setOnEventLogged { box.append($0) }

        let context = try XCTUnwrap(client.getLlmAnalyticsContext())
        await context.logEventAsync(["action": "awaited", "feature": "llm"])

        XCTAssertEqual(
            box.count, 1,
            "the event must already be buffered when the await returns — no polling needed"
        )
        XCTAssertEqual(box.all.first?["action"]?.stringValue, "awaited")
    }

    /// The Gemini handle is the same shape — both accessors hand out the
    /// context built by `makeAnalyticsContext()`.
    func testGeminiContextHasTheSameTwin() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }
        let box = EventBox()
        await client.analyticsQueue.setOnEventLogged { box.append($0) }

        let context = try XCTUnwrap(client.getGeminiAnalyticsContext())
        await context.logEventAsync(["action": "gemini-awaited"])

        XCTAssertEqual(box.count, 1)
    }

    /// An event that is not JSON-representable is dropped by `prepared(_:)` on
    /// the caller's thread — logged, not silent — and the await still returns.
    func testUnrepresentableEventIsDroppedRatherThanBuffered() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }
        let box = EventBox()
        await client.analyticsQueue.setOnEventLogged { box.append($0) }

        let context = try XCTUnwrap(client.getLlmAnalyticsContext())
        await context.logEventAsync(["action": "bad", "payload": OpaqueValue()])

        XCTAssertEqual(box.count, 0, "a non-JSON-representable event is dropped by prepared(_:)")
    }

    // MARK: - Behavior 11: the synchronous member survives the window

    /// The deprecated member still logs. It just does not say when — the
    /// enqueue is an unstructured task, so the assertion polls.
    @available(*, deprecated, message: "Deprecated context: exercises the deprecated AnalyticsContext.logEvent on purpose (#2244).")
    func testDeprecatedSynchronousLogEventStillWorks() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }
        let box = EventBox()
        await client.analyticsQueue.setOnEventLogged { box.append($0) }

        let context = try XCTUnwrap(client.getLlmAnalyticsContext())
        context.logEvent(["action": "sync-still-works"])

        let deadline = Date().addingTimeInterval(5)
        while box.count == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(box.all.first?["action"]?.stringValue, "sync-still-works")
    }

    /// The deprecation message points at the twin by name — that is the whole
    /// migration instruction a caller gets from the compiler.
    func testDeprecationMessageNamesTheTwin() throws {
        let source = try ClientSourceText.clientSource("Types/Events.swift")
        let region = try ClientSourceText.slice(
            source,
            from: "public final class AnalyticsContext",
            to: "public func logEventAsync"
        )
        let deprecation = try XCTUnwrap(
            region.split(separator: "\n").first { $0.contains("@available(*, deprecated") },
            "AnalyticsContext.logEvent must carry a deprecation"
        )
        XCTAssertTrue(
            deprecation.contains("logEventAsync"),
            "the deprecation must name the twin: \(deprecation)"
        )
    }

    // MARK: - Behavior 12: a context built the old way still works

    /// A hand-constructed context with only the synchronous closure keeps
    /// compiling (this call site is the proof) and its `logEventAsync` falls
    /// back to that closure — exactly once, not once per closure.
    func testContextWithoutAnAsyncClosureFallsBackAndLogsOnce() async {
        let calls = AtomicInt()
        let context = AnalyticsContext(logEvent: { _ in calls.increment() })

        await context.logEventAsync(["action": "fallback"])

        XCTAssertEqual(calls.value, 1, "the fallback must call the synchronous closure exactly once")
    }

    /// The async closure, when supplied, is the only one used — a context must
    /// not double-log through both.
    func testContextWithAnAsyncClosureDoesNotAlsoCallTheSyncOne() async {
        let syncCalls = AtomicInt()
        let asyncCalls = AtomicInt()
        let context = AnalyticsContext(
            logEvent: { _ in syncCalls.increment() },
            logEventAsync: { _ in asyncCalls.increment() }
        )

        await context.logEventAsync(["action": "async-only"])

        XCTAssertEqual(asyncCalls.value, 1)
        XCTAssertEqual(syncCalls.value, 0, "the synchronous closure must not fire as well")
    }

    /// The added parameter is defaulted and sits between the two existing ones,
    /// so both old call shapes still resolve.
    func testExistingConstructionShapesStillCompile() {
        let withPhaseGate = AnalyticsContext(
            logEvent: { _ in },
            isEnabled: { phase in phase == "success" }
        )
        XCTAssertTrue(withPhaseGate.isEnabled("success"))
        XCTAssertFalse(withPhaseGate.isEnabled("start"))

        let trailingClosure = AnalyticsContext { _ in }
        XCTAssertTrue(trailingClosure.isEnabled(), "the trailing-closure form still binds to logEvent")
    }

    // MARK: - Behavior 13: the LLM / Gemini closures stamp at the call site

    /// The defect this fixes: an event handed straight to the actor is stamped
    /// whenever the unstructured task runs, while one lowered with `prepared(_:)`
    /// carries the instant the call site logged it.
    ///
    /// The delay between the two stands in for a busy actor — the point is
    /// which clock the row ends up with, not how the wait was produced.
    func testPreparedOnTheCallersThreadKeepsTheCallSiteTimestamp() async throws {
        let queue = AnalyticsQueue(logger: Logger(level: .none, scope: "2244-test"))
        let box = EventBox()
        await queue.setOnEventLogged { box.append($0) }
        let formatter = ISO8601DateFormatter()

        // The fixed path: lower on the caller's thread, hand over later. The
        // gap is seconds rather than milliseconds because the row's
        // `timestamp` is ISO-8601 at whole-second resolution — anything
        // shorter would not be distinguishable in the recorded value.
        let callSite = Date()
        let prepared = queue.prepared(AnalyticsEventInput(action: "llm_call", feature: "llm"))
        try await Task.sleep(nanoseconds: 2_200_000_000)
        await queue.logEvent(prepared)

        // The old path, for contrast: the actor stamps when it ingests.
        await queue.logEvent(AnalyticsEventInput(action: "actor_stamped", feature: "llm"))

        let rows = box.all
        XCTAssertEqual(rows.count, 2)
        let preparedRow = try XCTUnwrap(rows.first { $0["action"]?.stringValue == "llm_call" })
        let actorRow = try XCTUnwrap(rows.first { $0["action"]?.stringValue == "actor_stamped" })
        let preparedAt = try XCTUnwrap(
            formatter.date(from: try XCTUnwrap(preparedRow["timestamp"]?.stringValue))
        )
        let actorAt = try XCTUnwrap(
            formatter.date(from: try XCTUnwrap(actorRow["timestamp"]?.stringValue))
        )

        XCTAssertLessThan(
            abs(preparedAt.timeIntervalSince(callSite)), 1.1,
            "the prepared row must carry the call-site instant (to the second it records)"
        )
        XCTAssertGreaterThanOrEqual(
            actorAt.timeIntervalSince(preparedAt), 1.0,
            "the un-prepared row is stamped when the actor ingests it — the behavior being fixed"
        )
    }

    /// And the client's LLM / Gemini wiring takes that fixed path: `prepared`
    /// is called before the `Task`, not inside it.
    func testLlmAndGeminiClosuresPrepareBeforeHandingOver() throws {
        let source = try ClientSourceText.code("JsBaoClient.swift")
        for api in ["llm = LlmAPI(", "gemini = GeminiAPI("] {
            let region = try ClientSourceText.slice(source, from: api, to: "        )")
            XCTAssertTrue(
                region.contains("let prepared = analyticsQueue.prepared(event)"),
                "\(api) must lower the event on the caller's thread"
            )
            XCTAssertTrue(
                region.contains("Task { await analyticsQueue.logEvent(prepared) }"),
                "\(api) must hand the prepared row to the actor"
            )
        }
    }
}

/// A value no JSON encoder can represent — the drop path's input.
private final class OpaqueValue {}
