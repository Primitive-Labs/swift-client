import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// #1913 — the client's own implementation must keep honoring the deprecated
/// `QueryOptions.offset` pagination and the deprecated `.remoteUpdate` event
/// during their deprecation windows, without tripping the public deprecations
/// on itself. These tests are the behavioral guards for that internal use.
///
/// Every test here references a deprecated symbol (`QueryOptions(offset:)`,
/// `.remoteUpdate`, `JsBaoEvent.remoteUpdate.rawValue`), which would itself
/// emit a deprecation warning from ordinary test code. Each method is marked
/// `@available(*, deprecated)` so the reference sits inside a deprecated
/// context — Swift suppresses the diagnostic there. This keeps `swift build`
/// / `swift test` output warning-free, which the deploy acceptance greps for.
/// XCTest still discovers and runs deprecated test methods (they are exposed
/// to the runtime, not referenced by name), so coverage is unaffected.
final class DeprecationWindowInternalUseTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "dep_items",
        fields: [
            "id":   FieldDescriptor(type: .id),
            "rank": FieldDescriptor(type: .number),
        ]
    )

    /// 5 items with ids p1–p5 for offset-slicing assertions.
    private func seeded() throws -> DynamicModel {
        SchemaSync.clearCache()
        let model = DynamicModel(doc: YDocument(), schema: schema)
        for i in 1...5 {
            _ = try model.create(id: "p\(i)", values: ["rank": .number(Double(i))])
        }
        return model
    }

    // MARK: - Behavior 3: offset pagination unchanged

    /// Offset-based pagination is behaviorally unchanged after the split into
    /// internal `offsetForQuery` storage + deprecated `offset` accessor: a
    /// query with `offset: 2` (sorted by id, paired with a limit as SQLite
    /// requires) still skips the first two rows and returns p3, p4, p5.
    @available(*, deprecated, message: "Deprecated context: exercises the deprecated QueryOptions(offset:) on purpose (#1913).")
    func testOffsetPaginationBehaviorUnchanged() throws {
        let model = try seeded()
        let rows = try model.query(
            nil,
            options: QueryOptions(sort: ["id": 1], limit: 10, offset: 2)
        )
        XCTAssertEqual(
            rows.map { $0["id"] as? String },
            ["p3", "p4", "p5"],
            "offset: 2 should skip the first two rows and return the rest in id order"
        )
    }

    /// The deprecated `offset` setter and the internal `offsetForQuery`
    /// storage stay in sync: mutating `.offset` after construction is what the
    /// engine reads, so post-construction offset mutation still slices rows.
    @available(*, deprecated, message: "Deprecated context: exercises the deprecated QueryOptions.offset setter on purpose (#1913).")
    func testOffsetSetterFeedsInternalStorage() throws {
        let model = try seeded()
        var opts = QueryOptions(sort: ["id": 1], limit: 10)
        opts.offset = 3
        XCTAssertEqual(opts.offsetForQuery, 3,
                       "the deprecated offset setter must write internal offsetForQuery")
        let rows = try model.query(nil, options: opts)
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["p4", "p5"])
    }

    // MARK: - Behavior 4 + on/onAny edge: raw-key emit reaches subscribers

    /// The client emits `.remoteUpdate` internally by resolving the event from
    /// its raw key (`JsBaoClient.remoteUpdateRawKey`) rather than naming the
    /// deprecated case. Subscribers registered under the deprecated case — via
    /// both `on` (typed) and `onAny` (raw payload) — must still fire, because
    /// the emitter dispatches by `rawValue` and the raw key equals the case's
    /// raw value.
    @available(*, deprecated, message: "Deprecated context: subscribes to the deprecated .remoteUpdate case on purpose (#1913).")
    func testRemoteUpdateRawKeyReachesTypedAndRawSubscribers() throws {
        let emitter = EventEmitter()

        let typedHits = ThreadSafeBox<[String]>([])
        let rawHits = ThreadSafeBox<Int>(0)

        let typedSub = emitter.on(.remoteUpdate) { (e: RemoteUpdateEvent) in
            typedHits.mutate { $0.append(e.documentId) }
        }
        defer { typedSub.cancel() }
        let rawSub = emitter.onAny(.remoteUpdate) { _ in
            rawHits.mutate { $0 += 1 }
        }
        defer { rawSub.cancel() }

        // Emit the way the client does: look the event up by the raw key
        // instead of naming the deprecated case.
        let event = JsBaoEvent(rawValue: JsBaoClient.remoteUpdateRawKey)!
        emitter.emit(event, RemoteUpdateEvent(documentId: "doc-1"))

        XCTAssertEqual(typedHits.value, ["doc-1"],
                       "typed on(.remoteUpdate) subscriber must fire from a raw-key emit")
        XCTAssertEqual(rawHits.value, 1,
                       "onAny(.remoteUpdate) subscriber must fire from a raw-key emit")
    }

    // MARK: - Behavior 6: drift guard

    /// The internal raw key used to emit `.remoteUpdate` must equal the
    /// deprecated case's `rawValue`. If someone renamed the case's raw value,
    /// the internal emit and public subscription would land on different keys
    /// and silently stop delivering — this guard fails the build instead.
    @available(*, deprecated, message: "Deprecated context: reads JsBaoEvent.remoteUpdate.rawValue on purpose (#1913).")
    func testRemoteUpdateRawKeyDriftGuard() {
        XCTAssertEqual(
            JsBaoClient.remoteUpdateRawKey,
            JsBaoEvent.remoteUpdate.rawValue,
            "remoteUpdateRawKey must stay tied to JsBaoEvent.remoteUpdate.rawValue"
        )
        // #1994 moved the escape hatch into the payload's own `eventKey`, so the
        // typed emit resolves the same key without naming the case.
        XCTAssertEqual(
            RemoteUpdateEvent.eventKey.rawValue,
            JsBaoEvent.remoteUpdate.rawValue,
            "RemoteUpdateEvent.eventKey must resolve to the deprecated case"
        )
    }

    // MARK: - #1994: the untyped event surface stays functional for one release

    /// `client.events` still returns the live registry, so an app that has not
    /// migrated to `client.stream(for:)` keeps working for the whole window.
    @available(*, deprecated, message: "Deprecated context: reads the deprecated client.events property on purpose (#1994).")
    func testDeprecatedEventsPropertyStillReturnsTheLiveRegistry() {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "test-app",
            token: "test-token",
            offline: false,
            logLevel: .error,
            storageConfig: .memory,
            autoNetwork: false
        ))
        XCTAssertTrue(
            client.events === client.eventEmitter,
            "client.events must still hand back the same registry the client emits on"
        )

        let received = ThreadSafeBox<[ConnectionStatus]>([])
        let sub = client.events.on(.status) { (event: StatusChangedEvent) in
            received.mutate { $0.append(event.status) }
        }
        defer { sub.cancel() }

        client.eventEmitter.emit(StatusChangedEvent(status: .connected))
        XCTAssertEqual(received.value, [.connected],
                       "a handler registered through client.events must still fire")
    }

    /// The deprecated `on` handlers still fire synchronously inside `emit`, in
    /// registration order — the delivery contract every existing consumer was
    /// written against. Sharing one registry with the streams (rather than
    /// wrapping `on` in a `Task`) is what preserves it.
    @available(*, deprecated, message: "Deprecated context: exercises the `on` shim on purpose (#1994).")
    func testDeprecatedOnKeepsSynchronousRegistrationOrderDelivery() {
        let emitter = EventEmitter()
        let order = ThreadSafeBox<[String]>([])

        let first = emitter.on(.documentClosed) { (_: DocumentClosedEvent) in
            order.mutate { $0.append("first") }
        }
        let second = emitter.on(.documentClosed) { (_: DocumentClosedEvent) in
            order.mutate { $0.append("second") }
        }
        let third = emitter.onAny(.documentClosed) { _ in
            order.mutate { $0.append("third") }
        }
        defer {
            first.cancel()
            second.cancel()
            third.cancel()
        }

        emitter.emit(DocumentClosedEvent(documentId: "d1"))
        // Asserted immediately after `emit` returns, with no awaiting: if
        // delivery had become asynchronous this would still be empty.
        XCTAssertEqual(order.value, ["first", "second", "third"],
                       "callbacks must fire synchronously inside emit, in registration order")
    }

    /// The deprecated untyped `emit(_:_:)` still reaches subscribers, including
    /// stream consumers on the same key — an app that emits its own events
    /// through the old surface keeps working.
    @available(*, deprecated, message: "Deprecated context: exercises the untyped emit on purpose (#1994).")
    func testDeprecatedUntypedEmitStillReachesSubscribers() async {
        let emitter = EventEmitter()
        let stream = emitter.makeStream(
            for: DocumentClosedEvent.self,
            buffering: .unbounded,
            replayingLatest: false
        )
        var iterator = stream.makeAsyncIterator()

        emitter.emit(.documentClosed, DocumentClosedEvent(documentId: "from-untyped-emit"))

        let event = await iterator.next()
        XCTAssertEqual(event?.documentId, "from-untyped-emit",
                       "the untyped emit must still fan out to stream consumers")
    }

    /// The deprecated free `waitForEvent` still resolves and still times out with
    /// `.unavailable` — it now shares `nextEvent`'s resume-once machinery, so this
    /// is the guard that the shared path did not change its behavior.
    @available(*, deprecated, message: "Deprecated context: exercises the free waitForEvent on purpose (#1994).")
    func testDeprecatedWaitForEventStillResolvesAndTimesOut() async throws {
        let emitter = EventEmitter()

        let waiter = Task { try await waitForEvent(emitter: emitter, event: .documentClosed, timeout: 5) }
        // Let the wait register before emitting.
        while emitter.activeHandlerCount == 0 {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        emitter.emit(DocumentClosedEvent(documentId: "d1"))

        let payload = try await waiter.value
        XCTAssertEqual((payload as? DocumentClosedEvent)?.documentId, "d1")

        do {
            _ = try await waitForEvent(emitter: emitter, event: .documentOpened, timeout: 0.2)
            XCTFail("expected a timeout")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .unavailable)
        }
    }

    /// `KvCache`'s deprecated untyped emit closure is still honored, adapted onto
    /// the typed one — the cache keeps firing `cacheUpdated` for a caller that
    /// injected the old closure shape.
    ///
    /// Supplied through `init(emit:)` since #1993 Phase D2: `KvCache` is an
    /// actor now, so `setEmitter` (a synchronous mutation of actor state) is
    /// gone and construction is the only place the emitter is attached. The
    /// deprecated *untyped* closure shape this test guards is unaffected.
    @available(*, deprecated, message: "Deprecated context: uses the untyped KvCache emit closure on purpose (#1994).")
    func testDeprecatedKvCacheEmitClosureStillReceivesEvents() async {
        let seen = ThreadSafeBox<[String]>([])
        let cache = KvCache(emit: { (event: JsBaoEvent, _: Any) in
            seen.mutate { $0.append(event.rawValue) }
        } as @Sendable (JsBaoEvent, Any) -> Void)

        // Drive the adapter directly: the untyped closure must receive the key
        // derived from the typed payload.
        await cache.emitForTesting(CacheUpdatedEvent(key: "k", updatedAt: "2026-01-01", value: 1))
        XCTAssertEqual(seen.value, [JsBaoEvent.cacheUpdated.rawValue],
                       "the untyped emit closure must still receive the event, keyed from the payload type")
    }

    // MARK: - #1993 Phase D3: the deprecated synchronous analytics surface

    /// Fork 1 Option C's whole promise: a caller that cannot add an `await` —
    /// one in a synchronous context — keeps working for the deprecation window.
    /// The event reaches the buffer with the overrides in force; it just gets
    /// there on an unstructured task rather than on the caller's, which is why
    /// this polls instead of asserting straight after the call.
    ///
    /// The override is applied through the **awaited** twin on purpose (review
    /// of PR #2266). `AnalyticsAPI`'s own header states that two consecutive
    /// deprecated calls are not ordered against each other — each spawns its own
    /// unstructured task — so asserting that a synchronous `setPlanOverride`
    /// lands before a synchronous `logEvent` would be pinning the opposite of
    /// the documented contract, and would go red under a scheduling change
    /// rather than a regression. Awaiting the override first makes the
    /// precondition deterministic while still driving the deprecated members
    /// this test exists for.
    @available(*, deprecated, message: "Deprecated context: exercises the synchronous analytics surface on purpose (#1993).")
    func testDeprecatedSynchronousAnalyticsSurfaceStillBuffersEvents() async throws {
        let queue = AnalyticsQueue(logger: Logger(level: .none, scope: "deprecation-window"))
        let api = AnalyticsAPI(queue: queue, resolveUserUlid: { "user-1" })

        await api.setPlanOverrideAsync("pro")
        api.logEvent(AnalyticsEventInput(action: "click", feature: "cta"))
        api.logSnapshot(context: .object(["screen": .string("home")]))

        var buffered: [[String: JSONValue]] = []
        for _ in 0..<100 where buffered.count < 2 {
            try await Task.sleep(nanoseconds: 20_000_000)
            buffered = await queue.bufferedEvents
        }

        let actions = buffered.compactMap { $0["action"]?.stringValue }
        XCTAssertTrue(actions.contains("click"), "the deprecated logEvent must still buffer, got \(actions)")
        XCTAssertTrue(actions.contains("_snapshot"), "the deprecated logSnapshot must still buffer, got \(actions)")
        XCTAssertTrue(
            buffered.allSatisfy { $0["plan"] == .string("pro") },
            "an override in force before the call must reach every deprecated-path event"
        )
    }

    /// The ordering the deprecation window *does* promise, which had no test:
    /// the `Async` twins do their work on the caller's task, so an event logged
    /// immediately before a flush is in **that** batch. This is the guarantee
    /// the deprecated members explicitly do not give (their doc says an event
    /// logged just before a `flush()` may miss it and go out with the next
    /// one), so a change that made the twins unordered would otherwise be
    /// invisible.
    func testAsyncTwinsAreOrderedAgainstEachOther() async throws {
        let sent = ThreadSafeBox<[String]>([])
        let queue = AnalyticsQueue(
            logger: Logger(level: .none, scope: "deprecation-window"),
            sendMessage: { message in sent.mutate { $0.append(message) } },
            getConnectionId: { "conn-1" }
        )
        let api = AnalyticsAPI(queue: queue, resolveUserUlid: { "user-1" })

        await api.setPlanOverrideAsync("pro")
        await api.logEventAsync(AnalyticsEventInput(action: "ordered", feature: "cta"))
        await api.flushAsync()

        let batches = sent.value.joined(separator: "\n")
        XCTAssertTrue(batches.contains("\"ordered\""),
                      "an awaited event must be in the batch the next awaited flush sends, got \(batches)")
        XCTAssertTrue(batches.contains("\"pro\""),
                      "and it must carry the override awaited before it")
        let leftOver = await queue.bufferedEvents
        XCTAssertTrue(leftOver.isEmpty, "the awaited flush must have drained the buffer")
    }

    /// The deprecated top-level `JsBaoClient` members forward to the same
    /// place, on the untyped shape an existing app is most likely to be on.
    ///
    /// This drives the real facade members on a real client (constructed
    /// against an unreachable URL, so it never touches the network) rather than
    /// re-performing the two steps `logAnalyticsEvent` does internally. The
    /// earlier version did the latter, which meant it would still have passed
    /// if the deprecated member itself had been deleted (#1993 Phase D4).
    @available(*, deprecated, message: "Deprecated context: exercises the synchronous analytics surface on purpose (#1993).")
    func testDeprecatedSynchronousUntypedLogStillBuffers() async throws {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "test-app",
            token: "test-token",
            offline: false,
            logLevel: .error,
            storageConfig: .memory,
            autoNetwork: false
        ))

        // A synchronous call — which is the whole point of the window.
        client.logAnalyticsEvent([
            "action": "legacy_click", "feature": "cta", "count": 2,
        ])

        // Filtered by action because the client logs its own lifecycle events;
        // the deprecated path defers the ingest to an unstructured task, so this
        // polls rather than asserting straight after the call.
        var buffered: [[String: JSONValue]] = []
        for _ in 0..<100 where buffered.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
            buffered = await client.analyticsQueue.bufferedEvents
                .filter { $0["action"] == .string("legacy_click") }
        }
        XCTAssertEqual(buffered.first?["action"], .string("legacy_click"))
        XCTAssertEqual(buffered.first?["count"], .number(2))
        XCTAssertEqual(buffered.first?["feature"], .string("cta"))
    }
}
